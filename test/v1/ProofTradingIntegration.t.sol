// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PimdMarkets} from "src/v1/PimdMarkets.sol";
import {PimdRegistry} from "src/v1/PimdRegistry.sol";
import {BoundaryOracle} from "src/v1/BoundaryOracle.sol";
import {BoundaryProofVerifier} from "src/v1/BoundaryProofVerifier.sol";
import {PimdSwap} from "src/v1/PimdSwap.sol";
import {MarketTypes as T} from "src/v1/libraries/MarketTypes.sol";
import {MockToken} from "./helpers/Mocks.sol";
import {AdversarialPoolManager as Manager} from "./helpers/AdversarialPoolManager.sol";
import {MainnetFixture as F} from "./fixtures/MainnetFixture.sol";

/// @dev Offline anchor for the genuine bundled mainnet witness; this is not a live fork.
contract IntegrationHistoryAnchor {
    fallback(bytes calldata data) external returns (bytes memory) {
        uint256 n = abi.decode(data, (uint256));
        require(n == F.LAST_BLOCK && n < block.number && block.number - n <= 8191, "history");
        return abi.encode(F.ANCHOR);
    }
}

contract ProofTradingIntegrationTest is Test {
    PimdMarkets internal markets;
    BoundaryOracle internal oracle;
    PimdSwap internal swapper;
    Manager internal manager;
    MockToken internal usdc;
    MockToken internal imd;
    address internal alice = makeAddr("proof-alice");
    address internal bob = makeAddr("proof-bob");
    PimdMarkets.MarketSpec internal spec;

    function setUp() public {
        vm.chainId(1);
        vm.roll(F.LAST_BLOCK + 3);
        vm.warp(F.BOUNDARY + 60);
        MockToken cash = new MockToken(6);
        MockToken asset = new MockToken(18);
        vm.etch(T.USDC, address(cash).code);
        vm.etch(T.IMD, address(asset).code);
        usdc = MockToken(T.USDC);
        imd = MockToken(T.IMD);
        PimdRegistry registry = new PimdRegistry(address(this));
        BoundaryProofVerifier verifier = new BoundaryProofVerifier();
        IntegrationHistoryAnchor history = new IntegrationHistoryAnchor();
        vm.etch(verifier.HISTORY(), address(history).code);
        oracle = new BoundaryOracle(registry, verifier);
        swapper = new PimdSwap(registry);
        markets = new PimdMarkets(address(this), registry, oracle, swapper);
        Manager implementation = new Manager();
        vm.etch(T.MANAGER, address(implementation).code);
        manager = Manager(T.MANAGER);
        manager.setRoute(registry.asset(1));
        usdc.mint(T.MANAGER, 1_000_000e6);
        _fund(alice);
        _fund(bob);
        spec = PimdMarkets.MarketSpec(T.IMD, 0, F.BOUNDARY, 0);
    }

    function _fund(address user) private {
        usdc.mint(user, 100e6);
        imd.mint(user, 100e18);
        vm.startPrank(user);
        usdc.approve(address(markets), 100e6);
        imd.approve(address(markets), 100e18);
        markets.deposit(T.USDC, 100e6);
        markets.deposit(T.IMD, 100e18);
        vm.stopPrank();
    }

    function _proofs() private pure returns (PimdMarkets.ProofSubmission[] memory p) {
        p = new PimdMarkets.ProofSubmission[](1);
        p[0].version = 1;
        p[0].boundary = F.BOUNDARY;
        p[0].proofs = F.proofs();
    }

    function _input(bool short) private pure returns (PimdMarkets.OrderInput memory i) {
        i.action = short ? PimdMarkets.Action.BuyDown : PimdMarkets.Action.BuyUp;
        i.quantity = 10e6;
        i.limitPrice = 600_000;
        i.expiry = F.BOUNDARY + 3600;
        i.assetOnly = short;
        i.maxSwapInput = short ? 10e18 : 0;
        i.feeBudget = short ? 1e18 : 1e6;
        i.maxSteps = 4;
    }

    function test_firstOrderProofFeedsFeesAndRealSwapperInOneTransaction() public {
        PimdMarkets.ProofSubmission[] memory p = _proofs();
        PimdMarkets.OrderInput memory short = _input(true);
        vm.prank(bob);
        markets.placeWithProofs(spec, short, p);
        PimdMarkets.OrderInput memory long = _input(false);
        vm.prank(alice);
        markets.place(spec, long);
        bytes32 id = markets.marketId(spec);
        assertEq(oracle.price(1, F.BOUNDARY), F.PRICE);
        assertEq(markets.market(id).reserveUSDC, 10e6);
        assertEq(markets.market(id).reserveAsset, 10e18);
        (uint256 up,) = markets.positions(id, alice);
        (, uint256 down) = markets.positions(id, bob);
        assertEq(up, 10e6);
        assertEq(down, 10e6);
        assertEq(usdc.balanceOf(address(markets)), 204e6);
        assertEq(imd.balanceOf(address(markets)), 196e18);
        assertEq(imd.allowance(address(markets), address(swapper)), 0);
        assertEq(usdc.balanceOf(address(swapper)), 0);
        assertEq(imd.balanceOf(address(swapper)), 0);
    }

    function test_invalidOrderCannotCommitItsAttachedProof() public {
        PimdMarkets.ProofSubmission[] memory p = _proofs();
        PimdMarkets.OrderInput memory i = _input(true);
        ++i.limitPrice;
        vm.prank(bob);
        vm.expectRevert(PimdMarkets.InvalidOrder.selector);
        markets.placeWithProofs(spec, i, p);
        _assertNothingCreated();
    }

    /// @dev Placement now needs a recorded boundary price for the fee floor, so the resting bid is placed
    /// after an earlier boundary is finalized optimistically; F.BOUNDARY itself stays unproven.
    function test_failedIncomingSwapRollsBackProofAndPreservesRestingBid() public {
        _seedEarlierOptimisticPrice();
        PimdMarkets.OrderInput memory long = _input(false);
        vm.prank(alice);
        uint64 bid = markets.place(spec, long);
        bytes32 beforeBid = keccak256(abi.encode(markets.order(bid)));
        PimdMarkets.ProofSubmission[] memory p = _proofs();
        PimdMarkets.OrderInput memory short = _input(true);
        manager.configure(Manager.Mode.PartialOutput);
        vm.prank(bob);
        vm.expectRevert(PimdMarkets.InvalidOrder.selector);
        markets.placeWithProofs(spec, short, p);
        assertEq(oracle.price(1, F.BOUNDARY), 0);
        assertEq(markets.nextOrderId(), 2);
        assertEq(keccak256(abi.encode(markets.order(bid))), beforeBid);
        assertEq(markets.balance(bob, T.IMD), 100e18);
        assertEq(imd.balanceOf(address(markets)), 200e18);
        assertEq(imd.allowance(address(markets), address(swapper)), 0);
        manager.configure(Manager.Mode.Normal);
        vm.prank(bob);
        markets.placeWithProofs(spec, short, p);
        assertEq(oracle.price(1, F.BOUNDARY), F.PRICE);
        assertEq(markets.market(markets.marketId(spec)).pairs, 10e6);
    }

    function test_secondBadProofRollsBackFirstGoodProof() public {
        PimdMarkets.ProofSubmission[] memory p = new PimdMarkets.ProofSubmission[](2);
        p[0] = _proofs()[0];
        p[1] = _proofs()[0];
        p[1].boundary -= 3600;
        PimdMarkets.OrderInput memory i = _input(true);
        vm.prank(bob);
        vm.expectRevert(BoundaryProofVerifier.InvalidHeaders.selector);
        markets.placeWithProofs(spec, i, p);
        _assertNothingCreated();
    }

    function test_oversizedProofBatchRejectedBeforeVerifyingAnything() public {
        PimdMarkets.OrderInput memory i = _input(true);
        PimdMarkets.ProofSubmission[] memory p = new PimdMarkets.ProofSubmission[](3);
        vm.prank(bob);
        vm.expectRevert(PimdMarkets.InvalidMarket.selector);
        markets.placeWithProofs(spec, i, p);
        _assertNothingCreated();
    }

    function test_restingOrderWithoutAnyRecordedPriceIsRefusedAndProofEnablesIt() public {
        PimdMarkets.OrderInput memory long = _input(false);
        vm.prank(alice);
        vm.expectRevert(PimdMarkets.MissingPrice.selector);
        markets.place(spec, long);
        assertEq(markets.nextOrderId(), 1);
        assertEq(markets.balance(alice, T.USDC), 100e6);
        vm.prank(alice);
        markets.placeWithProofs(spec, long, _proofs());
        assertEq(oracle.price(1, F.BOUNDARY), F.PRICE);
        assertTrue(markets.order(1).resting);
    }

    function test_proofAlreadyRecordedBySomeoneElseIsSkippedNotReverted() public {
        BoundaryProofVerifier.BlockProof[3] memory proofs = F.proofs();
        oracle.prove(1, F.BOUNDARY, proofs);
        PimdMarkets.OrderInput memory long = _input(false);
        vm.prank(alice);
        markets.placeWithProofs(spec, long, _proofs());
        assertEq(oracle.price(1, F.BOUNDARY), F.PRICE);
        assertTrue(markets.order(1).resting);
    }

    function test_feeBudgetBelowOwnExecutionFeeIsRefused() public {
        oracle.prove(1, F.BOUNDARY, F.proofs());
        bytes32 id = markets.marketId(spec);
        PimdMarkets.OrderInput memory long = _input(false);
        // The market does not exist until the first placement; create it with a valid order first.
        vm.prank(alice);
        markets.place(spec, long);
        uint256 makerFloor = markets.feeQuote(id, long.limitPrice, long.quantity, false, false);
        uint256 takerFloor = markets.feeQuote(id, long.limitPrice, long.quantity, true, false);
        assertGt(makerFloor, 0);
        assertGt(takerFloor, makerFloor);
        long.feeBudget = makerFloor - 1;
        vm.prank(alice);
        vm.expectRevert(PimdMarkets.InvalidOrder.selector);
        markets.place(spec, long);
        long.feeBudget = makerFloor;
        vm.prank(alice);
        markets.place(spec, long);
        long.immediateOrCancel = true;
        long.feeBudget = takerFloor - 1;
        vm.prank(alice);
        vm.expectRevert(PimdMarkets.InvalidOrder.selector);
        markets.place(spec, long);
    }

    function _seedEarlierOptimisticPrice() private {
        uint64 earlier = F.BOUNDARY - 30 hours;
        address proposer = makeAddr("proof-proposer");
        imd.mint(proposer, 10e18);
        vm.warp(F.BOUNDARY - 2 hours);
        vm.startPrank(proposer);
        imd.approve(address(oracle), 10e18);
        oracle.propose(1, earlier, F.PRICE, uint64(F.LAST_BLOCK - 100));
        vm.stopPrank();
        vm.warp(F.BOUNDARY - 1 hours);
        oracle.finalize(1, earlier);
        assertEq(oracle.latestBoundary(1), earlier);
        vm.warp(F.BOUNDARY + 60);
    }

    function test_claimWithClosingProofSettlesAndPaysWithoutKeeper() public {
        bytes32 id = _previousLadder();
        PimdMarkets.ProofSubmission[] memory p = _proofs();
        vm.prank(alice);
        markets.claimWithProofs(id, 10e6, 10e6, p);
        assertEq(uint8(markets.market(id).outcome), uint8(PimdMarkets.Outcome.Up));
        assertEq(markets.market(id).strike, 2e18);
        assertEq(markets.market(id).close, F.PRICE);
        assertEq(markets.market(id).reserveUSDC, 0);
        assertEq(markets.market(id).reserveAsset, 0);
        assertEq(markets.balance(alice, T.USDC), 100e6);
        assertEq(markets.balance(alice, T.IMD), 100e18);
    }

    function test_excessClaimRollsBackAttachedClosingPriceAndSettlement() public {
        bytes32 id = _previousLadder();
        PimdMarkets.ProofSubmission[] memory p = _proofs();
        vm.prank(alice);
        vm.expectRevert(PimdMarkets.InsufficientBalance.selector);
        markets.claimWithProofs(id, 10e6 + 1, 0, p);
        assertEq(oracle.price(1, F.BOUNDARY), 0);
        assertEq(uint8(markets.market(id).outcome), uint8(PimdMarkets.Outcome.Active));
        assertEq(markets.market(id).reserveUSDC, 10e6);
        (uint256 up, uint256 down) = markets.positions(id, alice);
        assertEq(up, 10e6);
        assertEq(down, 10e6);
    }

    function _previousLadder() private returns (bytes32 id) {
        spec.start = F.BOUNDARY - 3600;
        spec.strike = 2e18;
        vm.warp(spec.start + 60);
        vm.prank(alice);
        id = markets.split(spec, 10e6);
        vm.warp(F.BOUNDARY + 60);
    }

    function _assertNothingCreated() private view {
        assertEq(oracle.price(1, F.BOUNDARY), 0);
        assertEq(oracle.latestBoundary(1), 0);
        assertEq(markets.marketCount(), 0);
        assertEq(markets.nextOrderId(), 1);
        assertEq(markets.balance(bob, T.USDC), 100e6);
        assertEq(markets.balance(bob, T.IMD), 100e18);
    }
}
