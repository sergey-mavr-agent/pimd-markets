// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketFixture} from "./helpers/MarketFixture.sol";
import {PimdMarkets} from "../../src/v1/PimdMarkets.sol";
import {MarketTypes as T} from "../../src/v1/libraries/MarketTypes.sol";

contract MarketsTest is MarketFixture {
    function test_depositWithdrawAndFailureRollback() public {
        uint256 b = markets.balance(alice, T.USDC);
        vm.prank(alice);
        markets.withdraw(T.USDC, 1e6);
        assertEq(markets.balance(alice, T.USDC), b - 1e6);
        usdc.configure(true, false);
        vm.prank(alice);
        vm.expectRevert();
        markets.withdraw(T.USDC, 1e6);
        assertEq(markets.balance(alice, T.USDC), b - 1e6);
        usdc.configure(false, true);
        vm.prank(alice);
        vm.expectRevert(PimdMarkets.InvalidTransfer.selector);
        markets.deposit(T.USDC, 1e6);
        usdc.configure(false, false);
        _assertConservation(0);
    }

    function test_reentrantTokenCannotWithdrawTwice() public {
        usdc.setCallback(address(markets), abi.encodeCall(markets.withdraw, (T.USDC, 1e6)));
        vm.prank(alice);
        markets.withdraw(T.USDC, 1e6);
        assertFalse(usdc.callbackSucceeded());
        assertEq(usdc.callbackError(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        _assertConservation(0);
    }

    function test_splitMergeExactFractionalBacking() public {
        _split(alice, 1_234_567);
        PimdMarkets.Market memory m = markets.market(mid);
        assertEq(m.reserveUSDC, 1_234_567);
        assertEq(m.reserveAsset, 1_234_567e12);
        vm.prank(alice);
        markets.merge(mid, 234_567);
        m = markets.market(mid);
        assertEq(m.pairs, 1e6);
        assertEq(m.reserveUSDC, 1e6);
        assertEq(m.reserveAsset, 1e18);
        _assertConservation(0);
    }

    function test_newLongAndShortMintAndFeeFormula() public {
        uint64 maker = _place(bob, PimdMarkets.Action.BuyDown, 10e6, 600_000);
        uint64 taker = _place(alice, PimdMarkets.Action.BuyUp, 10e6, 600_000);
        (uint256 up,) = markets.positions(mid, alice);
        (, uint256 down) = markets.positions(mid, bob);
        assertEq(up, 10e6);
        assertEq(down, 10e6);
        assertEq(markets.market(mid).pairs, 10e6);
        assertEq(markets.balance(owner, T.USDC), 220_500); // taker 294000, rebate 73500
        assertEq(markets.balance(owner, T.IMD), 42e15); // maker .0042 * 10 IMD
        assertFalse(markets.order(maker).resting);
        assertFalse(markets.order(taker).resting);
        _assertConservation(taker);
    }

    function test_priceAboveOneCreditsShortExcess() public {
        uint256 before = markets.balance(bob, T.USDC);
        _place(bob, PimdMarkets.Action.BuyDown, 10e6, 1_500_000);
        _place(alice, PimdMarkets.Action.BuyUp, 10e6, 1_500_000);
        assertGt(markets.balance(bob, T.USDC), before + 5e6);
        _assertConservation(2);
    }

    function test_largeTickAlignedPricesAreNotArtificiallyCapped() public {
        usdc.mint(alice, 2e12);
        vm.startPrank(alice);
        usdc.approve(address(markets), 2e12);
        markets.deposit(T.USDC, 2e12);
        vm.stopPrank();
        _place(bob, PimdMarkets.Action.BuyDown, 1, 1e18 + 100);
        _place(alice, PimdMarkets.Action.BuyUp, 1, 1e18 + 100);
        assertEq(markets.market(mid).reserveUSDC, 1);
        assertEq(markets.market(mid).reserveAsset, 1e12);
        _assertConservation(2);
    }

    function test_holdersSellUpWithoutMinting() public {
        _split(bob, 10e6);
        _place(bob, PimdMarkets.Action.SellUp, 10e6, 700_000);
        _place(alice, PimdMarkets.Action.BuyUp, 10e6, 700_000);
        (uint256 up,) = markets.positions(mid, alice);
        assertEq(up, 10e6);
        (up,) = markets.positions(mid, bob);
        assertEq(up, 0);
        assertEq(markets.market(mid).pairs, 10e6);
        _assertConservation(2);
    }

    function test_holdersSellDownWithoutMinting() public {
        _split(bob, 10e6);
        _place(bob, PimdMarkets.Action.SellDown, 10e6, 700_000);
        _place(alice, PimdMarkets.Action.BuyDown, 10e6, 700_000);
        (, uint256 down) = markets.positions(mid, alice);
        assertEq(down, 10e6);
        assertEq(markets.market(mid).pairs, 10e6);
        _assertConservation(2);
    }

    function test_holdersOnBothSidesMerge() public {
        _split(bob, 10e6);
        _split(alice, 10e6);
        _place(bob, PimdMarkets.Action.SellDown, 10e6, 700_000);
        _place(alice, PimdMarkets.Action.SellUp, 10e6, 700_000);
        assertEq(markets.market(mid).pairs, 10e6);
        _assertConservation(2);
    }

    function test_sellDownAboveOnePaysUSDC() public {
        _split(bob, 10e6);
        uint256 before = markets.balance(bob, T.USDC);
        _place(bob, PimdMarkets.Action.SellDown, 10e6, 1_500_000);
        _place(alice, PimdMarkets.Action.BuyDown, 10e6, 1_500_000);
        assertEq(markets.balance(bob, T.USDC), before - 5e6);
        _assertConservation(2);
    }

    function test_priceThenFIFOAndPartialFills() public {
        uint64 first = _place(bob, PimdMarkets.Action.BuyDown, 10e6, 700_000);
        uint64 second = _place(carol, PimdMarkets.Action.BuyDown, 10e6, 700_000);
        uint64 cheaper = _place(carol, PimdMarkets.Action.BuyDown, 10e6, 600_000);
        assertEq(markets.bestAsk(mid), cheaper);
        _place(alice, PimdMarkets.Action.BuyUp, 25e6, 800_000);
        assertEq(markets.order(first).remaining, 0);
        assertEq(markets.order(cheaper).remaining, 0);
        assertEq(markets.order(second).remaining, 5e6);
        assertEq(markets.bestAsk(mid), second);
        _assertConservation(4);
    }

    function test_bidPricePriority() public {
        uint64 low = _place(alice, PimdMarkets.Action.BuyUp, 10e6, 400_000);
        uint64 high = _place(carol, PimdMarkets.Action.BuyUp, 10e6, 600_000);
        assertEq(markets.bestBid(mid), high);
        _place(bob, PimdMarkets.Action.BuyDown, 15e6, 300_000);
        assertEq(markets.order(high).remaining, 0);
        assertEq(markets.order(low).remaining, 5e6);
        _assertConservation(3);
    }

    function test_marketOrderWorstPriceAndRemainderCancelled() public {
        _place(bob, PimdMarkets.Action.BuyDown, 10e6, 600_000);
        _place(carol, PimdMarkets.Action.BuyDown, 10e6, 800_000);
        PimdMarkets.OrderInput memory i = _input(PimdMarkets.Action.BuyUp, 20e6, 700_000);
        i.immediateOrCancel = true;
        vm.prank(alice);
        uint64 id = markets.place(spec, i);
        (uint256 up,) = markets.positions(mid, alice);
        assertEq(up, 10e6);
        assertEq(markets.order(id).remaining, 0);
        assertEq(markets.bestBid(mid), 0);
        assertEq(markets.order(2).remaining, 10e6);
        _assertConservation(id);
    }

    function test_fillCapRestsRemainderAndPermissionlessMatchingContinues() public {
        _place(bob, PimdMarkets.Action.BuyDown, 10e6, 600_000);
        _place(carol, PimdMarkets.Action.BuyDown, 10e6, 600_000);
        PimdMarkets.OrderInput memory i = _input(PimdMarkets.Action.BuyUp, 20e6, 600_000);
        i.maxSteps = 1;
        vm.prank(alice);
        uint64 id = markets.place(spec, i);
        assertEq(markets.bestBid(mid), id);
        assertEq(markets.order(2).remaining, 10e6);
        assertEq(markets.order(id).remaining, 10e6);
        _assertConservation(id);
        assertEq(markets.matchMarket(mid, 1), 1);
        assertEq(markets.bestBid(mid), 0);
        assertEq(markets.bestAsk(mid), 0);
        _assertConservation(id);
    }

    function test_queuedSamePriceOrderRetainsFIFOPriorityOverNewOrder() public {
        _place(bob, PimdMarkets.Action.BuyDown, 10e6, 600_000);
        _place(carol, PimdMarkets.Action.BuyDown, 10e6, 600_000);
        PimdMarkets.OrderInput memory i = _input(PimdMarkets.Action.BuyUp, 20e6, 600_000);
        i.maxSteps = 1;
        vm.prank(alice);
        uint64 first = markets.place(spec, i);
        uint64 second = _place(bob, PimdMarkets.Action.BuyUp, 10e6, 600_000);
        assertEq(markets.order(first).remaining, 0);
        assertEq(markets.order(second).remaining, 10e6);
        (uint256 up,) = markets.positions(mid, alice);
        assertEq(up, 20e6);
        _assertConservation(second);
    }

    function test_queuedShortSwapFailureCancelsOnlyItsRemainingPart() public {
        _place(alice, PimdMarkets.Action.BuyUp, 10e6, 600_000);
        _place(carol, PimdMarkets.Action.BuyUp, 10e6, 600_000);
        PimdMarkets.OrderInput memory i = _input(PimdMarkets.Action.BuyDown, 20e6, 600_000);
        i.maxSteps = 1;
        i.assetOnly = true;
        i.maxSwapInput = 8.4e18;
        vm.prank(bob);
        uint64 id = markets.place(spec, i);
        swapper.configure(true, false);
        assertEq(markets.matchMarket(mid, 64), 0);
        assertEq(markets.order(id).remaining, 0);
        (, uint256 down) = markets.positions(mid, bob);
        assertEq(down, 10e6);
        assertEq(markets.market(mid).pairs, 10e6);
        _assertConservation(id);
    }

    function test_queuedFeeBudgetExhaustionReleasesUnfilledPart() public {
        _place(bob, PimdMarkets.Action.BuyDown, 10e6, 600_000);
        _place(carol, PimdMarkets.Action.BuyDown, 10e6, 600_000);
        PimdMarkets.OrderInput memory i = _input(PimdMarkets.Action.BuyUp, 20e6, 600_000);
        i.maxSteps = 1;
        i.feeBudget = 300_000;
        vm.prank(alice);
        uint64 id = markets.place(spec, i);
        assertEq(markets.matchMarket(mid, 64), 0);
        assertEq(markets.order(id).remaining, 0);
        (uint256 up,) = markets.positions(mid, alice);
        assertEq(up, 10e6);
        _assertConservation(id);
    }

    function test_validAndInvalidInsertionHints() public {
        uint64 first = _place(bob, PimdMarkets.Action.BuyDown, 10e6, 600_000);
        uint64 last = _place(carol, PimdMarkets.Action.BuyDown, 10e6, 800_000);
        PimdMarkets.OrderInput memory i = _input(PimdMarkets.Action.BuyDown, 10e6, 700_000);
        i.insertionHint = last;
        vm.prank(alice);
        vm.expectRevert(PimdMarkets.InvalidOrder.selector);
        markets.place(spec, i);
        i.insertionHint = first;
        vm.prank(alice);
        uint64 middle = markets.place(spec, i);
        assertEq(markets.order(first).next, middle);
        assertEq(markets.order(middle).next, last);
        assertEq(markets.order(last).previous, middle);
        _assertConservation(middle);
    }

    function test_cancelUnauthorizedDoubleCancelAndExpiry() public {
        uint64 id = _place(bob, PimdMarkets.Action.BuyDown, 10e6, 600_000);
        vm.prank(alice);
        vm.expectRevert(PimdMarkets.Unauthorized.selector);
        markets.cancel(id);
        vm.prank(bob);
        markets.cancel(id);
        vm.prank(bob);
        vm.expectRevert(PimdMarkets.Unauthorized.selector);
        markets.cancel(id);
        uint64 id2 = _place(bob, PimdMarkets.Action.BuyDown, 10e6, 600_000);
        vm.warp(start + 3600);
        uint64[] memory ids = new uint64[](2);
        ids[0] = id2;
        ids[1] = id2;
        markets.expire(ids);
        assertEq(markets.bestAsk(mid), 0);
        _assertConservation(id2);
    }

    function test_expiredMakerSkipped() public {
        PimdMarkets.OrderInput memory i = _input(PimdMarkets.Action.BuyDown, 10e6, 600_000);
        i.expiry = uint64(block.timestamp + 300);
        vm.prank(bob);
        markets.place(spec, i);
        vm.warp(i.expiry);
        _place(carol, PimdMarkets.Action.BuyDown, 10e6, 600_000);
        _place(alice, PimdMarkets.Action.BuyUp, 10e6, 600_000);
        assertEq(markets.order(1).remaining, 0);
        (, uint256 down) = markets.positions(mid, bob);
        assertEq(down, 0);
        _assertConservation(3);
    }

    function test_invalidTickMinimumExpiryAndLateOrders() public {
        PimdMarkets.OrderInput memory i = _input(PimdMarkets.Action.BuyUp, 10e6, 600_001);
        vm.expectRevert(PimdMarkets.InvalidOrder.selector);
        markets.place(spec, i);
        i.limitPrice = 600_000;
        i.quantity = 1e6;
        vm.expectRevert(PimdMarkets.InvalidOrder.selector);
        markets.place(spec, i);
        i.quantity = 10e6;
        i.expiry = uint64(block.timestamp + 299);
        vm.expectRevert(PimdMarkets.InvalidOrder.selector);
        markets.place(spec, i);
        _split(alice, 1e6);
        i.expiry = start + 3600;
        vm.warp(start + 3600);
        vm.prank(alice);
        vm.expectRevert(PimdMarkets.InvalidOrder.selector);
        markets.place(spec, i);
    }

    function test_shortAssetOnlySwapAndLimitBudget() public {
        PimdMarkets.OrderInput memory i = _input(PimdMarkets.Action.BuyDown, 10e6, 600_000);
        i.assetOnly = true;
        i.maxSwapInput = 4.2e18;
        vm.prank(bob);
        markets.place(spec, i);
        _place(alice, PimdMarkets.Action.BuyUp, 10e6, 600_000);
        assertEq(imd.balanceOf(address(swapper)), 4e18);
        _assertConservation(2);
    }

    function test_failedRestingSwapCancelsAndContinues() public {
        PimdMarkets.OrderInput memory i = _input(PimdMarkets.Action.BuyDown, 10e6, 600_000);
        i.assetOnly = true;
        i.maxSwapInput = 4.2e18;
        vm.prank(bob);
        markets.place(spec, i);
        _place(carol, PimdMarkets.Action.BuyDown, 10e6, 600_000);
        swapper.configure(true, false);
        _place(alice, PimdMarkets.Action.BuyUp, 10e6, 600_000);
        assertEq(markets.order(1).remaining, 0);
        (, uint256 d) = markets.positions(mid, bob);
        assertEq(d, 0);
        (, d) = markets.positions(mid, carol);
        assertEq(d, 10e6);
        assertEq(imd.allowance(address(markets), address(swapper)), 0);
        _assertConservation(3);
    }

    function test_failedTakerSwapRollsBackWholeTransaction() public {
        _place(alice, PimdMarkets.Action.BuyUp, 10e6, 600_000);
        PimdMarkets.OrderInput memory i = _input(PimdMarkets.Action.BuyDown, 10e6, 600_000);
        i.assetOnly = true;
        i.maxSwapInput = 4.2e18;
        swapper.configure(true, false);
        vm.prank(bob);
        vm.expectRevert(PimdMarkets.InvalidOrder.selector);
        markets.place(spec, i);
        assertEq(markets.order(1).remaining, 10e6);
        assertEq(markets.nextOrderId(), 2);
        _assertConservation(1);
    }

    function test_shortOutputAndUnderBufferedInputRejected() public {
        PimdMarkets.OrderInput memory i = _input(PimdMarkets.Action.BuyDown, 10e6, 600_000);
        i.assetOnly = true;
        i.maxSwapInput = 4e18;
        vm.prank(bob);
        vm.expectRevert(PimdMarkets.InvalidOrder.selector);
        markets.place(spec, i);
        i.maxSwapInput = 4.2e18;
        vm.prank(bob);
        markets.place(spec, i);
        swapper.configure(false, true);
        vm.prank(alice);
        vm.expectRevert(PimdMarkets.InvalidTransfer.selector);
        markets.place(spec, _input(PimdMarkets.Action.BuyUp, 10e6, 600_000));
        _assertConservation(1);
    }

    function test_feeBudgetMustCoverOwnExecutionAtPlacement() public {
        // At P = 1 the maker fee for 10 DOWN shares at 0.60 is 0.042 IMD and the taker fee for 10 UP
        // shares is 0.294 USDC (see test_newLongAndShortMintAndFeeFormula).
        PimdMarkets.OrderInput memory i = _input(PimdMarkets.Action.BuyDown, 10e6, 600_000);
        i.feeBudget = 0;
        vm.prank(bob);
        vm.expectRevert(PimdMarkets.InvalidOrder.selector);
        markets.place(spec, i);
        i.feeBudget = 42e15 - 1;
        vm.prank(bob);
        vm.expectRevert(PimdMarkets.InvalidOrder.selector);
        markets.place(spec, i);
        i.feeBudget = 42e15;
        vm.prank(bob);
        uint64 maker = markets.place(spec, i);
        assertTrue(markets.order(maker).resting);
        i = _input(PimdMarkets.Action.BuyUp, 10e6, 600_000);
        i.immediateOrCancel = true;
        i.feeBudget = 294_000 - 1;
        vm.prank(alice);
        vm.expectRevert(PimdMarkets.InvalidOrder.selector);
        markets.place(spec, i);
        i.feeBudget = 294_000;
        vm.prank(alice);
        markets.place(spec, i);
        assertEq(markets.order(maker).remaining, 0);
        assertEq(markets.balance(owner, T.IMD), 42e15);
        _assertConservation(2);
    }

    function test_insufficientMakerFeeCancelledAndTakerFeeReverts() public {
        PimdMarkets.OrderInput memory i = _input(PimdMarkets.Action.BuyDown, 10e6, 600_000);
        i.feeBudget = 42e15;
        vm.prank(bob);
        markets.place(spec, i);
        // The asset price falls to 0.5 USD, so the IMD-denominated maker fee rises to 0.072 IMD and
        // bob's resting budget no longer covers it.
        prices.record(1, start + 300, 0.5e18);
        _place(carol, PimdMarkets.Action.BuyDown, 10e6, 600_000);
        i = _input(PimdMarkets.Action.BuyUp, 10e6, 600_000);
        i.feeBudget = 36_000; // the maker floor at P = 0.5, far below the 252_000 taker fee
        vm.prank(alice);
        vm.expectRevert(PimdMarkets.InsufficientBalance.selector);
        markets.place(spec, i);
        assertTrue(markets.order(1).resting);
        _place(alice, PimdMarkets.Action.BuyUp, 10e6, 600_000);
        assertEq(markets.order(1).remaining, 0);
        assertFalse(markets.order(1).resting);
        (, uint256 down) = markets.positions(mid, carol);
        assertEq(down, 10e6);
        _assertConservation(3);
    }

    function test_normalMarketWhoseStrikeCannotBeRecordedIsFrozen() public {
        spec.period = 3;
        (spec.start,) = registry.bounds(3, start);
        mid = markets.marketId(spec);
        uint64 monthStart = spec.start;
        // One second before the oracle's proposal window closes the market can still be created.
        vm.warp(uint256(monthStart) + 3 days - 1 hours - 1);
        PimdMarkets.OrderInput memory i = _input(PimdMarkets.Action.BuyUp, 100e6, 10_000);
        i.expiry = uint64(block.timestamp + 10 days);
        vm.prank(alice);
        uint64 early = markets.place(spec, i);
        assertTrue(markets.order(early).resting);
        _split(alice, 5e6);
        // From the moment no proof and no proposal can record the start price, the void is certain:
        // no new order, pair or execution, while cancel and merge still release collateral.
        vm.warp(uint256(monthStart) + 3 days - 1 hours);
        vm.prank(bob);
        vm.expectRevert(PimdMarkets.InvalidMarket.selector);
        markets.place(spec, _input(PimdMarkets.Action.BuyDown, 100e6, 10_000));
        vm.prank(bob);
        vm.expectRevert(PimdMarkets.InvalidMarket.selector);
        markets.split(spec, 1e6);
        vm.expectRevert(PimdMarkets.InvalidMarket.selector);
        markets.matchMarket(mid, 64);
        vm.prank(alice);
        markets.cancel(early);
        vm.prank(alice);
        markets.merge(mid, 5e6);
        // A live proposal keeps the market open; its refund closes it again.
        prices.setLiveProposal(1, monthStart, true);
        i.expiry = uint64(block.timestamp + 10 days);
        vm.prank(alice);
        uint64 late = markets.place(spec, i);
        prices.setLiveProposal(1, monthStart, false);
        vm.prank(bob);
        vm.expectRevert(PimdMarkets.InvalidMarket.selector);
        markets.place(spec, _input(PimdMarkets.Action.BuyDown, 100e6, 10_000));
        // A recorded start price reopens trading for the rest of the month.
        prices.record(1, monthStart, 1e18);
        vm.prank(bob);
        markets.place(spec, _input(PimdMarkets.Action.BuyDown, 100e6, 10_000));
        assertEq(markets.order(late).remaining, 0);
        _assertConservation(3);
        // A ladder at the same start never needs the start price.
        spec.strike = 2e18;
        _split(bob, 1e6);
        _assertConservation(3);
    }

    function test_attachedProofsSkipBoundariesAlreadyRecorded() public {
        PimdMarkets.ProofSubmission[] memory proofs = new PimdMarkets.ProofSubmission[](2);
        proofs[0].version = 1;
        proofs[0].boundary = start; // recorded in the fixture: skipped instead of reverting
        proofs[1].version = 1;
        proofs[1].boundary = start + 3600; // not recorded: proven and recorded now
        vm.prank(alice);
        markets.placeWithProofs(spec, _input(PimdMarkets.Action.BuyUp, 10e6, 600_000), proofs);
        assertEq(prices.proofCalls(), 1);
        assertEq(prices.price(1, start + 3600), 1e18);
        _split(bob, 10e6);
        vm.warp(start + 3600);
        PimdMarkets.ProofSubmission[] memory again = new PimdMarkets.ProofSubmission[](1);
        again[0] = proofs[1];
        vm.prank(bob);
        markets.claimWithProofs(mid, 10e6, 10e6, again);
        assertEq(prices.proofCalls(), 1);
        assertEq(uint8(markets.market(mid).outcome), uint8(PimdMarkets.Outcome.Refund));
        PimdMarkets.ProofSubmission[] memory tooMany = new PimdMarkets.ProofSubmission[](3);
        vm.prank(bob);
        vm.expectRevert(PimdMarkets.InvalidMarket.selector);
        markets.claimWithProofs(mid, 0, 0, tooMany);
        _assertConservation(1);
    }

    function test_upWinDownWinTieAndVoid() public {
        _split(alice, 10e6);
        prices.record(1, start + 3600, 2e18);
        vm.warp(start + 3600);
        markets.settle(mid);
        assertEq(uint8(markets.market(mid).outcome), uint8(PimdMarkets.Outcome.Up));
        vm.prank(alice);
        markets.claim(mid, 10e6, 10e6);
        assertEq(markets.market(mid).reserveUSDC, 0);
        _assertConservation(0);
    }

    function test_downWinAndDuplicateClaimRejected() public {
        _split(alice, 10e6);
        prices.record(1, start + 3600, 0.5e18);
        vm.warp(start + 3600);
        vm.prank(alice);
        markets.claim(mid, 10e6, 10e6);
        assertEq(uint8(markets.market(mid).outcome), uint8(PimdMarkets.Outcome.Down));
        vm.prank(alice);
        vm.expectRevert(PimdMarkets.InsufficientBalance.selector);
        markets.claim(mid, 10e6, 10e6);
        _assertConservation(0);
    }

    function test_equalPriceRefundsEachSideInItsCoin() public {
        _split(alice, 10e6);
        prices.record(1, start + 3600, 1e18);
        vm.warp(start + 3600);
        uint256 before = markets.balance(alice, T.USDC);
        uint256 a = markets.balance(alice, T.IMD);
        vm.prank(alice);
        markets.claim(mid, 10e6, 0);
        assertEq(markets.balance(alice, T.USDC), before + 10e6);
        assertEq(markets.balance(alice, T.IMD), a);
        vm.prank(alice);
        markets.claim(mid, 0, 10e6);
        assertEq(markets.balance(alice, T.IMD), a + 10e18);
        _assertConservation(0);
    }

    function test_claimAllIncludesStandardAndLadderMarkets() public {
        _split(alice, 10e6);
        bytes32 standard = mid;
        spec.strike = 1.5e18;
        mid = markets.marketId(spec);
        _split(alice, 10e6);
        prices.record(1, start + 3600, 2e18);
        vm.warp(start + 3600);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = standard;
        ids[1] = mid;
        vm.prank(alice);
        markets.claimAll(ids);
        assertEq(markets.market(standard).reserveUSDC, 0);
        assertEq(markets.market(mid).reserveAsset, 0);
        vm.prank(alice);
        markets.claimAll(ids);
        _assertConservation(0);
    }

    function test_voidAfterThreeDaysAndNoEarlySettlement() public {
        _split(alice, 10e6);
        vm.expectRevert(PimdMarkets.InvalidMarket.selector);
        markets.settle(mid);
        vm.warp(start + 3600);
        vm.expectRevert(PimdMarkets.MissingPrice.selector);
        markets.settle(mid);
        vm.warp(start + 3600 + 3 days);
        markets.settle(mid);
        assertEq(uint8(markets.market(mid).outcome), uint8(PimdMarkets.Outcome.Refund));
        vm.prank(alice);
        markets.claim(mid, 10e6, 10e6);
        _assertConservation(0);
    }

    function test_cancelReleasesSharesAfterSettlement() public {
        _split(alice, 10e6);
        uint64 id = _place(alice, PimdMarkets.Action.SellUp, 10e6, 600_000);
        prices.record(1, start + 3600, 2e18);
        vm.warp(start + 3600);
        markets.settle(mid);
        vm.prank(alice);
        markets.cancel(id);
        vm.prank(alice);
        markets.claim(mid, 10e6, 10e6);
        _assertConservation(id);
    }

    function test_ladderThreeSignificantDigitsAndCalendarMarket() public {
        spec.strike = 1.25e18;
        mid = markets.marketId(spec);
        _split(alice, 10e6);
        prices.record(1, start + 3600, 1.3e18);
        vm.warp(start + 3600);
        markets.settle(mid);
        assertEq(markets.market(mid).strike, 1.25e18);
        assertEq(uint8(markets.market(mid).outcome), uint8(PimdMarkets.Outcome.Up));
        vm.warp(start + 60);
        spec.strike = 1.234e18;
        vm.prank(alice);
        vm.expectRevert(PimdMarkets.InvalidMarket.selector);
        markets.split(spec, 1e6);
        spec.strike = 0;
        spec.period = 3;
        (spec.start,) = registry.bounds(3, start);
        mid = markets.marketId(spec);
        prices.record(1, spec.start, 1e18); // the month started two weeks ago; its strike must exist
        _split(alice, 1e6);
        assertGe(markets.market(mid).end - markets.market(mid).start, 28 days);
        _assertConservation(0);
    }

    function test_futureMarketAndConfigSnapshot() public {
        spec.start += 3600;
        mid = markets.marketId(spec);
        _split(alice, 10e6);
        T.Asset memory a = registry.asset(1);
        a.unitsPerShare = 2e18;
        a.maxOpenPairs = 12e6;
        vm.prank(owner);
        registry.configureAsset(a);
        _split(alice, 10e6);
        assertEq(markets.market(mid).version, 1);
        assertEq(markets.market(mid).factor, 1e12);
        spec.start += 3600;
        mid = markets.marketId(spec);
        _split(alice, 10e6);
        assertEq(markets.market(mid).version, 2);
        vm.prank(alice);
        vm.expectRevert(PimdMarkets.InvalidMarket.selector);
        markets.split(spec, 3e6);
        _assertConservation(0);
    }

    function test_openPairCapPartialFillPreservesBacking() public {
        T.Asset memory a = registry.asset(1);
        a.maxOpenPairs = 15e6;
        vm.prank(owner);
        registry.configureAsset(a);
        prices.record(2, start, 1e18);
        _place(bob, PimdMarkets.Action.BuyDown, 20e6, 600_000);
        _place(alice, PimdMarkets.Action.BuyUp, 20e6, 600_000);
        assertEq(markets.market(mid).pairs, 15e6);
        assertEq(markets.order(1).remaining, 5e6);
        assertEq(markets.bestBid(mid), 2);
        assertEq(markets.order(2).remaining, 5e6);
        assertEq(markets.matchMarket(mid, 64), 0);
        _assertConservation(2);
    }

    function test_feesUseLatestRecordedBoundary() public {
        _split(alice, 1e6);
        uint256 before = markets.feeQuote(mid, 600_000, 10e6, true, false);
        prices.record(1, start + 300, 2e18);
        uint256 after_ = markets.feeQuote(mid, 600_000, 10e6, true, false);
        assertGt(after_, before);
    }

    function testFuzz_fractionalMatchingConserves(uint128 rawQuantity, uint32 rawPrice, bool high) public {
        uint128 quantity = uint128(bound(rawQuantity, 10e6, 1000e6));
        uint128 x = uint128(bound(rawPrice, 1000, 30000) * 100);
        if (high) x += 1e6;
        _place(bob, PimdMarkets.Action.BuyDown, quantity, x);
        _place(alice, PimdMarkets.Action.BuyUp, quantity, x);
        assertEq(markets.market(mid).reserveUSDC, quantity);
        assertEq(markets.market(mid).reserveAsset, uint256(quantity) * 1e12);
        _assertConservation(2);
    }

    function testFuzz_multipleFractionalFillsDoNotExhaustCash(uint32 raw) public {
        uint128 part = uint128(bound(raw, 4e6, 10e6));
        uint128 total = part * 3;
        _place(alice, PimdMarkets.Action.BuyUp, total, 333_300);
        _place(bob, PimdMarkets.Action.BuyDown, part, 333_300);
        _place(bob, PimdMarkets.Action.BuyDown, part, 333_300);
        _place(carol, PimdMarkets.Action.BuyDown, part, 333_300);
        assertEq(markets.order(1).remaining, 0);
        _assertConservation(4);
    }
}
