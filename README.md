# Carry hook

A custom-curve Uniswap v4 hook that takes its price from the pair's main Uniswap pool and uses its own reserves for size. Every swap fills inside the main pool's spread, on a curve with a flat center and steep tails.

This repo holds the exact source of the hook as deployed on **Robinhood Chain mainnet (chain 4663)**, its libraries, the vault adapter and the read-only lens, with their unit tests. The Carry vault and site live elsewhere.

## Deployed (Robinhood Chain, chain 4663)

| Contract | Address |
|---|---|
| CarryStrategy (the hook) | [`0x5800dd5c9D56C1DC9e6eB05892a6BA8e039B2A88`](https://robinhoodchain.blockscout.com/address/0x5800dd5c9D56C1DC9e6eB05892a6BA8e039B2A88?tab=contract) |
| CarryBooks (external library) | [`0xda9313469414432b21edcfdd874ba448153901e2`](https://robinhoodchain.blockscout.com/address/0xda9313469414432b21edcfdd874ba448153901e2?tab=contract) |
| CarryStrategyAdapter (vault → hook, MSTR market) | [`0xF8746E93eA69D8DE73b9D141e3552B1d84BaF185`](https://robinhoodchain.blockscout.com/address/0xF8746E93eA69D8DE73b9D141e3552B1d84BaF185?tab=contract) |
| CarryLens (read only) | [`0x25A1971df57D4848d7c7a5ED4880cAbaDBDE2fBa`](https://robinhoodchain.blockscout.com/address/0x25A1971df57D4848d7c7a5ED4880cAbaDBDE2fBa?tab=contract) |
| Carry vault (the only liquidity source) | [`0x58F1888b7dD66e216f4c0165774bDbcaE3DBd816`](https://robinhoodchain.blockscout.com/address/0x58F1888b7dD66e216f4c0165774bDbcaE3DBd816) |
| Timelock (hook admin) | [`0x9065da33204Ccc5Ccf292624916598a4673ee7A3`](https://robinhoodchain.blockscout.com/address/0x9065da33204Ccc5Ccf292624916598a4673ee7A3) |
| Uniswap v4 PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |

All are verified (Sourcify, full match).

**MSTR/USDG pool** id `0xdf918ec569657b705c4973e1312814152e42a4a01e93634b480b3ac26b8819fa`
(currency0 USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, currency1 MSTR `0xec262a75e413fAfD0dF80480274532C79D42da09`, fee 0, tick spacing 1).
Main (reference) pool: Uniswap v4 MSTR/USDG `0x319bac87e616a89e241c10aeb8afd4892a852cdd8b373cd9765ecddc40b87cfe` (no hook).

## How it works

- **Tracks the main pool.** Each swap is priced off the pair's main Uniswap v4 pool. The pool's centre price steps toward that pool's spot (capped per block), and every fill stays at or inside the main pool's live bid and ask, up to a set edge (23 bp today).
- **Flat center.** Near 50/50 the curve is almost flat (LAM 0.02), so most depth sits at the market price. As trades tilt the pool, the price leans slightly toward the side that rebalances it.
- **Steep tails.** Past about 2.7x off balance the curve turns constant-product, so large one-way trades pay more and neither side runs dry.
- **Early-deposit bonus.** Positions form one line; fees are weighted 7x at the front, falling to 1.2x at the back.
- **Vault-only liquidity.** `beforeAddLiquidity` / `beforeRemoveLiquidity` always revert; only the Carry vault (through the adapter) can deposit. Stock deposits are paired 50/50 with lender USDG.
- **Swaps.** `beforeSwapReturnsDelta` (custom accounting) against the hook's own reserves, held as ERC-6909 claims in the PoolManager. Exact in and exact out, no hookData. `quoteView(poolId, zeroForOne, amountSpecified)` gives a quote off chain.
- **Admin.** Not upgradeable, no proxy. Fee (0.05% today), edge, curve, protocol-fee passthrough and pool pause are bounded settings held by a TimelockController whose proposer/executor is a 2-of-4 Safe.

Hook permission flags (from the address, `...2A88`): beforeInitialize, beforeAddLiquidity, beforeRemoveLiquidity, beforeSwap, beforeSwapReturnsDelta.

## Build, test, verify

```
git clone --recurse-submodules https://github.com/makerlee0x/carry-hook && cd carry-hook
forge test
python3 script/verify-bytecode.py        # compares the build with the mainnet bytecode
```

The verify script masks only immutables (constructor values), the CarryBooks link address and the library's own address; every other byte must match. Compiler settings are in `foundry.toml` (solc 0.8.26, via_ir, 200 runs, cancun, no metadata).

`PROVENANCE.md` records where the code came from (the Disciple follower hook) and the renames.

## License

MIT
