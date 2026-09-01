# Starter repository: findings and fixes

Notes from getting `cozfuttu/ritual-chain-workshop-2` to build and test cleanly on a
fresh machine (Windows 11, Node v24.13.1, pnpm 11.9.0), before touching any
contract logic.

## Summary

Out of the box, `npx hardhat build` succeeds but `npx hardhat test` fails, and the
documented `.env` workflow does not work. Both are artifacts of how the starter was
assembled: the five commits span 15 minutes (`427a269` 19:45:56 to `6e93b08`
20:00:57, 2026-08-14) and the repository has not been touched since.

## Finding 1: `.env` is never read

`hardhat/.env.example` line 1 states the file is "loaded automatically by
hardhat.config.ts". It is not. The final commit `6e93b08` ("chore: moved to config
variables") deleted the `process.loadEnvFile()` call that made this true:

```diff
-try {
-  process.loadEnvFile();
-} catch {}
```

The same commit also hardcoded the RPC URL, dropping the `RITUAL_RPC_URL` override
that `.env.example` still documents as available.

## Finding 2: private key variable name mismatch

The same commit renamed the key lookup, but `.env.example` and `hardhat/README.md`
were not updated:

| Source | Name |
| --- | --- |
| `.env.example` | `RITUAL_PRIVATE_KEY` |
| `hardhat/README.md` | `RITUAL_PRIVATE_KEY` |
| `hardhat.config.ts` (before this fix) | `DEPLOYER_PRIVATE_KEY` |

Two of the three sources agree, so the config was aligned to them rather than the
other way around. `configVariable()` itself is kept: it is the newer mechanism, it
gives a clear error when the value is absent, and it also resolves Hardhat's
encrypted keystore in addition to environment variables.

## Finding 3: orphaned scaffold test

`test/Counter.ts` arrived with `7e1ce86` ("feat: starter") as leftover Hardhat
scaffolding. Its contract `Counter.sol` was never committed, so every run failed:

```
HardhatError: HHE1000: Artifact for contract "Counter" not found.
```

Compiling alone does not surface this, which is consistent with the suite never
having been run before publication.

## Changes made

| File | Change |
| --- | --- |
| `hardhat/hardhat.config.ts` | Restored `process.loadEnvFile()`; restored the `RITUAL_RPC_URL` override; renamed `DEPLOYER_PRIVATE_KEY` to `RITUAL_PRIVATE_KEY` |
| `hardhat/test/Counter.ts` | Removed |

### Verification

| Command | Before | After |
| --- | --- | --- |
| `npx hardhat build` | exit 0 | exit 0 |
| `npx hardhat test` | exit 1, 2 failing | exit 0 |
| `process.loadEnvFile()` on Node 24 | n/a | confirmed reads `.env` |

`.gitignore` already excludes `.env` and `.env.*` while keeping `.env.example`, so
restoring `.env` support does not risk committing a key.

## Still missing from the starter

`hardhat/README.md` and the deployment scripts describe files that were never
committed. These are the gaps this fork sets out to fill:

| Referenced by | Path | Status |
| --- | --- | --- |
| `hardhat/README.md` | `contracts/RitualPredict.t.sol` (33 Solidity tests) | absent |
| `hardhat/README.md` | `contracts/mocks/RitualMocks.sol` | absent |
| `hardhat/README.md` | `test/RitualPredict.e2e.ts` (2 TypeScript tests) | absent |
| `scripts/deploy.ts:92`, `scripts/export-abi.ts:12`, `scripts/market-presets.ts:17` | `web/` frontend | absent |

`contracts/RitualPredict.sol` also carries five unimplemented bodies marked
`// we'll fill this up`, at lines 208, 240, 380, 423 and 432:
`createMarket`, `onScheduledResolve`, `_readOracle`, `_pickExecutor` and
`_scheduleResolution`.
