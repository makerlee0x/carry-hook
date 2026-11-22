# Routing notes for integrators

For routers and aggregators quoting the Carry hook on Robinhood Chain (4663). Values were read on chain on 2026-11-22.

| | |
|---|---|
| Hook | `0x5800dd5c9D56C1DC9e6eB05892a6BA8e039B2A88` |
| Pool | `0xdf918ec569657b705c4973e1312814152e42a4a01e93634b480b3ac26b8819fa` (MSTR/USDG) |
| PoolKey | currency0 USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, currency1 MSTR `0xec262a75e413fAfD0dF80480274532C79D42da09`, fee 0, tickSpacing 1 |
| Flags | beforeInitialize, beforeAddLiquidity, beforeRemoveLiquidity, beforeSwap, beforeSwapReturnsDelta |
| Price source | Uniswap v4 MSTR/USDG `0x319bac87e616a89e241c10aeb8afd4892a852cdd8b373cd9765ecddc40b87cfe` (no hook, fee 0.25%, tickSpacing 25) |

## Zero liquidity, custom accounting

Carry fills every swap in `beforeSwap` from its own reserves, which it holds as ERC-6909 claims in the PoolManager. The whole swap settles inside one unlock.

- The PoolManager's `liquidity` for the pool is always 0, and its subgraph TVL will read near 0.
- `slot0` stays at the value `createPool` passed to `initialize`: `sqrtPriceX96 = 2^96` (tick 0). It is a placeholder, not a price. Read the price from a quote. In Uniswap's router this is `sqrtPriceFromQuoter: true`.
- The standard V4Quoter prices the pool correctly. The hook also has a read-only quote with no revert to decode: `quoteView(poolId, zeroForOne, amountSpecified)` returns `(amountIn, amountOut)`.
- Exact in and exact out are both supported. No hookData. The price is the same for every sender: nothing depends on `sender`, `tx.origin` or calldata.
- The hook emits `HookSwap(id, sender, amount0, amount1, fee0, fee1)` on every swap.

## Gas

V4Quoter `gasEstimate`, same block (119,872,143), for a single hop:

| | Carry | MSTR/USDG v4 (no hook) |
|---|---|---|
| Exact-in, $1 to $25 | ~151,000 | ~43,000 |
| Exact-in, $50 to $100 | ~154,000 | ~43,000 |

The extra cost is about 110k per hop. A heuristic overhead of 150,000 per hop is a safe setting (Uniswap's `gasOverheadPerHop`). The hook needs no minimum `gasleft()`.

## Which pools exist

The set of pools is closed. `beforeInitialize` reverts with `ExternalInit` for everyone. Only the Carry vault adapter (`carry()` = `0xF8746E93eA69D8DE73b9D141e3552B1d84BaF185`) can create a pool, and it does that through the hook. Nobody else can open a Carry pool on any token. Today there is one pool: MSTR/USDG.

`beforeAddLiquidity` and `beforeRemoveLiquidity` always revert with `LiquidityDisabled`. LPs deposit through the Carry vault, never through the PoolManager or a position manager, so LP screens should not offer this pool.

## How the price is set

- **Centre price (anchor).** On the first swap or sample in each block, the anchor steps toward the leader's spot as recorded in an earlier block. Each step is at most `minStep` (10,000 pips = 1%). `block.number` on Robinhood Chain is the L1 block number (about 12 s). A leader price pushed within one transaction never enters the anchor in that transaction, and a faked sample can move the anchor by at most one step.
- **Curve.** Near 50/50 the curve is nearly flat (LAM 0.02), and the pool fee is 0.05%. Far off balance (about 2.7x) it turns constant-product, so neither side runs dry.
- **Bound from the live leader.** Every fill is also capped by the leader's live bid and ask in the same call. Our ask is at least `leaderAsk * (1 - edge)`, and never below the leader's own bid. Our bid is at most `leaderBid * (1 + edge)`, and never above the leader's own ask. The edge is 23 bp. So no trade can buy here and sell into the leader at a profit, or the reverse. The live bound only limits a fill: moving the leader inside a transaction can make our price worse for the trader, never better.

Size: the pool is small (about 1.4 MSTR + 101 USDG). It beats the leader on small trades and falls behind from about $12. V4Quoter results at block 119,872,143, compared with the leader:

| Trade | Buy MSTR | Sell MSTR |
|---|---|---|
| $1 | +22.5 bp | +21.4 bp |
| $5 | +15.1 bp | +13.9 bp |
| $10 | +5.5 bp | +4.6 bp |
| $15 | -4.3 bp | -4.7 bp |
| $25 | -24.4 bp | -23.1 bp |

## Reverts a quote can hit

| Error | When |
|---|---|
| `UnknownPool` / `NotLive` | Not a Carry pool, or not live |
| `Paused` | Pool paused by the admin or guardian |
| `BadParams` | `amountSpecified` is 0 or `type(int256).min`, or an amount doesn't fit int128 |
| `ZeroOutput` | The trade is too small to give a non-zero amount on both sides |
| `NoAnchor` | The leader returned no price |
| `Reentrancy` | Re-entered within the same hook call |

An exact-out larger than the pool's reserves can't be filled and reverts.

## Fees

- **LP fee:** 0.05% of the input, taken inside the hook. The PoolKey fee is 0, because the PoolManager's own swap does nothing.
- **Uniswap protocol fee:** the PoolManager's protocol fee can't apply here, since the PoolManager swaps nothing. Instead the hook has a passthrough: `setProtocolFee(pool, pips)` (at most 1,000 pips) adds a fee on top of the input, and `claimProtocolFee(pool)` (anyone can call it) pays the total to `protoTo`. Uniswap's fee adapter on Robinhood (`0x6d0009504D129CF5002Dba61D9Ae8575AA79314c`) returns `getFee = 0` for this pool key today. The passthrough is set to match whatever it returns, paid to Uniswap's TokenJar (`0x2Ac03e14cfE755426DaAeE0a4994184cE81482F8`).

## Admin powers

The hook is not upgradeable and has no proxy. `admin()` is a TimelockController (`0x9065da33204Ccc5Ccf292624916598a4673ee7A3`). Its only proposer, executor and canceller is a 2-of-4 Safe (`0xfca980530914188772F913011369C00780AB15fa`). The timelock delay is 0 today, and a 48-hour delay is planned when the public site launches.

| Call | Who | Hard limit in code |
|---|---|---|
| `setFeeAndEdge` | admin | fee 1 to 30,000 pips (max 3%); edge at most 500 bp |
| `setCurve` | admin | LAM 0.005 to 0.25 |
| `setProtocolFee` / `setProtocolFeeTo` | admin | at most 1,000 pips; recipient not zero |
| `setLeader` | admin | same coin and quote as the pool; the anchor still moves at most `minStep` per block |
| `setGate`, `setTipRule`, `setDepthRule` | admin | bounded deposit and keeper settings; they don't change swap prices |
| `setPaused` | admin; guardian can pause only | stops swaps and deposits; withdrawals still work |
| `setGuardian`, admin handover | admin | two-step handover (`pendingAdmin`) |

No setting can move user funds, mint claims or skip the live-leader bound.

## Source and verification

- Source: this repo, the exact deployed code. `python3 script/verify-bytecode.py` compares the build with mainnet bytecode.
- Explorer: verified on [Blockscout](https://robinhoodchain.blockscout.com/address/0x5800dd5c9D56C1DC9e6eB05892a6BA8e039B2A88?tab=contract) via Sourcify (full match).
- Hooklist: [`hooks/robinhood/0x5800…2a88.json`](https://github.com/Uniswap/hooklist/blob/main/hooks/robinhood/0x5800dd5c9d56c1dc9e6eb05892a6ba8e039b2a88.json).
