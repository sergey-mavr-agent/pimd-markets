// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketFixture} from "./helpers/MarketFixture.sol";
import {PimdMarkets} from "src/v1/PimdMarkets.sol";
import {MarketTypes as T} from "src/v1/libraries/MarketTypes.sol";

/// @notice Independent edge cases supplementing the accepted implementation's examples.
/// forge-config: default.fuzz.runs = 512
contract MarketAdversarialTest is MarketFixture {
    function _snapshot() internal view returns (bytes32) {
        (uint256 up, uint256 down) = markets.positions(mid, alice);
        return keccak256(
            abi.encode(
                markets.marketCount(),
                markets.nextOrderId(),
                markets.market(mid),
                markets.bestBid(mid),
                markets.bestAsk(mid),
                up,
                down,
                markets.balance(alice, T.USDC),
                markets.balance(alice, T.IMD),
                markets.balance(owner, T.USDC),
                markets.balance(owner, T.IMD),
                usdc.balanceOf(address(markets)),
                imd.balanceOf(address(markets))
            )
        );
    }

    function test_zeroUnsupportedAndExcessTransfersLeaveAccountingUntouched() public {
        bytes32 beforeState = _snapshot();
        vm.startPrank(alice);
        vm.expectRevert(PimdMarkets.InvalidTransfer.selector);
        markets.deposit(T.USDC, 0);
        vm.expectRevert(PimdMarkets.InvalidTransfer.selector);
        markets.withdraw(T.USDC, 0);
        vm.expectRevert(PimdMarkets.InvalidTransfer.selector);
        markets.deposit(address(swapper), 1);
        vm.expectRevert(PimdMarkets.InsufficientBalance.selector);
        markets.withdraw(T.USDC, 100_000e6 + 1);
        vm.expectRevert(PimdMarkets.InsufficientBalance.selector);
        markets.withdraw(T.IMD, type(uint256).max);
        vm.stopPrank();
        assertEq(_snapshot(), beforeState);
    }

    function test_ownerCannotWithdrawDepositorsFunds() public {
        vm.prank(owner);
        vm.expectRevert(PimdMarkets.InsufficientBalance.selector);
        markets.withdraw(T.IMD, 1);
        vm.prank(owner);
        vm.expectRevert(PimdMarkets.InsufficientBalance.selector);
        markets.withdraw(T.USDC, 1);
        _assertConservation(0);
    }

    function test_invalidOrdersRollBackLazyCreationAndEscrow() public {
        bytes32 beforeState = _snapshot();
        for (uint8 fault; fault < 11; ++fault) {
            PimdMarkets.OrderInput memory i = _input(PimdMarkets.Action.BuyUp, 10e6, 600_000);
            if (fault == 0) i.quantity = 0;
            if (fault == 1) i.limitPrice = 0;
            if (fault == 2) i.limitPrice = 600_001;
            if (fault == 3) i.maxSteps = 0;
            if (fault == 4) i.maxSteps = 65;
            if (fault == 5) i.quantity = 1;
            if (fault == 6) i.assetOnly = true;
            if (fault == 7) i.expiry = uint64(block.timestamp + 299);
            if (fault == 8) i.expiry = start + 3601;
            if (fault == 9) i.insertionHint = 1;
            if (fault == 10) i.insertionHint = type(uint64).max;
            vm.prank(alice);
            vm.expectRevert(PimdMarkets.InvalidOrder.selector);
            markets.place(spec, i);
            assertEq(_snapshot(), beforeState, "invalid order changed persistent state");
        }
    }

    function test_failedShareEscrowDoesNotCreateMarketOrConsumeOrderId() public {
        bytes32 beforeState = _snapshot();
        for (uint8 side = 2; side < 4; ++side) {
            PimdMarkets.OrderInput memory i = _input(PimdMarkets.Action(side), 10e6, 600_000);
            vm.prank(alice);
            vm.expectRevert(PimdMarkets.InsufficientBalance.selector);
            markets.place(spec, i);
            assertEq(_snapshot(), beforeState);
        }
    }

    function test_unalignedStartAndFourSignificantDigitsRollBackMarketCreation() public {
        bytes32 beforeState = _snapshot();
        PimdMarkets.MarketSpec memory bad = spec;
        bad.start += 1;
        vm.prank(alice);
        vm.expectRevert(PimdMarkets.InvalidMarket.selector);
        markets.split(bad, 1);
        bad = spec;
        bad.strike = 1.001e18;
        vm.prank(alice);
        vm.expectRevert(PimdMarkets.InvalidMarket.selector);
        markets.split(bad, 1);
        assertEq(_snapshot(), beforeState);
    }

    function test_zeroSplitAndMergeAndExcessMergeAreAtomic() public {
        vm.prank(alice);
        vm.expectRevert(PimdMarkets.InvalidMarket.selector);
        markets.split(spec, 0);
        assertEq(markets.marketCount(), 0);
        _split(alice, 1);
        bytes32 beforeState = _snapshot();
        vm.startPrank(alice);
        vm.expectRevert(PimdMarkets.InvalidMarket.selector);
        markets.merge(mid, 0);
        vm.expectRevert(PimdMarkets.InsufficientBalance.selector);
        markets.merge(mid, 2);
        vm.stopPrank();
        assertEq(_snapshot(), beforeState);
        vm.prank(alice);
        markets.merge(mid, 1);
        assertEq(markets.market(mid).reserveAsset, 0);
        assertEq(markets.market(mid).pairs, 0);
        _assertConservation(0);
    }

    function test_expiryIsInclusiveAtExactDeadlineAndRefundsWithoutFees() public {
        uint256 cash = markets.balance(alice, T.USDC);
        PimdMarkets.OrderInput memory i = _input(PimdMarkets.Action.BuyUp, 10e6, 600_000);
        i.expiry = uint64(block.timestamp + 300);
        vm.prank(alice);
        uint64 oid = markets.place(spec, i);
        uint64[] memory ids = new uint64[](3);
        ids[0] = oid;
        ids[1] = oid;
        ids[2] = type(uint64).max;
        vm.warp(i.expiry - 1);
        markets.expire(ids);
        assertTrue(markets.order(oid).resting);
        vm.warp(i.expiry);
        vm.prank(carol);
        markets.expire(ids);
        assertFalse(markets.order(oid).resting);
        assertEq(markets.balance(alice, T.USDC), cash);
        assertEq(markets.balance(owner, T.USDC), 0);
        _assertConservation(oid);
    }

    function test_exactMinimumNotionalAndMarketEndBoundaries() public {
        PimdMarkets.OrderInput memory i = _input(PimdMarkets.Action.BuyUp, 2e6, 500_000);
        vm.prank(alice);
        uint64 oid = markets.place(spec, i);
        i.quantity -= 1;
        vm.prank(alice);
        vm.expectRevert(PimdMarkets.InvalidOrder.selector);
        markets.place(spec, i);
        vm.warp(start + 3600);
        i.quantity = 2e6;
        i.immediateOrCancel = true;
        vm.prank(alice);
        vm.expectRevert(PimdMarkets.InvalidOrder.selector);
        markets.place(spec, i);
        vm.expectRevert(PimdMarkets.InvalidOrder.selector);
        markets.matchMarket(mid, 1);
        vm.prank(alice);
        markets.cancel(oid);
        _assertConservation(oid);
    }

    function test_batchedLimitsAndUnknownMarketDoNotChangeBalances() public {
        vm.expectRevert(PimdMarkets.InvalidOrder.selector);
        markets.expire(new uint64[](65));
        vm.expectRevert(PimdMarkets.InvalidMarket.selector);
        markets.claimAll(new bytes32[](65));
        vm.expectRevert(PimdMarkets.InvalidOrder.selector);
        markets.matchMarket(mid, 1);
        vm.expectRevert(PimdMarkets.InvalidMarket.selector);
        markets.settle(mid);
        vm.prank(alice);
        vm.expectRevert(PimdMarkets.InvalidMarket.selector);
        markets.claim(mid, 1, 0);
        assertEq(markets.marketCount(), 0);
        _assertConservation(0);
    }

    function test_claimBatchRollsBackEarlierClaimWhenLaterMarketIsNotReady() public {
        _split(alice, 10e6);
        bytes32 early = mid;
        PimdMarkets.MarketSpec memory future = spec;
        future.start += 3600;
        vm.prank(alice);
        bytes32 late = markets.split(future, 10e6);
        prices.record(1, start + 3600, 2e18);
        vm.warp(start + 3600);
        bytes32 beforeState = _snapshot();
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = early;
        ids[1] = late;
        vm.prank(alice);
        vm.expectRevert(PimdMarkets.InvalidMarket.selector);
        markets.claimAll(ids);
        assertEq(_snapshot(), beforeState, "earlier claim must roll back with the batch");
        (uint256 up, uint256 down) = markets.positions(early, alice);
        assertEq(up, 10e6);
        assertEq(down, 10e6);
        _assertConservation(0);
    }

    function test_settledMarketCannotReopenAndExcessClaimsCannotBurnShares() public {
        _split(alice, 10e6);
        prices.record(1, start + 3600, 2e18);
        vm.warp(start + 3600);
        markets.settle(mid);
        bytes32 beforeState = _snapshot();
        vm.startPrank(alice);
        vm.expectRevert(PimdMarkets.InsufficientBalance.selector);
        markets.claim(mid, 10e6 + 1, 0);
        vm.expectRevert(PimdMarkets.InsufficientBalance.selector);
        markets.claim(mid, 0, 0);
        vm.expectRevert(PimdMarkets.InvalidMarket.selector);
        markets.split(spec, 1);
        vm.expectRevert(PimdMarkets.InvalidMarket.selector);
        markets.merge(mid, 1);
        vm.stopPrank();
        vm.expectRevert(PimdMarkets.InvalidMarket.selector);
        markets.settle(mid);
        assertEq(_snapshot(), beforeState);
    }

    function testFuzz_partialClaimsPayExactlyOnce(uint128 rawQ, uint128 rawPart, uint8 result) public {
        uint128 q = uint128(bound(rawQ, 1, 1000e6));
        uint256 part = bound(rawPart, 1, q);
        _split(alice, q);
        uint256 cash = markets.balance(alice, T.USDC);
        uint256 asset = markets.balance(alice, T.IMD);
        result %= 4;
        if (result < 3) prices.record(1, start + 3600, result == 0 ? 2e18 : result == 1 ? 0.5e18 : 1e18);
        vm.warp(result == 3 ? start + 3600 + 3 days : start + 3600);
        vm.startPrank(alice);
        markets.claim(mid, part, 0);
        markets.claim(mid, 0, part);
        if (part < q) markets.claim(mid, q - part, q - part);
        vm.expectRevert(PimdMarkets.InsufficientBalance.selector);
        markets.claim(mid, 1, 0);
        vm.stopPrank();
        assertEq(markets.balance(alice, T.USDC), cash + q);
        assertEq(markets.balance(alice, T.IMD), asset + uint256(q) * 1e12);
        assertEq(markets.market(mid).reserveUSDC, 0);
        assertEq(markets.market(mid).reserveAsset, 0);
        _assertConservation(0);
    }

    function testFuzz_splitMergeAcrossUnitsNeverCreatesDust(uint64 rawUnits, uint128 rawQ, uint8 rawCycles) public {
        uint128 units = uint128(bound(rawUnits, 1, 1e18) * 1e6);
        uint128 q = uint128(bound(rawQ, 1, 100e6));
        uint256 needed = uint256(q) * (units / 1e6);
        T.Asset memory a = registry.asset(1);
        a.unitsPerShare = units;
        vm.prank(owner);
        registry.configureAsset(a);
        imd.mint(alice, needed);
        vm.startPrank(alice);
        imd.approve(address(markets), needed);
        markets.deposit(T.IMD, needed);
        uint256 cash = markets.balance(alice, T.USDC);
        uint256 asset = markets.balance(alice, T.IMD);
        for (uint256 j; j < bound(rawCycles, 1, 8); ++j) {
            markets.split(spec, q);
            assertEq(markets.market(mid).reserveAsset, needed);
            markets.merge(mid, q);
            assertEq(markets.balance(alice, T.USDC), cash);
            assertEq(markets.balance(alice, T.IMD), asset);
        }
        vm.stopPrank();
        assertEq(markets.market(mid).pairs, 0);
        _assertConservation(0);
    }

    function testFuzz_allMirroredMatchesConserveSharesAndCollateral(
        uint128 rawQ,
        uint32 rawPrice,
        uint8 combination,
        bool bidIsMaker
    ) public {
        uint128 q = uint128(bound(rawQ, 10e6, 100e6));
        uint128 x = uint128(bound(rawPrice, 1000, 30000) * 100);
        combination %= 4;
        bool oldBid = combination & 1 != 0;
        bool oldAsk = combination & 2 != 0;
        if (oldBid) _split(alice, q);
        if (oldAsk) _split(bob, q);
        PimdMarkets.Action bid = oldBid ? PimdMarkets.Action.SellDown : PimdMarkets.Action.BuyUp;
        PimdMarkets.Action ask = oldAsk ? PimdMarkets.Action.SellUp : PimdMarkets.Action.BuyDown;
        if (bidIsMaker) {
            _place(alice, bid, q, x);
            _place(bob, ask, q, x);
        } else {
            _place(bob, ask, q, x);
            _place(alice, bid, q, x);
        }
        (uint256 aliceUp, uint256 aliceDown) = markets.positions(mid, alice);
        (uint256 bobUp, uint256 bobDown) = markets.positions(mid, bob);
        assertEq(aliceUp, q);
        assertEq(aliceDown, 0);
        assertEq(bobUp, 0);
        assertEq(bobDown, q);
        assertEq(markets.market(mid).pairs, q);
        assertEq(markets.market(mid).reserveUSDC, q);
        assertEq(markets.market(mid).reserveAsset, uint256(q) * 1e12);
        assertEq(markets.bestBid(mid), 0);
        assertEq(markets.bestAsk(mid), 0);
        _assertConservation(2);
    }
}
