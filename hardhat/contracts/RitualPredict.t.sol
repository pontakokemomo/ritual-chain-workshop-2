// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {RitualPredict} from "./RitualPredict.sol";
import {RitualChain} from "./ritual/RitualChain.sol";
import {MockScheduler, MockHttpPrecompile, MockJqPrecompile, MockTeeServiceRegistry, MockRitualWallet} from "./mocks/RitualMocks.sol";

/**
 * Unit tests for RitualPredict.
 *
 * `vm.etch` places the mock runtime code at the canonical Ritual addresses, so the
 * contract under test reaches the Scheduler, the precompiles, the TEE registry and
 * RitualWallet through the same constants it uses on chain. Nothing here needs a
 * network or a funded account.
 */
contract RitualPredictTest is Test {
    uint256 constant BLOCK_TIME_MS = 195;

    string constant QUESTION = "Will ETH/USD be at least 4000 when this resolves?";
    string constant ORACLE_URL = "https://oracle.example/v1/price";
    string constant JSON_PATH = ".ethereum.usd";
    string constant ORACLE_JSON = '{"ethereum":{"usd":4200}}';
    uint256 constant OBSERVED = 4200;
    uint256 constant TARGET = 4000;

    uint256 constant BETTING_SECONDS = 60;
    uint256 constant RESOLVE_DELAY_SECONDS = 30;

    RitualPredict predict;
    MockScheduler scheduler;
    MockHttpPrecompile http;
    MockJqPrecompile jq;
    MockTeeServiceRegistry registry;
    MockRitualWallet wallet;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCAC0);

    address constant EXECUTOR_A = address(0xE1);
    address constant EXECUTOR_B = address(0xE2);

    function setUp() public {
        vm.etch(RitualChain.SCHEDULER, address(new MockScheduler()).code);
        vm.etch(
            RitualChain.HTTP_PRECOMPILE,
            address(new MockHttpPrecompile()).code
        );
        vm.etch(RitualChain.JQ_PRECOMPILE, address(new MockJqPrecompile()).code);
        vm.etch(
            RitualChain.TEE_SERVICE_REGISTRY,
            address(new MockTeeServiceRegistry()).code
        );
        vm.etch(
            RitualChain.RITUAL_WALLET,
            address(new MockRitualWallet()).code
        );

        scheduler = MockScheduler(RitualChain.SCHEDULER);
        http = MockHttpPrecompile(RitualChain.HTTP_PRECOMPILE);
        jq = MockJqPrecompile(RitualChain.JQ_PRECOMPILE);
        registry = MockTeeServiceRegistry(RitualChain.TEE_SERVICE_REGISTRY);
        wallet = MockRitualWallet(RitualChain.RITUAL_WALLET);

        // The etched copies start with blank storage, so the default world is built here.
        registry.addExecutor(EXECUTOR_A);
        registry.addExecutor(EXECUTOR_B);
        http.setResponse(200, bytes(ORACLE_JSON), "");
        jq.setResult(JSON_PATH, ORACLE_JSON, OBSERVED);

        vm.roll(1_000);
        vm.fee(1 gwei);

        predict = new RitualPredict(BLOCK_TIME_MS);

        vm.deal(address(this), 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
    }

    // ───────────────────────────── helpers ──────────────────────────────

    function _params()
        internal
        pure
        returns (RitualPredict.NewMarket memory p)
    {
        p = RitualPredict.NewMarket({
            question: QUESTION,
            oracleUrl: ORACLE_URL,
            jsonPath: JSON_PATH,
            target: TARGET,
            comparator: RitualPredict.Comparator.GTE,
            bettingSeconds: BETTING_SECONDS,
            resolveDelaySeconds: RESOLVE_DELAY_SECONDS
        });
    }

    function _create() internal returns (uint256 id) {
        id = predict.createMarket(_params());
    }

    function _scheduleIdOf(uint256 id) internal view returns (uint256) {
        return predict.getMarket(id).scheduleId;
    }

    function _rollToResolve(uint256 id) internal {
        vm.roll(predict.getMarket(id).resolveBlock);
    }

    function _fire(uint256 id, uint256 executionIndex) internal {
        scheduler.fire(_scheduleIdOf(id), executionIndex);
    }

    /// A market with stakes on both sides, rolled forward and ready to be woken.
    function _armedMarket() internal returns (uint256 id) {
        id = _create();
        vm.prank(alice);
        predict.bet{value: 3 ether}(id, true);
        vm.prank(bob);
        predict.bet{value: 1 ether}(id, false);
        _rollToResolve(id);
    }

    function _state(uint256 id) internal view returns (RitualPredict.MarketState) {
        return predict.getMarket(id).state;
    }

    // ══════════════════════════ createMarket ═══════════════════════════

    function test_CreateMarket_ReturnsIncrementingIds() public {
        assertEq(_create(), 1);
        assertEq(_create(), 2);
        assertEq(predict.marketCount(), 2);
    }

    function test_CreateMarket_StoresTheResolutionRule() public {
        uint256 id = _create();
        RitualPredict.Market memory m = predict.getMarket(id);

        assertEq(m.id, id);
        assertEq(m.creator, address(this));
        assertEq(m.question, QUESTION);
        assertEq(m.oracleUrl, ORACLE_URL);
        assertEq(m.jsonPath, JSON_PATH);
        assertEq(m.target, TARGET);
        assertEq(uint256(m.comparator), uint256(RitualPredict.Comparator.GTE));
        assertEq(uint256(m.state), uint256(RitualPredict.MarketState.Open));
        assertEq(uint256(m.outcome), uint256(RitualPredict.Outcome.Unresolved));
        assertEq(m.attempts, 0);
    }

    function test_CreateMarket_ConvertsSecondsToBlocks() public {
        uint256 start = block.number;
        uint256 id = _create();
        RitualPredict.Market memory m = predict.getMarket(id);

        assertEq(m.closeBlock, start + (BETTING_SECONDS * 1000) / BLOCK_TIME_MS);
        assertEq(
            m.resolveBlock,
            m.closeBlock + (RESOLVE_DELAY_SECONDS * 1000) / BLOCK_TIME_MS
        );
        assertGt(m.resolveBlock, m.closeBlock);
    }

    function test_CreateMarket_BooksThreeAttemptsWithTheScheduler() public {
        uint256 id = _create();
        RitualPredict.Market memory m = predict.getMarket(id);
        MockScheduler.Call memory c = scheduler.getCall(m.scheduleId);

        assertEq(c.to, address(predict), "the Scheduler calls back the market");
        assertEq(c.payer, address(predict), "the market pays for itself");
        assertEq(uint256(c.startBlock), m.resolveBlock);
        assertEq(uint256(c.numCalls), uint256(predict.MAX_ATTEMPTS()));
        assertEq(
            uint256(c.frequency),
            uint256(predict.RETRY_INTERVAL_BLOCKS())
        );
        assertEq(uint256(c.ttl), uint256(predict.SCHEDULER_TTL_BLOCKS()));
        assertEq(uint256(c.gas), uint256(predict.RESOLVE_GAS_LIMIT()));
        assertEq(c.value, 0);
    }

    /// The TTL is the binding constraint: it has to outlast trigger drift *and* the
    /// async HTTP settlement, because the settlement replay re-checks it.
    function test_CreateMarket_SchedulingConstantsAreWithinSchedulerLimits()
        public
        view
    {
        assertLe(
            uint256(predict.RETRY_INTERVAL_BLOCKS()) *
                uint256(predict.MAX_ATTEMPTS()),
            10_000,
            "frequency * numCalls must stay under MAX_LIFESPAN"
        );
        assertLe(
            uint256(predict.SCHEDULER_TTL_BLOCKS()),
            500,
            "TTL must stay under the Scheduler maximum"
        );
        assertGt(
            uint256(predict.SCHEDULER_TTL_BLOCKS()),
            predict.HTTP_TTL_BLOCKS(),
            "the scheduled tx must outlive the HTTP request it makes"
        );
    }

    function test_CreateMarket_EncodesTheExecutionIndexPlaceholder() public {
        uint256 id = _create();
        bytes memory data = scheduler.getCall(_scheduleIdOf(id)).data;

        assertEq(data.length, 4 + 32 + 32);

        bytes32 selectorWord;
        uint256 firstArg;
        uint256 secondArg;
        assembly {
            selectorWord := mload(add(data, 32))
            firstArg := mload(add(data, 36))
            secondArg := mload(add(data, 68))
        }
        assertEq(
            bytes4(selectorWord),
            RitualPredict.onScheduledResolve.selector
        );
        assertEq(firstArg, 0, "bytes 4-35 are the Scheduler's to overwrite");
        assertEq(secondArg, id);
    }

    function test_CreateMarket_AppliesTheFeeFloor() public {
        vm.fee(0);
        uint256 id = _create();
        MockScheduler.Call memory c = scheduler.getCall(_scheduleIdOf(id));

        assertEq(c.maxFeePerGas, predict.MIN_MAX_FEE_PER_GAS());
        assertEq(c.maxPriorityFeePerGas, 0);
    }

    function test_CreateMarket_DoublesABasefeeAboveTheFloor() public {
        vm.fee(5 gwei);
        uint256 id = _create();
        assertEq(scheduler.getCall(_scheduleIdOf(id)).maxFeePerGas, 10 gwei);
    }

    function test_CreateMarket_EmitsTheResolutionRule() public {
        vm.expectEmit(true, false, false, true, address(predict));
        emit RitualPredict.ResolutionRuleSet(
            1,
            ORACLE_URL,
            JSON_PATH,
            TARGET,
            RitualPredict.Comparator.GTE
        );
        _create();
    }

    function test_CreateMarket_EmitsMarketCreated() public {
        uint64 closeBlock = uint64(
            block.number + (BETTING_SECONDS * 1000) / BLOCK_TIME_MS
        );
        uint64 resolveBlock = uint64(
            closeBlock + (RESOLVE_DELAY_SECONDS * 1000) / BLOCK_TIME_MS
        );

        vm.expectEmit(true, true, false, true, address(predict));
        emit RitualPredict.MarketCreated(
            1,
            address(this),
            QUESTION,
            closeBlock,
            resolveBlock,
            1
        );
        _create();
    }

    function test_CreateMarket_RevertsOnAnEmptyQuestion() public {
        RitualPredict.NewMarket memory p = _params();
        p.question = "";
        vm.expectRevert(RitualPredict.EmptyString.selector);
        predict.createMarket(p);
    }

    function test_CreateMarket_RevertsOnAnEmptyOracleUrl() public {
        RitualPredict.NewMarket memory p = _params();
        p.oracleUrl = "";
        vm.expectRevert(RitualPredict.EmptyString.selector);
        predict.createMarket(p);
    }

    function test_CreateMarket_RevertsOnAnEmptyJsonPath() public {
        RitualPredict.NewMarket memory p = _params();
        p.jsonPath = "";
        vm.expectRevert(RitualPredict.EmptyString.selector);
        predict.createMarket(p);
    }

    function test_CreateMarket_RevertsOnAShortBettingWindow() public {
        RitualPredict.NewMarket memory p = _params();
        p.bettingSeconds = predict.MIN_BETTING_SECONDS() - 1;
        vm.expectRevert(RitualPredict.BadDuration.selector);
        predict.createMarket(p);
    }

    function test_CreateMarket_RevertsOnAShortResolveDelay() public {
        RitualPredict.NewMarket memory p = _params();
        p.resolveDelaySeconds = predict.MIN_RESOLVE_DELAY_SECONDS() - 1;
        vm.expectRevert(RitualPredict.BadDuration.selector);
        predict.createMarket(p);
    }

    function test_CreateMarket_RevertsWhenLongerThanTheMaximum() public {
        RitualPredict.NewMarket memory p = _params();
        p.bettingSeconds = predict.MAX_MARKET_SECONDS();
        vm.expectRevert(RitualPredict.BadDuration.selector);
        predict.createMarket(p);
    }

    function test_Constructor_RevertsOnZeroBlockTime() public {
        vm.expectRevert(RitualPredict.BadDuration.selector);
        new RitualPredict(0);
    }

    // ═════════════════════════════ betting ═════════════════════════════

    function test_Bet_AccumulatesBothPools() public {
        uint256 id = _create();

        vm.prank(alice);
        predict.bet{value: 3 ether}(id, true);
        vm.prank(carol);
        predict.bet{value: 2 ether}(id, true);
        vm.prank(bob);
        predict.bet{value: 1 ether}(id, false);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(m.totalYes, 5 ether);
        assertEq(m.totalNo, 1 ether);
        assertEq(address(predict).balance, 6 ether);
    }

    function test_Bet_TracksPerAccountStakes() public {
        uint256 id = _create();

        vm.prank(alice);
        predict.bet{value: 1 ether}(id, true);
        vm.prank(alice);
        predict.bet{value: 2 ether}(id, false);

        (uint256 yes, uint256 no, bool alreadySettled, ) = predict.stakesOf(
            id,
            alice
        );
        assertEq(yes, 1 ether);
        assertEq(no, 2 ether);
        assertFalse(alreadySettled);
    }

    function test_Bet_RevertsOnZeroStake() public {
        uint256 id = _create();
        vm.expectRevert(RitualPredict.ZeroStake.selector);
        predict.bet{value: 0}(id, true);
    }

    function test_Bet_RevertsAtTheCloseBlock() public {
        uint256 id = _create();
        vm.roll(predict.getMarket(id).closeBlock);

        vm.prank(alice);
        vm.expectRevert(RitualPredict.BettingClosed.selector);
        predict.bet{value: 1 ether}(id, true);
    }

    function test_Bet_RevertsOnAnUnknownMarket() public {
        vm.expectRevert(RitualPredict.UnknownMarket.selector);
        predict.bet{value: 1 ether}(999, true);
    }

    // ══════════════════════════════ views ══════════════════════════════

    function test_GetMarket_FlipsToClosedAtTheCloseBlock() public {
        uint256 id = _create();
        assertEq(uint256(_state(id)), uint256(RitualPredict.MarketState.Open));

        vm.roll(predict.getMarket(id).closeBlock);
        assertEq(
            uint256(_state(id)),
            uint256(RitualPredict.MarketState.Closed),
            "no transaction flips Open to Closed, so the view has to"
        );
    }

    function test_GetMarket_RevertsOnAnUnknownMarket() public {
        vm.expectRevert(RitualPredict.UnknownMarket.selector);
        predict.getMarket(1);
    }

    function test_GetMarkets_ReturnsNewestFirst() public {
        _create();
        _create();
        _create();

        RitualPredict.Market[] memory all = predict.getMarkets();
        assertEq(all.length, 3);
        assertEq(all[0].id, 3);
        assertEq(all[1].id, 2);
        assertEq(all[2].id, 1);
    }

    // ═══════════════════ callback authorisation & guards ═══════════════

    function test_Resolve_RevertsWhenTheCallerIsNotTheScheduler() public {
        uint256 id = _armedMarket();
        vm.expectRevert(RitualPredict.OnlyScheduler.selector);
        predict.onScheduledResolve(0, id);
    }

    function test_Resolve_IgnoresAnUnknownMarket() public {
        vm.prank(RitualChain.SCHEDULER);
        predict.onScheduledResolve(0, 999); // must not revert
    }

    function test_Resolve_IgnoresATriggerBeforeTheResolveBlock() public {
        uint256 id = _create();
        vm.roll(predict.getMarket(id).resolveBlock - 1);

        _fire(id, 0);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(m.attempts, 0, "an early trigger must not burn an attempt");
        assertEq(http.callCount(), 0);
    }

    function test_Resolve_IsIdempotentAfterResolution() public {
        uint256 id = _armedMarket();
        _fire(id, 0);
        assertEq(
            uint256(_state(id)),
            uint256(RitualPredict.MarketState.Resolved)
        );

        uint256 callsBefore = http.callCount();
        vm.roll(block.number + 200);
        _fire(id, 1); // a leftover booked execution

        assertEq(http.callCount(), callsBefore, "no second oracle read");
        assertEq(predict.getMarket(id).attempts, 1);
        assertEq(
            uint256(_state(id)),
            uint256(RitualPredict.MarketState.Resolved)
        );
    }

    // ═══════════════════════ resolution: happy path ════════════════════

    function test_Resolve_YesWhenTheObservedValueMeetsTheTarget() public {
        uint256 id = _armedMarket();
        _fire(id, 0);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(uint256(m.state), uint256(RitualPredict.MarketState.Resolved));
        assertEq(uint256(m.outcome), uint256(RitualPredict.Outcome.Yes));
        assertEq(m.observedValue, OBSERVED);
        assertEq(m.attempts, 1);
    }

    function test_Resolve_NoWhenTheObservedValueMissesTheTarget() public {
        RitualPredict.NewMarket memory p = _params();
        p.target = 9_000; // 4200 >= 9000 is false
        uint256 id = predict.createMarket(p);

        vm.prank(alice);
        predict.bet{value: 1 ether}(id, true);
        vm.prank(bob);
        predict.bet{value: 1 ether}(id, false);
        _rollToResolve(id);
        _fire(id, 0);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(uint256(m.outcome), uint256(RitualPredict.Outcome.No));
        assertEq(m.observedValue, OBSERVED);
    }

    function test_Resolve_SendsTheConfiguredRequestToAnExecutor() public {
        uint256 id = _armedMarket();
        _fire(id, 0);

        assertEq(http.callCount(), 1);
        assertEq(http.lastUrl(), ORACLE_URL);
        assertEq(uint256(http.lastMethod()), uint256(RitualChain.HTTP_GET));
        assertEq(http.lastTtl(), predict.HTTP_TTL_BLOCKS());
        assertTrue(
            http.lastExecutor() == EXECUTOR_A ||
                http.lastExecutor() == EXECUTOR_B,
            "the executor must come from the registry, never a constant"
        );
    }

    function test_Resolve_CancelsTheRemainingAttempts() public {
        uint256 id = _armedMarket();
        uint256 scheduleId = _scheduleIdOf(id);
        assertEq(scheduler.getCallState(scheduleId), 0);

        _fire(id, 0);
        assertEq(scheduler.getCallState(scheduleId), 3, "CANCELLED");
    }

    function test_Resolve_SurvivesASchedulerThatRefusesToCancel() public {
        uint256 id = _armedMarket();
        scheduler.setRejectCancel(true);

        _fire(id, 0);

        assertEq(
            uint256(_state(id)),
            uint256(RitualPredict.MarketState.Resolved),
            "a failed cancel must not undo a successful resolution"
        );
    }

    function test_Resolve_HonoursEveryComparator() public {
        assertEq(
            uint256(_outcomeWith(RitualPredict.Comparator.GT)),
            uint256(RitualPredict.Outcome.Yes)
        );
        assertEq(
            uint256(_outcomeWith(RitualPredict.Comparator.GTE)),
            uint256(RitualPredict.Outcome.Yes)
        );
        assertEq(
            uint256(_outcomeWith(RitualPredict.Comparator.LT)),
            uint256(RitualPredict.Outcome.No)
        );
        assertEq(
            uint256(_outcomeWith(RitualPredict.Comparator.LTE)),
            uint256(RitualPredict.Outcome.No)
        );
    }

    function _outcomeWith(
        RitualPredict.Comparator c
    ) internal returns (RitualPredict.Outcome) {
        RitualPredict.NewMarket memory p = _params();
        p.comparator = c;
        uint256 id = predict.createMarket(p);

        vm.prank(alice);
        predict.bet{value: 1 ether}(id, true);
        vm.prank(bob);
        predict.bet{value: 1 ether}(id, false);
        _rollToResolve(id);
        _fire(id, 0);

        return predict.getMarket(id).outcome;
    }

    // ═══════════════════════ resolution: failure paths ═════════════════

    function _assertAttemptFailed(
        uint256 id,
        uint8 expectedAttempts
    ) internal view {
        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(m.attempts, expectedAttempts);
        assertEq(
            uint256(m.outcome),
            uint256(RitualPredict.Outcome.Unresolved),
            "a failed read is never an answer"
        );
        assertEq(
            uint256(m.state),
            uint256(RitualPredict.MarketState.Resolving)
        );
    }

    function test_Resolve_FailsWhenNoExecutorIsAvailable() public {
        uint256 id = _armedMarket();
        registry.setMode(MockTeeServiceRegistry.Mode.NotFound);

        vm.expectEmit(true, false, false, true, address(predict));
        emit RitualPredict.ResolutionFailed(id, 1, "no TEE executor available");
        _fire(id, 0);

        _assertAttemptFailed(id, 1);
        assertEq(http.callCount(), 0, "no HTTP call without an executor");
    }

    function test_Resolve_FailsWhenTheRegistryIsUnreachable() public {
        uint256 id = _armedMarket();
        registry.setMode(MockTeeServiceRegistry.Mode.Fail);

        _fire(id, 0);
        _assertAttemptFailed(id, 1);
    }

    function test_Resolve_FailsWhenThePrecompileCallFails() public {
        uint256 id = _armedMarket();
        http.setMode(MockHttpPrecompile.Mode.Fail);

        vm.expectEmit(true, false, false, true, address(predict));
        emit RitualPredict.ResolutionFailed(
            id,
            1,
            "http precompile rejected the request"
        );
        _fire(id, 0);
        _assertAttemptFailed(id, 1);
    }

    function test_Resolve_FailsOnANon200Status() public {
        uint256 id = _armedMarket();
        http.setResponse(503, bytes(ORACLE_JSON), "");

        vm.expectEmit(true, false, false, true, address(predict));
        emit RitualPredict.ResolutionFailed(id, 1, "http status was not 200");
        _fire(id, 0);
        _assertAttemptFailed(id, 1);
    }

    function test_Resolve_FailsOnAnExecutorErrorMessage() public {
        uint256 id = _armedMarket();
        http.setResponse(200, bytes(ORACLE_JSON), "dns lookup failed");

        vm.expectEmit(true, false, false, true, address(predict));
        emit RitualPredict.ResolutionFailed(id, 1, "dns lookup failed");
        _fire(id, 0);
        _assertAttemptFailed(id, 1);
    }

    /// The simulation pass returns an envelope whose actualOutput is still empty. That
    /// must be a caught failure, not a revert that rolls the attempt counter back.
    function test_Resolve_FailsOnAnUnsettledEnvelope() public {
        uint256 id = _armedMarket();
        http.setMode(MockHttpPrecompile.Mode.Unsettled);

        vm.expectEmit(true, false, false, true, address(predict));
        emit RitualPredict.ResolutionFailed(
            id,
            1,
            "http response could not be decoded"
        );
        _fire(id, 0);
        _assertAttemptFailed(id, 1);
    }

    function test_Resolve_FailsOnAMalformedPayload() public {
        uint256 id = _armedMarket();
        http.setMode(MockHttpPrecompile.Mode.Garbage);

        _fire(id, 0);
        _assertAttemptFailed(id, 1);
    }

    function test_Resolve_FailsWhenTheReturndataIsNotAnEnvelope() public {
        uint256 id = _armedMarket();
        http.setMode(MockHttpPrecompile.Mode.NotAnEnvelope);

        _fire(id, 0);
        _assertAttemptFailed(id, 1);
    }

    function test_Resolve_FailsWhenJqYieldsNothing() public {
        uint256 id = _armedMarket();
        jq.setMode(MockJqPrecompile.Mode.Empty);

        vm.expectEmit(true, false, false, true, address(predict));
        emit RitualPredict.ResolutionFailed(
            id,
            1,
            "jq did not yield a uint256"
        );
        _fire(id, 0);
        _assertAttemptFailed(id, 1);
    }

    /// A wrong outputType returns ok=true with a short output, which is why the length
    /// check in `_jqUint` is load-bearing.
    function test_Resolve_FailsWhenJqReturnsFewerThan32Bytes() public {
        uint256 id = _armedMarket();
        jq.setMode(MockJqPrecompile.Mode.Short);

        _fire(id, 0);
        _assertAttemptFailed(id, 1);
    }

    function test_Resolve_FailsWhenTheJqCallReverts() public {
        uint256 id = _armedMarket();
        jq.setMode(MockJqPrecompile.Mode.Fail);

        _fire(id, 0);
        _assertAttemptFailed(id, 1);
    }

    /// The jq mock answers on the (jsonPath, body) pair, so this fails only if the body
    /// the executor returned really did reach jq together with the configured path.
    function test_Resolve_FailsWhenTheBodyDoesNotMatchTheJsonPath() public {
        uint256 id = _armedMarket();
        http.setResponse(200, bytes('{"something":"else"}'), "");

        _fire(id, 0);
        _assertAttemptFailed(id, 1);
    }

    // ═══════════════════════ retries and invalidation ══════════════════

    function test_Resolve_ThreeFailedAttemptsInvalidateTheMarket() public {
        uint256 id = _armedMarket();
        http.setMode(MockHttpPrecompile.Mode.Fail);

        _fire(id, 0);
        _fire(id, 1);
        assertEq(
            uint256(_state(id)),
            uint256(RitualPredict.MarketState.Resolving)
        );

        vm.expectEmit(true, false, false, true, address(predict));
        emit RitualPredict.MarketInvalidated(
            id,
            "http precompile rejected the request"
        );
        _fire(id, 2);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(uint256(m.state), uint256(RitualPredict.MarketState.Invalid));
        assertEq(m.attempts, predict.MAX_ATTEMPTS());
        assertEq(
            uint256(m.outcome),
            uint256(RitualPredict.Outcome.Unresolved),
            "three unreadable oracles must never be read as NO"
        );
        assertEq(m.invalidReason, "http precompile rejected the request");
    }

    function test_Resolve_SucceedsOnALaterAttempt() public {
        uint256 id = _armedMarket();

        http.setMode(MockHttpPrecompile.Mode.Fail);
        _fire(id, 0);

        http.setResponse(200, bytes(ORACLE_JSON), ""); // the API comes back
        _fire(id, 1);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(uint256(m.state), uint256(RitualPredict.MarketState.Resolved));
        assertEq(uint256(m.outcome), uint256(RitualPredict.Outcome.Yes));
        assertEq(m.attempts, 2);
    }

    /// One unhealthy executor must not be able to sink a market.
    function test_Resolve_RerollsTheExecutorOnEveryAttempt() public {
        uint256 id = _armedMarket();
        http.setMode(MockHttpPrecompile.Mode.Fail);
        registry.setMode(MockTeeServiceRegistry.Mode.SeedEcho);

        address first = _seedEchoExecutor(id, 0);
        address second = _seedEchoExecutor(id, 1);
        assertTrue(first != second, "each attempt must re-roll the seed");

        vm.expectEmit(true, false, false, true, address(predict));
        emit RitualPredict.ResolutionAttempted(id, 1, first);
        _fire(id, 0);

        vm.expectEmit(true, false, false, true, address(predict));
        emit RitualPredict.ResolutionAttempted(id, 2, second);
        _fire(id, 1);
    }

    /**
     * A short-running async call is simulated once to build the commitment and then
     * replayed with the settled output injected. If the executor choice moved between
     * those two passes the request bytes would differ and the settlement would not
     * match, so the seed must not depend on the block. Firing the same execution index
     * 500 blocks apart has to pick the same executor.
     */
    function test_Resolve_ExecutorChoiceDoesNotDependOnTheBlock() public {
        uint256 id = _armedMarket();
        http.setMode(MockHttpPrecompile.Mode.Fail);
        registry.setMode(MockTeeServiceRegistry.Mode.SeedEcho);

        address expected = _seedEchoExecutor(id, 0);

        vm.expectEmit(true, false, false, true, address(predict));
        emit RitualPredict.ResolutionAttempted(id, 1, expected);
        _fire(id, 0);

        vm.roll(block.number + 500);
        vm.fee(77 gwei);

        vm.expectEmit(true, false, false, true, address(predict));
        emit RitualPredict.ResolutionAttempted(id, 2, expected);
        _fire(id, 0);
    }

    function _seedEchoExecutor(
        uint256 marketId,
        uint256 executionIndex
    ) internal view returns (address) {
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encode(
                                address(predict),
                                marketId,
                                executionIndex
                            )
                        )
                    )
                )
            );
    }

    function test_Resolve_EmptyWinningSideBecomesRefundable() public {
        uint256 id = _create();
        vm.prank(bob);
        predict.bet{value: 2 ether}(id, false); // nobody backs YES
        _rollToResolve(id);

        _fire(id, 0);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(uint256(m.state), uint256(RitualPredict.MarketState.Invalid));
        assertEq(
            uint256(m.outcome),
            uint256(RitualPredict.Outcome.Yes),
            "the outcome is still recorded"
        );
        assertEq(m.observedValue, OBSERVED);
        assertEq(m.invalidReason, "no stake on the winning side");

        uint256 before = bob.balance;
        vm.prank(bob);
        predict.claimRefund(id);
        assertEq(bob.balance - before, 2 ether);
    }

    // ═════════════════════════════ payouts ═════════════════════════════

    function test_Claim_PaysTheProportionalShare() public {
        uint256 id = _create();
        vm.prank(alice);
        predict.bet{value: 3 ether}(id, true);
        vm.prank(carol);
        predict.bet{value: 1 ether}(id, true);
        vm.prank(bob);
        predict.bet{value: 1 ether}(id, false);
        _rollToResolve(id);
        _fire(id, 0); // YES

        // pool = 5, winning side = 4
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        predict.claimWinnings(id);
        assertEq(alice.balance - aliceBefore, (3 ether * 5) / 4);

        uint256 carolBefore = carol.balance;
        vm.prank(carol);
        predict.claimWinnings(id);
        assertEq(carol.balance - carolBefore, (1 ether * 5) / 4);
    }

    function test_Claim_LeavesTheLoserWithNothing() public {
        uint256 id = _armedMarket();
        _fire(id, 0); // YES, bob backed NO

        vm.prank(bob);
        vm.expectRevert(RitualPredict.NothingToClaim.selector);
        predict.claimWinnings(id);
    }

    function test_Claim_RevertsBeforeResolution() public {
        uint256 id = _armedMarket();
        vm.prank(alice);
        vm.expectRevert(RitualPredict.NotResolved.selector);
        predict.claimWinnings(id);
    }

    function test_Claim_RevertsOnASecondClaim() public {
        uint256 id = _armedMarket();
        _fire(id, 0);

        vm.prank(alice);
        predict.claimWinnings(id);

        vm.prank(alice);
        vm.expectRevert(RitualPredict.AlreadySettled.selector);
        predict.claimWinnings(id);
    }

    function test_Refund_RevertsWhileTheMarketIsResolved() public {
        uint256 id = _armedMarket();
        _fire(id, 0);

        vm.prank(alice);
        vm.expectRevert(RitualPredict.NotInvalid.selector);
        predict.claimRefund(id);
    }

    function test_Refund_ReturnsEveryStakeAfterThreeFailures() public {
        uint256 id = _armedMarket();
        http.setMode(MockHttpPrecompile.Mode.Fail);
        _fire(id, 0);
        _fire(id, 1);
        _fire(id, 2);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        predict.claimRefund(id);
        assertEq(alice.balance - aliceBefore, 3 ether);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        predict.claimRefund(id);
        assertEq(bob.balance - bobBefore, 1 ether);

        assertEq(address(predict).balance, 0, "the whole pool went back");
    }

    function test_StakesOf_ReportsWhatIsClaimable() public {
        uint256 id = _armedMarket();
        _fire(id, 0); // YES

        (, , , uint256 aliceClaimable) = predict.stakesOf(id, alice);
        assertEq(aliceClaimable, (3 ether * 4) / 3);

        (, , , uint256 bobClaimable) = predict.stakesOf(id, bob);
        assertEq(bobClaimable, 0);

        vm.prank(alice);
        predict.claimWinnings(id);
        (, , bool settledNow, uint256 afterClaim) = predict.stakesOf(id, alice);
        assertTrue(settledNow);
        assertEq(afterClaim, 0);
    }

    // ════════════════════════ execution funding ════════════════════════

    function test_FundExecution_DepositsIntoTheRitualWallet() public {
        predict.fundExecution{value: 1 ether}(5_000);

        assertEq(predict.executionBalance(), 1 ether);
        assertEq(wallet.lockUntil(address(predict)), block.number + 5_000);
    }

    function test_FundExecution_RevertsOnZero() public {
        vm.expectRevert(RitualPredict.ZeroStake.selector);
        predict.fundExecution{value: 0}(5_000);
    }

    function test_Constructor_ApprovesTheScheduler() public view {
        assertTrue(
            scheduler.approved(address(predict), RitualChain.SCHEDULER),
            "the Scheduler must be allowed to draw fees and call back"
        );
    }
}
