// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title What CarryFollowerVault needs from a market's pool
/// @notice The vault holds every market's positions through this interface only, so a market can run on any hook
///         (or any adapter in front of one) that the vault's owner (the timelock) has approved, including hooks
///         written after the vault was deployed. Keep it small: it is fixed for the vault's life.
///
///         Conventions, for every implementation:
///         - `pool` is the implementation's own id for the market's pool (a Uniswap v4 PoolId for a v4 hook).
///         - Prices are X128 fixed point: raw USDG per raw stock unit, times 2^128.
///         - Tokens go in by `transferFrom(msg.sender)` against the vault's approval, for at most the amounts
///           given, and come out to `msg.sender`. Only the vault (`vault()`) may call the functions that move
///           tokens or change positions.
///         - Lots and shares are the implementation's own units; the vault only stores and passes them back.
///
///         What the vault checks, and what it trusts (round-5 audit). Inflows (`openMarket`, `deposit`) are
///         measured by the vault's balance change. On `withdraw` and `claim` the vault reverts unless at least the
///         reported stock and USDG arrived (it reverts rather than booking less, so a hook that under-pays freezes
///         its own markets' exits loudly instead of letting them leave short). No lender action reads a hook. There is no yield path: a pool keeps
///         its USDG (no Morpho tail, maker Nov 13); only the vault's idle lender USDG earns outside the pools.
///
///         Hard requirements on every implementation (audit each new hook against them):
///         1. `withdraw` and `claim` transfer to the vault, in the same call, at least the stock and USDG they
///            return. Never report more than was sent (the vault reverts if it did).
///         2. `claim` drains: it pays only what accrued since the lot's last claim, and a repeat claim with nothing
///            new returns (0, 0). It must succeed on a lot `withdraw` emptied in the same transaction.
///         3. `withdraw` takes the whole lot (principal and any compounded balance) less a documented floor, and
///            always lets the last lender-matched lot leave in full. A second `withdraw` of a lot returns (0, 0)
///            or reverts.
///         4. `deposit` and `openMarket` take at most the amounts given, send the vault nothing but the unused part
///            of the call's own pull (never tokens the hook held before), and `deposit` reverts if it takes
///            nothing. `openMarket` creates a pool for exactly (`stock`, `usdg`), `stock != usdg`, and returns a
///            pool id this hook never returned before and the seed lot it created; `deposit` returns a fresh lot.
///         5. `mark` is the price the pool's fills centre on and the vault matches and sells at: nonzero for a live
///            pool, and not movable within a transaction by a caller (only by the hook's own bounded, per-block
///            latching). A hook may value a new lot more conservatively than `mark` (fewer shares), never more.
///         6. The pool's tokens stay in the pool: nothing the vault's lots own is lent or deposited elsewhere
///            (anything that could lose or lock them needs a new interface and audit).
///         7. The code and `vault()` never change after approval (no proxy, no admin-settable vault).
///         8. No call back into the vault or the stock queue during any call.
interface ICarryHook {
    /// @notice The vault this implementation serves, checked once, when the hook is approved (requirement 7).
    function vault() external view returns (address);

    /// @notice Create a market's pool for `stock`/`usdg`, seeded with up to `stockIn` and `usdgIn` from the vault.
    ///         `params` is implementation-specific (for CarryStrategy: its `CreateParams`).
    /// @return pool the pool id, `seedLot` the lot the seed became, `seedShares` its shares.
    function openMarket(address stock, address usdg, uint256 stockIn, uint256 usdgIn, bytes calldata params)
        external
        returns (bytes32 pool, uint256 seedLot, uint256 seedShares);

    /// @notice The price the pool values stock at now (its anchor), X128. Deposits, fee splits and the
    ///         lenders' mark all use it.
    function mark(bytes32 pool) external view returns (uint256 priceX128);

    /// @notice Add up to `maxStock` and `maxUsdg` to the pool as a new lot.
    function deposit(bytes32 pool, uint256 maxStock, uint256 maxUsdg) external returns (uint256 lot, uint256 shares);

    /// @notice Take a whole lot out of the pool (less any floor the pool must keep, such as a seed's minimum
    ///         shares). Its unclaimed fees stay claimable with `claim`.
    function withdraw(bytes32 pool, uint256 lot) external returns (uint256 stock, uint256 usdg);

    /// @notice Pay out a lot's fees so far.
    function claim(bytes32 pool, uint256 lot) external returns (uint256 stock, uint256 usdg);

    /// @notice What `shares` of the pool are worth in USDG at `mark` (for the lenders' mark).
    function sharesValue(bytes32 pool, uint256 shares) external view returns (uint256 usdgValue);
}
