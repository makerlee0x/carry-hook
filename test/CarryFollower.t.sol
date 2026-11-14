// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {_noKey} from "./NoKey.sol";
import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {CarryStrategy} from "../src/CarryStrategy.sol";
import {MockERC20, MockVault, MockVaultNoMax} from "./mocks/Mocks.sol";
import {CarryLens} from "../src/CarryLens.sol";

/// @notice A v2 pair whose reserves the test sets (the leader).
contract MockPair {
    uint112 public r0;
    uint112 public r1;
    address public token0;
    address public token1;

    function set(uint112 a, uint112 b) external {
        r0 = a;
        r1 = b;
    }

    function setTokens(address t0, address t1) external {
        (token0, token1) = (t0, t1);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (r0, r1, 0);
    }
}

/// @notice Stand-in for Arbitrum's ArbGasInfo precompile (0x6c): a fixed L1 data fee for the transaction.
contract MockArbGasInfo {
    uint256 public fee;

    function set(uint256 f) external {
        fee = f;
    }

    function getCurrentTxL1GasFees() external view returns (uint256) {
        return fee;
    }
}

contract MockV2Factory {
    mapping(address => mapping(address => address)) public getPair;

    function add(address pair) external {
        address t0 = MockPair(pair).token0();
        address t1 = MockPair(pair).token1();
        (getPair[t0][t1], getPair[t1][t0]) = (pair, pair);
    }
}

/// @notice Carry v2 changes to the vendored follower hook: Carry-only LP, fees paid out from launch with the
///         boost line kept, no creator cut, admin fee setter.
contract CarryFollowerTest is Test {
    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );
    uint24 internal constant FEE = 2500; // 0.25%
    uint256 internal constant JAR_CAP = 1e18; // $1 of the 18-decimal test quote

    IPoolManager manager;
    CarryStrategy hook;
    PoolSwapTest swapper;
    MockERC20 usd;
    MockERC20 coin;
    MockPair pair;
    MockV2Factory v2f;
    MockPair refPair;
    address admin = address(0xAD);
    address stranger = address(0xBAD);
    address trader = address(0x7A);

    function setUp() public {
        vm.roll(100);
        vm.warp(1_000_000);
        manager = IPoolManager(address(new PoolManager(address(this))));
        usd = new MockERC20("USD", "USD", 18);
        coin = new MockERC20("COIN", "COIN", 18);
        pair = new MockPair();
        pair.set(1_000_000e18, 2_000_000e18); // 2 quote per coin, coin is token0
        pair.setTokens(address(coin), address(usd));
        v2f = new MockV2Factory();
        v2f.add(address(pair));
        refPair = new MockPair();
        refPair.set(1_000e18, 3_000_000e18);
        CarryStrategy.Config memory cfg = CarryStrategy.Config(10_000, address(usd), 1, address(refPair), bytes32(0), true);
        bytes memory args = abi.encode(manager, address(v2f), address(0), address(0), cfg, admin, JAR_CAP);
        bytes32 salt = _mine(args);
        hook = new CarryStrategy{salt: salt}(
            manager, address(v2f), address(0), address(0), cfg, admin, JAR_CAP
        );
        vm.prank(admin);
        hook.setCarry(address(this));
        swapper = new PoolSwapTest(manager);
        _fund(address(this));
        _fund(stranger);
        _fund(trader);
    }

    function _mine(bytes memory args) internal view returns (bytes32) {
        bytes32 initHash = keccak256(abi.encodePacked(type(CarryStrategy).creationCode, args));
        for (uint256 i = 0; i < 3_000_000; i++) {
            address a = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), initHash))))
            );
            if (uint160(a) & Hooks.ALL_HOOK_MASK == FLAGS) return bytes32(i);
        }
        revert("no salt");
    }

    function _fund(address who) internal {
        usd.mint(who, 1e30);
        coin.mint(who, 1e30);
        vm.startPrank(who);
        usd.approve(address(hook), type(uint256).max);
        coin.approve(address(hook), type(uint256).max);
        usd.approve(address(swapper), type(uint256).max);
        coin.approve(address(swapper), type(uint256).max);
        vm.stopPrank();
    }

    function _params(uint32 eid) internal view returns (CarryStrategy.CreateParams memory cp) {
        cp.coin = address(coin);
        cp.quote = address(usd);
        cp.fee = FEE;
        cp.src.kind = 1; // v2
        cp.src.coinIs0 = true;
        cp.src.target = address(pair);
        cp.src.remoteEid = eid;
        cp.src.push = eid != 0;
        cp.coinIn = 1000e18;
        cp.quoteIn = 2000e18;
        cp.srcKey = _noKey();
        cp.srcKey2 = _noKey();
    }

    function _create() internal returns (PoolKey memory key, PoolId id) {
        (key, id) = hook.createPool(_params(0));
    }

    function _zeroForOne(PoolKey memory key, bool buy) internal view returns (bool) {
        bool coinIs0 = Currency.unwrap(key.currency0) == address(coin);
        return buy ? !coinIs0 : coinIs0;
    }

    function _swap(PoolKey memory key, bool buy, int256 amountSpecified) internal returns (BalanceDelta d) {
        bool zeroForOne = _zeroForOne(key, buy);
        vm.prank(trader);
        d = swapper.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    /// @dev Round trips in one block, then a tiny trade in the next block settles them.
    function _trade(PoolKey memory key, uint256 rounds) internal {
        _nextBlock();
        for (uint256 i = 0; i < rounds; i++) {
            _swap(key, true, -int256(20e18)); // spend 20 quote
            _swap(key, false, -int256(10e18)); // sell 10 coin
        }
        _nextBlock();
        _swap(key, true, -int256(1e15));
        hook.settle(PoolIdLibrary.toId(key)); // v0.3: fees are paid out per epoch (the keeper settles hourly)
    }

    // -----------------------------------------------------------------------------------------

    function test_onlyCarryCreatesAndDeposits() public {
        vm.prank(stranger);
        vm.expectRevert(CarryStrategy.OnlyCarry.selector);
        hook.createPool(_params(0));

        (, PoolId id) = _create();
        _nextBlock();
        vm.prank(stranger);
        vm.expectRevert(CarryStrategy.OnlyCarry.selector);
        hook.deposit(id, 100e18, 200e18);

        (uint256 lot,) = hook.deposit(id, 100e18, 200e18);
        assertEq(lot, 2);
        (address owner,,,,) = hook.lotState(id, lot);
        assertEq(owner, address(this));
    }

    function test_crossChainPoolsRefused() public {
        vm.expectRevert(CarryStrategy.BadParams.selector);
        hook.createPool(_params(30101));
    }

    function test_feesPaidOutFromLaunchNoCreatorCut() public {
        (PoolKey memory key, PoolId id) = _create();
        CarryStrategy.PoolView memory v = hook.poolState(id);
        assertTrue(v.graduated, "graduated at launch");
        assertFalse(v.creatorOn, "no creator cut");

        _trade(key, 3);

        v = hook.poolState(id);
        assertFalse(v.creatorOn, "still no creator cut");
        assertEq(v.compounded, 0, "nothing compounds");
        (,, uint256 comp, uint256 cx, uint256 cy) = hook.lotState(id, 1);
        assertEq(comp, 0);
        assertGt(cx + cy, 0, "fees escrowed for the lot");

        uint256 c0 = coin.balanceOf(address(this));
        uint256 u0 = usd.balanceOf(address(this));
        (uint256 x, uint256 y) = hook.claim(id, 1);
        assertEq(x, cx);
        assertEq(y, cy);
        assertEq(coin.balanceOf(address(this)) - c0, x);
        assertEq(usd.balanceOf(address(this)) - u0, y);
    }

    function test_earlyLotEarnsMoreThanLaterLot() public {
        (PoolKey memory key, PoolId id) = _create(); // lot 1: 1000 coin + 2000 quote
        _nextBlock();
        (uint256 lot2, uint256 sh2) = hook.deposit(id, 1000e18, 2000e18);
        (, uint256 sh1,,,) = hook.lotState(id, 1);
        assertApproxEqRel(sh1, sh2, 0.001e18, "same size");

        _trade(key, 3);

        (,,, uint256 x1, uint256 y1) = hook.lotState(id, 1);
        (,,, uint256 x2, uint256 y2) = hook.lotState(id, lot2);
        uint256 e1 = x1 * 2 + y1;
        uint256 e2 = x2 * 2 + y2;
        assertGt(e2, 0);
        assertGt(e1, e2, "front of the line earns more");
    }

    function test_setFeeOnlyAdminBoundedAndRepricesNextSwap() public {
        (PoolKey memory key, PoolId id) = _create();
        _nextBlock();
        bool zf = _zeroForOne(key, true);
        (, uint256 outLow) = hook.quoteView(id, zf, -int256(20e18));

        vm.expectRevert(CarryStrategy.OnlyAdmin.selector);
        hook.setFeeAndEdge(id, 5000, 23);
        vm.startPrank(admin);
        vm.expectRevert(CarryStrategy.BadParams.selector);
        hook.setFeeAndEdge(id, 0, 23);
        vm.expectRevert(CarryStrategy.BadParams.selector);
        hook.setFeeAndEdge(id, 30_001, 23);
        hook.setFeeAndEdge(id, 30_000, 23);
        vm.stopPrank();

        (, uint256 outHigh) = hook.quoteView(id, zf, -int256(20e18));
        assertLt(outHigh, outLow, "higher fee, fewer coins");
        uint256 c0 = coin.balanceOf(trader);
        _swap(key, true, -int256(20e18));
        assertEq(coin.balanceOf(trader) - c0, outHigh, "swap matches the new quote");
    }

    function test_createRejectsFeeAboveThreePercent() public {
        CarryStrategy.CreateParams memory cp = _params(0);
        cp.fee = 30_001;
        vm.expectRevert(CarryStrategy.BadParams.selector);
        hook.createPool(cp);
    }

    function test_adminHandOverAndSetCarry() public {
        vm.expectRevert(CarryStrategy.OnlyAdmin.selector);
        hook.setCarry(stranger);
        vm.expectRevert(CarryStrategy.OnlyAdmin.selector);
        hook.proposeAdmin(stranger);

        vm.prank(admin);
        hook.proposeAdmin(stranger);
        vm.expectRevert(CarryStrategy.OnlyAdmin.selector);
        hook.acceptAdmin();
        vm.prank(stranger);
        hook.acceptAdmin();
        assertEq(hook.admin(), stranger);
        assertEq(hook.pendingAdmin(), address(0));

        // set once at deploy: not even the new admin can point it elsewhere
        vm.prank(stranger);
        vm.expectRevert(CarryStrategy.BadParams.selector);
        hook.setCarry(trader);
        assertEq(hook.carry(), address(this));
        vm.prank(admin);
        vm.expectRevert(CarryStrategy.OnlyAdmin.selector);
        hook.setCarry(admin);
        vm.prank(stranger);
        vm.expectRevert(CarryStrategy.BadParams.selector);
        hook.setGuardian(address(0));
    }

    function test_constructorNeedsAdmin() public {
        CarryStrategy.Config memory cfg = CarryStrategy.Config(10_000, address(usd), 1, address(refPair), bytes32(0), true);
        vm.expectRevert(CarryStrategy.BadParams.selector);
        new CarryStrategy(manager, address(v2f), address(0), address(0), cfg, address(0), JAR_CAP);
    }

    // -----------------------------------------------------------------------------------------
    // step 2: 50/50 deposits and the leader switch
    // -----------------------------------------------------------------------------------------

    function test_depositIs5050AtAnchorAndKeepsPrice() public {
        (PoolKey memory key, PoolId id) = _create();
        _nextBlock();
        _swap(key, true, -int256(300e18)); // buy: the pool now holds extra quote
        _swap(key, true, -int256(300e18));
        _nextBlock();
        CarryStrategy.PoolView memory v0 = hook.poolState(id);
        assertGt(v0.quoteReserve * 1e18 / v0.coinReserve, 2.2e18, "pool off its 50/50 mix");
        bool zf = _zeroForOne(key, true);
        (, uint256 out0) = hook.quoteView(id, zf, -int256(1e15));

        uint256 c0 = coin.balanceOf(address(this));
        uint256 u0 = usd.balanceOf(address(this));
        (uint256 lot, uint256 shares) = hook.deposit(id, 100e18, 1_000e18);
        uint256 cIn = c0 - coin.balanceOf(address(this));
        uint256 uIn = u0 - usd.balanceOf(address(this));
        CarryStrategy.PoolView memory v1 = hook.poolState(id);
        uint256 m = v1.anchorX128;
        assertEq(cIn, 100e18, "all the coin");
        assertApproxEqAbs(uIn, (cIn * m) >> 128, 1, "equal value of quote at the anchor");

        // shares by value at the anchor
        // the pool's value after the settle the deposit ran (fees left for escrow), before the deposit
        uint256 vPool = (((v1.coinReserve - cIn) * m) >> 128) + v1.quoteReserve - uIn;
        uint256 vIn = ((cIn * m) >> 128) + uIn;
        assertApproxEqRel(shares, v0.principal * vIn / vPool, 1e12);
        assertEq(lot, 2);

        // the quoted price did not move
        (, uint256 out1) = hook.quoteView(id, zf, -int256(1e15));
        assertApproxEqRel(out1, out0, 1e14, "price unchanged by the deposit");
        // the pool kept its imbalance: reserves / centre unchanged
        uint256 r0 = ((v0.quoteReserve << 64) / v0.coinReserve << 64) * 1e18 / v0.tX128;
        uint256 r1 = ((v1.quoteReserve << 64) / v1.coinReserve << 64) * 1e18 / v1.tX128;
        assertApproxEqRel(r1, r0, 1e12, "imbalance against the centre kept");
    }

    function test_depositRefusedWhileRebalancing() public {
        (, PoolId id) = _create();
        _nextBlock();
        pair.set(1_000_000e18, 2_200_000e18); // leader jumps 10%
        _nextBlock();
        hook.sample(id); // takes the new sample (no tip: jar empty)
        _nextBlock();
        vm.expectRevert(CarryStrategy.Rebalancing.selector);
        hook.deposit(id, 100e18, 1_000e18);
    }

    /// round-2 recheck: moving the leader onto the lagging anchor and sampling in the same block cannot pass the gate.
    function test_depositGateUsesAnEarlierBlocksSample() public {
        (, PoolId id) = _create();
        _nextBlock();
        pair.set(1_000_000e18, 2_200_000e18); // leader jumps 10%
        for (uint256 i; i < 3; i++) {
            _nextBlock();
            hook.sample(id); // the anchor walks 1% a block toward 2.2
        }
        _nextBlock();
        uint256 a = hook.poolState(id).anchorX128;
        // the attacker pushes the leader to where this block's anchor will be, samples, and deposits
        pair.set(1_000_000e18, uint112(Math.mulDiv(1_000_000e18 * 101 / 100, a, 1 << 128)));
        hook.sample(id);
        CarryStrategy.PoolView memory v = hook.poolState(id);
        assertApproxEqRel(v.anchorX128, Math.mulDiv(a, 101, 100), 1e15, "anchor stepped onto the pushed spot");
        vm.expectRevert(CarryStrategy.Rebalancing.selector);
        hook.deposit(id, 100e18, 1_000e18);
    }

    /// v0.3: a deposit no longer needs a keeper sample. Inside the 1% gate it goes through on its own, valued at
    /// the worst of the anchor, the live leader and an earlier block's sample, so the lots already in never lose.
    function test_depositNeedsNoKeeperAndIsValuedAtTheWorstPrice() public {
        (, PoolId id) = _create();
        _nextBlock();
        pair.set(1_000_000e18, 2_010_000e18); // leader up 0.5%, nobody samples
        _nextBlock();
        CarryStrategy.PoolView memory v0 = hook.poolState(id);
        (uint256 lot, uint256 sh) = hook.deposit(id, 100e18, 1_000e18);
        assertGt(lot, 1);
        // shares at the anchor (2.0) would be 2x * 2 / (1000 * 2 + 2000) * S; at the leader (2.01) a little fewer
        uint256 st = v0.principal + v0.compounded;
        uint256 atAnchor = Math.mulDiv(400e18, st, 4000e18);
        assertLt(sh, atAnchor, "valued at the worse price for the depositor");
        assertApproxEqRel(sh, atAnchor, 0.005e18);
    }

    function test_setLeaderStepsToTheNewLeader() public {
        (PoolKey memory key, PoolId id) = _create();
        MockPair pair2 = new MockPair();
        pair2.set(1_000_000e18, 2_100_000e18); // 2.1 quote per coin
        pair2.setTokens(address(coin), address(usd));
        v2f.add(address(pair2));
        CarryStrategy.CreateParams memory cp = _params(0);
        cp.src.target = address(pair2);

        vm.expectRevert(CarryStrategy.OnlyAdmin.selector);
        hook.setLeader(id, cp.src, _noKey(), _noKey());

        // a pool of other tokens is refused
        MockERC20 other = new MockERC20("O", "O", 18);
        MockPair bad = new MockPair();
        bad.set(1_000_000e18, 2_100_000e18);
        bad.setTokens(address(other), address(usd));
        v2f.add(address(bad));
        CarryStrategy.Source memory sBad = _params(0).src; // a fresh copy (memory structs are references)
        sBad.target = address(bad);
        vm.prank(admin);
        vm.expectRevert(CarryStrategy.BadParams.selector);
        hook.setLeader(id, sBad, _noKey(), _noKey());

        _nextBlock();
        uint256 a0 = hook.poolState(id).anchorX128;
        vm.prank(admin);
        hook.setLeader(id, cp.src, _noKey(), _noKey());
        assertEq(hook.poolState(id).anchorX128, a0, "no jump at the switch");

        _nextBlock();
        _swap(key, true, -int256(1e15));
        uint256 a1 = hook.poolState(id).anchorX128;
        assertGt(a1, a0, "steps toward the new leader");
        assertLe(a1, a0 * 101 / 100 + 1, "at most one step per block");
        for (uint256 i = 0; i < 8; i++) {
            _nextBlock();
            _swap(key, true, -int256(1e15));
        }
        uint256 a2 = hook.poolState(id).anchorX128;
        uint256 target = (uint256(2_100_000e18) << 128) / 1_000_000e18;
        assertApproxEqRel(a2, target, 1e12, "caught up with the new leader");
    }

    function test_jarFillsAtTwoPercentUpToTheCap() public {
        (PoolKey memory key, PoolId id) = _create();
        _nextBlock();
        _swap(key, true, -int256(20e18));
        _swap(key, false, -int256(10e18));
        // the interval's earnings, as the settle will mark them (at the anchor, 2 quote per coin)
        CarryStrategy.PoolView memory v = hook.poolState(id);
        uint256 earned = (v.coinReserve * 2 + v.quoteReserve) - (1000e18 * 2 + 2000e18);
        _nextBlock();
        hook.settle(id);
        v = hook.poolState(id);
        uint256 jar = v.jarX * 2 + v.jarY;
        assertApproxEqRel(jar, earned * 2 / 100, 0.01e18, "2% of the earnings");

        // a small cap, so the test fills it with a few dozen trades
        uint256 cap = 0.05e18;
        vm.expectRevert(CarryStrategy.OnlyAdmin.selector);
        hook.setTipRule(cap, 10_500, 200, 100);
        vm.prank(admin);
        hook.setTipRule(cap, 10_500, 200, 100);
        assertEq(hook.jarCap(), cap);
        for (uint256 i = 0; i < 40; i++) _trade(key, 3);
        v = hook.poolState(id);
        jar = v.jarX * 2 + v.jarY;
        assertLe(jar, cap + 1e9, "stops at the cap");
        assertGe(jar, cap * 99 / 100, "fills to the cap");
    }

    /// maker's v0.3 notes: the jar skim is quote only, and the curve centre is rescaled so the price is unchanged;
    /// quoteView previews the same rescale (its quote matches the swap that settles).
    function test_jarSkimIsQuoteOnlyAndKeepsThePrice() public {
        (PoolKey memory key, PoolId id) = _create();
        _nextBlock();
        _swap(key, true, -int256(20e18));
        _swap(key, false, -int256(10e18));
        CarryStrategy.PoolView memory v0 = hook.poolState(id);
        _nextBlock();
        vm.warp(block.timestamp + hook.settleEvery()); // no payout for 6 hours: the next swap is the backstop
        (, uint256 out) = hook.quoteView(id, _zeroForOne(key, true), -int256(1e15));
        uint256 c0 = coin.balanceOf(trader);
        _swap(key, true, -int256(1e15)); // pays out the epoch, skimming the jar
        assertEq(coin.balanceOf(trader) - c0, out, "the preview matches the settle");
        CarryStrategy.PoolView memory v1 = hook.poolState(id);
        assertEq(v1.jarX, 0, "no coin in the jar");
        assertGt(v1.jarY, 0, "quote in the jar");
        // reserves against the centre (y / (x * T)) are where they were, up to the tiny settling trade
        uint256 r0 = v0.quoteReserve * 1e18 / (v0.coinReserve * (v0.tX128 >> 64) >> 64);
        uint256 r1 = (v1.quoteReserve - 1e15) * 1e18 / ((v1.coinReserve + out) * (v1.tX128 >> 64) >> 64);
        assertApproxEqRel(r1, r0, 1e12, "the price is unchanged by the skim");
    }

    /// maker's v0.3 notes: a sample tip adds the transaction's L1 data fee (ArbGasInfo), at cost (v0.3 default).
    function test_sampleTipAddsTheL1Fee() public {
        (, PoolId id) = _create();
        hook.fundJar(id, 0, 1e24);
        MockArbGasInfo g = new MockArbGasInfo();
        vm.etch(address(0x6c), address(g).code);
        vm.fee(1 gwei);
        pair.set(1_000_000e18, 2_100_000e18); // the leader moves 5%: the next sample is tipped
        _nextBlock();
        uint256 snap = vm.snapshotState();
        uint256 b0 = usd.balanceOf(stranger);
        vm.prank(stranger, stranger);
        hook.sample(id);
        uint256 noL1 = usd.balanceOf(stranger) - b0;
        assertGt(noL1, 0, "tipped");
        vm.revertToState(snap);
        MockArbGasInfo(address(0x6c)).set(1e13); // 0.00001 ETH of L1 data fee
        b0 = usd.balanceOf(stranger);
        vm.prank(stranger, stranger);
        hook.sample(id);
        uint256 withL1 = usd.balanceOf(stranger) - b0;
        // the reference pool prices 1 ETH at 3,000 quote: 1e13 wei at cost = 0.03 quote more
        assertApproxEqRel(withL1 - noL1, 1e13 * 3000, 0.01e18, "the L1 fee at cost");
    }

    /// maker Nov 11: the tip markup and the jar skim are admin settings within hard bounds.
    function test_tipRuleIsBoundedAndApplies() public {
        vm.expectRevert(CarryStrategy.OnlyAdmin.selector);
        hook.setTipRule(JAR_CAP, 11_000, 300, 100);
        vm.startPrank(admin);
        vm.expectRevert(CarryStrategy.BadParams.selector);
        hook.setTipRule(JAR_CAP, 8_999, 200, 100);
        vm.expectRevert(CarryStrategy.BadParams.selector);
        hook.setTipRule(JAR_CAP, 15_001, 200, 100);
        vm.expectRevert(CarryStrategy.BadParams.selector);
        hook.setTipRule(JAR_CAP, 10_500, 1_001, 100);
        vm.expectRevert(CarryStrategy.BadParams.selector);
        hook.setTipRule(JAR_CAP, 10_500, 200, 9);
        hook.setTipRule(JAR_CAP, 15_000, 0, 100); // cost + 50%, no skim
        vm.stopPrank();
        assertEq(hook.tipBps(), 15_000);
        assertEq(hook.skimBps(), 0);

        (PoolKey memory key, PoolId id) = _create();
        _trade(key, 3);
        assertEq(hook.poolState(id).jarY, 0, "no skim at 0");

        hook.fundJar(id, 0, 1e24);
        MockArbGasInfo g = new MockArbGasInfo();
        vm.etch(address(0x6c), address(g).code);
        vm.fee(1 gwei);
        pair.set(1_000_000e18, 2_100_000e18);
        _nextBlock();
        uint256 snap = vm.snapshotState();
        uint256 b0 = usd.balanceOf(stranger);
        vm.prank(stranger, stranger);
        hook.sample(id);
        uint256 noL1 = usd.balanceOf(stranger) - b0;
        vm.revertToState(snap);
        MockArbGasInfo(address(0x6c)).set(1e13);
        b0 = usd.balanceOf(stranger);
        vm.prank(stranger, stranger);
        hook.sample(id);
        assertApproxEqRel(usd.balanceOf(stranger) - b0 - noL1, 1e13 * 3000 * 150 / 100, 0.01e18, "cost + 50%");
    }

    /// The lens decodes the hook's pool settings (a layout change in the hook fails this test).
    function test_lensMatchesTheHook() public {
        (PoolKey memory key, PoolId id) = _create();
        hook.fundJar(id, 3, 7);
        CarryLens lens = new CarryLens();
        CarryLens.PoolInfo memory i = lens.poolInfo(address(hook), id);
        assertTrue(i.exists && i.live);
        assertEq(i.coinIs0, Currency.unwrap(key.currency0) == address(coin));
        assertEq(i.fee, FEE);
        assertEq(i.coin, address(coin));
        assertEq(i.quote, address(usd));
        assertEq(i.leader.kind, 1);
        assertTrue(i.leader.coinIs0);
        assertEq(i.leader.target, address(pair));
        assertEq(i.leader.kind2, 0);
        assertEq(i.leader.target2, address(0));
        assertEq(i.jarX, 3);
        assertEq(i.jarY, 7);
        vm.prank(admin);
        hook.setFeeAndEdge(id, 30_000, 23);
        assertEq(lens.poolInfo(address(hook), id).fee, 30_000);
        assertFalse(lens.poolInfo(address(hook), PoolId.wrap(bytes32(uint256(1)))).exists);
    }

    function test_hookFitsEip170() public {
        uint256 size = address(hook).code.length;
        emit log_named_uint("CarryStrategy runtime bytes", size);
        assertLe(size, 24_576);
    }


    // -----------------------------------------------------------------------------------------
    // v0.3 settings
    // -----------------------------------------------------------------------------------------

    address guardian = address(0x6A);

    function _createWith(uint16 edgeBps, uint32 lamPpm) internal returns (PoolKey memory key, PoolId id) {
        CarryStrategy.CreateParams memory cp = _params(0);
        cp.edgeBps = edgeBps;
        cp.lamPpm = lamPpm;
        (key, id) = hook.createPool(cp);
    }

    /// The edge lets fills go further inside the leader's live quote. At a 0.25% fee against a 0.3% leader, a 1bp
    /// edge holds a small buy at the leader's ask less 1bp; the launch 23bp lets the curve's own price through.
    function test_edgeLetsFillsInsideTheLeader() public {
        (PoolKey memory kA, PoolId a) = _createWith(1, 0);
        (, PoolId b) = _create(); // the default, 23bp
        _nextBlock();
        bool zf = _zeroForOne(kA, true);
        (, uint256 outA) = hook.quoteView(a, zf, -int256(1e18));
        (, uint256 outB) = hook.quoteView(b, zf, -int256(1e18));
        assertGt(outB, outA, "a bigger edge gives more");
        vm.prank(admin);
        hook.setFeeAndEdge(a, FEE, 23);
        (, uint256 outA2) = hook.quoteView(a, zf, -int256(1e18));
        assertEq(outA2, outB, "same settings, same quote");
        uint256 c0 = coin.balanceOf(trader);
        _swap(kA, true, -int256(1e18));
        assertEq(coin.balanceOf(trader) - c0, outA2, "the swap matches quoteView");
    }

    function test_setFeeAndEdgeIsAdminOnlyAndBounded() public {
        (, PoolId id) = _create();
        vm.expectRevert(CarryStrategy.OnlyAdmin.selector);
        hook.setFeeAndEdge(id, 500, 23);
        vm.startPrank(admin);
        vm.expectRevert(CarryStrategy.BadParams.selector);
        hook.setFeeAndEdge(id, 500, 501);
        vm.expectRevert(CarryStrategy.BadParams.selector);
        hook.setFeeAndEdge(id, 0, 23);
        hook.setFeeAndEdge(id, 500, 500); // a 1% pool's room
        hook.setFeeAndEdge(id, 500, 0);
        vm.stopPrank();
        vm.expectRevert(CarryStrategy.BadParams.selector);
        _createWith(501, 0);
    }

    /// A flatter curve (LAM 0.02) moves the price less on a big one-way trade than v0.2's 0.05.
    function test_curveFlatnessIsAPerPoolSetting() public {
        (PoolKey memory k, PoolId a) = _create(); // LAM 0.02
        (, PoolId b) = _createWith(0, 50_000);
        _nextBlock();
        bool zf = _zeroForOne(k, true);
        (, uint256 flat) = hook.quoteView(a, zf, -int256(400e18));
        (, uint256 steep) = hook.quoteView(b, zf, -int256(400e18));
        assertGt(flat, steep, "flatter, less impact");
        vm.expectRevert(CarryStrategy.OnlyAdmin.selector);
        hook.setCurve(b, 20_000);
        vm.startPrank(admin);
        vm.expectRevert();
        hook.setCurve(b, 4_999);
        vm.expectRevert();
        hook.setCurve(b, 250_001);
        hook.setCurve(b, 20_000);
        vm.stopPrank();
        (, uint256 b2) = hook.quoteView(b, zf, -int256(400e18));
        assertEq(b2, flat, "same curve, same quote");
        CarryLens.PoolInfo memory i = new CarryLens().poolInfo(address(hook), b);
        assertEq(i.lamPpm, 20_000);
        assertEq(i.edgeBps, 23);
    }

    /// The Uniswap protocol-fee passthrough: off by default; when on it is charged on the input on top of the
    /// pool's own price, kept out of the book, quoted by quoteView, and paid to protoTo.
    function test_protocolFeePassthrough() public {
        (PoolKey memory k, PoolId id) = _create();
        _nextBlock();
        bool zf = _zeroForOne(k, true);
        (, uint256 out0) = hook.quoteView(id, zf, -int256(20e18));
        vm.expectRevert(CarryStrategy.OnlyAdmin.selector);
        hook.setProtocolFee(id, 1_000);
        vm.startPrank(admin);
        vm.expectRevert(CarryStrategy.BadParams.selector);
        hook.setProtocolFee(id, 1_001);
        hook.setProtocolFee(id, 1_000); // 0.1%
        vm.stopPrank();
        // exact in: 20 quote in, of which 20 / 1.001 trades
        (uint256 in1, uint256 out1) = hook.quoteView(id, zf, -int256(20e18));
        assertEq(in1, 20e18);
        assertLt(out1, out0, "the fee comes out of the input");
        uint256 y0 = hook.poolState(id).quoteReserve;
        uint256 c0 = coin.balanceOf(trader);
        _swap(k, true, -int256(20e18));
        assertEq(coin.balanceOf(trader) - c0, out1, "swap matches the quote");
        uint256 pf = 20e18 - (hook.poolState(id).quoteReserve - y0);
        assertApproxEqRel(pf, Math.mulDiv(20e18, 1_000, 1_001_000), 1e9, "0.1% on top, kept out of the book");
        // exact out: the fee is added to the input
        (uint256 in2, uint256 out2) = hook.quoteView(id, !zf, int256(5e18));
        assertEq(out2, 5e18);
        uint256 u0 = coin.balanceOf(trader);
        _swap(k, false, int256(5e18));
        assertEq(u0 - coin.balanceOf(trader), in2, "exact out pays the quoted input, fee included");
        // claims go to protoTo
        vm.expectRevert(CarryStrategy.BadParams.selector);
        hook.claimProtocolFee(id);
        vm.prank(admin);
        hook.setProtocolFeeTo(stranger);
        uint256 s0 = usd.balanceOf(stranger);
        uint256 sc0 = coin.balanceOf(stranger);
        (uint256 px, uint256 py) = hook.claimProtocolFee(id);
        assertEq(py, pf);
        assertGt(px, 0);
        assertEq(usd.balanceOf(stranger) - s0, py);
        assertEq(coin.balanceOf(stranger) - sc0, px);
        (px, py) = hook.claimProtocolFee(id);
        assertEq(px + py, 0, "drained");
    }

    /// The guardian stops a pool's swaps and deposits at once; only the admin restarts it; exits never stop.
    function test_guardianPausesSwapsAndDepositsNotExits() public {
        (PoolKey memory k, PoolId id) = _create();
        vm.prank(admin);
        hook.setGuardian(guardian);
        vm.expectRevert(CarryStrategy.OnlyAdmin.selector);
        hook.setPaused(id, true);
        vm.prank(guardian);
        hook.setPaused(id, true);
        _nextBlock();
        vm.expectRevert();
        _swap(k, true, -int256(1e18));
        vm.expectRevert(CarryStrategy.Paused.selector);
        hook.deposit(id, 10e18, 100e18);
        vm.expectRevert(CarryStrategy.Paused.selector);
        hook.quoteView(id, true, -int256(1e18));
        (, uint256 sh,,,) = hook.lotState(id, 1);
        hook.withdraw(id, 1, sh / 2, 0); // exits work
        hook.claim(id, 1);
        vm.prank(guardian);
        vm.expectRevert(CarryStrategy.OnlyAdmin.selector);
        hook.setPaused(id, false);
        vm.prank(admin);
        hook.setPaused(id, false);
        _swap(k, true, -int256(1e18));
    }

    /// Epochs: swaps do not pay out until `settleEvery` passes; a claim, a deposit or settle() pays out now.
    function test_feesArePaidPerEpochAndAClaimPaysUpToNow() public {
        (PoolKey memory k, PoolId id) = _create();
        _nextBlock();
        for (uint256 i; i < 3; i++) {
            _swap(k, true, -int256(20e18));
            _swap(k, false, -int256(10e18));
            _nextBlock();
        }
        (,,, uint256 cx, uint256 cy) = hook.lotState(id, 1);
        assertEq(cx + cy, 0, "nothing paid out by the swaps");
        uint256 c0 = coin.balanceOf(address(this));
        uint256 u0 = usd.balanceOf(address(this));
        (uint256 x, uint256 y) = hook.claim(id, 1);
        assertGt(x + y, 0, "the claim paid out the epoch");
        assertEq(coin.balanceOf(address(this)) - c0, x);
        assertEq(usd.balanceOf(address(this)) - u0, y);
        (x, y) = hook.claim(id, 1);
        assertEq(x + y, 0, "a repeat claim has nothing new");
        // the swap backstop
        _swap(k, true, -int256(20e18));
        _swap(k, false, -int256(10e18));
        _nextBlock();
        _swap(k, true, -int256(1e15));
        (,,, cx, cy) = hook.lotState(id, 1);
        assertEq(cx + cy, 0, "not due yet");
        vm.warp(block.timestamp + hook.settleEvery());
        _swap(k, true, -int256(1e15));
        (,,, cx, cy) = hook.lotState(id, 1);
        assertGt(cx + cy, 0, "the backstop paid out");
        vm.expectRevert(CarryStrategy.OnlyAdmin.selector);
        hook.setGate(100, 1 hours);
        vm.startPrank(admin);
        vm.expectRevert(CarryStrategy.BadParams.selector);
        hook.setGate(100, 9 minutes);
        vm.expectRevert(CarryStrategy.BadParams.selector);
        hook.setGate(9, 1 hours);
        hook.setGate(200, 1 hours);
        vm.stopPrank();
        assertEq(hook.settleEvery(), 1 hours);
        assertEq(hook.gateBps(), 200);
    }

    /// An epoch values each swap at its own anchor: trading while the price moves pays the lots what a payout
    /// after every block would have paid.
    function test_epochPaysWhatEachSwapEarnedAtItsOwnPrice() public {
        (PoolKey memory kA, PoolId a) = _create();
        (PoolKey memory kB, PoolId b) = _create();
        _nextBlock();
        for (uint256 i; i < 4; i++) {
            pair.set(1_000_000e18, uint112(2_000_000e18 + i * 15_000e18)); // the leader climbs 0.75% a block
            _swap(kA, true, -int256(20e18));
            _swap(kA, false, -int256(10e18));
            _swap(kB, true, -int256(20e18));
            _swap(kB, false, -int256(10e18));
            hook.settle(b); // B pays out every block, A once at the end
            _nextBlock();
        }
        hook.settle(a);
        hook.settle(b);
        (,,, uint256 ax, uint256 ay) = hook.lotState(a, 1);
        (,,, uint256 bx, uint256 by) = hook.lotState(b, 1);
        uint256 m = hook.poolState(a).anchorX128;
        uint256 va = Math.mulDiv(ax, m, 1 << 128) + ay;
        uint256 vb = Math.mulDiv(bx, m, 1 << 128) + by;
        assertGt(va, 0);
        assertApproxEqRel(va, vb, 0.02e18, "the same fees either way");
    }

    // -----------------------------------------------------------------------------------------
    // Round-6 audit fixes
    // -----------------------------------------------------------------------------------------

    function _valueAt(PoolId id, uint256 priceX128) internal view returns (uint256) {
        CarryStrategy.PoolView memory v = hook.poolState(id);
        return Math.mulDiv(v.coinReserve, priceX128, 1 << 128) + v.quoteReserve;
    }

    /// N-1: while the anchor trails the leader, fills sit near the live leader, so marking them at the anchor would
    /// book the lag as fees and pay it out of principal. Marked at the less favourable of the anchor and the block's
    /// sample, the payout is what the trades earned at the leader: the reserves, valued at the leader, do not fall.
    function test_r6_lagIsNotBookedAsFees() public {
        (PoolKey memory k, PoolId id) = _create();
        _nextBlock();
        hook.sample(id);
        _nextBlock();
        pair.set(1_000_000e18, 2_018_000e18); // the leader +0.9%; the anchor still reads 2.0 this block
        uint256 lx128 = Math.mulDiv(2_018e15, 1 << 128, 1e18);
        uint256 before = _valueAt(id, lx128);
        for (uint256 i; i < 5; i++) {
            _swap(k, true, -int256(40e18));
        }
        assertLt(hook.poolState(id).anchorX128, lx128, "the anchor lags");
        hook.settle(id);
        // unfixed, ~1.8 quote of lag was paid out here; what is left is the jar skim and rounding
        assertGe(_valueAt(id, lx128) + 1e15, before, "no principal paid out as fees");
    }

    /// Vercel review on #135: a leader pushed only for the block's first-touch sample, then put back, does not move
    /// the fee mark: a sample pushed 50% books exactly what a sample pushed 1% books.
    function test_r6_pushedSampleDoesNotMoveTheMark() public {
        (PoolKey memory kA, PoolId a) = _create();
        (PoolKey memory kC, PoolId c) = _create();
        _nextBlock();
        hook.sample(a);
        hook.sample(c);
        _nextBlock();
        pair.set(1_000_000e18, 3_000_000e18); // pushed 50% for one reading
        hook.sample(a);
        pair.set(1_000_000e18, 2_020_000e18); // pushed one step (1%)
        hook.sample(c);
        pair.set(1_000_000e18, 2_000_000e18); // restored
        for (uint256 i; i < 3; i++) {
            _swap(kA, false, -int256(10e18));
            _swap(kA, true, -int256(2e18));
            _swap(kC, false, -int256(10e18));
            _swap(kC, true, -int256(2e18));
        }
        _nextBlock();
        hook.settle(a);
        hook.settle(c);
        (,,, uint256 ax, uint256 ay) = hook.lotState(a, 1);
        (,,, uint256 cx, uint256 cy) = hook.lotState(c, 1);
        assertGt(cx + cy, 0, "fees paid");
        assertEq(ax, cx, "same coin paid");
        assertEq(ay, cy, "same quote paid");
        assertEq(hook.poolState(a).coinReserve, hook.poolState(c).coinReserve, "same book");
    }

    /// Vercel review on #135 (second finding): a real leader move larger than one anchor step is still marked in
    /// full, so a buyer after a 3% rise cannot turn the gap into fees paid out of principal.
    function test_r6_bigRealMoveIsNotBookedAsFees() public {
        (PoolKey memory k, PoolId id) = _create();
        _nextBlock();
        hook.sample(id);
        _nextBlock();
        pair.set(1_000_000e18, 2_060_000e18); // the leader +3%, three anchor steps
        uint256 lx128 = Math.mulDiv(2_060e15, 1 << 128, 1e18);
        uint256 before = _valueAt(id, lx128);
        for (uint256 i; i < 5; i++) {
            _swap(k, true, -int256(40e18));
        }
        hook.settle(id);
        // a mark clipped to one step pays ~3.9 quote of the gap out here; what is left is the jar skim and rounding
        assertGe(_valueAt(id, lx128) + 1e16, before, "no principal paid out as fees");
    }

    /// Edge vs the leader's fee: whatever the edge, a fill never crosses the leader's own bid (buys) or ask (sells),
    /// so nothing can be bought here and sold there at a profit, even with a stale anchor and the 500bp edge.
    function test_r6_edgeNeverCrossesTheLeadersBidOrAsk() public {
        (PoolKey memory k, PoolId id) = _createWith(500, 0);
        _nextBlock();
        hook.sample(id);
        _nextBlock();
        pair.set(1_000_000e18, 2_018_000e18); // leader up, anchor stale low
        bool zf = _zeroForOne(k, true);
        (uint256 qIn, uint256 cOut) = hook.quoteView(id, zf, int256(1e15)); // buy 0.001 coin, exact out
        uint256 leaderBid = Math.mulDiv(2_018e15, 997, 1000); // the v2 leader's bid, 0.3% fee
        assertGe(Math.mulDiv(qIn, 1e18, cOut), leaderBid, "a buy pays at least the leader's bid");
        pair.set(1_000_000e18, 1_982_000e18); // leader down, anchor stale high
        _nextBlock();
        (uint256 cIn, uint256 qOut) = hook.quoteView(id, !zf, -int256(1e15)); // sell 0.001 coin, exact in
        uint256 leaderAsk = Math.mulDiv(1_982e15, 1000, 997, Math.Rounding.Ceil);
        assertLe(Math.mulDiv(qOut, 1e18, cIn), leaderAsk, "a sell gets at most the leader's ask");
    }

    /// M-01: a leader pushed in the closing transaction does not change what the epoch pays: capital moves and
    /// settle() pay out at the stored anchor.
    function test_r6_settleIgnoresALeaderPushedThisTransaction() public {
        (PoolKey memory kA, PoolId a) = _create();
        (PoolKey memory kB, PoolId b) = _create();
        _nextBlock();
        for (uint256 i; i < 3; i++) {
            _swap(kA, true, -int256(20e18));
            _swap(kA, false, -int256(10e18));
            _swap(kB, true, -int256(20e18));
            _swap(kB, false, -int256(10e18));
        }
        _nextBlock();
        hook.settle(b); // honest leader
        pair.set(1_000_000e18, 2_020_000e18); // pushed 1% for one transaction
        hook.settle(a);
        pair.set(1_000_000e18, 2_000_000e18);
        (,,, uint256 ax, uint256 ay) = hook.lotState(a, 1);
        (,,, uint256 bx, uint256 by) = hook.lotState(b, 1);
        assertGt(ay + ax, 0);
        assertEq(ax, bx, "same coin paid");
        assertEq(ay, by, "same quote paid");
    }

    /// L-02: the deposit gate is at most 2%; protoTo cannot be set to zero.
    function test_r6_gateCapAndProtoToZero() public {
        vm.startPrank(admin);
        vm.expectRevert(CarryStrategy.BadParams.selector);
        hook.setGate(201, 1 hours);
        hook.setGate(200, 1 hours);
        vm.expectRevert(CarryStrategy.OnlyAdmin.selector);
        hook.setProtocolFeeTo(address(0));
        vm.stopPrank();
    }
}
