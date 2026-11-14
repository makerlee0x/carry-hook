# Disciple follower hook (Carry v2)

Carry v2 runs each stock market in a Disciple follower pool: a Uniswap v4 hook that prices every swap off a leader
pool (MSTR/USDG v4 0.25% to start) instead of holding concentrated liquidity. See the v2 design spec
(https://claude.ai/artifact/GyCJiVb3RJJfPVRNtDpwxB).

- Source: makerlee0x/disciple, branch `claude/project-thread-udhera`, commit `041bcd9acaec087f8f9eab77318b66f917cc5f38`
  (`contracts/src/hook/DiscipleHook.sol`, `DiscipleBooks.sol`, `libraries/`, and `contracts/src/libraries/CurrencySettler.sol`).
  Nov 12 2026: the hook contract is renamed `CarryStrategy` (`src/CarryStrategy.sol`) so explorers show that name; the
  libraries keep their Disciple names.
  Nov 14 2026 (before the v0.3 deploy): the libraries and the lens are renamed to Carry names, a pure rename with
  identical bytecode: `DiscipleBooks` -> `CarryBooks`, `DiscipleLens` -> `CarryLens`, `DiscipleLedger` -> `CarryLedger`,
  `DiscipleSwapMath` -> `CarrySwapMath`, `DiscipleFlatMath` -> `CarryFlatMath`, `DisciplePrice` -> `CarryPrice`,
  `DiscipleDepth` -> `CarryDepth` (tests under `test/libraries/` likewise).
  The library tests under `test/libraries/` come from the same commit. The LayerZero push routes are not copied: Carry
  pools are same-chain only.
- The first commit of this folder is that copy with only two mechanical edits, so later diffs show Carry's changes:
  - Carry's v4-core (`d153b04`, the DualPool pin) moved `SwapParams` and `ModifyLiquidityParams` out of
    `IPoolManager` into `types/PoolOperation.sol`. The hook imports them from there.
  - `CurrencySettler.sol` sits in `src/libraries/`, so its import path changed.
- Build and test: `FOUNDRY_PROFILE=follower forge test`. Settings follow the Disciple repo: solc 0.8.26, via_ir,
  optimizer runs 200, cancun.
- Deploying needs a hook address whose low bits match `getHookPermissions()` (mine one with CREATE2).
- Carry step 3 removed the cross-chain code paths (LayerZero push, local mode, held seeds, keeper credits and
  `collect`) from the hook, since Carry pools are same-chain only, and added the Morpho tail (`DiscipleTail.sol`,
  a linked library).
- Carry step 4 added `CarryFollowerVault.sol`, the Carry adapter (the hook's `carry`): pooled lenders with idle USDG
  in Morpho, 50/50 stock positions, the fee split and treasury cut, and the matched-lender swap exit. It is new
  Carry code, not vendored from Disciple.
- Carry step 5 added the mainnet deploy script (`script/DeployCarryFollowerMainnet.s.sol`) and its fork test
  (`test/fork/CarryFollowerMainnet.t.sol`, run by CI's `fork` job), plus `openPositionsOf` on the vault for
  STRATEGY staking.
- Carry step 6 pointed the site at v2: `public/js/carry-chain.js` reads and transacts with the v2 vault and hook when
  `config.json` sets `chain.carryVersion: 2` (the mainnet config does), the app copy and in-app docs describe v2
  (`scripts/v2-site-copy.py`, `scripts/build-docs.py`), and `docs/MAINNET_SITE.md` lists the v2 config keys.
- Post-merge harden: `DeployCarryFollowerMainnet` leaves the vault **paused** until the timelock unpauses; CI runs
  `FollowerEip170Test` so CarryStrategy / CarryFollowerVault / CarryBooks (DiscipleBooks before Nov 14) / DiscipleTail stay under EIP-170.
- Site PR #102 follows the #101 ABI (9-field positions, shortfallOf, LeaderThin / IdleDown copy).
- Close all / Claim all: `close(ids[], maxSells[], minSaleOuts[])` (replaces `close` and `closeMin`) and `harvestMany(ids[])`.
- One market at a time: `addMarket(cp, cap, seedOwner)` opens the seed position for `seedOwner` (the deployer) and
  refunds the unused seed to it, so a market the timelock adds later still has the deployer's seed, fees and close.
  `DeployCarryFollowerMainnet` launches only `LAUNCH_MARKETS` (default MSTR), and `script/CarryAddMarket.s.sol` adds
  the rest (runbook: `docs/CARRY_V2_MARKETS.md`; auditor addendum: seed-owner).
