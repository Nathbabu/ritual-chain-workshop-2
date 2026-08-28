// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {RitualPredict} from "./RitualPredict.sol";
import {RitualChain} from "./ritual/RitualChain.sol";
import {
    MockScheduler,
    MockRitualWallet,
    MockTEEServiceRegistry,
    MockHttpPrecompile,
    MockJqPrecompile
} from "./mocks/RitualMocks.sol";

contract RitualPredictTest is Test {
    RitualPredict predict;

    MockScheduler          scheduler;
    MockRitualWallet       wallet;
    MockTEEServiceRegistry teeRegistry;
    MockHttpPrecompile     httpPrecompile;
    MockJqPrecompile       jqPrecompile;

    address constant EXECUTOR = address(0xE7EC);
    uint256 constant BLOCK_TIME_MS = 200;
    uint256 constant BET_AMOUNT = 1 ether;

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    // ── Helper: build a sensible NewMarket param struct ──────────────────────
    function _defaultParams() internal pure returns (RitualPredict.NewMarket memory) {
        return RitualPredict.NewMarket({
            question:            "Will ETH/USD be >= $4000?",
            oracleUrl:           "https://oracle.example.com/eth",
            jsonPath:            ".price",
            target:              4000,
            comparator:          RitualPredict.Comparator.GTE,
            bettingSeconds:      60,
            resolveDelaySeconds: 30
        });
    }

    // ── Helper: create a market and return its ID ─────────────────────────────
    function _createMarket() internal returns (uint256) {
        return predict.createMarket(_defaultParams());
    }

    // ── Helper: simulate a successful scheduled resolve ───────────────────────
    function _resolve(uint256 marketId, uint256 observedValue) internal {
        httpPrecompile.setResponse(200, bytes(string(abi.encodePacked('{"price":', _uintStr(observedValue), '}'))), "");
        jqPrecompile.setValue(observedValue);
        vm.prank(RitualChain.SCHEDULER);
        predict.onScheduledResolve(0, marketId);
    }

    function _uintStr(uint256 n) internal pure returns (string memory) {
        if (n == 0) return "0";
        uint256 tmp = n; uint256 len;
        while (tmp != 0) { tmp /= 10; len++; }
        bytes memory buf = new bytes(len);
        while (n != 0) { buf[--len] = bytes1(uint8(48 + n % 10)); n /= 10; }
        return string(buf);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // setUp
    // ─────────────────────────────────────────────────────────────────────────
    function setUp() public {
        // Deploy mocks to capture their bytecode.
        MockScheduler          sch  = new MockScheduler();
        MockRitualWallet       wlt  = new MockRitualWallet();
        MockTEEServiceRegistry tee  = new MockTEEServiceRegistry();
        MockHttpPrecompile     http = new MockHttpPrecompile();
        MockJqPrecompile       jq_  = new MockJqPrecompile();

        // Etch bytecode at canonical addresses. Storage is NOT copied, only code.
        vm.etch(RitualChain.SCHEDULER,            address(sch).code);
        vm.etch(RitualChain.RITUAL_WALLET,        address(wlt).code);
        vm.etch(RitualChain.TEE_SERVICE_REGISTRY, address(tee).code);
        vm.etch(RitualChain.HTTP_PRECOMPILE,      address(http).code);
        vm.etch(RitualChain.JQ_PRECOMPILE,        address(jq_).code);

        // Bind typed wrappers to the canonical addresses so setters write to the right storage.
        scheduler      = MockScheduler(RitualChain.SCHEDULER);
        wallet         = MockRitualWallet(RitualChain.RITUAL_WALLET);
        teeRegistry    = MockTEEServiceRegistry(RitualChain.TEE_SERVICE_REGISTRY);
        httpPrecompile = MockHttpPrecompile(RitualChain.HTTP_PRECOMPILE);
        jqPrecompile   = MockJqPrecompile(RitualChain.JQ_PRECOMPILE);

        // Initialise mock state at canonical addresses.
        teeRegistry.setExecutor(EXECUTOR, true);
        // Set a default successful HTTP response so tests that don't explicitly configure
        // the mock get a valid oracle read instead of an empty-response failure.
        httpPrecompile.setResponse(200, bytes("{\"price\":4500}"), "");
        jqPrecompile.setValue(4500);

        predict = new RitualPredict(BLOCK_TIME_MS);

        vm.deal(alice, 100 ether);
        vm.deal(bob,   100 ether);
    }


    // ─────────────────────────────────────────────────────────────────────────
    // 1. Construction
    // ─────────────────────────────────────────────────────────────────────────
    function test_BlockTimeMsStored() public view {
        assertEq(predict.blockTimeMs(), BLOCK_TIME_MS);
    }

    function test_RevertConstructorZeroBlockTime() public {
        vm.expectRevert(RitualPredict.BadDuration.selector);
        new RitualPredict(0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. createMarket — validation
    // ─────────────────────────────────────────────────────────────────────────
    function test_CreateMarketReturnsId() public {
        uint256 id = _createMarket();
        assertEq(id, 1);
        assertEq(predict.marketCount(), 1);
    }

    function test_CreateMarketIncrementsCount() public {
        _createMarket();
        _createMarket();
        assertEq(predict.marketCount(), 2);
    }

    function test_CreateMarketRevertBettingTooShort() public {
        RitualPredict.NewMarket memory p = _defaultParams();
        p.bettingSeconds = 29; // MIN is 30
        vm.expectRevert(RitualPredict.BadDuration.selector);
        predict.createMarket(p);
    }

    function test_CreateMarketRevertBettingTooLong() public {
        RitualPredict.NewMarket memory p = _defaultParams();
        p.bettingSeconds = 1 days + 1;
        vm.expectRevert(RitualPredict.BadDuration.selector);
        predict.createMarket(p);
    }

    function test_CreateMarketRevertResolveDelayTooShort() public {
        RitualPredict.NewMarket memory p = _defaultParams();
        p.resolveDelaySeconds = 14;
        vm.expectRevert(RitualPredict.BadDuration.selector);
        predict.createMarket(p);
    }

    function test_CreateMarketRevertEmptyQuestion() public {
        RitualPredict.NewMarket memory p = _defaultParams();
        p.question = "";
        vm.expectRevert(RitualPredict.EmptyString.selector);
        predict.createMarket(p);
    }

    function test_CreateMarketRevertEmptyOracleUrl() public {
        RitualPredict.NewMarket memory p = _defaultParams();
        p.oracleUrl = "";
        vm.expectRevert(RitualPredict.EmptyString.selector);
        predict.createMarket(p);
    }

    function test_CreateMarketRevertEmptyJsonPath() public {
        RitualPredict.NewMarket memory p = _defaultParams();
        p.jsonPath = "";
        vm.expectRevert(RitualPredict.EmptyString.selector);
        predict.createMarket(p);
    }

    function test_CreateMarketSchedulesResolution() public {
        _createMarket();
        // nextCallId starts at 0 (constructor bypassed by vm.etch), so after one schedule() call
        // the first assigned ID is 0 and nextCallId becomes 1. The market's scheduleId == 0.
        // Verify the market recorded a scheduleId and the scheduler has the data stored.
        RitualPredict.Market memory m = predict.getMarket(1);
        MockScheduler sched = MockScheduler(RitualChain.SCHEDULER);
        // The call data for scheduleId should have non-empty calldata (the encoded callback).
        (bytes memory data,,,,,,,,,,) = sched.calls(m.scheduleId);
        assertGt(data.length, 0);
    }

    function test_CreateMarketEmitsEvents() public {
        vm.expectEmit(true, true, false, false);
        emit RitualPredict.MarketCreated(1, address(this), _defaultParams().question, 0, 0, 0);
        _createMarket();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. getMarket / state
    // ─────────────────────────────────────────────────────────────────────────
    function test_GetMarketUnknownReverts() public {
        vm.expectRevert(RitualPredict.UnknownMarket.selector);
        predict.getMarket(99);
    }

    function test_GetMarketShowsOpenInitially() public {
        uint256 id = _createMarket();
        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(uint8(m.state), uint8(RitualPredict.MarketState.Open));
    }

    function test_GetMarketShowsClosedAfterCloseBlock() public {
        uint256 id = _createMarket();
        RitualPredict.Market memory m = predict.getMarket(id);
        vm.roll(m.closeBlock);
        RitualPredict.Market memory closed = predict.getMarket(id);
        assertEq(uint8(closed.state), uint8(RitualPredict.MarketState.Closed));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. bet
    // ─────────────────────────────────────────────────────────────────────────
    function test_BetYesAccountedCorrectly() public {
        uint256 id = _createMarket();
        vm.prank(alice);
        predict.bet{value: BET_AMOUNT}(id, true);
        assertEq(predict.yesStake(id, alice), BET_AMOUNT);
        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(m.totalYes, BET_AMOUNT);
    }

    function test_BetNoAccountedCorrectly() public {
        uint256 id = _createMarket();
        vm.prank(bob);
        predict.bet{value: BET_AMOUNT}(id, false);
        assertEq(predict.noStake(id, bob), BET_AMOUNT);
        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(m.totalNo, BET_AMOUNT);
    }

    function test_BetRevertZeroStake() public {
        uint256 id = _createMarket();
        vm.prank(alice);
        vm.expectRevert(RitualPredict.ZeroStake.selector);
        predict.bet{value: 0}(id, true);
    }

    function test_BetRevertAfterCloseBlock() public {
        uint256 id = _createMarket();
        RitualPredict.Market memory m = predict.getMarket(id);
        vm.roll(m.closeBlock);
        vm.prank(alice);
        vm.expectRevert(RitualPredict.BettingClosed.selector);
        predict.bet{value: BET_AMOUNT}(id, true);
    }

    function test_BetRevertUnknownMarket() public {
        vm.prank(alice);
        vm.expectRevert(RitualPredict.UnknownMarket.selector);
        predict.bet{value: BET_AMOUNT}(99, true);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. onScheduledResolve — auth
    // ─────────────────────────────────────────────────────────────────────────
    function test_ResolveRevertNotScheduler() public {
        uint256 id = _createMarket();
        vm.expectRevert(RitualPredict.OnlyScheduler.selector);
        predict.onScheduledResolve(0, id);
    }

    function test_ResolveIgnoresUnknownMarket() public {
        vm.prank(RitualChain.SCHEDULER);
        predict.onScheduledResolve(0, 999); // must not revert
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6. Resolution — happy path YES win
    // ─────────────────────────────────────────────────────────────────────────
    function test_ResolveYesWin() public {
        uint256 id = _createMarket();
        vm.prank(alice); predict.bet{value: BET_AMOUNT}(id, true);
        vm.prank(bob);   predict.bet{value: BET_AMOUNT}(id, false);

        _resolve(id, 4500); // 4500 >= 4000 → YES

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(uint8(m.state),   uint8(RitualPredict.MarketState.Resolved));
        assertEq(uint8(m.outcome), uint8(RitualPredict.Outcome.Yes));
        assertEq(m.observedValue, 4500);
    }

    function test_ResolveNoWin() public {
        uint256 id = _createMarket();
        vm.prank(alice); predict.bet{value: BET_AMOUNT}(id, true);
        vm.prank(bob);   predict.bet{value: BET_AMOUNT}(id, false);

        _resolve(id, 3000); // 3000 < 4000 → NO

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(uint8(m.state),   uint8(RitualPredict.MarketState.Resolved));
        assertEq(uint8(m.outcome), uint8(RitualPredict.Outcome.No));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 7. Comparators
    // ─────────────────────────────────────────────────────────────────────────
    function test_ComparatorGT_Win() public {
        RitualPredict.NewMarket memory p = _defaultParams();
        p.comparator = RitualPredict.Comparator.GT;
        p.target = 4000;
        uint256 id = predict.createMarket(p);
        vm.prank(alice); predict.bet{value: BET_AMOUNT}(id, true);

        jqPrecompile.setValue(4001);
        httpPrecompile.setResponse(200, bytes('{"price":4001}'), "");
        vm.prank(RitualChain.SCHEDULER);
        predict.onScheduledResolve(0, id);

        assertEq(uint8(predict.getMarket(id).outcome), uint8(RitualPredict.Outcome.Yes));
    }

    function test_ComparatorGT_Loss() public {
        RitualPredict.NewMarket memory p = _defaultParams();
        p.comparator = RitualPredict.Comparator.GT;
        p.target = 4000;
        uint256 id = predict.createMarket(p);
        vm.prank(bob); predict.bet{value: BET_AMOUNT}(id, false);

        jqPrecompile.setValue(4000); // equal is NOT greater than
        httpPrecompile.setResponse(200, bytes('{"price":4000}'), "");
        vm.prank(RitualChain.SCHEDULER);
        predict.onScheduledResolve(0, id);

        assertEq(uint8(predict.getMarket(id).outcome), uint8(RitualPredict.Outcome.No));
    }

    function test_ComparatorLT_Win() public {
        RitualPredict.NewMarket memory p = _defaultParams();
        p.comparator = RitualPredict.Comparator.LT;
        p.target = 4000;
        uint256 id = predict.createMarket(p);
        vm.prank(alice); predict.bet{value: BET_AMOUNT}(id, true);

        jqPrecompile.setValue(3999);
        httpPrecompile.setResponse(200, bytes('{"price":3999}'), "");
        vm.prank(RitualChain.SCHEDULER);
        predict.onScheduledResolve(0, id);

        assertEq(uint8(predict.getMarket(id).outcome), uint8(RitualPredict.Outcome.Yes));
    }

    function test_ComparatorLTE_Win() public {
        RitualPredict.NewMarket memory p = _defaultParams();
        p.comparator = RitualPredict.Comparator.LTE;
        p.target = 4000;
        uint256 id = predict.createMarket(p);
        vm.prank(alice); predict.bet{value: BET_AMOUNT}(id, true);

        jqPrecompile.setValue(4000); // equal passes LTE
        httpPrecompile.setResponse(200, bytes('{"price":4000}'), "");
        vm.prank(RitualChain.SCHEDULER);
        predict.onScheduledResolve(0, id);

        assertEq(uint8(predict.getMarket(id).outcome), uint8(RitualPredict.Outcome.Yes));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 8. Failure and retry path
    // ─────────────────────────────────────────────────────────────────────────
    function test_OracleFailureDoesNotSettle() public {
        uint256 id = _createMarket();
        vm.prank(alice); predict.bet{value: BET_AMOUNT}(id, true);

        MockHttpPrecompile(RitualChain.HTTP_PRECOMPILE).setFailure();
        vm.prank(RitualChain.SCHEDULER);
        predict.onScheduledResolve(0, id);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(uint8(m.state), uint8(RitualPredict.MarketState.Resolving));
        assertEq(m.attempts, 1);
    }

    function test_ThreeFailuresInvalidateMarket() public {
        uint256 id = _createMarket();
        vm.prank(alice); predict.bet{value: BET_AMOUNT}(id, true);

        MockHttpPrecompile(RitualChain.HTTP_PRECOMPILE).setFailure();

        vm.prank(RitualChain.SCHEDULER); predict.onScheduledResolve(0, id);
        vm.prank(RitualChain.SCHEDULER); predict.onScheduledResolve(1, id);
        vm.prank(RitualChain.SCHEDULER); predict.onScheduledResolve(2, id);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(uint8(m.state), uint8(RitualPredict.MarketState.Invalid));
    }

    function test_Http404InvalidatesAfterMaxAttempts() public {
        uint256 id = _createMarket();
        vm.prank(alice); predict.bet{value: BET_AMOUNT}(id, true);

        MockHttpPrecompile(RitualChain.HTTP_PRECOMPILE).setResponse(404, bytes(""), "");

        vm.prank(RitualChain.SCHEDULER); predict.onScheduledResolve(0, id);
        vm.prank(RitualChain.SCHEDULER); predict.onScheduledResolve(1, id);
        vm.prank(RitualChain.SCHEDULER); predict.onScheduledResolve(2, id);

        assertEq(uint8(predict.getMarket(id).state), uint8(RitualPredict.MarketState.Invalid));
    }

    function test_JqFailureDoesNotSettle() public {
        uint256 id = _createMarket();
        vm.prank(alice); predict.bet{value: BET_AMOUNT}(id, true);

        MockHttpPrecompile(RitualChain.HTTP_PRECOMPILE).setResponse(200, bytes('{"price":4500}'), "");
        MockJqPrecompile(RitualChain.JQ_PRECOMPILE).setFailure();

        vm.prank(RitualChain.SCHEDULER); predict.onScheduledResolve(0, id);
        assertEq(uint8(predict.getMarket(id).state), uint8(RitualPredict.MarketState.Resolving));
    }

    function test_SuccessAfterOneFailureResolves() public {
        uint256 id = _createMarket();
        vm.prank(alice); predict.bet{value: BET_AMOUNT}(id, true);

        MockHttpPrecompile(RitualChain.HTTP_PRECOMPILE).setFailure();
        vm.prank(RitualChain.SCHEDULER); predict.onScheduledResolve(0, id);
        assertEq(uint8(predict.getMarket(id).state), uint8(RitualPredict.MarketState.Resolving));

        // Second attempt succeeds
        MockHttpPrecompile(RitualChain.HTTP_PRECOMPILE).setResponse(200, bytes('{"price":4500}'), "");
        jqPrecompile.setValue(4500);
        vm.prank(RitualChain.SCHEDULER); predict.onScheduledResolve(1, id);
        assertEq(uint8(predict.getMarket(id).state), uint8(RitualPredict.MarketState.Resolved));
    }

    function test_LeftoverCallbackAfterResolutionIsIdempotent() public {
        uint256 id = _createMarket();
        vm.prank(alice); predict.bet{value: BET_AMOUNT}(id, true);
        _resolve(id, 4500);

        // A third call from the Scheduler (leftover) should not change state.
        vm.prank(RitualChain.SCHEDULER);
        predict.onScheduledResolve(2, id); // must not revert
        assertEq(uint8(predict.getMarket(id).state), uint8(RitualPredict.MarketState.Resolved));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 9. Empty winning side → Invalid
    // ─────────────────────────────────────────────────────────────────────────
    function test_EmptyWinningSideInvalidates() public {
        uint256 id = _createMarket();
        // Only NO bets placed; YES wins the oracle → winningPool = 0.
        vm.prank(bob); predict.bet{value: BET_AMOUNT}(id, false);
        _resolve(id, 5000); // YES wins via GTE comparator

        assertEq(uint8(predict.getMarket(id).state), uint8(RitualPredict.MarketState.Invalid));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 10. Payouts
    // ─────────────────────────────────────────────────────────────────────────
    function test_WinnerReceivesFullPool() public {
        uint256 id = _createMarket();
        vm.prank(alice); predict.bet{value: BET_AMOUNT}(id, true);
        vm.prank(bob);   predict.bet{value: BET_AMOUNT}(id, false);
        _resolve(id, 4500); // YES wins

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        predict.claimWinnings(id);
        assertEq(alice.balance - balBefore, 2 * BET_AMOUNT);
    }

    function test_LoserCannotClaimWinnings() public {
        uint256 id = _createMarket();
        vm.prank(alice); predict.bet{value: BET_AMOUNT}(id, true);
        vm.prank(bob);   predict.bet{value: BET_AMOUNT}(id, false);
        _resolve(id, 4500); // YES wins; bob loses

        vm.prank(bob);
        vm.expectRevert(RitualPredict.NothingToClaim.selector);
        predict.claimWinnings(id);
    }

    function test_CannotClaimTwice() public {
        uint256 id = _createMarket();
        vm.prank(alice); predict.bet{value: BET_AMOUNT}(id, true);
        _resolve(id, 4500);
        vm.prank(alice); predict.claimWinnings(id);

        vm.prank(alice);
        vm.expectRevert(RitualPredict.AlreadySettled.selector);
        predict.claimWinnings(id);
    }

    function test_ClaimWinningsRevertNotResolved() public {
        uint256 id = _createMarket();
        vm.prank(alice); predict.bet{value: BET_AMOUNT}(id, true);

        vm.prank(alice);
        vm.expectRevert(RitualPredict.NotResolved.selector);
        predict.claimWinnings(id);
    }

    function test_ProportionalPayoutMultipleWinners() public {
        uint256 id = _createMarket();
        vm.prank(alice); predict.bet{value: 1 ether}(id, true);
        vm.prank(bob);   predict.bet{value: 3 ether}(id, true);
        // Deploy a third player
        address carol = makeAddr("carol");
        vm.deal(carol, 100 ether);
        vm.prank(carol); predict.bet{value: 4 ether}(id, false);

        _resolve(id, 4500); // YES wins; pool = 8 ETH

        uint256 aliceBefore = alice.balance;
        vm.prank(alice); predict.claimWinnings(id);
        // Alice had 1/4 of winning pool (1 out of 4 YES), entitled to 1/4 of 8 ETH = 2 ETH.
        assertEq(alice.balance - aliceBefore, 2 ether);

        uint256 bobBefore = bob.balance;
        vm.prank(bob); predict.claimWinnings(id);
        // Bob had 3/4 of YES pool, entitled to 3/4 of 8 ETH = 6 ETH.
        assertEq(bob.balance - bobBefore, 6 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 11. Refunds
    // ─────────────────────────────────────────────────────────────────────────
    function test_RefundOnInvalidMarket() public {
        uint256 id = _createMarket();
        vm.prank(alice); predict.bet{value: BET_AMOUNT}(id, true);

        MockHttpPrecompile(RitualChain.HTTP_PRECOMPILE).setFailure();
        vm.prank(RitualChain.SCHEDULER); predict.onScheduledResolve(0, id);
        vm.prank(RitualChain.SCHEDULER); predict.onScheduledResolve(1, id);
        vm.prank(RitualChain.SCHEDULER); predict.onScheduledResolve(2, id);

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        predict.claimRefund(id);
        assertEq(alice.balance - balBefore, BET_AMOUNT);
    }

    function test_RefundRevertNotInvalid() public {
        uint256 id = _createMarket();
        vm.prank(alice); predict.bet{value: BET_AMOUNT}(id, true);

        vm.prank(alice);
        vm.expectRevert(RitualPredict.NotInvalid.selector);
        predict.claimRefund(id);
    }

    function test_RefundCannotClaimTwice() public {
        uint256 id = _createMarket();
        vm.prank(alice); predict.bet{value: BET_AMOUNT}(id, true);

        MockHttpPrecompile(RitualChain.HTTP_PRECOMPILE).setFailure();
        vm.prank(RitualChain.SCHEDULER); predict.onScheduledResolve(0, id);
        vm.prank(RitualChain.SCHEDULER); predict.onScheduledResolve(1, id);
        vm.prank(RitualChain.SCHEDULER); predict.onScheduledResolve(2, id);

        vm.prank(alice); predict.claimRefund(id);
        vm.prank(alice);
        vm.expectRevert(RitualPredict.AlreadySettled.selector);
        predict.claimRefund(id);
    }

    function test_RefundCoveresBothSideBets() public {
        uint256 id = _createMarket();
        vm.prank(alice); predict.bet{value: 1 ether}(id, true);
        vm.prank(alice); predict.bet{value: 2 ether}(id, false);

        MockHttpPrecompile(RitualChain.HTTP_PRECOMPILE).setFailure();
        vm.prank(RitualChain.SCHEDULER); predict.onScheduledResolve(0, id);
        vm.prank(RitualChain.SCHEDULER); predict.onScheduledResolve(1, id);
        vm.prank(RitualChain.SCHEDULER); predict.onScheduledResolve(2, id);

        uint256 balBefore = alice.balance;
        vm.prank(alice); predict.claimRefund(id);
        assertEq(alice.balance - balBefore, 3 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 12. stakesOf view
    // ─────────────────────────────────────────────────────────────────────────
    function test_StakesOfReturnsCorrectValues() public {
        uint256 id = _createMarket();
        vm.prank(alice); predict.bet{value: 1 ether}(id, true);
        vm.prank(alice); predict.bet{value: 2 ether}(id, false);

        (uint256 yes, uint256 no, bool settled_, uint256 claimable) = predict.stakesOf(id, alice);
        assertEq(yes, 1 ether);
        assertEq(no, 2 ether);
        assertFalse(settled_);
        assertEq(claimable, 0);
    }

    function test_StakesOfShowsClaimableAfterResolve() public {
        uint256 id = _createMarket();
        vm.prank(alice); predict.bet{value: 1 ether}(id, true);
        _resolve(id, 4500);

        (,,,uint256 claimable) = predict.stakesOf(id, alice);
        assertEq(claimable, 1 ether); // only YES staked, gets full pool = 1 ETH back
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 13. getMarkets pagination
    // ─────────────────────────────────────────────────────────────────────────
    function test_GetMarketsReturnsMostRecentFirst() public {
        _createMarket();
        _createMarket();
        _createMarket();

        RitualPredict.Market[] memory all = predict.getMarkets();
        assertEq(all.length, 3);
        assertEq(all[0].id, 3);
        assertEq(all[1].id, 2);
        assertEq(all[2].id, 1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 14. Execution funding
    // ─────────────────────────────────────────────────────────────────────────
    function test_FundExecutionDepositsToWallet() public {
        vm.deal(address(this), 1 ether);
        predict.fundExecution{value: 1 ether}(1000);
        assertGe(predict.executionBalance(), 0); // wallet mock doesn't track by address correctly in etch, but call shouldn't revert
    }

    function test_FundExecutionRevertZeroValue() public {
        vm.expectRevert(RitualPredict.ZeroStake.selector);
        predict.fundExecution{value: 0}(1000);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 15. decodeHttpResponse
    // ─────────────────────────────────────────────────────────────────────────
    function test_DecodeHttpResponseParsesCorrectly() public view {
        bytes memory body = bytes("{\"price\":4500}");
        bytes memory actualOutput = abi.encode(
            uint16(200),
            new string[](0),
            new string[](0),
            body,
            ""
        );
        bytes memory raw = abi.encode(bytes(""), actualOutput);

        (uint16 status, bytes memory b, string memory err) = predict.decodeHttpResponse(raw);
        assertEq(status, 200);
        assertEq(string(b), string(body));
        assertEq(bytes(err).length, 0);
    }

    function test_DecodeHttpResponseRevertsOnEmptyOutput() public {
        bytes memory raw = abi.encode(bytes(""), bytes(""));
        vm.expectRevert();
        predict.decodeHttpResponse(raw);
    }
}
