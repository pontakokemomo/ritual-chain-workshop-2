# Ritual Predict — contracts

The `RitualPredict` market contract, its tests, and the deployment scripts.
Full architecture and the workshop runbook live in [../README.md](../README.md).

## Layout

```
contracts/
  RitualPredict.sol          the market: creation, betting, autonomous resolution, payouts
  RitualPredict.t.sol        Solidity unit tests
  ritual/RitualChain.sol     canonical Ritual addresses + system contract interfaces
  mocks/RitualMocks.sol      test-only stand-ins for the precompiles and system contracts
test/
  RitualPredict.e2e.ts       end-to-end walkthroughs of the workshop flow
scripts/
  block-time.ts              measure the chain's current block time
  deploy.ts                  deploy + prepay execution fees
  fund.ts                    top up the prepaid execution balance
  status.ts                  live state of every market
  create-demo-market.ts      create the preset market from the CLI
  export-abi.ts              copy the compiled ABI into the frontend
```

## Commands

```bash
cp .env.example .env                            # RITUAL_PRIVATE_KEY, funded from the faucet

npx hardhat test                                # 132 Solidity + 3 TypeScript tests
npx hardhat test solidity                       # Solidity unit tests only
npx hardhat test nodejs                         # TypeScript end-to-end tests only
npx hardhat test solidity --gas-stats           # with a gas usage table
npx hardhat build                               # compile
npx hardhat build && npx tsc --noEmit           # compile, then typecheck

npx hardhat run scripts/block-time.ts           # measure block time
npx hardhat run scripts/deploy.ts               # deploy to Ritual Chain
PREDICT_ADDRESS=0x... npx hardhat run scripts/status.ts
PREDICT_ADDRESS=0x... npx hardhat run scripts/fund.ts
```

## Tests

Nothing here needs network access, a funded account, or a live Ritual Chain. The precompiles and
system contracts do not exist locally, so the mocks' runtime code is placed at the canonical Ritual
addresses instead: `vm.etch` in the Solidity tests, `hardhat_setCode` in the TypeScript ones. The
contract under test is never modified and never told it is being tested. It calls `0x0801`,
`0x0803`, the Scheduler and the TEEServiceRegistry by their real addresses.

**`contracts/RitualPredict.t.sol` — 132 Solidity unit tests**, covering the contract from the
inside: the resolution path and its failure modes, boundary values around the comparator and the
stake sizes, the full state machine, the simulate-and-replay double execution, interrupted and
re-run executions, reentrancy, transaction ordering, insufficient balances, and gas under load.

**`test/RitualPredict.e2e.ts` — 3 TypeScript end-to-end tests**, covering the same market from the
outside: a wallet signs real transactions, blocks are actually mined between them, and every read
goes through the ABI exactly as a frontend would see it. A market runs from creation to a winner
being paid; an unreachable oracle exhausts its three attempts and everyone is refunded; and the
whole market list is read back the way a UI would render it.

These run on Hardhat's in-process EVM by default. To run them against a real local node instead:

```bash
npx hardhat node                                # in one terminal
E2E_NETWORK=localhost npx hardhat test nodejs   # in another
```
