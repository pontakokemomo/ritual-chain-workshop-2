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

    // ═══════════════════════════════════════════════════════════════════
    //                          BOUNDARY VALUES
    //
    // Every limit in the contract, exercised at the value itself and at one
    // step either side of it: the comparison against the target, stake
    // sizes, participant counts, durations, block deadlines and the
    // attempt counter.
    // ═══════════════════════════════════════════════════════════════════

    /// Teach the oracle mocks to report one specific number.
    function _setObserved(uint256 observed) internal {
        string memory json = string.concat(
            '{"ethereum":{"usd":',
            vm.toString(observed),
            "}}"
        );
        http.setResponse(200, bytes(json), "");
        jq.setResult(JSON_PATH, json, observed);
    }

    function _outcomeFor(
        uint256 target,
        RitualPredict.Comparator c,
        uint256 observed
    ) internal returns (RitualPredict.Outcome) {
        _setObserved(observed);

        RitualPredict.NewMarket memory p = _params();
        p.target = target;
        p.comparator = c;
        uint256 id = predict.createMarket(p);

        vm.prank(alice);
        predict.bet{value: 1 ether}(id, true);
        vm.prank(bob);
        predict.bet{value: 1 ether}(id, false);
        _rollToResolve(id);
        _fire(id, 0);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(m.observedValue, observed);
        return m.outcome;
    }

    function _assertYes(RitualPredict.Outcome o, string memory why) internal pure {
        assertEq(uint256(o), uint256(RitualPredict.Outcome.Yes), why);
    }

    function _assertNo(RitualPredict.Outcome o, string memory why) internal pure {
        assertEq(uint256(o), uint256(RitualPredict.Outcome.No), why);
    }

    // ── the comparison itself: observed exactly on the target ──────────

    function test_Boundary_ObservedEqualsTarget_GT_IsNo() public {
        _assertNo(
            _outcomeFor(TARGET, RitualPredict.Comparator.GT, TARGET),
            "equal is not strictly greater"
        );
    }

    function test_Boundary_ObservedEqualsTarget_GTE_IsYes() public {
        _assertYes(
            _outcomeFor(TARGET, RitualPredict.Comparator.GTE, TARGET),
            "equal satisfies at-least"
        );
    }

    function test_Boundary_ObservedEqualsTarget_LT_IsNo() public {
        _assertNo(
            _outcomeFor(TARGET, RitualPredict.Comparator.LT, TARGET),
            "equal is not strictly less"
        );
    }

    function test_Boundary_ObservedEqualsTarget_LTE_IsYes() public {
        _assertYes(
            _outcomeFor(TARGET, RitualPredict.Comparator.LTE, TARGET),
            "equal satisfies at-most"
        );
    }

    function test_Boundary_ObservedOneBelowTarget_GTE_IsNo() public {
        _assertNo(
            _outcomeFor(TARGET, RitualPredict.Comparator.GTE, TARGET - 1),
            "one short of the target must not pay YES"
        );
    }

    function test_Boundary_ObservedOneAboveTarget_GT_IsYes() public {
        _assertYes(
            _outcomeFor(TARGET, RitualPredict.Comparator.GT, TARGET + 1),
            "one over the target is enough"
        );
    }

    function test_Boundary_ObservedOneAboveTarget_LTE_IsNo() public {
        _assertNo(
            _outcomeFor(TARGET, RitualPredict.Comparator.LTE, TARGET + 1),
            "one over the target breaks at-most"
        );
    }

    // ── the ends of the uint256 range ──────────────────────────────────

    function test_Boundary_ZeroTargetAndZeroObserved() public {
        _assertYes(
            _outcomeFor(0, RitualPredict.Comparator.GTE, 0),
            "0 >= 0"
        );
        _assertNo(_outcomeFor(0, RitualPredict.Comparator.GT, 0), "0 > 0 is false");
    }

    function test_Boundary_ZeroTargetIsAlwaysMetByGte() public {
        _assertYes(
            _outcomeFor(0, RitualPredict.Comparator.GTE, type(uint256).max),
            "everything is at least zero"
        );
    }

    function test_Boundary_MaxUintTarget() public {
        _assertYes(
            _outcomeFor(
                type(uint256).max,
                RitualPredict.Comparator.GTE,
                type(uint256).max
            ),
            "max >= max"
        );
        _assertNo(
            _outcomeFor(
                type(uint256).max,
                RitualPredict.Comparator.GT,
                type(uint256).max
            ),
            "nothing exceeds the maximum"
        );
    }

    // ── stake size: the smallest and largest amounts ───────────────────

    function test_Boundary_OneWeiOnEachSideStillPaysOut() public {
        uint256 id = _create();

        vm.prank(alice);
        predict.bet{value: 1 wei}(id, true);
        vm.prank(bob);
        predict.bet{value: 1 wei}(id, false);
        _rollToResolve(id);
        _fire(id, 0); // YES

        uint256 before = alice.balance;
        vm.prank(alice);
        predict.claimWinnings(id);

        assertEq(alice.balance - before, 2 wei, "the whole pool, two wei");
        assertEq(address(predict).balance, 0);
    }

    /// The pool would have to be larger than every token that will ever exist for
    /// `stake * pool` to overflow, but the ceiling is worth pinning down.
    function test_Boundary_AstronomicalStakesStillPayOut() public {
        uint256 huge = 2 ** 120; // ~1.3e36 wei, ten orders of magnitude past any supply
        uint256 id = _create();

        vm.deal(alice, huge);
        vm.prank(alice);
        predict.bet{value: huge}(id, true);
        vm.deal(bob, huge);
        vm.prank(bob);
        predict.bet{value: huge}(id, false);
        _rollToResolve(id);
        _fire(id, 0); // YES

        vm.prank(alice);
        predict.claimWinnings(id);

        assertEq(alice.balance, 2 * huge, "the winner takes both sides");
        assertEq(address(predict).balance, 0);
    }

    /// Integer division keeps sub-wei remainders in the contract. That is deliberate,
    /// and this pins the size of it: strictly less than one wei per winner.
    function test_Boundary_DustFromIntegerDivisionStaysBehind() public {
        uint256 id = _create();

        address[3] memory winners = [alice, carol, address(0xDEAD01)];
        for (uint256 i = 0; i < winners.length; i++) {
            vm.deal(winners[i], 1 ether);
            vm.prank(winners[i]);
            predict.bet{value: 1 wei}(id, true);
        }
        vm.prank(bob);
        predict.bet{value: 1 wei}(id, false);

        _rollToResolve(id);
        _fire(id, 0); // YES

        uint256 paid;
        for (uint256 i = 0; i < winners.length; i++) {
            uint256 before = winners[i].balance;
            vm.prank(winners[i]);
            predict.claimWinnings(id);
            paid += winners[i].balance - before;
        }

        // pool = 4 wei, winning side = 3 wei, each winner gets 4/3 = 1 wei.
        assertEq(paid, 3 wei);
        assertEq(address(predict).balance, 1 wei, "one wei of dust is left");
        assertLt(
            address(predict).balance,
            winners.length,
            "dust is always under one wei per winner"
        );
    }

    // ── participant count: none, one, many ─────────────────────────────

    function test_Boundary_MarketWithNoBetsAtAllBecomesInvalid() public {
        uint256 id = _create();
        _rollToResolve(id);
        _fire(id, 0);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(uint256(m.state), uint256(RitualPredict.MarketState.Invalid));
        assertEq(m.invalidReason, "no stake on the winning side");
        assertEq(address(predict).balance, 0);
    }

    function test_Boundary_SingleParticipantOnTheWinningSideTakesEverything()
        public
    {
        uint256 id = _create();

        vm.prank(alice);
        predict.bet{value: 1 ether}(id, true);
        vm.prank(bob);
        predict.bet{value: 9 ether}(id, false);
        _rollToResolve(id);
        _fire(id, 0); // YES

        uint256 before = alice.balance;
        vm.prank(alice);
        predict.claimWinnings(id);

        assertEq(alice.balance - before, 10 ether, "the lone winner takes the pool");
    }

    /// Everyone on one side, and that side wins: each participant gets exactly their
    /// own stake back, because the pool and the winning pool are the same number.
    function test_Boundary_EveryoneOnTheWinningSideGetsTheirStakeBack() public {
        uint256 id = _create();

        vm.prank(alice);
        predict.bet{value: 3 ether}(id, true);
        vm.prank(carol);
        predict.bet{value: 7 ether}(id, true);
        _rollToResolve(id);
        _fire(id, 0); // YES

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        predict.claimWinnings(id);
        assertEq(alice.balance - aliceBefore, 3 ether);

        uint256 carolBefore = carol.balance;
        vm.prank(carol);
        predict.claimWinnings(id);
        assertEq(carol.balance - carolBefore, 7 ether);

        assertEq(address(predict).balance, 0);
    }

    function test_Boundary_FiftyWinnersCanAllClaim() public {
        uint256 id = _create();
        uint256 n = 50;

        for (uint256 i = 0; i < n; i++) {
            address p = address(uint160(0x100000 + i));
            vm.deal(p, 1 ether);
            vm.prank(p);
            predict.bet{value: 1 ether}(id, true);
        }
        vm.prank(bob);
        predict.bet{value: 1 ether}(id, false);

        _rollToResolve(id);
        _fire(id, 0); // YES

        uint256 pool = (n + 1) * 1 ether;
        assertEq(address(predict).balance, pool);

        uint256 paid;
        for (uint256 i = 0; i < n; i++) {
            address p = address(uint160(0x100000 + i));
            vm.prank(p);
            predict.claimWinnings(id);
            paid += p.balance;
        }

        assertLe(paid, pool, "payouts can never exceed the pool");
        assertEq(address(predict).balance, pool - paid);
        assertLt(address(predict).balance, n, "under one wei of dust per winner");
    }

    // ── durations: exactly at the minimum and the maximum ──────────────

    function test_Boundary_MinimumBettingWindowIsAccepted() public {
        RitualPredict.NewMarket memory p = _params();
        p.bettingSeconds = predict.MIN_BETTING_SECONDS();
        assertEq(predict.createMarket(p), 1);
    }

    function test_Boundary_MinimumResolveDelayIsAccepted() public {
        RitualPredict.NewMarket memory p = _params();
        p.resolveDelaySeconds = predict.MIN_RESOLVE_DELAY_SECONDS();
        assertEq(predict.createMarket(p), 1);
    }

    function test_Boundary_ExactlyTheMaximumMarketLengthIsAccepted() public {
        RitualPredict.NewMarket memory p = _params();
        p.resolveDelaySeconds = predict.MIN_RESOLVE_DELAY_SECONDS();
        p.bettingSeconds =
            predict.MAX_MARKET_SECONDS() -
            p.resolveDelaySeconds;

        uint256 id = predict.createMarket(p);
        RitualPredict.Market memory m = predict.getMarket(id);
        assertGt(m.resolveBlock, m.closeBlock);
    }

    function test_Boundary_OneSecondOverTheMaximumReverts() public {
        RitualPredict.NewMarket memory p = _params();
        p.resolveDelaySeconds = predict.MIN_RESOLVE_DELAY_SECONDS();
        p.bettingSeconds =
            predict.MAX_MARKET_SECONDS() -
            p.resolveDelaySeconds +
            1;

        vm.expectRevert(RitualPredict.BadDuration.selector);
        predict.createMarket(p);
    }

    /// A chain slow enough that the whole window rounds to zero blocks still has to
    /// produce a usable market: `_secondsToBlocks` clamps to one block.
    function test_Boundary_VerySlowChainClampsToOneBlock() public {
        RitualPredict predictSlow = new RitualPredict(1_000_000_000); // 1000 s/block
        uint256 start = block.number;

        uint256 id = predictSlow.createMarket(_params());
        RitualPredict.Market memory m = predictSlow.getMarket(id);

        assertEq(m.closeBlock, start + 1);
        assertEq(m.resolveBlock, start + 2);
    }

    function test_Boundary_VeryFastChainProducesLargeBlockCounts() public {
        RitualPredict predictFast = new RitualPredict(1); // 1 ms/block
        uint256 start = block.number;

        uint256 id = predictFast.createMarket(_params());
        RitualPredict.Market memory m = predictFast.getMarket(id);

        assertEq(m.closeBlock, start + BETTING_SECONDS * 1000);
        assertEq(
            m.resolveBlock,
            m.closeBlock + RESOLVE_DELAY_SECONDS * 1000
        );
    }

    // ── block deadlines: the last block that still works ───────────────

    function test_Boundary_BetSucceedsOnTheBlockBeforeClose() public {
        uint256 id = _create();
        vm.roll(predict.getMarket(id).closeBlock - 1);

        vm.prank(alice);
        predict.bet{value: 1 ether}(id, true);
        assertEq(predict.getMarket(id).totalYes, 1 ether);
    }

    function test_Boundary_ResolveRunsOnTheResolveBlockItself() public {
        uint256 id = _armedMarket(); // rolls to exactly resolveBlock
        assertEq(block.number, predict.getMarket(id).resolveBlock);

        _fire(id, 0);
        assertEq(
            uint256(_state(id)),
            uint256(RitualPredict.MarketState.Resolved)
        );
    }

    function test_Boundary_ResolveIsIgnoredOneBlockEarly() public {
        uint256 id = _create();
        vm.roll(predict.getMarket(id).resolveBlock - 1);

        _fire(id, 0);
        assertEq(predict.getMarket(id).attempts, 0);
    }

    // ── the attempt counter: the last chance ───────────────────────────

    function test_Boundary_ThirdAttemptCanStillResolveTheMarket() public {
        uint256 id = _armedMarket();
        http.setMode(MockHttpPrecompile.Mode.Fail);

        _fire(id, 0);
        _fire(id, 1);
        http.setResponse(200, bytes(ORACLE_JSON), ""); // back just in time
        _fire(id, 2);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(m.attempts, predict.MAX_ATTEMPTS());
        assertEq(uint256(m.state), uint256(RitualPredict.MarketState.Resolved));
        assertEq(uint256(m.outcome), uint256(RitualPredict.Outcome.Yes));
    }

    // ── property-based sweeps over the whole stake range ───────────────

    /// Whatever the three stakes are, the winners between them can never draw more than
    /// the pool, and what stays behind is under one wei per winner.
    function testFuzz_PayoutsNeverExceedThePool(
        uint96 yesA,
        uint96 yesB,
        uint96 noC
    ) public {
        uint256 a = bound(uint256(yesA), 1, 1e28);
        uint256 b = bound(uint256(yesB), 1, 1e28);
        uint256 c = bound(uint256(noC), 1, 1e28);

        uint256 id = _create();
        vm.deal(alice, a);
        vm.prank(alice);
        predict.bet{value: a}(id, true);
        vm.deal(carol, b);
        vm.prank(carol);
        predict.bet{value: b}(id, true);
        vm.deal(bob, c);
        vm.prank(bob);
        predict.bet{value: c}(id, false);

        _rollToResolve(id);
        _fire(id, 0); // YES

        uint256 pool = a + b + c;
        assertEq(address(predict).balance, pool);

        vm.prank(alice);
        predict.claimWinnings(id);
        vm.prank(carol);
        predict.claimWinnings(id);

        uint256 left = address(predict).balance;
        assertLt(left, 2, "at most one wei of dust per winner stays behind");
        assertEq(alice.balance + carol.balance, pool - left);
    }

    function testFuzz_RefundsReturnExactlyWhatWasStaked(
        uint96 yesA,
        uint96 noB
    ) public {
        uint256 a = bound(uint256(yesA), 1, 1e28);
        uint256 b = bound(uint256(noB), 1, 1e28);

        uint256 id = _create();
        vm.deal(alice, a);
        vm.prank(alice);
        predict.bet{value: a}(id, true);
        vm.deal(bob, b);
        vm.prank(bob);
        predict.bet{value: b}(id, false);

        _rollToResolve(id);
        http.setMode(MockHttpPrecompile.Mode.Fail);
        _fire(id, 0);
        _fire(id, 1);
        _fire(id, 2);

        vm.prank(alice);
        predict.claimRefund(id);
        vm.prank(bob);
        predict.claimRefund(id);

        assertEq(alice.balance, a);
        assertEq(bob.balance, b);
        assertEq(address(predict).balance, 0, "a refund leaves nothing behind");
    }

    /// Any observed value at or above the target is YES, anything below it is NO. This
    /// sweeps the whole comparison rather than the handful of points above.
    function testFuzz_GteMatchesTheTargetExactly(uint256 observed) public {
        RitualPredict.Outcome o = _outcomeFor(
            TARGET,
            RitualPredict.Comparator.GTE,
            observed
        );
        if (observed >= TARGET) {
            _assertYes(o, "at or above the target is YES");
        } else {
            _assertNo(o, "below the target is NO");
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //                        STATE TRANSITIONS
    //
    // A market is a five-state machine. `Closed` is the odd one out: no
    // transaction exists to flip Open -> Closed, so `getMarket` derives it
    // from the block number and it is never written to storage.
    //
    //        createMarket
    //             |
    //             v
    //          [Open] --- block >= closeBlock (derived, no tx) --> [Closed]
    //                                                                  |
    //                                        block >= resolveBlock,    |
    //                                        the Scheduler fires ------+
    //                                                                  v
    //                          read failed (attempt < 3) --> [Resolving] --+
    //                                                 ^                    |
    //                                                 +--------------------+
    //                                                        retry
    //                          read ok, winners exist --> [Resolved]  (terminal)
    //                          3 failed reads, or nobody
    //                          on the winning side     --> [Invalid]   (terminal)
    //
    // Valid events per state; everything else must revert or be ignored:
    //
    //   state      bet             claimWinnings  claimRefund   Scheduler fire
    //   -----------------------------------------------------------------------
    //   Open       accepted        NotResolved    NotInvalid    ignored (early)
    //   Closed     BettingClosed   NotResolved    NotInvalid    resolves
    //   Resolving  BettingClosed   NotResolved    NotInvalid    retries
    //   Resolved   BettingClosed   pays once      NotInvalid    ignored
    //   Invalid    BettingClosed   NotResolved    refunds once  ignored
    //
    // The tests below walk every valid path, then sweep the whole invalid
    // half of that table, then prove both terminal states are terminal.
    // ═══════════════════════════════════════════════════════════════════

    // ── a market parked in each state ──────────────────────────────────

    function _openMarket() internal returns (uint256 id) {
        id = _create();
        vm.prank(alice);
        predict.bet{value: 3 ether}(id, true);
        vm.prank(bob);
        predict.bet{value: 1 ether}(id, false);
    }

    function _closedMarket() internal returns (uint256 id) {
        id = _openMarket();
        vm.roll(predict.getMarket(id).closeBlock); // betting over, resolution not due
    }

    function _resolvingMarket() internal returns (uint256 id) {
        id = _armedMarket();
        http.setMode(MockHttpPrecompile.Mode.Fail);
        _fire(id, 0); // one failed attempt, two still booked
        http.setResponse(200, bytes(ORACLE_JSON), "");
    }

    function _resolvedMarket() internal returns (uint256 id) {
        id = _armedMarket();
        _fire(id, 0);
    }

    function _invalidMarket() internal returns (uint256 id) {
        id = _armedMarket();
        http.setMode(MockHttpPrecompile.Mode.Fail);
        _fire(id, 0);
        _fire(id, 1);
        _fire(id, 2);
        http.setResponse(200, bytes(ORACLE_JSON), "");
    }

    function _assertState(
        uint256 id,
        RitualPredict.MarketState expected,
        string memory why
    ) internal view {
        assertEq(uint256(_state(id)), uint256(expected), why);
    }

    // ── valid paths, walked end to end ─────────────────────────────────

    function test_Fsm_HappyPathOpenToClosedToResolved() public {
        uint256 id = _create();
        _assertState(id, RitualPredict.MarketState.Open, "fresh markets are Open");

        vm.prank(alice);
        predict.bet{value: 3 ether}(id, true);
        vm.prank(bob);
        predict.bet{value: 1 ether}(id, false);
        _assertState(
            id,
            RitualPredict.MarketState.Open,
            "a bet does not move the state"
        );

        vm.roll(predict.getMarket(id).closeBlock);
        _assertState(
            id,
            RitualPredict.MarketState.Closed,
            "the close block ends betting"
        );

        _rollToResolve(id);
        _assertState(
            id,
            RitualPredict.MarketState.Closed,
            "still Closed until the Scheduler fires"
        );

        _fire(id, 0);
        _assertState(
            id,
            RitualPredict.MarketState.Resolved,
            "a good read is final"
        );
    }

    function test_Fsm_FailedReadParksInResolvingThenRecovers() public {
        uint256 id = _armedMarket();

        http.setMode(MockHttpPrecompile.Mode.Fail);
        _fire(id, 0);
        _assertState(
            id,
            RitualPredict.MarketState.Resolving,
            "a failed read waits for a retry"
        );
        assertEq(predict.getMarket(id).attempts, 1);

        _fire(id, 1);
        _assertState(
            id,
            RitualPredict.MarketState.Resolving,
            "still waiting after the second"
        );
        assertEq(predict.getMarket(id).attempts, 2);

        http.setResponse(200, bytes(ORACLE_JSON), "");
        _fire(id, 2);
        _assertState(
            id,
            RitualPredict.MarketState.Resolved,
            "the last attempt lands"
        );
    }

    function test_Fsm_ThreeFailedReadsEndInInvalid() public {
        uint256 id = _armedMarket();
        http.setMode(MockHttpPrecompile.Mode.Fail);

        _fire(id, 0);
        _fire(id, 1);
        _assertState(
            id,
            RitualPredict.MarketState.Resolving,
            "two failures are not fatal"
        );

        _fire(id, 2);
        _assertState(id, RitualPredict.MarketState.Invalid, "the third one is");

        // A failed read is never taken as NO.
        assertEq(
            uint256(predict.getMarket(id).outcome),
            uint256(RitualPredict.Outcome.Unresolved),
            "an unread oracle leaves the outcome unresolved"
        );
    }

    function test_Fsm_EmptyWinningSideJumpsStraightToInvalid() public {
        uint256 id = _create();
        vm.prank(bob);
        predict.bet{value: 1 ether}(id, false); // nobody on YES, and YES will win
        _rollToResolve(id);

        _fire(id, 0);
        _assertState(
            id,
            RitualPredict.MarketState.Invalid,
            "one attempt, straight to Invalid"
        );
        assertEq(
            uint256(predict.getMarket(id).outcome),
            uint256(RitualPredict.Outcome.Yes),
            "the outcome is still recorded, the market is just unpayable"
        );
    }

    // ── the invalid half of the table, state by state ──────────────────

    function test_Fsm_OpenRejectsBothClaims() public {
        uint256 id = _openMarket();

        vm.expectRevert(RitualPredict.NotResolved.selector);
        vm.prank(alice);
        predict.claimWinnings(id);

        vm.expectRevert(RitualPredict.NotInvalid.selector);
        vm.prank(alice);
        predict.claimRefund(id);
    }

    function test_Fsm_ClosedRejectsEveryUserAction() public {
        uint256 id = _closedMarket();
        _assertState(id, RitualPredict.MarketState.Closed, "parked in Closed");

        vm.expectRevert(RitualPredict.BettingClosed.selector);
        vm.prank(carol);
        predict.bet{value: 1 ether}(id, true);

        vm.expectRevert(RitualPredict.NotResolved.selector);
        vm.prank(alice);
        predict.claimWinnings(id);

        vm.expectRevert(RitualPredict.NotInvalid.selector);
        vm.prank(alice);
        predict.claimRefund(id);
    }

    function test_Fsm_ResolvingRejectsEveryUserAction() public {
        uint256 id = _resolvingMarket();
        _assertState(
            id,
            RitualPredict.MarketState.Resolving,
            "parked in Resolving"
        );

        vm.expectRevert(RitualPredict.BettingClosed.selector);
        vm.prank(carol);
        predict.bet{value: 1 ether}(id, true);

        vm.expectRevert(RitualPredict.NotResolved.selector);
        vm.prank(alice);
        predict.claimWinnings(id);

        // The one that matters: money must not leave a market that can still resolve.
        vm.expectRevert(RitualPredict.NotInvalid.selector);
        vm.prank(alice);
        predict.claimRefund(id);
    }

    function test_Fsm_ResolvedRejectsBetsAndRefunds() public {
        uint256 id = _resolvedMarket();

        vm.expectRevert(RitualPredict.BettingClosed.selector);
        vm.prank(carol);
        predict.bet{value: 1 ether}(id, true);

        // A winner must not take the payout and then the stake back on top.
        vm.expectRevert(RitualPredict.NotInvalid.selector);
        vm.prank(alice);
        predict.claimRefund(id);
    }

    function test_Fsm_InvalidRejectsBetsAndWinnings() public {
        uint256 id = _invalidMarket();

        vm.expectRevert(RitualPredict.BettingClosed.selector);
        vm.prank(carol);
        predict.bet{value: 1 ether}(id, true);

        // No payout can be computed for a market that was never resolved.
        vm.expectRevert(RitualPredict.NotResolved.selector);
        vm.prank(alice);
        predict.claimWinnings(id);
    }

    // ── terminal states really are terminal ────────────────────────────

    /// The most important one: once everyone is entitled to a refund, a late oracle
    /// recovery must not turn the market back into a payable one.
    function test_Fsm_InvalidIsTerminalEvenWhenTheOracleRecovers() public {
        uint256 id = _invalidMarket(); // the oracle is healthy again by now

        _fire(id, 3); // a leftover booked execution arrives

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(
            uint256(m.state),
            uint256(RitualPredict.MarketState.Invalid),
            "still Invalid"
        );
        assertEq(
            m.attempts,
            predict.MAX_ATTEMPTS(),
            "the attempt counter did not move"
        );
        assertEq(
            uint256(m.outcome),
            uint256(RitualPredict.Outcome.Unresolved),
            "no outcome was written after the fact"
        );

        // And the refund path still works afterwards.
        vm.prank(alice);
        predict.claimRefund(id);
        assertEq(alice.balance, 100 ether, "alice got her stake back");
    }

    function test_Fsm_ResolvedIsTerminalEvenIfTheOracleChangesItsMind() public {
        uint256 id = _resolvedMarket(); // YES, observed 4200

        _setObserved(1); // the same URL would now answer NO
        _fire(id, 1);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(
            uint256(m.state),
            uint256(RitualPredict.MarketState.Resolved)
        );
        assertEq(
            uint256(m.outcome),
            uint256(RitualPredict.Outcome.Yes),
            "the outcome is frozen"
        );
        assertEq(
            m.observedValue,
            OBSERVED,
            "so is the value it was decided on"
        );
        assertEq(m.attempts, 1, "and no extra attempt was spent");
    }

    function test_Fsm_RefundIsAOneWayTransitionPerAccount() public {
        uint256 id = _invalidMarket();

        vm.prank(alice);
        predict.claimRefund(id);

        vm.expectRevert(RitualPredict.AlreadySettled.selector);
        vm.prank(alice);
        predict.claimRefund(id);

        // Settling one account leaves every other account alone.
        vm.prank(bob);
        predict.claimRefund(id);
        assertEq(address(predict).balance, 0);
    }

    function test_Fsm_SettlingIsPerAccountNotPerMarket() public {
        uint256 id = _resolvedMarket(); // alice backed YES and won, bob backed NO

        vm.prank(alice);
        predict.claimWinnings(id);

        vm.expectRevert(RitualPredict.NothingToClaim.selector);
        vm.prank(bob);
        predict.claimWinnings(id);

        vm.expectRevert(RitualPredict.AlreadySettled.selector);
        vm.prank(alice);
        predict.claimWinnings(id);
    }

    // ── Closed is derived, not stored ──────────────────────────────────

    /// `Closed` never reaches storage: `getMarket` synthesises it from the block number.
    /// Rolling back before the close block therefore shows `Open` again, which a stored
    /// state could never do. `bet` checks the block directly for exactly this reason, so
    /// nothing depends on a state that is not really there.
    function test_Fsm_ClosedIsDerivedFromTheBlockNotStored() public {
        uint256 id = _openMarket();
        uint64 closeBlock = predict.getMarket(id).closeBlock;

        vm.roll(closeBlock);
        _assertState(
            id,
            RitualPredict.MarketState.Closed,
            "at the close block: Closed"
        );

        vm.roll(closeBlock - 1);
        _assertState(
            id,
            RitualPredict.MarketState.Open,
            "one block earlier it is Open again, so Closed was never written"
        );

        // getMarkets() goes through the same view, so the list agrees with the detail.
        vm.roll(closeBlock);
        RitualPredict.Market[] memory all = predict.getMarkets();
        assertEq(
            uint256(all[0].state),
            uint256(RitualPredict.MarketState.Closed)
        );
    }

    /// Resolution reads the stored state, which is still `Open` while the view reports
    /// `Closed`. This pins that the derived state does not block the real transition.
    function test_Fsm_ResolutionWorksFromTheDerivedClosedState() public {
        uint256 id = _closedMarket();
        _assertState(id, RitualPredict.MarketState.Closed, "the view says Closed");

        _rollToResolve(id);
        _fire(id, 0);
        _assertState(
            id,
            RitualPredict.MarketState.Resolved,
            "and it still resolves"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    //                  INTERRUPTED AND RE-RUN EXECUTIONS
    //
    // Three different things can make this contract's code run more than
    // once for what a user thinks of as a single operation:
    //
    //  1. The chain itself. A short-running async call is executed twice
    //     by design: once as a simulation that builds the commitment (the
    //     HTTP output is still empty) and once as a replay with the
    //     settled output injected. The simulation's state is discarded.
    //     Both passes must build a byte-identical request or the
    //     settlement will not match the commitment.
    //
    //  2. An execution that dies half-way (out of gas). The EVM discards
    //     everything it touched, so the market must be left exactly as it
    //     was and the Scheduler's next booked attempt must still work.
    //
    //  3. A payee that calls back into the contract while it is being
    //     paid. Native transfers forward all remaining gas, so a winner
    //     that is a contract can re-enter `claimWinnings` or
    //     `claimRefund` from inside its own payout.
    //
    // A fourth case is not re-execution but the same class of question:
    // several markets are in flight at once, and settling one must not
    // touch the others.
    // ═══════════════════════════════════════════════════════════════════

    // ── 1. simulation, then replay ─────────────────────────────────────

    /// The simulation pass cannot read a settled output, so it takes the failure path.
    /// That must cost the market nothing, because the chain throws that state away and
    /// replays the same execution from where it started.
    function test_Rerun_TheSimulationPassIsDiscardedAndTheReplayDecides() public {
        uint256 id = _armedMarket();
        uint256 snap = vm.snapshotState();

        // Pass 1: the builder simulates. actualOutput is still empty.
        http.setMode(MockHttpPrecompile.Mode.Unsettled);
        _fire(id, 0);
        assertEq(
            predict.getMarket(id).attempts,
            1,
            "inside the simulation the attempt does look spent"
        );
        _assertState(
            id,
            RitualPredict.MarketState.Resolving,
            "and the market does look parked"
        );

        // The chain discards all of that and replays with the output injected.
        vm.revertToState(snap);
        http.setResponse(200, bytes(ORACLE_JSON), "");
        _fire(id, 0);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(m.attempts, 1, "only the replay is real, so one attempt was spent");
        assertEq(
            uint256(m.state),
            uint256(RitualPredict.MarketState.Resolved),
            "and the replay decides the market"
        );
        assertEq(m.observedValue, OBSERVED);
    }

    /// The commitment is built from the request bytes of the simulation and checked
    /// again on the replay. The replay happens in a later block at a different basefee,
    /// so nothing in the request may depend on either.
    function test_Rerun_BothPassesBuildTheIdenticalRequest() public {
        uint256 id = _armedMarket();
        uint256 snap = vm.snapshotState();

        http.setMode(MockHttpPrecompile.Mode.Unsettled);
        _fire(id, 0);
        address simExecutor = http.lastExecutor();
        string memory simUrl = http.lastUrl();
        uint256 simTtl = http.lastTtl();
        uint8 simMethod = http.lastMethod();

        vm.revertToState(snap);
        vm.roll(block.number + 250); // the replay lands in a later block
        vm.fee(9 gwei); // at a different basefee
        http.setResponse(200, bytes(ORACLE_JSON), "");
        _fire(id, 0);

        assertEq(http.lastExecutor(), simExecutor, "the same executor in both passes");
        assertEq(http.lastUrl(), simUrl, "the same url");
        assertEq(http.lastTtl(), simTtl, "the same ttl");
        assertEq(http.lastMethod(), simMethod, "the same method");
    }

    /// Each retry is a fresh simulate-and-replay pair, and the second one must not be
    /// contaminated by the first.
    function test_Rerun_EachRetryIsItsOwnSimulateAndReplayPair() public {
        uint256 id = _armedMarket();

        http.setMode(MockHttpPrecompile.Mode.Fail);
        _fire(id, 0); // attempt 1 genuinely fails
        address firstExecutor = http.lastExecutor();

        uint256 snap = vm.snapshotState();
        http.setMode(MockHttpPrecompile.Mode.Unsettled);
        _fire(id, 1); // attempt 2, simulation pass
        address secondExecutor = http.lastExecutor();
        assertTrue(
            secondExecutor != firstExecutor,
            "a retry re-rolls the executor, so one bad node cannot sink a market"
        );

        vm.revertToState(snap);
        http.setResponse(200, bytes(ORACLE_JSON), "");
        _fire(id, 1); // attempt 2, replay

        assertEq(
            http.lastExecutor(),
            secondExecutor,
            "the replay of attempt 2 reaches the same executor its simulation chose"
        );
        assertEq(predict.getMarket(id).attempts, 2, "one failure plus one success");
        _assertState(id, RitualPredict.MarketState.Resolved, "and it resolves");
    }

    // ── 2. an execution that dies half-way ─────────────────────────────

    function test_Rerun_AnExecutionThatRunsOutOfGasLeavesNoTrace() public {
        uint256 id = _armedMarket();

        bool finished = true;
        try scheduler.fire{gas: 80_000}(_scheduleIdOf(id), 0) {} catch {
            finished = false;
        }
        assertFalse(finished, "the execution was cut short");

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(m.attempts, 0, "a half-finished execution burns no attempt");
        assertEq(
            uint256(m.state),
            uint256(RitualPredict.MarketState.Closed),
            "and leaves the market exactly as it was"
        );
        assertEq(m.totalYes, 3 ether, "the pools are untouched");
        assertEq(m.totalNo, 1 ether);

        // The next booked attempt still works, which is the whole point of not
        // recording anything on the way in.
        _fire(id, 1);
        _assertState(
            id,
            RitualPredict.MarketState.Resolved,
            "the Scheduler's next attempt resolves it"
        );
    }

    // ── 3. a payee that calls back in ──────────────────────────────────

    function test_Rerun_AReentrantWinnerCannotBePaidTwice() public {
        uint256 id = _create();
        ReentrantClaimer attacker = new ReentrantClaimer();
        attacker.arm(predict, id, 0); // re-enter claimWinnings

        attacker.bet{value: 3 ether}(true);
        vm.prank(bob);
        predict.bet{value: 1 ether}(id, false);
        _rollToResolve(id);
        _fire(id, 0); // YES

        attacker.claim();

        assertEq(attacker.reenterCount(), 1, "it did try to come back in");
        assertTrue(attacker.nestedFailed(), "and the second claim was refused");
        assertEq(address(attacker).balance, 4 ether, "exactly one payout, not two");
        assertEq(address(predict).balance, 0, "nothing extra left the contract");
    }

    /// The cross-function version: take the payout, then try to take the stake back
    /// through the refund path during the same transfer.
    function test_Rerun_AWinnerCannotGrabARefundDuringItsOwnPayout() public {
        uint256 id = _create();
        ReentrantClaimer attacker = new ReentrantClaimer();
        attacker.arm(predict, id, 1); // re-enter claimRefund

        attacker.bet{value: 3 ether}(true);
        vm.prank(bob);
        predict.bet{value: 1 ether}(id, false);
        _rollToResolve(id);
        _fire(id, 0); // YES

        attacker.claim();

        assertTrue(attacker.nestedFailed(), "a resolved market has no refund path");
        assertEq(address(attacker).balance, 4 ether, "the payout and nothing more");
        assertEq(address(predict).balance, 0);
    }

    function test_Rerun_AReentrantRefundCannotBeTakenTwice() public {
        uint256 id = _create();
        ReentrantClaimer attacker = new ReentrantClaimer();
        attacker.arm(predict, id, 1); // re-enter claimRefund

        attacker.bet{value: 3 ether}(true);
        vm.prank(bob);
        predict.bet{value: 1 ether}(id, false);
        _rollToResolve(id);

        http.setMode(MockHttpPrecompile.Mode.Fail);
        _fire(id, 0);
        _fire(id, 1);
        _fire(id, 2); // three failures: everyone refunds

        attacker.refund();

        assertTrue(attacker.nestedFailed(), "the second refund was refused");
        assertEq(address(attacker).balance, 3 ether, "its own stake, once");
        assertEq(address(predict).balance, 1 ether, "bob's stake is still waiting");
    }

    /// A payout that cannot be delivered must not be recorded as settled, or the money
    /// would be stranded. The claim reverts whole and can be made again later.
    function test_Rerun_ARejectedPayoutCanBeClaimedAgainLater() public {
        uint256 id = _create();
        PickyReceiver picky = new PickyReceiver();
        picky.arm(predict, id);

        picky.bet{value: 3 ether}(true);
        vm.prank(bob);
        predict.bet{value: 1 ether}(id, false);
        _rollToResolve(id);
        _fire(id, 0); // YES

        picky.setAccepting(false);
        vm.expectRevert(RitualPredict.TransferFailed.selector);
        picky.claim();

        (, , bool alreadySettled, uint256 claimable) = predict.stakesOf(
            id,
            address(picky)
        );
        assertFalse(alreadySettled, "a failed transfer settles nothing");
        assertEq(claimable, 4 ether, "the payout is still owed");
        assertEq(address(predict).balance, 4 ether, "and the money is still here");

        picky.setAccepting(true);
        picky.claim();
        assertEq(address(picky).balance, 4 ether, "the retry goes through");
        assertEq(address(predict).balance, 0);
    }

    // ── 4. several markets in flight at once ───────────────────────────

    function test_Rerun_SettlingOneMarketLeavesTheOthersUntouched() public {
        uint256 first = _openMarket();
        uint256 second = _openMarket();
        uint256 third = _openMarket();

        _rollToResolve(second);
        _fire(second, 0); // only the middle one

        _assertState(second, RitualPredict.MarketState.Resolved, "the middle one settled");
        _assertState(first, RitualPredict.MarketState.Closed, "the first is untouched");
        _assertState(third, RitualPredict.MarketState.Closed, "so is the third");

        RitualPredict.Market memory a = predict.getMarket(first);
        assertEq(a.attempts, 0, "no attempt was spent on a market that did not fire");
        assertEq(a.totalYes, 3 ether, "its pools are its own");
        assertEq(a.totalNo, 1 ether);
        assertEq(
            uint256(a.outcome),
            uint256(RitualPredict.Outcome.Unresolved),
            "and it has no outcome yet"
        );

        // The third market can now settle the opposite way without disturbing the second.
        _setObserved(1); // below the target, so NO
        _fire(third, 0);

        assertEq(
            uint256(predict.getMarket(third).outcome),
            uint256(RitualPredict.Outcome.No),
            "the third resolves on its own reading"
        );
        RitualPredict.Market memory b = predict.getMarket(second);
        assertEq(
            uint256(b.outcome),
            uint256(RitualPredict.Outcome.Yes),
            "the second keeps the answer it was settled with"
        );
        assertEq(b.observedValue, OBSERVED, "and the value it was settled on");
    }

    function test_Rerun_ClaimingOnOneMarketLeavesTheOtherClaimable() public {
        uint256 first = _openMarket();
        uint256 second = _openMarket();

        _rollToResolve(first);
        _fire(first, 0);
        _fire(second, 0);

        vm.prank(alice);
        predict.claimWinnings(first);

        (, , bool settledFirst, ) = predict.stakesOf(first, alice);
        (, , bool settledSecond, uint256 claimableSecond) = predict.stakesOf(
            second,
            alice
        );
        assertTrue(settledFirst, "the first market is settled for alice");
        assertFalse(settledSecond, "the second is not");
        assertEq(claimableSecond, 4 ether, "and is still fully claimable");

        vm.prank(alice);
        predict.claimWinnings(second);
        // 3 ether staked on each of the two markets, 4 ether paid back from each.
        assertEq(
            alice.balance,
            100 ether - 6 ether + 8 ether,
            "both payouts arrived"
        );
    }
    // ═══════════════════════════════════════════════════════════════════
    //          MANY USERS AT ONCE, THE CLOCK, EMPTY WALLETS, LOAD
    //
    // There is no true concurrency inside a contract: the EVM orders every
    // transaction in a block and runs them one at a time. The real
    // questions behind "what if two people act at once" are therefore
    //
    //   * does the order they arrive in change anyone's money?
    //   * can two actions that must not overlap land in the same block?
    //
    // Both are tested below, along with the wall clock (which this
    // contract never reads), empty wallets on both sides, and what
    // happens as the numbers get large.
    // ═══════════════════════════════════════════════════════════════════

    // ── many people acting at once ─────────────────────────────────────

    /// Pari-mutuel payouts are computed from the final pool totals, so the order the
    /// bets arrived in cannot matter. Same four bets, two different orders, same money.
    function test_Concurrency_PayoutsDependOnTotalsNotOnArrivalOrder() public {
        uint256 snap = vm.snapshotState();

        uint256 forwards = _create();
        vm.prank(alice);
        predict.bet{value: 3 ether}(forwards, true);
        vm.prank(carol);
        predict.bet{value: 2 ether}(forwards, true);
        vm.prank(bob);
        predict.bet{value: 1 ether}(forwards, false);
        _rollToResolve(forwards);
        _fire(forwards, 0);
        vm.prank(alice);
        predict.claimWinnings(forwards);
        uint256 aliceForwards = alice.balance;
        vm.prank(carol);
        predict.claimWinnings(forwards);
        uint256 carolForwards = carol.balance;

        vm.revertToState(snap);

        uint256 backwards = _create();
        vm.prank(bob);
        predict.bet{value: 1 ether}(backwards, false);
        vm.prank(carol);
        predict.bet{value: 2 ether}(backwards, true);
        vm.prank(alice);
        predict.bet{value: 3 ether}(backwards, true);
        _rollToResolve(backwards);
        _fire(backwards, 0);
        vm.prank(carol);
        predict.claimWinnings(backwards); // and claimed in the opposite order too
        vm.prank(alice);
        predict.claimWinnings(backwards);

        assertEq(alice.balance, aliceForwards, "alice is paid the same either way");
        assertEq(carol.balance, carolForwards, "so is carol");
    }

    /// Twenty people bet without a single block passing between them.
    function test_Concurrency_TwentyBetsInOneBlock() public {
        uint256 id = _create();
        uint256 startBlock = block.number;

        for (uint256 i = 0; i < 20; i++) {
            address p = address(uint160(0x200000 + i));
            vm.deal(p, 1 ether);
            vm.prank(p);
            predict.bet{value: 1 ether}(id, i % 4 != 0); // 15 YES, 5 NO
        }

        assertEq(block.number, startBlock, "no block passed while they were betting");
        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(m.totalYes, 15 ether);
        assertEq(m.totalNo, 5 ether);

        _rollToResolve(id);
        _fire(id, 0); // YES

        uint256 paid;
        for (uint256 i = 0; i < 20; i++) {
            address p = address(uint160(0x200000 + i));
            if (i % 4 == 0) continue; // the losers get nothing
            vm.prank(p);
            predict.claimWinnings(id);
            paid += p.balance;
        }
        assertLe(paid, 20 ether, "the pool is never overdrawn");
        assertLt(address(predict).balance, 15, "under one wei per winner is left");
    }

    /// Two markets created without a block in between must not share anything.
    function test_Concurrency_MarketsCreatedInOneBlockStaySeparate() public {
        uint256 startBlock = block.number;
        uint256 a = _create();
        uint256 b = _create();
        assertEq(block.number, startBlock, "same block");

        assertTrue(a != b, "distinct market ids");
        assertTrue(
            _scheduleIdOf(a) != _scheduleIdOf(b),
            "and distinct bookings with the Scheduler"
        );

        vm.prank(alice);
        predict.bet{value: 1 ether}(a, true);
        assertEq(predict.getMarket(b).totalYes, 0, "a bet lands in one market only");
    }

    /// A late bet on the winning side dilutes everyone already there. That is what
    /// pari-mutuel means, and it is worth stating rather than discovering.
    function test_Concurrency_ALateBetDilutesTheBackersAlreadyOnThatSide() public {
        uint256 snap = vm.snapshotState();

        uint256 alone = _create();
        vm.prank(alice);
        predict.bet{value: 1 ether}(alone, true);
        vm.prank(bob);
        predict.bet{value: 1 ether}(alone, false);
        _rollToResolve(alone);
        _fire(alone, 0);
        vm.prank(alice);
        predict.claimWinnings(alone);
        uint256 payoutAlone = alice.balance - 99 ether; // she staked 1

        vm.revertToState(snap);

        uint256 crowded = _create();
        vm.prank(alice);
        predict.bet{value: 1 ether}(crowded, true);
        vm.prank(carol);
        predict.bet{value: 9 ether}(crowded, true); // arrives just before the close
        vm.prank(bob);
        predict.bet{value: 1 ether}(crowded, false);
        _rollToResolve(crowded);
        _fire(crowded, 0);
        vm.prank(alice);
        predict.claimWinnings(crowded);
        uint256 payoutCrowded = alice.balance - 99 ether;

        assertEq(payoutAlone, 2 ether, "alone she takes the whole pool");
        assertEq(payoutCrowded, 1.1 ether, "sharing with carol she takes a tenth of it");
        assertLt(payoutCrowded, payoutAlone, "a late backer dilutes the earlier ones");
    }

    /// Betting and resolving must never be able to land in the same block, whatever
    /// durations the creator asks for.
    function testFuzz_ResolutionIsAlwaysAfterTheCloseBlock(
        uint32 bettingSeconds,
        uint32 delaySeconds
    ) public {
        uint256 betting = bound(
            uint256(bettingSeconds),
            predict.MIN_BETTING_SECONDS(),
            predict.MAX_MARKET_SECONDS() - predict.MIN_RESOLVE_DELAY_SECONDS()
        );
        uint256 delay = bound(
            uint256(delaySeconds),
            predict.MIN_RESOLVE_DELAY_SECONDS(),
            predict.MAX_MARKET_SECONDS() - betting
        );

        RitualPredict.NewMarket memory p = _params();
        p.bettingSeconds = betting;
        p.resolveDelaySeconds = delay;

        RitualPredict.Market memory m = predict.getMarket(predict.createMarket(p));
        assertGt(m.closeBlock, block.number, "betting is open for at least one block");
        assertGt(
            m.resolveBlock,
            m.closeBlock,
            "and resolution is always at least one block later"
        );
    }

    // ── the wall clock ─────────────────────────────────────────────────

    /// Runs an identical market from an identical starting state at a given wall-clock
    /// time, and hands back the finished market for comparison.
    function _lifecycleAtTimestamp(
        uint256 timestampMs
    ) internal returns (RitualPredict.Market memory m) {
        uint256 snap = vm.snapshotState();
        vm.warp(timestampMs);

        uint256 id = _armedMarket();
        _fire(id, 0);
        m = predict.getMarket(id);

        vm.revertToState(snap);
    }

    /// The contract contains no reference to `block.timestamp` at all: deadlines are
    /// block numbers, and the constructor converts human seconds into blocks once. So
    /// there is no calendar arithmetic anywhere, and nothing for a leap day, a leap
    /// second or a timezone to break. Rather than skip the question, this runs the same
    /// market on a leap day, on the 2100 boundary (a year divisible by 100 but not 400,
    /// the classic off-by-one in date code) and far in the future, and shows that every
    /// field of the result is byte-for-byte the same.
    ///
    /// Timestamps are in milliseconds because that is what Ritual Chain reports.
    function test_Clock_TheWallClockCannotChangeAnything() public {
        RitualPredict.Market memory leapDay = _lifecycleAtTimestamp(
            1_835_395_200_000 // 2028-02-29
        );
        RitualPredict.Market memory notALeapYear = _lifecycleAtTimestamp(
            4_108_233_600_000 // 2100-03-01
        );
        RitualPredict.Market memory farFuture = _lifecycleAtTimestamp(
            253_402_300_799_000 // 9999-12-31
        );

        assertEq(leapDay.closeBlock, notALeapYear.closeBlock, "same close block");
        assertEq(leapDay.closeBlock, farFuture.closeBlock);
        assertEq(leapDay.resolveBlock, notALeapYear.resolveBlock, "same resolve block");
        assertEq(leapDay.resolveBlock, farFuture.resolveBlock);
        assertEq(uint256(leapDay.state), uint256(notALeapYear.state), "same state");
        assertEq(uint256(leapDay.state), uint256(farFuture.state));
        assertEq(uint256(leapDay.outcome), uint256(notALeapYear.outcome), "same outcome");
        assertEq(uint256(leapDay.outcome), uint256(farFuture.outcome));
        assertEq(leapDay.observedValue, notALeapYear.observedValue);
        assertEq(leapDay.observedValue, farFuture.observedValue);
        assertEq(leapDay.attempts, notALeapYear.attempts);
        assertEq(leapDay.attempts, farFuture.attempts);
    }

    /// The deadline is a block number, so a clock that jumps does not move it either.
    function test_Clock_ASuddenJumpDoesNotCloseOrOpenAMarket() public {
        uint256 id = _openMarket();

        vm.warp(block.timestamp + 3650 days); // ten years pass on the clock
        _assertState(
            id,
            RitualPredict.MarketState.Open,
            "betting is still open: no block was mined"
        );

        vm.prank(carol);
        predict.bet{value: 1 ether}(id, true); // and still accepted

        vm.roll(predict.getMarket(id).closeBlock); // one block does what a decade did not
        _assertState(id, RitualPredict.MarketState.Closed, "blocks are the only clock");
    }

    // ── empty wallets, on both sides ───────────────────────────────────

    /// `vm.prank` only changes who the sender *appears* to be; the ether still comes
    /// out of the test contract's own balance. To test a genuinely empty wallet the
    /// bettor has to be a real account with a real balance, so this one is a contract.
    function test_Funds_ABettorWithoutTheMoneyCannotBet() public {
        uint256 id = _create();

        BrokeBettor broke = new BrokeBettor(predict);
        vm.deal(address(broke), 0.5 ether); // wants to stake 1 ether, holds half

        vm.expectRevert();
        broke.tryBet(id, 1 ether);
        assertEq(predict.getMarket(id).totalYes, 0, "nothing was recorded");

        broke.tryBet(id, 0.5 ether); // exactly what it holds does go through
        assertEq(predict.getMarket(id).totalYes, 0.5 ether, "spending it all is fine");
        assertEq(address(broke).balance, 0, "and leaves the wallet empty");

        vm.expectRevert();
        broke.tryBet(id, 1 wei); // now even one wei is out of reach
    }

    /// The contract prepays its own scheduled executions out of its RitualWallet
    /// balance. Nothing stops a market being created while that balance is zero: the
    /// booking is made, but on a real chain the Scheduler skips an execution it cannot
    /// charge for. This pins the behaviour so it is a known operating requirement
    /// rather than a surprise.
    function test_Funds_AMarketIsBookedEvenWithNoPrepaidBalance() public {
        assertEq(predict.executionBalance(), 0, "nothing prepaid yet");

        uint256 id = _create();
        assertTrue(_scheduleIdOf(id) != 0, "the booking is made regardless");

        predict.fundExecution{value: 1 ether}(1000);
        assertEq(
            predict.executionBalance(),
            1 ether,
            "funding it afterwards still works"
        );
    }

    /// After a market resolves, the contract must be holding exactly what it still owes.
    function test_Funds_TheContractHoldsExactlyWhatItStillOwes() public {
        uint256 id = _create();
        vm.prank(alice);
        predict.bet{value: 3 ether}(id, true);
        vm.prank(carol);
        predict.bet{value: 2 ether}(id, true);
        vm.prank(bob);
        predict.bet{value: 5 ether}(id, false);
        _rollToResolve(id);
        _fire(id, 0); // YES

        (, , , uint256 aliceOwed) = predict.stakesOf(id, alice);
        (, , , uint256 carolOwed) = predict.stakesOf(id, carol);
        (, , , uint256 bobOwed) = predict.stakesOf(id, bob);
        assertEq(bobOwed, 0, "the losing side is owed nothing");
        assertGe(
            address(predict).balance,
            aliceOwed + carolOwed,
            "the balance covers every outstanding claim"
        );

        vm.prank(alice);
        predict.claimWinnings(id);
        (, , , uint256 carolStillOwed) = predict.stakesOf(id, carol);
        assertGe(
            address(predict).balance,
            carolStillOwed,
            "and still covers the rest afterwards"
        );
    }

    // ── load: what happens as the numbers grow ─────────────────────────

    /// The Scheduler is told to allow RESOLVE_GAS_LIMIT gas per execution. If the
    /// callback does not fit inside that, every resolution on a real chain fails.
    function test_Load_ResolutionFitsInsideTheBookedGasLimit() public {
        uint256 id = _armedMarket();

        uint256 before = gasleft();
        _fire(id, 0);
        uint256 used = before - gasleft();

        _assertState(id, RitualPredict.MarketState.Resolved, "it did resolve");
        assertLt(
            used,
            predict.RESOLVE_GAS_LIMIT(),
            "a resolution must fit in the gas the contract books for it"
        );
        // Comfortably inside, not just barely: the mocks are cheaper than the real
        // precompiles, so the margin has to be wide. Measured at ~223k gas here,
        // roughly a ninth of the 2,000,000 booked.
        assertLt(used, predict.RESOLVE_GAS_LIMIT() / 4, "with room to spare");
    }

    /// Nothing in `bet` loops over participants, so the two-hundredth bettor pays what
    /// the second one paid.
    function test_Load_BettingCostDoesNotGrowWithTheCrowd() public {
        uint256 id = _create();

        address second = address(uint160(0x300000));
        vm.deal(second, 1 ether);
        vm.prank(alice);
        predict.bet{value: 1 ether}(id, true); // the first bet also opens the pool
        uint256 g0 = gasleft();
        vm.prank(second);
        predict.bet{value: 1 ether}(id, true);
        uint256 earlyCost = g0 - gasleft();

        for (uint256 i = 1; i < 198; i++) {
            address p = address(uint160(0x300000 + i));
            vm.deal(p, 1 ether);
            vm.prank(p);
            predict.bet{value: 1 ether}(id, true);
        }

        address last = address(uint160(0x300000 + 198));
        vm.deal(last, 1 ether);
        uint256 g1 = gasleft();
        vm.prank(last);
        predict.bet{value: 1 ether}(id, true);
        uint256 lateCost = g1 - gasleft();

        assertLe(
            lateCost,
            (earlyCost * 11) / 10,
            "the 200th bet costs what the 2nd did, within 10%"
        );
    }

    /// Payouts are pull-based: each winner pays for their own claim, and that cost does
    /// not depend on how many other winners there are.
    function test_Load_ClaimCostDoesNotGrowWithTheNumberOfWinners() public {
        uint256 id = _create();
        uint256 n = 100;

        for (uint256 i = 0; i < n; i++) {
            address p = address(uint160(0x400000 + i));
            vm.deal(p, 1 ether);
            vm.prank(p);
            predict.bet{value: 1 ether}(id, true);
        }
        vm.prank(bob);
        predict.bet{value: 3 ether}(id, false);
        _rollToResolve(id);
        _fire(id, 0);

        uint256 g0 = gasleft();
        vm.prank(address(uint160(0x400000)));
        predict.claimWinnings(id);
        uint256 firstCost = g0 - gasleft();

        for (uint256 i = 1; i < n - 1; i++) {
            vm.prank(address(uint160(0x400000 + i)));
            predict.claimWinnings(id);
        }

        uint256 g1 = gasleft();
        vm.prank(address(uint160(0x400000 + n - 1)));
        predict.claimWinnings(id);
        uint256 lastCost = g1 - gasleft();

        assertLe(
            lastCost,
            (firstCost * 12) / 10,
            "the hundredth winner pays what the first one paid, within 20%"
        );
    }

    /// `getMarkets()` is the only loop in the contract and it walks every market ever
    /// created. That is fine for a workshop and it is a hard ceiling for anything
    /// bigger, so the growth is measured rather than assumed.
    function test_Load_GetMarketsCostGrowsWithEveryMarketEverCreated() public {
        for (uint256 i = 0; i < 10; i++) _create();
        uint256 g0 = gasleft();
        predict.getMarkets();
        uint256 costAtTen = g0 - gasleft();

        for (uint256 i = 0; i < 50; i++) _create();
        uint256 g1 = gasleft();
        RitualPredict.Market[] memory all = predict.getMarkets();
        uint256 costAtSixty = g1 - gasleft();

        assertEq(all.length, 60, "every market comes back in one array");
        assertGt(
            costAtSixty,
            costAtTen * 4,
            "the cost is proportional to the number of markets, not constant"
        );

        // The marginal cost of one more market, used to state the practical ceiling.
        // Measured: ~384k gas at 10 markets, ~2.33M at 60, so roughly 39k per market.
        // An eth_call is not bound by the block gas limit, but a node's RPC cap is
        // typically 50M, which puts the practical ceiling near 1,200 markets.
        uint256 perMarket = (costAtSixty - costAtTen) / 50;
        assertGt(perMarket, 0);
        assertLt(perMarket, 100_000, "under 100k gas per market in the list");
    }

    /// A market that is heavily used in every dimension at once still settles.
    function test_Load_ABusyMarketStillResolvesAndPaysOut() public {
        uint256 id = _create();
        uint256 n = 150;
        uint256 stakedYes;

        for (uint256 i = 0; i < n; i++) {
            address p = address(uint160(0x500000 + i));
            uint256 stake = 1 ether + (i * 137 gwei); // deliberately uneven
            vm.deal(p, stake);
            vm.prank(p);
            predict.bet{value: stake}(id, true);
            stakedYes += stake;
        }
        vm.prank(bob);
        predict.bet{value: 7 ether}(id, false);

        _rollToResolve(id);
        _fire(id, 0); // YES

        uint256 pool = stakedYes + 7 ether;
        assertEq(address(predict).balance, pool);

        uint256 paid;
        for (uint256 i = 0; i < n; i++) {
            address p = address(uint160(0x500000 + i));
            vm.prank(p);
            predict.claimWinnings(id);
            paid += p.balance;
        }

        assertLe(paid, pool, "150 uneven winners never overdraw the pool");
        assertEq(address(predict).balance, pool - paid);
        assertLt(address(predict).balance, n, "under one wei of dust per winner");
    }
}

// ───────────────────────── test-only counterparties ──────────────────────────

/// A bettor that calls back into the contract from inside its own payout. It swallows
/// the nested failure, which is what a real attacker would do: blowing up its own
/// transfer would only cost it the payout it already had.
contract ReentrantClaimer {
    RitualPredict public predict;
    uint256 public marketId;
    uint8 public mode; // 0 = re-enter claimWinnings, 1 = re-enter claimRefund
    uint256 public reenterCount;
    bool public nestedFailed;
    bool private _inside;

    function arm(RitualPredict p, uint256 id, uint8 m) external {
        predict = p;
        marketId = id;
        mode = m;
    }

    function bet(bool isYes) external payable {
        predict.bet{value: msg.value}(marketId, isYes);
    }

    function claim() external {
        predict.claimWinnings(marketId);
    }

    function refund() external {
        predict.claimRefund(marketId);
    }

    receive() external payable {
        if (_inside) return;
        _inside = true;
        reenterCount += 1;

        if (mode == 0) {
            try predict.claimWinnings(marketId) {} catch {
                nestedFailed = true;
            }
        } else {
            try predict.claimRefund(marketId) {} catch {
                nestedFailed = true;
            }
        }

        _inside = false;
    }
}

/// A bettor that refuses payment until it is switched on, so a payout can be made to
/// fail and then retried.
contract PickyReceiver {
    RitualPredict public predict;
    uint256 public marketId;
    bool public accepting;

    function arm(RitualPredict p, uint256 id) external {
        predict = p;
        marketId = id;
    }

    function setAccepting(bool v) external {
        accepting = v;
    }

    function bet(bool isYes) external payable {
        predict.bet{value: msg.value}(marketId, isYes);
    }

    function claim() external {
        predict.claimWinnings(marketId);
    }

    receive() external payable {
        require(accepting, "not accepting right now");
    }
}

contract BrokeBettor {
    RitualPredict public predict;

    constructor(RitualPredict p) {
        predict = p;
    }

    function tryBet(uint256 marketId, uint256 amount) external {
        predict.bet{value: amount}(marketId, true);
    }
}
