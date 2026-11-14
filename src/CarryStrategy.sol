// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CurrencySettler} from "./libraries/CurrencySettler.sol";
import {CarrySwapMath as SM} from "./libraries/CarrySwapMath.sol";
import {CarryPrice as PR} from "./libraries/CarryPrice.sol";
import {CarryLedger as LG} from "./libraries/CarryLedger.sol";
import {CarryBooks as BK} from "./CarryBooks.sol";

/// @title Disciple
/// @notice A Uniswap v4 hook that runs small coin/quote pools priced off an anchor from a source pool.
///         One deployment serves many pools. Permissionless: anyone creates a pool against any source.
///
///         Same chain (beside a v2, v3 or v4 source on this chain): the anchor is latched once per block from
///         the source's spot as seen in an earlier block. Anyone may call sample() to take that price sample
///         without a trade; it does not settle the books or read source TVL. Each latch moves the anchor toward
///         the sample by at most one step (`minStep`), so a faked one-block sample shifts
///         the centre by no more than one step. There is no lag premium. Every fill respects the live source
///         boundary (ask >= source ask * (1 - edge), bid <= source bid * (1 + edge), and never past the leader's
///         own bid / ask), read in the same call.
///         Tip jar: a share of each interval's earnings goes to the pool's own jar (Carry: quote only) up to a cap. sample() pays its caller `tipBps` of its gas
///         from the jar (break-even at launch), but only while the centre is at least `dueBps` from the leader, so
///         the pool catches up after a move even with no trades.
///
///         Curve and fills: CarryFlatMath (v0.2 flat centre; via CarryBooks), slopes: CarrySwapMath. Price rules: CarryPrice. LP books: CarryLedger.
///         v4 concentrated liquidity is disabled; every swap is quoted in `beforeSwap`.
///         Custody: pool liquidity is held as the hook's ERC-6909 claims inside the PoolManager, so a swap only
///         mints and burns claims. Deposits, withdrawals and claims convert to and from ERC20 in one unlock.
///
///         Carry v2 changes (see follower/PROVENANCE.md and the v2 spec):
///         - Carry only: `carry` (the Carry adapter) is the only address that can create a pool or deposit, so it
///           owns every lot. Pools are same chain only.
///         - Fees are paid out, not compounded: every pool is graduated from launch, so each interval's earnings go
///           to the lots in kind (by the boost line, so early positions still earn more) from the first trade. There
///           is no 12%-of-leader goal and no creator cut; Carry's treasury share is taken in the adapter.
///         - `admin` (the Carry timelock) can change a live pool's fee, up to MAX_FEE (3%), and set `carry`.
///         - Deposits are 50/50 by value at the anchor, whatever the pool's mix, with shares by value; the curve
///           centre moves so the quoted price does not change. After that the mix drifts with trading.
///         - `admin` can point a live pool at a new leader (`setLeader`); the anchor steps to it at minStep a block.
///         - The leader's TVL is no longer read (no v4 depth counter), since nothing uses it.
///         - Tip jar: fills at `skimBps` of earnings (2% at launch; Disciple: 12%) up to `jarCap`, a fixed quote amount the admin sets
///           (about $1, a week of keeper tips), instead of 320 gas-priced tips.
///         - Same chain only: the LayerZero push route (cross-chain pools, local mode, keeper credits) is removed.
///         - v0.3: no Morpho tail. The pool's reserves stay in the PoolManager as claims; only the vault's idle lender
///           USDG earns outside the pool (maker Nov 13).
///
///         v0.3 (maker Nov 13; spec carry-v03-spec.md):
///         - Settings per pool, all through the admin (timelock): fee and edge together (`setFeeAndEdge`; launch
///           0.05% and 23bp, edge at most 500bp), curve flatness (`setCurve`; launch LAM 0.02), the Uniswap
///           protocol-fee passthrough (`setProtocolFee`; 0 = off). Global: tip rule (break-even by default), the
///           deposit gate and the payout backstop (`setGate`). The guardian can pause a pool (`setPaused`).
///         - Fees are paid out in epochs: each swap records what it earned at its own anchor, and deposits,
///           withdrawals, claims and `settle` (the keeper, hourly) pay the open epoch out to every lot. A swap pays
///           out only when none ran for `settleEvery` (6 hours), so busy blocks do not pay for the payout.
///         - Deposits need no keeper sample: they read the live leader and are valued at the worst of the anchor,
///           the live leader and an earlier block's sample, inside a 1% gate.
///         - Removed: the Morpho tail, the creator cut, restake and the revert-style quote (use `quoteView`).
contract CarryStrategy is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;
    using LG for LG.Book;

    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    /// @dev Source kinds for `Source.kind`: 1 = v2, 2 = v3, 3 = v4.
    uint8 internal constant SRC_V2 = 1;
    uint8 internal constant SRC_V3 = 2;
    uint8 internal constant SRC_V4 = 3;

    uint256 internal constant Q128 = 1 << 128;
    uint256 internal constant WAD = 1e18;
    /// @dev v0.3 bounds on the admin's settings: the edge (bps inside the leader's live quote), the Uniswap
    ///      protocol-fee passthrough (pips, v4's own maximum), the curve flatness (ppm), the swap-path payout
    ///      backstop (seconds) and the defaults a new pool starts with (maker Nov 13: 23bp edge, LAM 0.02).
    uint16 internal constant MAX_EDGE_BPS = 500;
    uint16 internal constant MAX_PROTO_FEE = 1_000;
    uint16 internal constant EDGE_BPS0 = 23;
    uint32 internal constant LAM_PPM0 = 20_000;
    /// @dev Gas a tipped sample() spends outside the measured span (calldata, the payout itself), plus the
    ///      transaction intrinsic and first-touch costs counted once per transaction, so a batch of samples is not paid it N times
    ///      (audit L-2 / GPT batching). Measured on anvil (keeper/test/local, real per-transaction accounting): a
    ///      repeat tipped sample was ~116k gas with ~84k outside the span. v0.2 moved the reentrancy flag to
    ///      transient storage (~2k less outside the span), and a batch of 8 in one transaction then measured 124%
    ///      at 63k, so it is 58k: a batch is paid <= 120%, a single repeat sample ~117%, a first tip ~103%.
    ///      Carry (Nov 11, live v0.2 on Robinhood, one sample per tx): tips paid 100-109% of the receipts' cost at
    ///      1.2x (e.g. 131,115 gas, 0 L1 gas, tipped ~103%), so a first-in-transaction sample counted ~112k of
    ///      131k: ~19k of per-transaction cost (calldata, first touches of the hook, the manager and their slots)
    ///      was missing, as the anvil "first tip ~103%" showed. That goes in the once-per-transaction part
    ///      (`TIP_INTRINSIC`, 21k -> 41k, also covering the L1 fee read), so a single sample is paid ~105% and a
    ///      repeat in a batch ~102% at the 1.05x markup. The L1 data fee is read live (`BK.l1Fee`; 0 on Robinhood
    ///      today, poster fee 0) in case the chain starts charging it.
    uint256 internal constant TIP_OVERHEAD = 58_000;
    uint256 internal constant TIP_INTRINSIC = 41_000;
    /// @dev Transient flag: the intrinsic was already paid to a sample() in this transaction.
    uint256 internal constant TIP_TX_SLOT = uint256(keccak256("disciple.tip.tx"));
    /// @dev One tip is at most this fraction of the jar, so a basefee spike cannot empty it in a few calls.
    uint256 internal constant TIP_DIV = 32;
    /// @dev Pool fee bound, in pips (Carry: 3%, maker Nov 11).
    uint24 internal constant MAX_FEE = 30_000;
    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    /// @dev Leg 1 is a pool of the coin and a token X. With no leg 2 (`kind2 == 0`, the mirror case) X is the quote.
    ///      With leg 2 (same chain only) it is a pool of X and the quote, and the price is leg 1 x leg 2 (two-hop).
    ///      Native ETH in a pool counts as `weth`.
    struct Source {
        uint8 kind; // leg 1: SRC_V2 / SRC_V3 / SRC_V4
        bool coinIs0; // the coin is token0 of leg 1
        uint32 remoteEid; // 0 = same chain; else the home chain's LayerZero eid
        address target; // v2 pair / v3 pool; for v4 the PoolManager (remote: the remote manager)
        bytes32 v4Id; // v4 source pool id
        int8 decShift; // cross chain: price * 10^decShift converts home raw quote-per-coin to local raw units
        int8 tvlShift; // cross chain: TVL * 10^tvlShift converts home raw quote units to local raw quote units
        bool push; // must be true for a cross-chain pool (LayerZero push from a sender on chain `remoteEid`)
        uint8 kind2; // leg 2 kind, 0 = none
        bool xIs0; // X is token0 of leg 2
        address target2; // leg 2 v2 pair / v3 pool (v4: unused)
        bytes32 v4Id2; // leg 2 v4 pool id
    }

    struct Pool {
        bool exists;
        bool live; // ledger initialised (cross chain waits for its first price)
        bool coinIs0; // coin is currency0 of the Disciple pool
        uint24 fee; // pips
        address coin;
        uint16 edgeBps; // v0.3: fills may be this far inside the leader's live quote (bps; same slot as fee)
        uint16 protoFee; // v0.3: Uniswap protocol-fee passthrough on the input, pips (0 = off)
        bool paused; // v0.3: swaps and deposits stopped (guardian or admin); exits still work
        address quote;
        uint32 lamPpm; // v0.3: curve flatness inside the band, ppm (same slot as quote)
        uint64 ewb; // expWad(W * (1 - lam)), set with lamPpm
        Source src;
        uint256 tX128; // curve seed ratio T (quote raw per coin raw, X128)
        uint256 anchorX128; // A
        uint64 settledBlock; // same chain: last block the ledger settled
        uint64 settledAt; // v0.3: timestamp of the last payout (epoch; same slot as the block fields)
        uint64 sampleBlock; // (the four block/time fields share one slot: one read per swap)
        uint64 sampleAt; // timestamp of sampleX128
        uint256 sampleX128; // same chain: last source spot sampled
        uint256 jarX; // same chain tip jar, coin raw (held as claims, outside the book)
        uint256 jarY; // tip jar, quote raw
        address x; // same chain: leg 1's other token (the quote, or X for two-hop)
        LG.Book book;
        uint256 prevX128; // same chain: the sample before sampleX128, from an earlier block (deposits; set to spot at pool creation and setLeader)
        uint128 protoX; // v0.3: protocol fee owed, coin raw (claims outside the book)
        uint128 protoY; // quote raw
    }

    struct CreateParams {
        address coin;
        address quote; // any ERC20 other than the coin
        uint24 fee; // Disciple fee in pips
        Source src;
        uint256 coinIn;
        uint256 quoteIn;
        PoolKey srcKey; // same-chain v4 leg 1 only: its key, which must hash to `src.v4Id`
        PoolKey srcKey2; // same-chain v4 leg 2 only: its key, which must hash to `src.v4Id2`
        uint16 edgeBps; // v0.3: 0 = the default (EDGE_BPS0)
        uint32 lamPpm; // v0.3: 0 = the default (LAM_PPM0)
    }

    /// @dev One token movement inside an unlock: `into` the pool's claims from `who`, or out of them to `who`.
    struct Move {
        address token;
        address who;
        uint256 amt;
        bool into;
    }

    IPoolManager public immutable poolManager;
    /// @notice Same-chain v2 / v3 sources must be pools of these factories (0 = that kind is off).
    address public immutable v2Factory;
    address public immutable v3Factory;
    /// @notice Native ETH in a same-chain source pool counts as this token (the chain's WETH).
    address public immutable weth;
    /// @notice Smallest per-reading anchor step, in pips (the step is minStep, whatever the pool fee: audit M-3). Robinhood 1%,
    ///         Ethereum 5% (slower blocks: a move up to ~10% is caught up in two readings).
    uint24 public immutable minStep;
    /// @notice The chain's reference WETH/stable pool, used only to value tip-jar gas in a non-ETH quote.
    address public immutable refToken;
    uint8 internal immutable refKind;
    address internal immutable refTarget;
    bytes32 internal immutable refV4Id;
    bool internal immutable refWethIs0;

    /// @dev Per-chain settings fixed at deploy. `ref*`: one WETH/refToken pool (kind 0 = none: tips then pay only
    ///      pools with WETH or refToken as a token, or a two-hop source through WETH; other pools pay no tips).
    struct Config {
        uint24 minStep;
        address refToken;
        uint8 refKind;
        address refTarget;
        bytes32 refV4Id;
        bool refWethIs0;
    }
    /// @notice Disciple pools per pair so far, by sorted (currency0, currency1). Pool n of a pair has tickSpacing n,
    ///         so a pair is never squatted.
    mapping(address => mapping(address => uint256)) public poolsOf;

    mapping(PoolId => Pool) internal pools;
    /// @dev Reentrancy flag, in transient storage (cleared at the end of each call; a reverted call clears it too).
    uint256 internal constant LOCK_SLOT = uint256(keccak256("disciple.lock"));
    /// @notice Carry: the timelock that may change pool fees and `carry`. Handed on in two steps.
    address public admin;
    address public pendingAdmin;
    /// @notice Carry: the adapter, the only address that may create pools and deposit.
    address public carry;
    /// @notice Carry: each pool's tip jar fills (2% of earnings) up to this value, in quote raw at the anchor
    ///         (USDG: 1e6 = $1). It pays the keeper's sample() tips. Set by the admin.
    uint256 public jarCap;
    /// @notice Carry: may stop a pool's swaps and deposits at once (emergency; only the admin restarts). Set by the admin.
    address public guardian;
    /// @notice Carry: leader depth rule (admin). `minDepth`: the least the leader must take to move 1%, in quote
    ///         raw (`BK.depth1`). `depthBps`: the pool's value may be at most this share of that depth (0 = no
    ///         limit). Checked when a pool is created, when its leader changes and on every deposit; trades and
    ///         exits never check it. Both 0 = off. The depth used is the lower of the leader's depth now and
    ///         `depthSeen`, a slow reading that rises at most 10% and falls at most 10% per hour, so liquidity added
    ///         for one transaction cannot pass the rule.
    uint256 public minDepth;
    uint16 public depthBps;
    /// @notice Carry: each pool's slow leader depth reading and when it last moved (see `minDepth`).
    mapping(PoolId => BK.Depth) public depthSeen;
    /// @notice Carry: what a sample() tip pays, in bps of its cost (10,500 = cost + 5%; 10,000 to 15,000), and the
    ///         share of each interval's earnings skimmed into the pool's tip jar (200 = 2%; at most 1,000 = 10%).
    ///         Set by the admin (`setTipRule`, with `jarCap`).
    uint16 public tipBps = 10_000;
    uint16 public skimBps = 200;
    /// @notice v0.3: sample() pays a tip only while the centre is at least `dueBps` from the live leader (100 = 1%).
    uint16 public dueBps = 100;
    /// @notice v0.3: a deposit is refused while the anchor is more than `gateBps` from the live leader (the pool is
    ///         or the earlier sample (the pool is still catching up); within it the deposit is valued at the worst
    ///         of the three (anchor, live leader, earlier sample) for the depositor.
    uint16 public gateBps = 100;
    /// @notice v0.3: fees are paid to the lots in epochs. Deposits, withdrawals, claims and `settle` (the keeper,
    ///         hourly) pay out the open epoch; a swap does only if no payout ran for `settleEvery` seconds.
    uint32 public settleEvery = 6 hours;
    /// @notice v0.3: where `claimProtocolFee` pays the Uniswap protocol-fee passthrough (set by the admin).
    address public protoTo;

    // ---------------------------------------------------------------------------------------------
    // Events and errors
    // ---------------------------------------------------------------------------------------------

    event Created(
        PoolId indexed id, address indexed coin, address quote, address indexed creator, uint32 remoteEid, uint24 fee
    );
    /// @dev Standard hook events (OpenZeppelin IHookEvents) so indexers see a custom-curve pool's flow. Amounts
    ///      are the pool's view per currency: positive = into the pool, negative = out. Fee is the LP fee, in the
    ///      input currency.
    event HookSwap(
        bytes32 indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint128 hookLPfeeAmount0,
        uint128 hookLPfeeAmount1
    );
    event HookModifyLiquidity(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1);
    event Tipped(PoolId indexed id, address indexed to, uint256 x, uint256 y);
    event Deposited(PoolId indexed id, address indexed owner, uint256 lot, uint256 shares, uint256 x, uint256 y);
    event Withdrawn(PoolId indexed id, address indexed owner, uint256 lot, uint256 x, uint256 y);
    event Claimed(PoolId indexed id, address indexed to, uint256 x, uint256 y);
    event JarFunded(PoolId indexed id, address indexed from, uint256 x, uint256 y);
    event CreatorSet(PoolId indexed id, address creator, bool compounds);
    event AdminProposed(address indexed admin);
    event AdminSet(address indexed admin);
    event CarrySet(address indexed carry);
    event FeeSet(PoolId indexed id, uint24 fee, uint16 edgeBps);
    event CurveSet(PoolId indexed id, uint32 lamPpm);
    event ProtocolFeeSet(PoolId indexed id, uint16 pips);
    event ProtocolFeeToSet(address indexed to);
    event ProtocolFeePaid(PoolId indexed id, address indexed to, uint256 x, uint256 y);
    event PausedSet(PoolId indexed id, bool paused);
    event Settled(PoolId indexed id);
    event TipRuleSet(uint256 jarCap, uint16 tipBps, uint16 skimBps, uint16 dueBps);
    event GateSet(uint16 gateBps, uint32 settleEvery);
    event LeaderSet(PoolId indexed id, uint8 kind, address target, bytes32 v4Id);
    event GuardianSet(address indexed guardian);
    event DepthRuleSet(uint256 minDepth, uint16 depthBps);

    error OnlyPoolManager();
    error Reentrancy();
    error UnknownPool();
    error BadParams();
    error NotLive();
    error NoAnchor();
    error OnlyCreator();
    error LiquidityDisabled();
    error ExternalInit();
    error HookNotImplemented();
    error ZeroOutput();
    error OnlyAdmin();
    error OnlyCarry();
    error Rebalancing();
    error LeaderThin();
    error Paused();

    modifier lock() {
        _enter();
        _;
        _exit();
    }

    function _enter() internal {
        uint256 slot = LOCK_SLOT;
        uint256 l;
        assembly {
            l := tload(slot)
        }
        if (l != 0) revert Reentrancy();
        assembly {
            tstore(slot, 1)
        }
    }

    function _exit() internal {
        uint256 slot = LOCK_SLOT;
        assembly {
            tstore(slot, 0)
        }
    }

    constructor(
        IPoolManager manager_,
        address v2Factory_,
        address v3Factory_,
        address weth_,
        Config memory cfg,
        address admin_,
        uint256 jarCap_
    ) {
        if (address(manager_) == address(0) || cfg.minStep == 0 || cfg.minStep >= 1e6 || admin_ == address(0)) {
            revert BadParams();
        }
        admin = admin_;
        jarCap = jarCap_;
        poolManager = manager_;
        v2Factory = v2Factory_;
        v3Factory = v3Factory_;
        weth = weth_;
        minStep = cfg.minStep;
        refToken = cfg.refToken;
        refKind = cfg.refKind;
        refTarget = cfg.refTarget;
        refV4Id = cfg.refV4Id;
        refWethIs0 = cfg.refWethIs0;
        if (cfg.refKind != 0 && BK.refSpot(manager_, cfg.refKind, cfg.refTarget, cfg.refV4Id, cfg.refWethIs0) == 0) {
            revert BadParams();
        }
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeAddLiquidity = true;
        p.beforeRemoveLiquidity = true;
        p.beforeSwap = true;
        p.beforeSwapReturnDelta = true;
    }

    // ---------------------------------------------------------------------------------------------
    // Pool creation
    // ---------------------------------------------------------------------------------------------

    /// @notice Create a pool (Carry only, same chain only). The seed is trimmed to 50/50 by value at the source's
    ///         current spot; the rest stays with the caller.
    function createPool(CreateParams calldata cp) external lock returns (PoolKey memory key, PoolId id) {
        if (msg.sender != carry) revert OnlyCarry();
        address quote = cp.quote;
        if (cp.coin == address(0) || quote == address(0) || cp.coin == quote) revert BadParams();
        if (cp.fee == 0 || cp.fee > MAX_FEE || cp.coinIn == 0 || cp.quoteIn == 0 || cp.edgeBps > MAX_EDGE_BPS) {
            revert BadParams();
        }
        Source calldata s = cp.src;
        _sameChain(s);
        address x1 = _checkSource(cp.coin, cp.quote, s, cp.srcKey, cp.srcKey2);

        bool coinIs0 = cp.coin < quote;
        (address c0, address c1) = coinIs0 ? (cp.coin, quote) : (quote, cp.coin);
        // the PoolManager refuses tickSpacing above 32767, and a wrapped value lands on an existing pool
        uint256 n = ++poolsOf[c0][c1];
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0,
            tickSpacing: int24(int256(n)),
            hooks: IHooks(address(this))
        });
        id = key.toId();
        Pool storage p = pools[id];
        if (p.exists) revert BadParams();
        p.exists = true;
        p.coinIs0 = coinIs0;
        p.coin = cp.coin;
        p.quote = quote;
        p.fee = cp.fee;
        p.edgeBps = cp.edgeBps == 0 ? EDGE_BPS0 : cp.edgeBps;
        _setShape(p, cp.lamPpm == 0 ? LAM_PPM0 : cp.lamPpm);
        p.src = s;
        p.book.creator = msg.sender;

        p.x = x1;
        // Carry: the leader's TVL is not read (no graduation test or creator cut)
        (uint256 spot,,) = _sourceSpot(p);
        if (spot == 0) revert NoAnchor();
        p.sampleX128 = spot;
        p.prevX128 = spot;
        p.sampleBlock = uint64(block.number);
        p.sampleAt = uint64(block.timestamp);
        p.anchorX128 = spot;
        p.settledBlock = uint64(block.number);
        p.settledAt = uint64(block.timestamp);
        _goLive(id, p, cp.coinIn, cp.quoteIn, spot);
        _checkDepth(id, p);

        poolManager.initialize(key, uint160(1 << 96));
        emit Created(id, cp.coin, quote, msg.sender, 0, cp.fee);
    }

    /// @dev A Carry leader is a same-chain pool: no push route and no decimal shifts.
    function _sameChain(Source calldata s) internal pure {
        if (
            s.kind < SRC_V2 || s.kind > SRC_V4 || s.kind2 > SRC_V4 || s.remoteEid != 0 || s.push || s.decShift != 0
                || s.tvlShift != 0
        ) revert BadParams();
    }

    /// @dev A same-chain source is real pools only: leg 1 holds the coin and X (the quote when there is no leg 2),
    ///      leg 2 holds X and the quote, each oriented as the source says. v2 / v3 are checked through their factory,
    ///      v4 through its key (never one of this hook's own pools). Native ETH counts as `weth`.
    function _checkSource(
        address coin,
        address quote,
        Source calldata s,
        PoolKey calldata srcKey,
        PoolKey calldata srcKey2
    ) internal view returns (address x1) {
        address a;
        (a, x1) = _legTokens(s.kind, s.target, s.v4Id, srcKey, s.coinIs0);
        if (a != coin) revert BadParams();
        address x = x1;
        if (s.kind2 != 0) {
            (address x2, address q) = _legTokens(s.kind2, s.target2, s.v4Id2, srcKey2, s.xIs0);
            if (x2 != x) revert BadParams();
            x = q;
        }
        if (x != quote) revert BadParams();
    }

    function _legTokens(uint8 kind, address target, bytes32 v4Id, PoolKey calldata k, bool baseIs0)
        internal
        view
        returns (address, address)
    {
        return BK.legTokens(kind, target, v4Id, k, baseIs0, weth, kind == SRC_V2 ? v2Factory : v3Factory);
    }

    /// @dev Trim the seed to 50/50 by value at `spot`, open the books and take the trimmed seed from the caller.
    function _goLive(PoolId id, Pool storage p, uint256 xIn, uint256 yIn, uint256 spot) internal {
        uint256 x = xIn;
        uint256 y = Math.mulDiv(x, spot, Q128);
        if (y > yIn) {
            y = yIn;
            x = Math.mulDiv(y, Q128, spot);
        }
        if (x == 0 || y == 0) revert BadParams();
        address creator = p.book.creator;
        BK.init(p.book, creator, x, y, spot);
        // Carry: paid out from the first interval, never compounded
        p.book.graduated = true;
        p.tX128 = PR.recentre(x, y);
        p.live = true;
        _moves(id, _pair(p, x, y, msg.sender, true));
        _liq(id, p, creator, x, y, true);
    }

    // ---------------------------------------------------------------------------------------------
    // Carry admin (the timelock)
    // ---------------------------------------------------------------------------------------------

    /// @notice Change a live pool's fee (pips, at most MAX_FEE) and edge (bps, at most MAX_EDGE_BPS) in one call:
    ///         fills sit at most `edgeBps` inside the leader's live quote, and never past the leader's own bid / ask
    ///         (CarryBooks.sameQuote), so no edge lets a trade round-trip against the leader at a profit.
    ///         Takes effect from the next swap.
    function setFeeAndEdge(PoolId id, uint24 fee, uint16 edgeBps) external lock {
        if (msg.sender != admin) revert OnlyAdmin();
        Pool storage p = _live(id);
        if (fee == 0 || fee > MAX_FEE || edgeBps > MAX_EDGE_BPS) revert BadParams();
        p.fee = fee;
        p.edgeBps = edgeBps;
        emit FeeSet(id, fee, edgeBps);
    }

    /// @notice Set a live pool's curve flatness (ppm, 5,000 to 250,000 = 0.005 to 0.25). The open epoch is paid
    ///         out first; the price at the curve centre does not change.
    function setCurve(PoolId id, uint32 lamPpm) external lock {
        if (msg.sender != admin) revert OnlyAdmin();
        Pool storage p = _live(id);
        _settleForCapital(p);
        _setShape(p, lamPpm);
        emit CurveSet(id, lamPpm);
    }

    function _setShape(Pool storage p, uint32 lamPpm) internal {
        uint256 sh = BK.shapeOf(uint256(lamPpm) * 1e12);
        p.lamPpm = lamPpm;
        p.ewb = uint64(uint128(sh));
    }

    /// @dev The pool's curve shape for CarryFlatMath: lam (WAD) high, expWad(W * (1 - lam)) low.
    function _shape(Pool storage p) internal view returns (uint256) {
        return ((uint256(p.lamPpm) * 1e12) << 128) | p.ewb;
    }

    /// @notice Uniswap protocol-fee passthrough for a pool, in pips of the swap input on top of the pool fee
    ///         (at most 1,000 = 0.1%; 0 = off, and then it costs a swap nothing). Kept out of the book and the
    ///         lots' earnings, counted per pool and paid to `protoTo` by `claimProtocolFee`.
    function setProtocolFee(PoolId id, uint16 pips) external lock {
        if (msg.sender != admin) revert OnlyAdmin();
        Pool storage p = _live(id);
        if (pips > MAX_PROTO_FEE) revert BadParams();
        p.protoFee = pips;
        emit ProtocolFeeSet(id, pips);
    }

    function setProtocolFeeTo(address to) external {
        if (msg.sender != admin || to == address(0)) revert OnlyAdmin();
        protoTo = to;
        emit ProtocolFeeToSet(to);
    }

    /// @notice Pay a pool's protocol fee so far to `protoTo` (anyone).
    function claimProtocolFee(PoolId id) external lock returns (uint256 x, uint256 y) {
        Pool storage p = _known(id);
        address to = protoTo;
        if (to == address(0)) revert BadParams();
        (x, y) = (p.protoX, p.protoY);
        p.protoX = 0;
        p.protoY = 0;
        _moves(id, _pair(p, x, y, to, false));
        emit ProtocolFeePaid(id, to, x, y);
    }

    /// @notice Stop (or restart) a pool's swaps and deposits. The guardian may only stop; the admin (timelock)
    ///         does both. Withdrawals and claims never stop (they need a readable leader, as they always did).
    function setPaused(PoolId id, bool paused_) external {
        if (msg.sender != admin && (msg.sender != guardian || !paused_)) revert OnlyAdmin();
        _known(id).paused = paused_;
        emit PausedSet(id, paused_);
    }

    /// @notice The deposit gate (bps, 10 to 200; it bounds what a pushed leader can take from a deposit, round-6 L-02) and the swap-path payout backstop (seconds, 10 minutes to 7 days).
    function setGate(uint16 gateBps_, uint32 settleEvery_) external {
        if (msg.sender != admin) revert OnlyAdmin();
        if (gateBps_ < 10 || gateBps_ > 200 || settleEvery_ < 10 minutes || settleEvery_ > 7 days) {
            revert BadParams();
        }
        gateBps = gateBps_;
        settleEvery = settleEvery_;
        emit GateSet(gateBps_, settleEvery_);
    }

    /// @notice Pay the open epoch's fees out to the lots now (anyone; the keeper runs it hourly).
    function settle(PoolId id) external lock {
        _settleForCapital(_live(id));
        emit Settled(id);
    }

    /// @notice Point a live pool at a new leader (same coin and quote; checked as createPool checks it). The open
    ///         interval is settled at the old leader first. The anchor then steps toward the new leader at most
    ///         `minStep` per block, as always, while every fill stays inside the new leader's live boundary.
    function setLeader(PoolId id, Source calldata s, PoolKey calldata srcKey, PoolKey calldata srcKey2)
        external
        lock
    {
        if (msg.sender != admin) revert OnlyAdmin();
        Pool storage p = _live(id);
        _sameChain(s);
        _settleForCapital(p);
        p.x = _checkSource(p.coin, p.quote, s, srcKey, srcKey2);
        p.src = s;
        (uint256 spot,,) = _sourceSpot(p);
        if (spot == 0) revert NoAnchor();
        p.sampleX128 = spot;
        p.prevX128 = spot;
        p.sampleBlock = uint64(block.number);
        p.sampleAt = uint64(block.timestamp);
        _checkDepth(id, p);
        emit LeaderSet(id, s.kind, s.target, s.v4Id);
    }

    /// @notice Set the tip jar: its cap (quote raw; a lower cap stops the skim, what a jar holds stays in it), what
    ///         a tip pays (bps of its cost, 9,000 to 15,000; 10,000 = break-even), the jar skim (bps of earnings, at
    ///         most 1,000) and the tip line (bps the centre must be from the leader, 10 to 1,000).
    function setTipRule(uint256 cap, uint16 tipBps_, uint16 skimBps_, uint16 dueBps_) external {
        if (msg.sender != admin) revert OnlyAdmin();
        if (tipBps_ < 9_000 || tipBps_ > 15_000 || skimBps_ > 1_000 || dueBps_ < 10 || dueBps_ > 1_000) {
            revert BadParams();
        }
        jarCap = cap;
        tipBps = tipBps_;
        skimBps = skimBps_;
        dueBps = dueBps_;
        emit TipRuleSet(cap, tipBps_, skimBps_, dueBps_);
    }

    /// @notice Set the leader depth rule (see `minDepth`, `depthBps`).
    function setDepthRule(uint256 minDepth_, uint16 depthBps_) external {
        if (msg.sender != admin) revert OnlyAdmin(); // a rule that shuts deposits by mistake is undone by the admin only (timelock)
        if (depthBps_ != 0 && depthBps_ < 1_000) revert BadParams(); // a pool may be at least 10% of the depth
        minDepth = minDepth_;
        depthBps = depthBps_;
        emit DepthRuleSet(minDepth_, depthBps_);
    }

    /// @notice Carry: update a pool's slow leader depth reading (anyone; the keeper runs it hourly so the
    ///         reading can climb after the leader deepens).
    function pokeDepth(PoolId id) external returns (uint256) {
        return _seeDepth(id, _live(id));
    }

    /// @dev The depth the rule uses (`BK.seeDepth`): liquidity added for one transaction cannot pass the rule, and
    ///      a leader thin now refuses deposits now. The first reading (pool creation) starts at the depth now; a
    ///      leader change keeps the slow reading, so it cannot be reset with flash liquidity.
    function _seeDepth(PoolId id, Pool storage p) internal returns (uint256) {
        Source storage s = p.src;
        (uint256 spot,, uint256 s1) = _sourceSpot(p);
        return BK.seeDepth(
            depthSeen[id], BK.depth1(poolManager, s.kind, s.target, s.v4Id, s.coinIs0, s1, spot, s.kind2 != 0)
        );
    }

    /// @dev Refuse a leader too thin for the rule, or a pool too big for its leader (audit M-2): a pool much
    ///      smaller than a 1% move of its leader cannot be milked by pushing the leader around.
    function _checkDepth(PoolId id, Pool storage p) internal {
        uint256 d = _seeDepth(id, p);
        uint256 lo = minDepth;
        uint16 r = depthBps;
        if (lo == 0 && r == 0) return;
        if (d < lo) revert LeaderThin();
        if (r != 0 && Math.mulDiv(p.book.x, p.anchorX128, Q128) + p.book.y > Math.mulDiv(d, r, 10_000)) {
            revert LeaderThin();
        }
    }

    /// @notice Set the guardian, who may stop any pool's swaps and deposits at once (`setPaused`).
    function setGuardian(address guardian_) external {
        if (msg.sender != admin) revert OnlyAdmin();
        if (guardian_ == address(0)) revert BadParams();
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    /// @notice Set the Carry adapter, once (deploy). It cannot be changed after.
    function setCarry(address carry_) external {
        if (msg.sender != admin) revert OnlyAdmin();
        if (carry != address(0) || carry_ == address(0)) revert BadParams();
        carry = carry_;
        emit CarrySet(carry_);
    }

    function proposeAdmin(address admin_) external {
        if (msg.sender != admin) revert OnlyAdmin();
        pendingAdmin = admin_;
        emit AdminProposed(admin_);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin || msg.sender == address(0)) revert OnlyAdmin();
        admin = msg.sender;
        pendingAdmin = address(0);
        emit AdminSet(msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // Swaps
    // ---------------------------------------------------------------------------------------------

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _enter();
        PoolId id = key.toId();
        Pool storage p = pools[id];
        if (!p.exists) revert UnknownPool();
        if (!p.live) revert NotLive();
        if (p.paused) revert Paused();
        if (params.amountSpecified == 0 || params.amountSpecified == type(int256).min) revert BadParams();

        (uint256 kb, uint256 ks, uint256 pb, uint256 ps, uint256 spot) = _prepareSame(p);

        bool exactIn = params.amountSpecified < 0;
        uint256 spec = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        // input is currency0 when zeroForOne; the input is the coin on a sell
        bool sell = params.zeroForOne == p.coinIs0;
        (uint256 coinAmt, uint256 quoteAmt, uint256 pf) =
            _fillP(p, p.book.x, p.book.y, p.tX128, sell ? ks : kb, sell ? ps : pb, sell, exactIn, spec);
        // v0.3: the book records each swap's earnings (paid out per epoch) at the less favourable of the anchor and
        // the leader, so the anchor's lag behind the leader is never booked as fees (round-6 N-1). The leader counts
        // only as far as both this block's sample and the live spot agree: a leader pushed for the sample alone and
        // put back cannot book a made-up loss. A real move of any size is marked in full once it is in the block's
        // sample; a move after the block's first touch is marked from the next block (the conservative side).
        {
            uint256 a = p.anchorX128;
            uint256 sm = p.sampleX128;
            if (sell) {
                if (spot > sm) sm = spot;
                p.book.swap(int256(coinAmt), -int256(quoteAmt), sm < a ? sm : a);
            } else {
                if (spot < sm) sm = spot;
                p.book.swap(-int256(coinAmt), int256(quoteAmt), sm > a ? sm : a);
            }
        }
        if (pf != 0) {
            // the protocol fee stays as claims outside the book (no transfer on the swap path)
            if (sell) p.protoX += uint128(pf);
            else p.protoY += uint128(pf);
        }

        (Currency coinC, Currency quoteC) = p.coinIs0 ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        Currency inC = sell ? coinC : quoteC;
        Currency outC = sell ? quoteC : coinC;
        uint256 inAmt = (sell ? coinAmt : quoteAmt) + pf;
        uint256 outAmt = sell ? quoteAmt : coinAmt;
        // claims only: the PoolManager need not hold the input token yet (the swapper pays after the hook runs)
        inC.take(poolManager, address(this), inAmt, true);
        outC.settle(poolManager, address(this), outAmt, true);

        {
            // input is currency0 when zeroForOne
            int128 i = int128(uint128(inAmt));
            int128 o = -int128(uint128(outAmt));
            uint128 f = uint128(inAmt * p.fee / 1e6); // inAmt < 2^127 and fee < 2^24: no overflow
            (int128 a0, int128 a1, uint128 f0, uint128 f1) =
                params.zeroForOne ? (i, o, f, uint128(0)) : (o, i, uint128(0), f);
            emit HookSwap(PoolId.unwrap(id), sender, a0, a1, f0, f1);
        }
        _exit();
        // exact in: the specified currency is the input; exact out: it is the output
        BeforeSwapDelta delta = exactIn
            ? toBeforeSwapDelta(int128(uint128(inAmt)), -int128(uint128(outAmt)))
            : toBeforeSwapDelta(-int128(uint128(outAmt)), int128(uint128(inAmt)));
        return (IHooks.beforeSwap.selector, delta, 0);
    }

    /// @dev The curve fill against reserves (u coin, v quote) and seed ratio t: the (coin, quote) amounts the book
    ///      moves for `spec` in or out, and the protocol fee `pf` on top of the input (in the input token; 0 when
    ///      the pool's passthrough is off). Exact in: the fee comes out of `spec`; exact out: it is added to the
    ///      input. k and b are the side's slope and match boundary.
    function _fillP(
        Pool storage p,
        uint256 u,
        uint256 v,
        uint256 t,
        uint256 k,
        uint256 b,
        bool sell,
        bool exactIn,
        uint256 spec
    ) internal view returns (uint256 coinAmt, uint256 quoteAmt, uint256 pf) {
        // the request and both sides must fit the int128 swap delta (scanner 2026-11-04; quote() too: audit I-1)
        if (spec > uint128(type(int128).max)) revert BadParams();
        uint256 pr = p.protoFee;
        if (pr != 0 && exactIn) {
            pf = Math.mulDiv(spec, pr, 1e6 + pr, Math.Rounding.Ceil);
            spec -= pf;
        }
        (coinAmt, quoteAmt) = BK.fill(u, v, t, k, b, sell, exactIn, spec, _shape(p));
        if (quoteAmt == 0 || coinAmt == 0) revert ZeroOutput();
        if (pr != 0 && !exactIn) pf = Math.mulDiv(sell ? coinAmt : quoteAmt, pr, 1e6, Math.Rounding.Ceil);
        if (coinAmt + pf > uint128(type(int128).max) || quoteAmt + pf > uint128(type(int128).max)) revert BadParams();
    }

    /// @notice Top up a pool's tip jar with its own tokens (anyone).
    function fundJar(PoolId id, uint256 x, uint256 y) external lock {
        Pool storage p = _known(id);
        p.jarX += x;
        p.jarY += y;
        _moves(id, _pair(p, x, y, msg.sender, true));
        emit JarFunded(id, msg.sender, x, y);
    }

    /// @notice Read-only quote: the same (amountIn, amountOut) as a swap sent in this block against
    ///         this state, from a plain view call (no revert to decode, usable from other contracts and quoters). It
    ///         works out what the swap's first touch would change without writing it: the anchor step, and on the
    ///         first swap of a block the jar skim the settle takes out of the reserves (or, cross chain, entering
    ///         local mode). Graduation and TVL readings do not move the price, so they are not needed here.
    function quoteView(PoolId id, bool zeroForOne, int256 amountSpecified)
        external
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        Pool storage p = _live(id); // UnknownPool / NotLive, as a swap (audit v0.2 L-6)
        if (p.paused) revert Paused();
        if (amountSpecified == 0 || amountSpecified == type(int256).min) revert BadParams();
        uint256 u = p.book.x;
        uint256 v = p.book.y;
        uint256 t = p.tX128;
        uint256 kb;
        uint256 ks;
        uint256 pb;
        uint256 ps;
        {
            (uint256 spot, uint24 srcFee,) = _sourceSpot(p);
            if (spot == 0) revert NoAnchor();
            uint256 a = p.sampleBlock < block.number ? _stepped(p) : p.anchorX128;
            if (_due(p) && p.book.dy != 0) {
                // the settle's skim and, on a graduated pool, its payout leave the reserves (audit v0.2 M-1)
                uint256 ox;
                uint256 oy;
                (ox, oy, t) = BK.settlePreview(p.book, a, _jarRoom(p, a, a), t, skimBps);
                u -= ox;
                v -= oy;
            }
            (kb, ks, pb, ps) = BK.sameQuote(a, t, p.fee, spot, srcFee, p.edgeBps);
        }
        bool exactIn = amountSpecified < 0;
        bool sell = zeroForOne == p.coinIs0;
        (uint256 c, uint256 q, uint256 pf) = _fillP(
            p,
            u,
            v,
            t,
            sell ? ks : kb,
            sell ? ps : pb,
            sell,
            exactIn,
            uint256(exactIn ? -amountSpecified : amountSpecified)
        );
        (amountIn, amountOut) = sell ? (c + pf, q) : (q + pf, c);
    }

    /// @notice Refresh a same-chain pool's source price sample without a trade. Anyone may call. The first call
    ///         in a block steps the anchor toward the previous sample and records the live one. It does not settle,
    ///         observe source TVL, or move graduation. While the centre is at least 1% from the leader the caller
    ///         is paid gas (with the L1 data fee) + 5% from the pool's tip jar (nothing if the pool's tokens cannot be valued in ETH).
    function sample(PoolId id) external lock {
        uint256 g0 = gasleft();
        Pool storage p = _live(id);
        if (p.sampleBlock >= block.number) return;
        uint256 a0 = p.anchorX128;
        (uint256 spot,) = _latchSame(p, false);
        if (!SM.movedBeyond(a0, spot, dueBps)) return;
        uint256 o = TIP_OVERHEAD;
        uint256 slot = TIP_TX_SLOT;
        bool first;
        assembly {
            first := iszero(tload(slot))
            if first {
                o := add(o, TIP_INTRINSIC)
                tstore(slot, 1)
            }
        }
        // Carry: gas at the basefee, plus the transaction's L1 data fee (Arbitrum Orbit) once per transaction,
        // as the intrinsic gas; paid at `tipBps` of cost (cost + 5% at launch)
        uint256 w = (g0 - gasleft() + o) * block.basefee;
        if (first) w += BK.l1Fee();
        uint256 q = _weiToQuote(p, w * tipBps / 10_000, p.anchorX128);
        if (q == 0) return;
        (uint256 cx, uint256 cy) = BK.tip(p.jarX, p.jarY, a0, q, TIP_DIV);
        p.jarX -= cx;
        p.jarY -= cy;
        _moves(id, _pair(p, cx, cy, msg.sender, false));
        emit Tipped(id, msg.sender, cx, cy);
    }

    /// @notice Whether sample() would pay a tip now: a live same-chain pool, not sampled yet this block, centre at
    ///         least 1% from the live leader, and something in the jar. For keepers (call it before sending).
    function sampleDue(PoolId id) external view returns (bool) {
        Pool storage p = pools[id];
        if (!p.live || p.sampleBlock >= block.number || p.jarX + p.jarY == 0) return false;
        (uint256 spot,,) = _sourceSpot(p);
        return SM.movedBeyond(p.anchorX128, spot, dueBps);
    }

    /// @dev `w` wei in the pool's quote, at the pool's centre and the reference pool (0 = cannot value).
    /// @dev `a`: the pool's centre to value at (the stored anchor, or the stepped one in quoteView: audit v0.2 I-1).
    function _weiToQuote(Pool storage p, uint256 w, uint256 a) internal view returns (uint256) {
        address q = p.quote;
        address c = p.coin;
        if (q == weth) return w;
        bool viaRef = q == refToken || c == refToken;
        if (viaRef) {
            if (refKind == 0) return 0;
            // fail-soft: a reference pool that cannot be read pays no tip and never reverts a swap (audit I-2)
            uint256 r = BK.refSpot(poolManager, refKind, refTarget, refV4Id, refWethIs0);
            w = Math.mulDiv(w, r, Q128);
            if (q == refToken) return w;
        } else if (c != weth) {
            // a two-hop source through WETH prices it: leg 2 is WETH/quote
            Source storage s = p.src;
            if (s.kind2 == 0 || p.x != weth) return 0;
            (uint256 r2,) = _leg(s.kind2, s.target2, s.v4Id2, s.xIs0);
            return Math.mulDiv(w, r2, Q128);
        }
        return Math.mulDiv(w, a, Q128);
    }

    /// @dev Room left in the jar, in quote raw at `mark`: `jarCap` less what it holds.
    function _jarRoom(Pool storage p, uint256 mark, uint256 a) internal view returns (uint256) {
        // Carry: a fixed cap in quote (same chain only), not a number of gas-priced tips
        (a);
        uint256 cap = jarCap;
        uint256 have = Math.mulDiv(p.jarX, mark, Q128) + p.jarY; // at the settle mark (audit L-1)
        return cap > have ? cap - have : 0;
    }

    /// @dev Close the open interval at `mark`, skimming into the jar (`dist` false: local mode, no payout).
    function _settleSame(Pool storage p, uint256 mark, bool dist) internal {
        (uint256 jy, uint256 t) = BK.settle(p.book, mark, dist, _jarRoom(p, mark, p.anchorX128), p.tX128, skimBps);
        p.jarY += jy;
        p.tX128 = t;
        p.settledBlock = uint64(block.number);
        p.settledAt = uint64(block.timestamp);
    }

    /// @dev v0.3: a swap pays out the open epoch only as a backstop, when no payout ran for `settleEvery`.
    function _due(Pool storage p) internal view returns (bool) {
        return block.timestamp >= uint256(p.settledAt) + settleEvery;
    }

    /// @dev The anchor the next latch would set: one step from the anchor toward the newest sample.
    function _stepped(Pool storage p) internal view returns (uint256) {
        return SM.stepToward(p.anchorX128, p.sampleX128, minStep);
    }

    /// @dev Settle the books if due, update the anchor state, and return the curve slopes and boundaries.
    function _prepareSame(Pool storage p)
        internal
        returns (uint256 kb, uint256 ks, uint256 pb, uint256 ps, uint256 spot)
    {
        uint24 srcFee;
        (spot, srcFee) = _latchSame(p, true);
        (kb, ks, pb, ps) = BK.sameQuote(p.anchorX128, p.tX128, p.fee, spot, srcFee, p.edgeBps);
    }

    /// @dev Same chain, first price touch of a block: step the anchor toward the newest source sample taken in an
    ///      earlier block (at most minStep per reading). Then record the live source for the next block. `settleBooks` (swaps) also pays out the open epoch when
    ///      none ran for `settleEvery` (the backstop). sample() and capital moves pass false.
    ///      Returns the live spot and the source fee for the match boundary.
    function _latchSame(Pool storage p, bool settleBooks) internal returns (uint256 spot, uint24 srcFee) {
        (spot, srcFee,) = _sourceSpot(p);
        if (spot == 0) revert NoAnchor();
        if (p.sampleBlock < block.number) {
            p.anchorX128 = _stepped(p);
            p.prevX128 = p.sampleX128;
            p.sampleX128 = spot;
            p.sampleBlock = uint64(block.number);
            p.sampleAt = uint64(block.timestamp);
        }
        // v0.3: epochs. Swaps settle only as a backstop; capital moves, claims and settle() pay out themselves
        // (_settleForCapital). An empty epoch has nothing to pay, so it is skipped.
        if (settleBooks && p.book.dy != 0 && _due(p)) _settleSame(p, p.anchorX128, true);
    }

    // ---------------------------------------------------------------------------------------------
    // LP actions
    // ---------------------------------------------------------------------------------------------

    /// @notice Carry: add coin and quote 50/50 by value at the anchor, whatever the pool's mix; the lot joins the
    ///         back of the boost line. Shares are by value at the worst (for the depositor) of the anchor, the live
    ///         leader and an earlier block's sample. The curve centre moves so the quoted price does not change: the
    ///         pool keeps its current imbalance, shared by all lots. Refused while the anchor is more than `gateBps`
    ///         from the live leader or the earlier sample (the pool is still catching up). Unused tokens stay with
    ///         the caller.
    function deposit(PoolId id, uint256 maxX, uint256 maxY) external lock returns (uint256 lot, uint256 shares) {
        if (msg.sender != carry) revert OnlyCarry();
        Pool storage p = _live(id);
        if (p.paused) revert Paused();
        _settleForCapital(p);
        uint256 m = p.anchorX128;
        uint256 prev = p.prevX128;
        (uint256 spot,,) = _sourceSpot(p);
        // v0.3 (audit M-1, without keeper samples): the deposit reads the live leader itself. It is refused only
        // while the anchor is more than `gateBps` (1% at launch, was 0.1% to 0.25%) from the live leader or from an
        // earlier block's sample, and it is valued at whichever of the three gives the depositor the fewest shares.
        // So a stale anchor, or a leader pushed in this block, can only cost the depositor, never the lots already
        // in. The keeper's tipped samples (from 1% off) keep the anchor inside the gate.
        uint256 g = gateBps;
        if (SM.movedBeyond(m, spot, g) || SM.movedBeyond(m, prev, g)) revert Rebalancing();
        uint256 x0 = p.book.x;
        uint256 y0 = p.book.y;
        uint256 tx_;
        uint256 ty_;
        (lot, shares, tx_, ty_) = BK.depositAt(p.book, msg.sender, maxX, maxY, m, spot, prev);
        // T' = T * (y' / x') * (x0 / y0), one rounding (reserves stay far below 2^128, so the products fit)
        p.tX128 = Math.mulDiv(p.tX128, p.book.y * x0, p.book.x * y0);
        if (p.tX128 == 0) revert BadParams();
        if (shares == 0) revert ZeroOutput();
        _checkDepth(id, p);
        _moves(id, _pair(p, tx_, ty_, msg.sender, true));
        _liq(id, p, msg.sender, tx_, ty_, true);
        emit Deposited(id, msg.sender, lot, shares, tx_, ty_);
    }

    /// @notice Burn principal shares `s` and compound balance `bal` from a lot, paid in both tokens pro rata.
    function withdraw(PoolId id, uint256 lot, uint256 s, uint256 bal) external lock returns (uint256 x, uint256 y) {
        Pool storage p = _live(id);
        _settleForCapital(p);
        (x, y) = BK.withdraw(p.book, lot, msg.sender, s, bal);
        _moves(id, _pair(p, x, y, msg.sender, false));
        _liq(id, p, msg.sender, x, y, false);
        emit Withdrawn(id, msg.sender, lot, x, y);
    }

    /// @notice Collect a lot's escrowed payouts (every Carry pool is graduated from launch).
    function claim(PoolId id, uint256 lot) external lock returns (uint256 x, uint256 y) {
        Pool storage p = _live(id);
        // v0.3: a claim pays out the open epoch to every lot first, so it gets its fees up to now
        _settleForCapital(p);
        (x, y) = BK.claim(p.book, lot, msg.sender);
        _moves(id, _pair(p, x, y, msg.sender, false));
        emit Claimed(id, msg.sender, x, y);
    }

    function _settleForCapital(Pool storage p) internal {
        _latchSame(p, false);
        // trades earlier in this block: close them now, so capital joining or leaving never shares in fees earned
        // before it (review D-01). Each swap already booked its earnings at its own price, so the mark only sizes the
        // payout; it is the stored anchor, which a price pushed in this transaction cannot move (round-6 M-01)
        if (p.book.dy != 0) _settleSame(p, p.anchorX128, true);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    struct PoolView {
        address coin;
        address quote;
        bool live;
        bool graduated;
        bool creatorOn;
        uint256 coinReserve;
        uint256 quoteReserve;
        uint256 anchorX128;
        uint256 ageOrBlock;
        uint256 tX128; // curve centre ratio (quote raw per coin raw, X128): reserves at this ratio quote the anchor
        uint256 principal;
        uint256 compounded;
        uint256 lots;
        uint64 sampleAt;
        uint256 jarX;
        uint256 jarY;
    }

    /// @notice Carry: read one storage slot (for `CarryLens.poolInfo`, which decodes the pool's settings).
    function extsload(bytes32 slot) external view returns (bytes32 v) {
        assembly {
            v := sload(slot)
        }
    }

    function poolState(PoolId id) external view returns (PoolView memory v) {
        Pool storage p = _known(id);
        LG.Book storage b = p.book;
        v.coin = p.coin;
        v.quote = p.quote;
        v.live = p.live;
        v.graduated = b.graduated;
        v.creatorOn = b.creatorOn;
        v.coinReserve = b.x;
        v.quoteReserve = b.y;
        v.anchorX128 = p.anchorX128;
        v.ageOrBlock = p.settledBlock;
        v.tX128 = p.tX128;
        v.principal = b.sp;
        v.compounded = b.b;
        v.lots = b.count;
        v.sampleAt = p.sampleAt;
        v.jarX = p.jarX;
        v.jarY = p.jarY;
    }

    /// @notice Lot info. Call from a static context for up-to-date figures (it checkpoints the lot).
    function lotState(PoolId id, uint256 lot)
        external
        returns (address owner, uint256 principal, uint256 compounded, uint256 claimX, uint256 claimY)
    {
        Pool storage p = _live(id);
        (principal, compounded, claimX, claimY) = BK.poke(p.book, lot);
        owner = p.book.lots[lot].owner;
    }

    // ---------------------------------------------------------------------------------------------
    // Source reads
    // ---------------------------------------------------------------------------------------------

    /// @dev Same-chain source spot (X128 quote raw per coin raw), its fee in pips, and leg 1's own spot (X raw
    ///      per coin raw). Two-hop: spot = leg 1 x leg 2, fee = both legs' fees compounded (rounded up).
    function _sourceSpot(Pool storage p) internal view returns (uint256 spot, uint24 fee, uint256 s1) {
        Source storage s = p.src;
        (spot, fee) = _leg(s.kind, s.target, s.v4Id, s.coinIs0);
        s1 = spot;
        if (s.kind2 != 0) {
            (uint256 s2, uint24 f2) = _leg(s.kind2, s.target2, s.v4Id2, s.xIs0);
            spot = Math.mulDiv(spot, s2, Q128);
            uint256 f = uint256(fee) + f2 - uint256(fee) * f2 / 1e6;
            fee = f >= 1e6 ? 999_999 : uint24(f);
        }
    }

    function _leg(uint8 kind, address target, bytes32 v4Id, bool baseIs0)
        internal
        view
        returns (uint256 spot, uint24 fee)
    {
        return BK.leg(poolManager, kind, target, v4Id, baseIs0);
    }

    // ---------------------------------------------------------------------------------------------
    // Hook plumbing
    // ---------------------------------------------------------------------------------------------

    function beforeInitialize(address, PoolKey calldata, uint160) external view returns (bytes4) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        revert ExternalInit();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert LiquidityDisabled();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert LiquidityDisabled();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _known(PoolId id) internal view returns (Pool storage p) {
        p = pools[id];
        if (!p.exists) revert UnknownPool();
    }

    function _live(PoolId id) internal view returns (Pool storage p) {
        p = _known(id);
        if (!p.live) revert NotLive();
    }

    /// @dev HookModifyLiquidity in currency order; `add` = into the pool.
    function _liq(PoolId id, Pool storage p, address who, uint256 x, uint256 y, bool add) internal {
        int128 a = int128(uint128(x));
        int128 b = int128(uint128(y));
        if (!add) (a, b) = (-a, -b);
        if (!p.coinIs0) (a, b) = (b, a);
        emit HookModifyLiquidity(PoolId.unwrap(id), who, a, b);
    }

    function _pair(Pool storage p, uint256 x, uint256 y, address who, bool into)
        internal
        view
        returns (Move[] memory m)
    {
        m = new Move[](2);
        m[0] = Move(p.coin, who, x, into);
        m[1] = Move(p.quote, who, y, into);
    }

    /// @dev Run token movements between ERC20 and pool `id`'s claims in one PoolManager unlock.
    function _moves(PoolId id, Move[] memory m) internal {
        id;
        poolManager.unlock(abi.encode(m));
    }

    /// @notice PoolManager callback for this contract's own `unlock` calls: token moves between ERC20 and claims.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        Move[] memory m = abi.decode(data, (Move[]));
        for (uint256 i = 0; i < m.length; i++) {
            Move memory mv = m[i];
            if (mv.amt == 0) continue;
            Currency c = Currency.wrap(mv.token);
            if (mv.into) {
                c.settle(poolManager, mv.who, mv.amt, false);
                c.take(poolManager, address(this), mv.amt, true);
            } else {
                c.settle(poolManager, address(this), mv.amt, true);
                c.take(poolManager, mv.who, mv.amt, false);
            }
        }
        return "";
    }
}
