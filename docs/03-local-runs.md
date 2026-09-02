# Local runs

Ritual Chain was down for the duration of this workshop, so nothing here was deployed
and no transaction hash exists. Everything below was run locally, and this file is the
record of those runs: the commands, and their real output, pasted unedited.

Reproduce any of it by cloning the repo and running the same command in `hardhat/`.

```
Date            2026-09-02
OS              Windows 11
Node            v24.13.1
Hardhat         3.13.0
solc            0.8.28 (optimizer on, 200 runs)
Test framework  Solidity tests via forge-std 1.9.4, TypeScript tests via node:test + viem
```

Nothing here needs network access or a funded account. Ritual's precompiles and system
contracts do not exist on a local chain, so the mocks' runtime code is placed at the
canonical addresses instead: `vm.etch` in the Solidity tests, `hardhat_setCode` in the
TypeScript ones. `RitualPredict` itself is unmodified and is never told it is being
tested; it calls `0x0801`, `0x0803`, the Scheduler and the TEEServiceRegistry by their
real addresses.

---

## 1. The whole suite

```bash
npx hardhat test
```

135 tests, all passing: 132 Solidity unit tests and 3 TypeScript end-to-end tests.

```
No contracts to compile

Running Solidity tests

  contracts/RitualPredict.t.sol:RitualPredictTest
    ✔ test_StakesOf_ReportsWhatIsClaimable()
    ✔ test_Resolve_YesWhenTheObservedValueMeetsTheTarget()
    ✔ test_Resolve_ThreeFailedAttemptsInvalidateTheMarket()
    ✔ test_Resolve_SurvivesASchedulerThatRefusesToCancel()
    ✔ test_Resolve_SucceedsOnALaterAttempt()
    ✔ test_Resolve_SendsTheConfiguredRequestToAnExecutor()
    ✔ test_Resolve_RevertsWhenTheCallerIsNotTheScheduler()
    ✔ test_Resolve_RerollsTheExecutorOnEveryAttempt()
    ✔ test_Resolve_NoWhenTheObservedValueMissesTheTarget()
    ✔ test_Resolve_IsIdempotentAfterResolution()
    ✔ test_Resolve_IgnoresAnUnknownMarket()
    ✔ test_Resolve_IgnoresATriggerBeforeTheResolveBlock()
    ✔ test_Resolve_HonoursEveryComparator()
    ✔ test_Resolve_FailsWhenTheReturndataIsNotAnEnvelope()
    ✔ test_Resolve_FailsWhenTheRegistryIsUnreachable()
    ✔ test_Resolve_FailsWhenThePrecompileCallFails()
    ✔ test_Resolve_FailsWhenTheJqCallReverts()
    ✔ test_Resolve_FailsWhenTheBodyDoesNotMatchTheJsonPath()
    ✔ test_Resolve_FailsWhenNoExecutorIsAvailable()
    ✔ test_Resolve_FailsWhenJqYieldsNothing()
    ✔ test_Resolve_FailsWhenJqReturnsFewerThan32Bytes()
    ✔ test_Resolve_FailsOnAnUnsettledEnvelope()
    ✔ test_Resolve_FailsOnAnExecutorErrorMessage()
    ✔ test_Resolve_FailsOnANon200Status()
    ✔ test_Resolve_FailsOnAMalformedPayload()
    ✔ test_Resolve_ExecutorChoiceDoesNotDependOnTheBlock()
    ✔ test_Resolve_EmptyWinningSideBecomesRefundable()
    ✔ test_Resolve_CancelsTheRemainingAttempts()
    ✔ test_Rerun_TheSimulationPassIsDiscardedAndTheReplayDecides()
    ✔ test_Rerun_SettlingOneMarketLeavesTheOthersUntouched()
    ✔ test_Rerun_EachRetryIsItsOwnSimulateAndReplayPair()
    ✔ test_Rerun_ClaimingOnOneMarketLeavesTheOtherClaimable()
    ✔ test_Rerun_BothPassesBuildTheIdenticalRequest()
    ✔ test_Rerun_AnExecutionThatRunsOutOfGasLeavesNoTrace()
    ✔ test_Rerun_AWinnerCannotGrabARefundDuringItsOwnPayout()
    ✔ test_Rerun_ARejectedPayoutCanBeClaimedAgainLater()
    ✔ test_Rerun_AReentrantWinnerCannotBePaidTwice()
    ✔ test_Rerun_AReentrantRefundCannotBeTakenTwice()
    ✔ test_Refund_RevertsWhileTheMarketIsResolved()
    ✔ test_Refund_ReturnsEveryStakeAfterThreeFailures()
    ✔ test_Load_ResolutionFitsInsideTheBookedGasLimit()
    ✔ test_Load_GetMarketsCostGrowsWithEveryMarketEverCreated()
    ✔ test_Load_ClaimCostDoesNotGrowWithTheNumberOfWinners()
    ✔ test_Load_BettingCostDoesNotGrowWithTheCrowd()
    ✔ test_Load_ABusyMarketStillResolvesAndPaysOut()
    ✔ test_GetMarkets_ReturnsNewestFirst()
    ✔ test_GetMarket_RevertsOnAnUnknownMarket()
    ✔ test_GetMarket_FlipsToClosedAtTheCloseBlock()
    ✔ test_Funds_TheContractHoldsExactlyWhatItStillOwes()
    ✔ test_Funds_AMarketIsBookedEvenWithNoPrepaidBalance()
    ✔ test_Funds_ABettorWithoutTheMoneyCannotBet()
    ✔ test_FundExecution_RevertsOnZero()
    ✔ test_FundExecution_DepositsIntoTheRitualWallet()
    ✔ test_Fsm_ThreeFailedReadsEndInInvalid()
    ✔ test_Fsm_SettlingIsPerAccountNotPerMarket()
    ✔ test_Fsm_ResolvingRejectsEveryUserAction()
    ✔ test_Fsm_ResolvedRejectsBetsAndRefunds()
    ✔ test_Fsm_ResolvedIsTerminalEvenIfTheOracleChangesItsMind()
    ✔ test_Fsm_ResolutionWorksFromTheDerivedClosedState()
    ✔ test_Fsm_RefundIsAOneWayTransitionPerAccount()
    ✔ test_Fsm_OpenRejectsBothClaims()
    ✔ test_Fsm_InvalidRejectsBetsAndWinnings()
    ✔ test_Fsm_InvalidIsTerminalEvenWhenTheOracleRecovers()
    ✔ test_Fsm_HappyPathOpenToClosedToResolved()
    ✔ test_Fsm_FailedReadParksInResolvingThenRecovers()
    ✔ test_Fsm_EmptyWinningSideJumpsStraightToInvalid()
    ✔ test_Fsm_ClosedRejectsEveryUserAction()
    ✔ test_Fsm_ClosedIsDerivedFromTheBlockNotStored()
    ✔ test_CreateMarket_StoresTheResolutionRule()
    ✔ test_CreateMarket_SchedulingConstantsAreWithinSchedulerLimits()
    ✔ test_CreateMarket_RevertsWhenLongerThanTheMaximum()
    ✔ test_CreateMarket_RevertsOnAnEmptyQuestion()
    ✔ test_CreateMarket_RevertsOnAnEmptyOracleUrl()
    ✔ test_CreateMarket_RevertsOnAnEmptyJsonPath()
    ✔ test_CreateMarket_RevertsOnAShortResolveDelay()
    ✔ test_CreateMarket_RevertsOnAShortBettingWindow()
    ✔ test_CreateMarket_ReturnsIncrementingIds()
    ✔ test_CreateMarket_EncodesTheExecutionIndexPlaceholder()
    ✔ test_CreateMarket_EmitsTheResolutionRule()
    ✔ test_CreateMarket_EmitsMarketCreated()
    ✔ test_CreateMarket_DoublesABasefeeAboveTheFloor()
    ✔ test_CreateMarket_ConvertsSecondsToBlocks()
    ✔ test_CreateMarket_BooksThreeAttemptsWithTheScheduler()
    ✔ test_CreateMarket_AppliesTheFeeFloor()
    ✔ test_Constructor_RevertsOnZeroBlockTime()
    ✔ test_Constructor_ApprovesTheScheduler()
    ✔ test_Concurrency_TwentyBetsInOneBlock()
    ✔ test_Concurrency_PayoutsDependOnTotalsNotOnArrivalOrder()
    ✔ test_Concurrency_MarketsCreatedInOneBlockStaySeparate()
    ✔ test_Concurrency_ALateBetDilutesTheBackersAlreadyOnThatSide()
    ✔ test_Clock_TheWallClockCannotChangeAnything()
    ✔ test_Clock_ASuddenJumpDoesNotCloseOrOpenAMarket()
    ✔ test_Claim_RevertsOnASecondClaim()
    ✔ test_Claim_RevertsBeforeResolution()
    ✔ test_Claim_PaysTheProportionalShare()
    ✔ test_Claim_LeavesTheLoserWithNothing()
    ✔ test_Boundary_ZeroTargetIsAlwaysMetByGte()
    ✔ test_Boundary_ZeroTargetAndZeroObserved()
    ✔ test_Boundary_VerySlowChainClampsToOneBlock()
    ✔ test_Boundary_VeryFastChainProducesLargeBlockCounts()
    ✔ test_Boundary_ThirdAttemptCanStillResolveTheMarket()
    ✔ test_Boundary_SingleParticipantOnTheWinningSideTakesEverything()
    ✔ test_Boundary_ResolveRunsOnTheResolveBlockItself()
    ✔ test_Boundary_ResolveIsIgnoredOneBlockEarly()
    ✔ test_Boundary_OneWeiOnEachSideStillPaysOut()
    ✔ test_Boundary_OneSecondOverTheMaximumReverts()
    ✔ test_Boundary_ObservedOneBelowTarget_GTE_IsNo()
    ✔ test_Boundary_ObservedOneAboveTarget_LTE_IsNo()
    ✔ test_Boundary_ObservedOneAboveTarget_GT_IsYes()
    ✔ test_Boundary_ObservedEqualsTarget_LT_IsNo()
    ✔ test_Boundary_ObservedEqualsTarget_LTE_IsYes()
    ✔ test_Boundary_ObservedEqualsTarget_GT_IsNo()
    ✔ test_Boundary_ObservedEqualsTarget_GTE_IsYes()
    ✔ test_Boundary_MinimumResolveDelayIsAccepted()
    ✔ test_Boundary_MinimumBettingWindowIsAccepted()
    ✔ test_Boundary_MaxUintTarget()
    ✔ test_Boundary_MarketWithNoBetsAtAllBecomesInvalid()
    ✔ test_Boundary_FiftyWinnersCanAllClaim()
    ✔ test_Boundary_ExactlyTheMaximumMarketLengthIsAccepted()
    ✔ test_Boundary_EveryoneOnTheWinningSideGetsTheirStakeBack()
    ✔ test_Boundary_DustFromIntegerDivisionStaysBehind()
    ✔ test_Boundary_BetSucceedsOnTheBlockBeforeClose()
    ✔ test_Boundary_AstronomicalStakesStillPayOut()
    ✔ test_Bet_TracksPerAccountStakes()
    ✔ test_Bet_RevertsOnZeroStake()
    ✔ test_Bet_RevertsOnAnUnknownMarket()
    ✔ test_Bet_RevertsAtTheCloseBlock()
    ✔ test_Bet_AccumulatesBothPools()
    ✔ testFuzz_ResolutionIsAlwaysAfterTheCloseBlock(uint32,uint32) (runs: 256)
    ✔ testFuzz_RefundsReturnExactlyWhatWasStaked(uint96,uint96) (runs: 256)
    ✔ testFuzz_PayoutsNeverExceedThePool(uint96,uint96,uint96) (runs: 256)
    ✔ testFuzz_GteMatchesTheTargetExactly(uint256) (runs: 256)

Running node:test tests

  RitualPredict end to end
    ✔ runs a market from creation to a winner being paid (106ms)
    ✔ refunds everyone when the oracle cannot be read three times
    ✔ exposes every market to a frontend in one call, newest first


135 passing (132 solidity, 3 nodejs)
```

---

## 2. Gas, measured rather than assumed

```bash
npx hardhat test solidity --gas-stats
```

```
╔══════════════════════════════════════════════════════════════════════════════════╗
║ contracts/RitualPredict.sol:RitualPredict                                        ║
╟───────────────────────────┬─────────┬─────────┬─────────┬─────────┬──────────────╢
║ Function name             │ Min     │ Average │ Median  │ Max     │ #calls       ║
╟───────────────────────────┼─────────┼─────────┼─────────┼─────────┼──────────────╢
║ bet                       │ 55931   │ 60635   │ 55956   │ 73056   │ 723          ║
║ claimRefund               │ 61813   │ 61813   │ 61813   │ 61813   │ 8            ║
║ claimWinnings             │ 64437   │ 64437   │ 64437   │ 64437   │ 339          ║
║ createMarket              │ 439604  │ 480786  │ 493740  │ 494100  │ 192          ║
║ decodeHttpResponse        │ 4148    │ 4150    │ 4148    │ 4204    │ 76           ║
║ executionBalance          │ 5600    │ 5600    │ 5600    │ 5600    │ 3            ║
║ fundExecution             │ 75799   │ 75799   │ 75799   │ 75799   │ 2            ║
║ getMarket                 │ 37486   │ 37587   │ 37526   │ 41885   │ 338          ║
║ getMarkets                │ 40692   │ 718184  │ 250173  │ 2331697 │ 4            ║
║ HTTP_TTL_BLOCKS           │ 250     │ 250     │ 250     │ 250     │ 2            ║
║ marketCount               │ 2326    │ 2326    │ 2326    │ 2326    │ 1            ║
║ MAX_ATTEMPTS              │ 315     │ 315     │ 315     │ 315     │ 5            ║
║ MAX_MARKET_SECONDS        │ 251     │ 251     │ 251     │ 251     │ 5            ║
║ MIN_BETTING_SECONDS       │ 228     │ 228     │ 228     │ 228     │ 3            ║
║ MIN_MAX_FEE_PER_GAS       │ 317     │ 317     │ 317     │ 317     │ 1            ║
║ MIN_RESOLVE_DELAY_SECONDS │ 250     │ 250     │ 250     │ 250     │ 6            ║
║ onScheduledResolve        │ 23980   │ 23980   │ 23980   │ 23980   │ 1            ║
║ RESOLVE_GAS_LIMIT         │ 292     │ 292     │ 292     │ 292     │ 3            ║
║ RETRY_INTERVAL_BLOCKS     │ 269     │ 269     │ 269     │ 269     │ 2            ║
║ SCHEDULER_TTL_BLOCKS      │ 249     │ 249     │ 249     │ 249     │ 3            ║
║ stakesOf                  │ 9583    │ 14648   │ 16871   │ 16871   │ 11           ║
╟───────────────────────────┼─────────┼─────────┼─────────┼─────────┼──────────────╢
║ Deployment                │ Min     │ Average │ Median  │ Max     │ #deployments ║
╟───────────────────────────┼─────────┼─────────┼─────────┼─────────┼──────────────╢
║                           │ 2649928 │ 2649936 │ 2649928 │ 2649952 │ 3            ║
╟───────────────────────────┼─────────┼─────────┴─────────┴─────────┴──────────────╢
║ Bytecode size             │ 11879   │                                            ║
╚═══════════════════════════╧═════════╧════════════════════════════════════════════╝
```

Four numbers in that table matter, and each has a test asserting it:

**`onScheduledResolve` — a full resolution costs ~223,000 gas** (the 23,980 row is the
`onlyScheduler` rejection path; the resolving path is measured directly inside
`test_Load_ResolutionFitsInsideTheBookedGasLimit`). `createMarket` books each execution
with `RESOLVE_GAS_LIMIT = 2,000,000`, so there is roughly a ninefold margin. If a
resolution did not fit inside the gas it booked for itself, every market on the real
chain would fail to settle, which makes this the single most important number here.

**`claimWinnings` — exactly 64,437 gas across all 339 calls.** Not an average that
happens to look flat: every single call cost the same. Payouts are pull-based and
loop-free, so a winner's cost does not depend on how many other winners exist.

**`bet` — 55,931 gas at the minimum, median 55,956, across 723 calls.** The 73,056
maximum is only the first bet into each pool, where cold storage is written for the
first time. The two-hundredth bettor pays what the second one paid.

**`getMarkets` — 40,692 gas at one market, 2,331,697 at sixty.** This is the only
unbounded loop in the contract, at roughly 39,000 gas per market. An `eth_call` is not
bound by the block gas limit, but a node's RPC cap is typically 50M, which puts the
practical ceiling near 1,200 markets. Fine for a workshop, and a real limit to know
about before it becomes a surprise.

---

## 3. Against a real local Hardhat node

The end-to-end tests run on Hardhat's in-process EVM by default. They can also be
pointed at an actual node over JSON-RPC, which exercises the same contract through a
real network round trip rather than an in-memory one.

```bash
npx hardhat node                                # terminal 1
E2E_NETWORK=localhost npx hardhat test nodejs   # terminal 2
```

```
No contracts to compile

Running node:test tests

  RitualPredict end to end
    ✔ runs a market from creation to a winner being paid (1623ms)
    ✔ refunds everyone when the oracle cannot be read three times (1457ms)
    ✔ exposes every market to a frontend in one call, newest first (1028ms)


  3 passing (5527ms)
```

The same three tests take ~5.5s here against ~1.8s in-process, which is the JSON-RPC
round trips showing up. `hardhat.config.ts` carries the `localhost` network entry this
uses, and `test/RitualPredict.e2e.ts` picks it up from `E2E_NETWORK`.

---

## 4. Typechecking

```bash
npx hardhat build && npx tsc --noEmit
```

Clean, no output. This reported seven `TS5097` errors on the starter's `scripts/*.ts`
until `tsconfig.json` gained `allowImportingTsExtensions` and `noEmit`: Hardhat 3 runs
TypeScript through Node's type stripping, which requires the `.ts` extension in import
paths, and TypeScript only permits that when it is not emitting JavaScript. Nothing in
this project is compiled to JavaScript, so `noEmit` is simply the truth.

---

## What the tests actually cover

The 132 Solidity tests examine the contract from the inside:

| Area | What it pins down |
| --- | --- |
| Creation and scheduling | Durations in seconds converted to blocks, three attempts booked 200 blocks apart in one `schedule()` call, the fee floor, every input rejection |
| The oracle read path | The exact request bytes sent to `0x0801`, executor selection from the registry, jq extraction, and every way a read can fail |
| Simulate and replay | The simulation pass is discarded and only the replay counts; both passes build byte-identical request bytes even 250 blocks apart at a different basefee |
| Boundary values | `observed == target` for all four comparators, one wei per side, 2^120 wei per side, zero and max-uint targets, minimum and maximum durations, the exact close and resolve blocks |
| State machine | All five states, every user action in every state, and that `Resolved` and `Invalid` are terminal |
| Interrupted execution | An execution that runs out of gas leaves no trace, and the next attempt still resolves |
| Reentrancy | Four attacker contracts: no double payout, no cross-function drain, and a rejected transfer settles nothing so it can be claimed again later |
| Ordering | Payouts depend on pool totals, not on the order bets arrived in; twenty bets in a single block; resolution can never land in the same block as a bet |
| The wall clock | The contract never reads `block.timestamp`, proven by running an identical market on a leap day, on 2100-03-01, and in the year 9999 and comparing every field |
| Empty wallets | A bettor who cannot cover the stake, and a market booked with no prepaid execution balance |
| Load | The four gas figures above, plus 151 uneven stakes settling without overdrawing the pool by a single wei |

The 3 TypeScript tests examine the same market from the outside, the way a frontend or
a deployment script would: a wallet signs real transactions, blocks are genuinely mined
between them, and every read goes through the ABI.
