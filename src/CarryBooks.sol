// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CarryLedger as LG} from "./libraries/CarryLedger.sol";
import {CarrySwapMath as SM} from "./libraries/CarrySwapMath.sol";
import {CarryFlatMath as FM} from "./libraries/CarryFlatMath.sol";

interface IV2R {
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface IV3S {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function fee() external view returns (uint24);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function liquidity() external view returns (uint128);
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
}

interface IFactoryLike {
    function getPair(address, address) external view returns (address);
    function getPool(address, address, uint24) external view returns (address);
}

/// @title CarryBooks
/// @notice Linked (external) entry points for the LP ledger, so the hook stays under the 24 KB code limit. Each call
///         is a DELEGATECALL into this library operating on the hook's own storage; the logic is CarryLedger's,
///         unchanged. Only the O(1) swap record stays inlined in the hook.
library CarryBooks {
    /// @dev v4 PoolManager transient slot that is nonzero while it is unlocked (Lock.sol).
    bytes32 internal constant IS_UNLOCKED_SLOT = 0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;

    using LG for LG.Book;

    function init(LG.Book storage bk, address creator, uint256 x, uint256 y, uint256 markX128) public {
        bk.init(creator, x, y, markX128);
    }

    /// @notice Close the interval at `markX128`, judging the creator cut and graduation from `t`. `skimRoom` (quote
    ///         raw at the mark) is how much the pool's tip jar can still take; returns the coin/quote skimmed for it.
    ///         Carry: the skim is quote only, so the curve centre `tX128` is returned rescaled by the quote reserve
    ///         it leaves (y'/y, as a deposit rescales it), which keeps the quoted price where it was.
    function settle(
        LG.Book storage bk,
        uint256 markX128,
        bool dist,
        uint256 skimRoom,
        uint256 tX128,
        uint256 skimBps
    ) public returns (uint256 jy, uint256 t2) {
        uint256 y0 = bk.y;
        (,, jy) = bk.settle(markX128, 0, 0, 0, dist, skimRoom, skimBps);
        t2 = jy == 0 ? tX128 : Math.mulDiv(tX128, y0 - jy, y0);
    }

    /// @notice Carry: a 50/50 deposit at mark `markX128`, shares by value at whichever of `markX128`, `liveX128` and
    ///         `prevX128` gives fewest (CarryLedger.depositAt).
    function depositAt(
        LG.Book storage bk,
        address owner,
        uint256 maxX,
        uint256 maxY,
        uint256 markX128,
        uint256 liveX128,
        uint256 prevX128
    ) public returns (uint256 id, uint256 shares, uint256 takeX, uint256 takeY) {
        return bk.depositAt(owner, maxX, maxY, markX128, liveX128, prevX128);
    }

    function withdraw(LG.Book storage bk, uint256 id, address owner, uint256 s, uint256 bal)
        public
        returns (uint256 cx, uint256 cy)
    {
        return bk.withdraw(id, owner, s, bal);
    }

    function claim(LG.Book storage bk, uint256 id, address owner) public returns (uint256, uint256) {
        return bk.claim(id, owner);
    }

    /// @notice Hand the creator role on. A compounding creator's lot is made here, paid by the creator, not inside
    ///         a later price delivery (audit L-3).
    function setCreator(LG.Book storage bk, address creator, bool compounds) public {
        bk.creator = creator;
        bk.creatorCompounds = compounds;
        uint256 cl = bk.creatorLot;
        if (cl != 0) bk.lots[cl].owner = creator;
        else if (compounds) LG.makeCreatorLot(bk);
    }

    function claimCreator(LG.Book storage bk) public returns (uint256, uint256) {
        return bk.claimCreator();
    }

    function poke(LG.Book storage bk, uint256 id) public returns (uint256, uint256, uint256, uint256) {
        return bk.poke(id);
    }

    /// @notice Same-chain slopes and match bounds. No lag premium: both sides pay the pool fee, and the centre
    ///         itself only moves toward the leader by a bounded step per reading (see CarrySwapMath.stepToward).
    ///         The live leader price, read in the same call, bounds every fill.
    function sameQuote(uint256 anchorX128, uint256 tX128, uint24 fee, uint256 spot, uint24 srcFee, uint256 edgeBps)
        public
        pure
        returns (uint256 kb, uint256 ks, uint256 pb, uint256 ps)
    {
        uint256 g = SM.markup(1e18, fee);
        (kb, ks) = SM.slopes(anchorX128, tX128, g, g);
        uint256 srcAsk = Math.mulDiv(spot, 1e6, 1e6 - srcFee, Math.Rounding.Ceil);
        uint256 srcBid = Math.mulDiv(spot, 1e6 - srcFee, 1e6);
        (pb, ps) = SM.matchBounds(srcAsk, srcBid, edgeBps);
        // round-6 (edge vs the leader's fee): never inside the leader's own bid / ask, so no edge, leader change or
        // leader fee change lets a trade buy here and sell there (or the reverse) at a profit
        if (pb < srcBid) pb = srcBid;
        if (ps > srcAsk) ps = srcAsk;
    }

    /// @notice What the next same-chain settle (`observe(t, cur, fresh)` then `settle(bk, t, markX128, true,
    ///         skimRoom)`) would take out of the tradable reserves, without doing it: the jar skim and, on a graduated
    ///         pool, the LP escrow and creator claim (for the hook's read-only quote; audit v0.2 M-1).
    function settlePreview(LG.Book storage bk, uint256 markX128, uint256 skimRoom, uint256 tX128, uint256 skimBps)
        public
        view
        returns (uint256 ox, uint256 oy, uint256 t2)
    {
        // Carry: as settle, the TVL judge is unused, and the curve centre is rescaled by the quote skim
        uint256 jy;
        (ox, oy, jy) = bk.settlePreview(markX128, skimRoom, 0, 0, skimBps);
        t2 = jy == 0 ? tX128 : Math.mulDiv(tX128, bk.y - jy, bk.y);
    }

    /// @notice Carry: a pool's slow leader depth reading (see `CarryStrategy.minDepth`).
    struct Depth {
        uint192 depth;
        uint64 at;
    }

    /// @notice Fold the leader depth now (`d`, from `depth1`) into the slow reading `o` and return the depth the
    ///         rule uses: the lower of the two after the reading moves toward `d` by at most 10% per hour either way
    ///         since its last move (counting at most one hour). The first reading starts at `d`.
    function seeDepth(Depth storage o, uint256 d) public returns (uint256) {
        uint256 n = d;
        uint256 old = o.depth;
        if (old != 0) {
            uint256 dt = block.timestamp - o.at;
            if (dt > 1 hours) dt = 1 hours;
            uint256 up = old + Math.mulDiv(old, 1_000 * dt, 10_000 * 1 hours);
            uint256 down = old - Math.mulDiv(old, 1_000 * dt, 10_000 * 1 hours);
            if (n > up) n = up;
            if (n < down) n = down;
        }
        if (n > type(uint192).max) n = type(uint192).max;
        o.depth = uint192(n);
        o.at = uint64(block.timestamp);
        return n < d ? n : d; // a rise counts only as far as the slow reading has climbed
    }

    /// @notice Carry: the current transaction's L1 data fee in wei on an Arbitrum chain (ArbGasInfo
    ///         `getCurrentTxL1GasFees` at 0x6c), 0 anywhere it cannot be read.
    function l1Fee() public view returns (uint256 f) {
        (bool ok, bytes memory r) = address(0x6c).staticcall(abi.encodeWithSignature("getCurrentTxL1GasFees()"));
        if (ok && r.length >= 32) f = abi.decode(r, (uint256));
        if (f > 1e18) f = 0; // garbage, not a fee
    }

    /// @notice One fill on the v0.2 flat-centre curve (CarryFlatMath). Returns (coin, quote) amounts.
    function fill(
        uint256 u,
        uint256 v,
        uint256 t,
        uint256 k,
        uint256 b,
        bool sell,
        bool exactIn,
        uint256 spec,
        uint256 shape
    ) public pure returns (uint256 coinAmt, uint256 quoteAmt) {
        if (sell) {
            (coinAmt, quoteAmt) = exactIn
                ? (spec, FM.sellExactIn(u, v, k, b, t, spec, shape))
                : (FM.sellExactOut(u, v, k, b, t, spec, shape), spec);
        } else {
            (quoteAmt, coinAmt) = exactIn
                ? (spec, FM.buyExactIn(u, v, k, b, t, spec, shape))
                : (FM.buyExactOut(u, v, k, b, t, spec, shape), spec);
        }
    }

    /// @notice v0.3: a pool's curve shape for flatness `lam` (WAD; see CarryFlatMath.shape).
    function shapeOf(uint256 lam) public pure returns (uint256) {
        return FM.shape(lam);
    }

    /// @notice Split a tip worth `q` quote raw out of a jar of (`jx` coin, `jy` quote), valued at `aX128`: quote
    ///         first, then coin. Capped at 1/`div` of the jar's value, and at what it holds.
    function tip(uint256 jx, uint256 jy, uint256 aX128, uint256 q, uint256 div)
        public
        pure
        returns (uint256 cx, uint256 cy)
    {
        uint256 cap = (Math.mulDiv(jx, aX128, 1 << 128) + jy) / div;
        if (q > cap) q = cap;
        if (q <= jy) return (0, q);
        cy = jy;
        cx = Math.mulDiv(q - jy, 1 << 128, aX128);
        if (cx > jx) cx = jx;
    }

    // ---------------------------------------------------------------------------------------------
    // Source reads (moved out of the hook for size)
    // ---------------------------------------------------------------------------------------------

    /// @dev One pool's spot (X128 other raw per base raw) and fee in pips (v2: Uniswap's 0.3%).
    error BadParams();

    /// @notice A verified same-chain source pool's (base, other) tokens, native ETH mapped to `weth`. v2 / v3 are
    ///         checked through `factory` (a zero factory has no code, so the call reverts: that kind is off); v4
    ///         through its key, never one of the hook's own pools (this runs by DELEGATECALL, so `this` = the hook).
    function legTokens(
        uint8 kind,
        address target,
        bytes32 v4Id,
        PoolKey calldata k,
        bool baseIs0,
        address weth,
        address factory
    ) public view returns (address base, address other) {
        address t0;
        address t1;
        if (kind == 3) {
            // hookless only: a hooked leader could charge or move price in ways its slot0 does not show
            if (keccak256(abi.encode(k)) != v4Id || address(k.hooks) != address(0)) revert BadParams();
            (t0, t1) = (Currency.unwrap(k.currency0), Currency.unwrap(k.currency1));
        } else {
            t0 = IV3S(target).token0();
            t1 = IV3S(target).token1();
            address real = kind == 1
                ? IFactoryLike(factory).getPair(t0, t1)
                : IFactoryLike(factory).getPool(t0, t1, IV3S(target).fee());
            if (real != target) revert BadParams();
        }
        if (t0 == address(0)) t0 = weth;
        (base, other) = baseIs0 ? (t0, t1) : (t1, t0);
    }

    /// @notice The reference leg's spot, or 0 if it cannot be read (no code, wrong interface, out-of-range data).
    function refSpot(IPoolManager pm, uint8 kind, address target, bytes32 v4Id, bool baseIs0)
        public
        view
        returns (uint256 spot)
    {
        if (kind == 3) {
            (spot,) = leg(pm, kind, target, v4Id, baseIs0);
            return spot;
        }
        bool v2 = kind == 1;
        (bool ok, bytes memory r) =
            target.staticcall(abi.encodeWithSelector(v2 ? IV2R.getReserves.selector : IV3S.slot0.selector));
        if (!ok || r.length < (v2 ? 96 : 224)) return 0;
        (uint256 a, uint256 b) = abi.decode(r, (uint256, uint256));
        if (v2) {
            if (a > type(uint112).max || b > type(uint112).max) return 0;
            (spot,) = _v2(a, b, baseIs0);
        } else {
            if (a > type(uint160).max) return 0;
            (spot,) = _concentrated(uint160(a), 0, baseIs0);
        }
    }

    function leg(IPoolManager pm, uint8 kind, address target, bytes32 v4Id, bool baseIs0)
        public
        view
        returns (uint256 spot, uint24 fee)
    {
        if (kind == 1) {
            (uint112 r0, uint112 r1,) = IV2R(target).getReserves();
            (spot,) = _v2(r0, r1, baseIs0);
            fee = 3000;
        } else if (kind == 2) {
            (uint160 sqrtP,,,,,,) = IV3S(target).slot0();
            (spot,) = _concentrated(sqrtP, 0, baseIs0);
            fee = IV3S(target).fee();
        } else {
            (uint160 sqrtP,, uint24 pf, uint24 lpFee) = StateLibrary.getSlot0(pm, PoolId.wrap(v4Id));
            (spot,) = _concentrated(sqrtP, 0, baseIs0);
            // a swap pays the protocol fee too (12 bits per direction). Take the smaller: the modelled bid and ask
            // then sit inside the leader's real quotes in both directions, so the edge clamp in `sameQuote` holds
            // even when the two directions' protocol fees differ (round-7 review)
            uint256 a = pf & 0xfff;
            if (pf >> 12 < a) a = pf >> 12;
            fee = uint24(a + lpFee - a * lpFee / 1e6);
        }
        if (fee >= 1e6) fee = 999_999;
    }

    /// @notice Carry: the leader's depth, in quote raw: about what it takes to move leg 1's price by 1% (half its
    ///         virtual reserves at the current price, times sqrt(1.01) - 1 ~ 1/200: in all, a quarter of a percent of
    ///         the virtual TVL), converted to the quote through leg 2 for two-hop. For a v3 / v4 leader this counts
    ///         only the liquidity in range at the current price.
    function depth1(
        IPoolManager pm,
        uint8 kind,
        address target,
        bytes32 v4Id,
        bool coinIs0,
        uint256 s1,
        uint256 spot,
        bool twoHop
    ) public view returns (uint256 d) {
        uint256 tvl;
        if (kind == 1) {
            (uint112 r0, uint112 r1,) = IV2R(target).getReserves();
            (, tvl) = _v2(r0, r1, coinIs0);
        } else if (kind == 2) {
            (uint160 sqrtP,,,,,,) = IV3S(target).slot0();
            (, tvl) = _concentrated(sqrtP, IV3S(target).liquidity(), coinIs0);
        } else {
            // inside an unlock, liquidity can be added and removed around this read for free
            if (pm.exttload(IS_UNLOCKED_SLOT) != 0) revert BadParams();
            (uint160 sqrtP,,,) = StateLibrary.getSlot0(pm, PoolId.wrap(v4Id));
            (, tvl) = _concentrated(sqrtP, StateLibrary.getLiquidity(pm, PoolId.wrap(v4Id)), coinIs0);
        }
        d = tvl / 400;
        if (twoHop && s1 != 0) d = Math.mulDiv(d, spot, s1);
    }

    function _v2(uint256 r0, uint256 r1, bool coinIs0) internal pure returns (uint256 spot, uint256 tvl) {
        (uint256 rc, uint256 rq) = coinIs0 ? (r0, r1) : (r1, r0);
        if (rc == 0 || rq == 0) return (0, 0);
        spot = Math.mulDiv(rq, (1 << 128), rc);
        tvl = 2 * rq;
    }

    /// @dev Spot from sqrtPriceX96 and a TVL proxy (virtual reserves at the current price, both sides in quote).
    function _concentrated(uint160 sqrtP, uint128 liq, bool coinIs0) internal pure returns (uint256 spot, uint256 tvl) {
        if (sqrtP == 0) return (0, 0);
        uint256 sp = uint256(sqrtP);
        uint256 q96 = 1 << 96;
        if (coinIs0) {
            spot = Math.mulDiv(sp, sp, 1 << 64); // sqrtP^2 / 2^192 * 2^128
            tvl = 2 * Math.mulDiv(uint256(liq), sp, q96);
        } else {
            spot = Math.mulDiv(Math.mulDiv((1 << 128), q96, sp), q96, sp); // 2^192 / sqrtP^2 * 2^128
            tvl = 2 * Math.mulDiv(uint256(liq), q96, sp);
        }
    }
}
