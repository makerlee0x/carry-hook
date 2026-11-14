// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CarryStrategy} from "./CarryStrategy.sol";
import {ICarryHook} from "./interfaces/ICarryHook.sol";

/// @title CarryStrategy behind the vault's ICarryHook interface
/// @notice The hook's `carry` is this adapter, and the adapter answers only to one vault. It holds the vault's lots
///         in the hook and passes tokens straight through: whatever it receives goes on to the vault in the same
///         call. Anything sent to it some other way goes to the vault with `flush` or the next withdraw or
///         claim, never inside a deposit (the vault measures a deposit by its balance change). The hook has no
///         Morpho tail (v0.3, maker Nov 13): the pool keeps its USDG (ICarryHook requirement 6). One adapter per (hook, vault) pair. A future hook can implement
///         ICarryHook itself and skip the adapter.
contract CarryStrategyAdapter is ICarryHook {
    using SafeERC20 for IERC20;

    uint256 internal constant Q128 = 1 << 128;
    /// @dev The hook's floor of pool shares (CarryLedger.MIN_SHARES): a seed lot (lot 1) leaves this much behind
    ///      so the pool never drains and the last lender-matched lot can always close in full (audit H-1).
    uint256 internal constant MIN_POOL_SHARES = 1e6;

    CarryStrategy public immutable strategy;
    address public immutable override vault;

    error OnlyVault();
    error BadParams();

    constructor(CarryStrategy strategy_, address vault_) {
        if (address(strategy_) == address(0) || vault_ == address(0)) revert BadParams();
        strategy = strategy_;
        vault = vault_;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    function openMarket(address stock, address usdg, uint256 stockIn, uint256 usdgIn, bytes calldata params)
        external
        onlyVault
        returns (bytes32 pool, uint256 seedLot, uint256 seedShares)
    {
        CarryStrategy.CreateParams memory cp = abi.decode(params, (CarryStrategy.CreateParams));
        if (cp.coin != stock || cp.quote != usdg || cp.coinIn != stockIn || cp.quoteIn != usdgIn) revert BadParams();
        (uint256 s0, uint256 y0) = _held(stock, usdg);
        _pull(stock, usdg, stockIn, usdgIn);
        (, PoolId id) = strategy.createPool(cp);
        _refund(stock, usdg, s0, y0);
        pool = PoolId.unwrap(id);
        seedLot = 1;
        (, seedShares,,,) = strategy.lotState(id, 1);
    }

    function mark(bytes32 pool) external view returns (uint256) {
        return strategy.poolState(PoolId.wrap(pool)).anchorX128;
    }

    function deposit(bytes32 pool, uint256 maxStock, uint256 maxUsdg)
        external
        onlyVault
        returns (uint256 lot, uint256 shares)
    {
        (address stock, address usdg) = _tokens(pool);
        (uint256 s0, uint256 y0) = _held(stock, usdg);
        _pull(stock, usdg, maxStock, maxUsdg);
        (lot, shares) = strategy.deposit(PoolId.wrap(pool), maxStock, maxUsdg);
        _refund(stock, usdg, s0, y0);
    }

    function withdraw(bytes32 pool, uint256 lot) external onlyVault returns (uint256 x, uint256 y) {
        PoolId id = PoolId.wrap(pool);
        (, uint256 principal,,,) = strategy.lotState(id, lot);
        if (lot == 1) principal = principal > MIN_POOL_SHARES ? principal - MIN_POOL_SHARES : 0;
        (x, y) = strategy.withdraw(id, lot, principal, 0);
        _flushPool(pool);
    }

    function claim(bytes32 pool, uint256 lot) external onlyVault returns (uint256 x, uint256 y) {
        (x, y) = strategy.claim(PoolId.wrap(pool), lot);
        _flushPool(pool);
    }

    function sharesValue(bytes32 pool, uint256 shares) external view returns (uint256) {
        CarryStrategy.PoolView memory v = strategy.poolState(PoolId.wrap(pool));
        uint256 st = v.principal + v.compounded;
        if (st == 0) return 0;
        return Math.mulDiv(shares, Math.mulDiv(v.coinReserve, v.anchorX128, Q128) + v.quoteReserve, st);
    }

    /// @notice Send anything this adapter holds of a pool's tokens to the vault (anyone).
    function flush(bytes32 pool) external {
        _flushPool(pool);
    }

    function _tokens(bytes32 pool) internal view returns (address stock, address usdg) {
        CarryStrategy.PoolView memory v = strategy.poolState(PoolId.wrap(pool));
        return (v.coin, v.quote);
    }

    function _pull(address stock, address usdg, uint256 s, uint256 y) internal {
        if (s != 0) IERC20(stock).safeTransferFrom(vault, address(this), s);
        if (y != 0) IERC20(usdg).safeTransferFrom(vault, address(this), y);
        IERC20(stock).forceApprove(address(strategy), s);
        IERC20(usdg).forceApprove(address(strategy), y);
    }

    function _held(address stock, address usdg) internal view returns (uint256, uint256) {
        return (IERC20(stock).balanceOf(address(this)), IERC20(usdg).balanceOf(address(this)));
    }

    /// @dev After a deposit: clear the approvals and send back only what is left of this call's own tokens. The
    ///      vault prices the deposit by its balance change, so tokens the adapter already held (a stray
    ///      transfer) must not ride along and shrink the position's measured USDG; they stay for
    ///      `flush` or the next withdraw or claim.
    function _refund(address stock, address usdg, uint256 s0, uint256 y0) internal {
        IERC20(stock).forceApprove(address(strategy), 0);
        IERC20(usdg).forceApprove(address(strategy), 0);
        (uint256 s, uint256 y) = _held(stock, usdg);
        if (s > s0) IERC20(stock).safeTransfer(vault, s - s0);
        if (y > y0) IERC20(usdg).safeTransfer(vault, y - y0);
    }

    function _flushPool(bytes32 pool) internal {
        (address stock, address usdg) = _tokens(pool);
        _flush(stock, usdg);
    }

    /// @dev Clear the approvals and pass every token held on to the vault.
    function _flush(address stock, address usdg) internal {
        IERC20(stock).forceApprove(address(strategy), 0);
        IERC20(usdg).forceApprove(address(strategy), 0);
        uint256 s = IERC20(stock).balanceOf(address(this));
        uint256 y = IERC20(usdg).balanceOf(address(this));
        if (s != 0) IERC20(stock).safeTransfer(vault, s);
        if (y != 0) IERC20(usdg).safeTransfer(vault, y);
    }
}
