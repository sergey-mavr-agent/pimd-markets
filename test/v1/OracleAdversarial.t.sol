// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OracleFixture} from "./helpers/OracleFixture.sol";
import {BoundaryOracle} from "src/v1/BoundaryOracle.sol";
import {BoundaryProofVerifier} from "src/v1/BoundaryProofVerifier.sol";
import {MarketTypes as T} from "src/v1/libraries/MarketTypes.sol";

/// forge-config: default.fuzz.runs = 512
contract OracleAdversarialTest is OracleFixture {
    function _snapshot(bytes32 id) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                oracle.proposal(id),
                oracle.price(1, BOUNDARY),
                oracle.latestBoundary(1),
                oracle.credit(proposer),
                oracle.credit(challenger),
                oracle.credit(sponsor),
                imd.balanceOf(address(oracle)),
                imd.balanceOf(address(intake)),
                imd.balanceOf(proposer),
                imd.balanceOf(challenger),
                imd.balanceOf(sponsor),
                intake.nonce()
            )
        );
    }

    function test_proofAndProposalWindowsMeetWithoutOverlap() public {
        vm.warp(BOUNDARY + 27 hours);
        vm.prank(proposer);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.propose(1, BOUNDARY, 1e18, FIRST_BLOCK);
        BoundaryProofVerifier.BlockProof[3] memory proof;
        oracle.prove(1, BOUNDARY, proof);
        assertEq(oracle.price(1, BOUNDARY), 1e18);
        vm.warp(BOUNDARY + 27 hours + 1);
        vm.prank(proposer);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.propose(1, BOUNDARY, 2e18, FIRST_BLOCK);
    }

    function test_oneSecondBeforeAndAtLatestProposalTime() public {
        vm.warp(BOUNDARY + 3 days - 1 hours);
        vm.prank(proposer);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.propose(1, BOUNDARY, 1e18, FIRST_BLOCK);
        assertEq(imd.balanceOf(address(oracle)), 0);
        vm.warp(BOUNDARY + 3 days - 1 hours - 1);
        bytes32 id = _propose(1e18);
        vm.warp(oracle.proposal(id).deadline);
        oracle.finalize(1, BOUNDARY);
        assertEq(oracle.price(1, BOUNDARY), 1e18);
        assertEq(oracle.credit(proposer), 10e18);
    }

    function test_disputeAtDeadlineFailsButFinalizationSucceeds() public {
        bytes32 id = _propose(2e18);
        vm.warp(oracle.proposal(id).deadline);
        bytes32 beforeState = _snapshot(id);
        vm.prank(challenger);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.dispute(1, BOUNDARY, 1e18);
        assertEq(_snapshot(id), beforeState);
        oracle.finalize(1, BOUNDARY);
        assertEq(oracle.credit(proposer), 10e18);
    }

    /// @dev Revised rule: an unchallenged proposal is never timed out; its window always closed before the
    /// timeout, so it still finalizes when first observed afterwards.
    function test_atTimeoutUncontestedProposalCannotBeTimedOutAndStillFinalizes() public {
        bytes32 id = _propose(2e18);
        vm.warp(BOUNDARY + 3 days);
        bytes32 beforeState = _snapshot(id);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.timeout(1, BOUNDARY);
        assertEq(_snapshot(id), beforeState);
        vm.warp(BOUNDARY + 30 days);
        oracle.finalize(1, BOUNDARY);
        assertTrue(oracle.proposal(id).finished);
        assertEq(oracle.price(1, BOUNDARY), 2e18);
        assertEq(oracle.credit(proposer), 10e18);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.finalize(1, BOUNDARY);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.timeout(1, BOUNDARY);
        assertEq(oracle.credit(proposer), 10e18);
    }

    function test_timeoutWithoutAnyProposalOrBeforeTimeoutIsRefused() public {
        vm.warp(BOUNDARY + 3 days);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.timeout(1, BOUNDARY);
        vm.warp(BOUNDARY + 3 days - 1 hours - 1);
        _disputed(2e18);
        vm.warp(BOUNDARY + 3 days - 1);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.timeout(1, BOUNDARY);
        vm.warp(BOUNDARY + 3 days);
        oracle.timeout(1, BOUNDARY);
        assertEq(oracle.price(1, BOUNDARY), 0);
        assertFalse(oracle.priceable(1, BOUNDARY), "a timed-out boundary can never be priced");
        vm.prank(stranger);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.propose(1, BOUNDARY, 1e18, FIRST_BLOCK);
    }

    function test_refundedSlotReopensAndDeadRequestsCannotTouchTheNewProposal() public {
        bytes32 id = _disputed(2e18);
        bytes32 oldFirst = oracle.proposal(id).requests[0];
        bytes32 oldSecond = oracle.proposal(id).requests[1];
        assertTrue(oldFirst != bytes32(0) && oldSecond != bytes32(0));
        _deliver(oldFirst, 1000e18);
        vm.prank(address(intake));
        oracle.onFailure(oldSecond, 2, bytes32(0), 5, 3, "");
        assertTrue(oracle.proposal(id).finished);
        assertTrue(oracle.priceable(1, BOUNDARY), "the proposal window is still open");

        vm.warp(block.timestamp + 10);
        vm.prank(stranger);
        oracle.propose(1, BOUNDARY, 2e18, FIRST_BLOCK);
        BoundaryOracle.Proposal memory fresh = oracle.proposal(id);
        assertEq(fresh.proposer, stranger);
        assertEq(fresh.challenger, address(0));
        assertFalse(fresh.finished);
        assertFalse(fresh.requested);
        assertEq(fresh.received, 0);
        assertEq(fresh.answers[0], 0);
        assertEq(fresh.requests[0], bytes32(0));

        // The dead proposal's callbacks are refused before and after the new dispute.
        BoundaryOracle.Attestation memory stale = _answer(oldSecond, 2000e6);
        bytes memory staleSig = _signature(stale);
        vm.prank(address(intake));
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.onOracleResult(oldSecond, stale, staleSig);
        vm.prank(sponsor);
        oracle.dispute(1, BOUNDARY, 1e18);
        bytes32 newFirst = oracle.proposal(id).requests[0];
        bytes32 newSecond = oracle.proposal(id).requests[1];
        assertTrue(newFirst != oldFirst && newSecond != oldSecond);
        vm.prank(address(intake));
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.onOracleResult(oldSecond, stale, staleSig);
        vm.prank(address(intake));
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.onFailure(oldSecond, 1, bytes32(0), 5, 3, "");
        assertFalse(oracle.proposal(id).finished, "a dead request cannot refund the live proposal");

        _deliver(newFirst, 1000e18);
        _deliver(newSecond, 2000e6);
        assertEq(oracle.price(1, BOUNDARY), 2e18);
        assertTrue(oracle.proposal(id).finished);
        vm.prank(proposer);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.propose(1, BOUNDARY, 1e18, FIRST_BLOCK);
    }

    function test_liveOrFinalizedProposalBlocksAnotherProposal() public {
        bytes32 id = _propose(2e18);
        vm.prank(stranger);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.propose(1, BOUNDARY, 1e18, FIRST_BLOCK);
        vm.prank(challenger);
        oracle.dispute(1, BOUNDARY, 1e18);
        vm.prank(stranger);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.propose(1, BOUNDARY, 1e18, FIRST_BLOCK);
        assertEq(oracle.proposal(id).proposer, proposer);
    }

    function test_priceableAcrossEveryWindow() public {
        uint64 b = BOUNDARY;
        assertTrue(oracle.priceable(1, b));
        vm.warp(b + 3 days - 1 hours - 1);
        assertTrue(oracle.priceable(1, b), "last second a proposal can still be made");
        vm.warp(b + 3 days - 1 hours);
        assertFalse(oracle.priceable(1, b), "no price, no proposal, window closed");
        vm.warp(b + 3 days - 1 hours - 1);
        _propose(2e18);
        vm.warp(b + 30 days);
        assertTrue(oracle.priceable(1, b), "an unchallenged proposal can always be finalized");
        oracle.finalize(1, b);
        assertTrue(oracle.priceable(1, b));

        uint64 c = BOUNDARY + 3600;
        vm.warp(c + 3 days - 1 hours - 1);
        vm.prank(proposer);
        oracle.propose(1, c, 2e18, FIRST_BLOCK);
        vm.prank(challenger);
        oracle.dispute(1, c, 1e18);
        vm.warp(c + 3 days - 1);
        assertTrue(oracle.priceable(1, c), "a disputed proposal can resolve until the timeout");
        vm.warp(c + 3 days);
        assertFalse(oracle.priceable(1, c), "an unanswered dispute is dead at the timeout");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_priceableNeverClaimsAnUnreachablePrice(uint256 rawTime) public {
        uint256 t = bound(rawTime, BOUNDARY + 27 hours + 1, BOUNDARY + 10 days);
        vm.warp(t);
        bool claimed = oracle.priceable(1, BOUNDARY);
        bool canPropose = t + 1 hours < uint256(BOUNDARY) + 3 days;
        assertEq(claimed, canPropose);
        if (canPropose) {
            _propose(1e18);
            vm.warp(oracle.proposal(oracle.proposalId(1, BOUNDARY)).deadline);
            oracle.finalize(1, BOUNDARY);
            assertEq(oracle.price(1, BOUNDARY), 1e18);
        } else {
            vm.prank(proposer);
            vm.expectRevert(BoundaryOracle.InvalidState.selector);
            oracle.propose(1, BOUNDARY, 1e18, FIRST_BLOCK);
        }
    }

    function test_invalidProposalValuesAndBlockWindowNeverPullBond() public {
        bytes32 id = oracle.proposalId(1, BOUNDARY);
        bytes32 beforeState = _snapshot(id);
        for (uint8 fault; fault < 5; ++fault) {
            uint256 value = fault == 0 ? 0 : fault == 1 ? T.MAX_PRICE + 1 : 1e18;
            uint64 first = fault == 2 ? 0 : fault == 3 ? uint64(block.number - 2) : FIRST_BLOCK;
            uint64 boundary = fault == 4 ? BOUNDARY + 1 : BOUNDARY;
            vm.prank(proposer);
            vm.expectRevert(BoundaryOracle.InvalidState.selector);
            oracle.propose(1, boundary, value, first);
            assertEq(_snapshot(id), beforeState);
        }
    }

    function test_foreignChainCannotProposeOrProve() public {
        vm.chainId(10);
        vm.prank(proposer);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.propose(1, BOUNDARY, 1e18, FIRST_BLOCK);
        vm.warp(BOUNDARY + 1);
        BoundaryProofVerifier.BlockProof[3] memory proof;
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.prove(1, BOUNDARY, proof);
        assertEq(imd.balanceOf(address(oracle)), 0);
    }

    function test_selfDisputeDuplicateDisputeAndExcessBudgetAreAtomic() public {
        bytes32 id = _propose(1e18);
        bytes32 beforeState = _snapshot(id);
        vm.prank(proposer);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.dispute(1, BOUNDARY, 1e18);
        vm.prank(challenger);
        vm.expectRevert(BoundaryOracle.InvalidPayment.selector);
        oracle.dispute(1, BOUNDARY, 10e18 + 1);
        assertEq(_snapshot(id), beforeState);
        vm.prank(challenger);
        oracle.dispute(1, BOUNDARY, 1e18);
        beforeState = _snapshot(id);
        vm.prank(sponsor);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.dispute(1, BOUNDARY, 1e18);
        vm.prank(sponsor);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.retryResolution(1, BOUNDARY, 1e18);
        assertEq(_snapshot(id), beforeState);
    }

    function test_taxedBondAndFailedTransferCannotLeaveProposalOrChallenge() public {
        bytes32 id = oracle.proposalId(1, BOUNDARY);
        bytes32 beforeState = _snapshot(id);
        imd.configure(false, true);
        vm.prank(proposer);
        vm.expectRevert(BoundaryOracle.InvalidPayment.selector);
        oracle.propose(1, BOUNDARY, 1e18, FIRST_BLOCK);
        assertEq(_snapshot(id), beforeState);
        imd.configure(false, false);
        _propose(1e18);
        beforeState = _snapshot(id);
        imd.configure(true, false);
        vm.prank(challenger);
        vm.expectRevert(bytes("transfer rejected"));
        oracle.dispute(1, BOUNDARY, 1e18);
        assertEq(_snapshot(id), beforeState);
    }

    function test_creditWithdrawalFailureAndReentrancyPreserveSinglePayment() public {
        bytes32 id = _propose(2e18);
        vm.warp(oracle.proposal(id).deadline);
        oracle.finalize(1, BOUNDARY);
        imd.configure(true, false);
        vm.prank(proposer);
        vm.expectRevert(bytes("transfer rejected"));
        oracle.withdrawCredit();
        assertEq(oracle.credit(proposer), 10e18);
        imd.configure(false, false);
        imd.setCallback(address(oracle), abi.encodeCall(oracle.withdrawCredit, ()));
        vm.prank(proposer);
        oracle.withdrawCredit();
        assertFalse(imd.callbackSucceeded());
        assertEq(imd.callbackError(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(oracle.credit(proposer), 0);
        assertEq(imd.balanceOf(proposer), 10_000e18);
        vm.prank(proposer);
        vm.expectRevert(BoundaryOracle.InvalidPayment.selector);
        oracle.withdrawCredit();
    }

    function test_thirdPartySponsorGetsOnlyActualSuccessfulCostBack() public {
        bytes32 id = _propose(2e18);
        intake.configure(0.5e18, false, true);
        vm.prank(challenger);
        oracle.dispute(1, BOUNDARY, 3e18);
        assertEq(oracle.credit(challenger), 3e18);
        vm.prank(sponsor);
        oracle.retryResolution(1, BOUNDARY, 0.5e18);
        assertEq(oracle.credit(sponsor), 0.5e18);
        intake.configure(0.5e18, false, false);
        vm.prank(sponsor);
        oracle.retryResolution(1, BOUNDARY, 2e18);
        assertEq(oracle.credit(sponsor), 1.5e18);
        BoundaryOracle.Proposal memory p = oracle.proposal(id);
        _deliver(p.requests[0], 1000e18);
        _deliver(p.requests[1], 2000e6);
        assertEq(oracle.credit(proposer), 19e18);
        assertEq(oracle.credit(challenger), 3e18);
        assertEq(oracle.credit(sponsor), 2.5e18);
        assertEq(imd.balanceOf(address(oracle)), 24.5e18);
        assertEq(imd.balanceOf(address(intake)), 1e18);
    }

    function test_partialAnswerThenFailureRefundsBondsAndRejectsLateAnswer() public {
        bytes32 id = _disputed(2e18);
        BoundaryOracle.Proposal memory p = oracle.proposal(id);
        _deliver(p.requests[0], 1000e18);
        vm.prank(address(intake));
        oracle.onFailure(p.requests[1], 1, bytes32(0), 5, 0, "");
        assertEq(oracle.credit(proposer), 10e18);
        assertEq(oracle.credit(challenger), 10e18);
        assertEq(oracle.price(1, BOUNDARY), 0);
        BoundaryOracle.Attestation memory a = _answer(p.requests[1], 2000e6);
        bytes memory sig = _signature(a);
        vm.prank(address(intake));
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.onOracleResult(p.requests[1], a, sig);
    }

    function test_invalidFailureStatusDoesNotTerminatePendingRequests() public {
        bytes32 id = _disputed(2e18);
        bytes32 beforeState = _snapshot(id);
        bytes32 rid = oracle.proposal(id).requests[0];
        for (uint8 status; status < 4; ++status) {
            if (status == 1 || status == 2) continue;
            vm.prank(address(intake));
            vm.expectRevert(BoundaryOracle.InvalidState.selector);
            oracle.onFailure(rid, status, bytes32(0), 5, 0, "");
        }
        assertEq(_snapshot(id), beforeState);
        (,,, bool pending) = oracle.requests(rid);
        assertTrue(pending);
    }

    function test_signedMalformedAnswersDoNotConsumeRequestOrAttestation() public {
        bytes32 id = _disputed(2e18);
        bytes32 rid = oracle.proposal(id).requests[0];
        bytes32 beforeState = _snapshot(id);
        for (uint8 fault; fault < 9; ++fault) {
            BoundaryOracle.Attestation memory a = _answer(rid, 1000e18);
            if (fault == 0) a.requestId = bytes32(0);
            if (fault == 1) a.answer = new bytes(31);
            if (fault == 2) a.answer = new bytes(33);
            if (fault == 3) a.answer = abi.encode(uint256(0));
            if (fault == 4) a.toBlock += 1;
            if (fault == 5) a.blockHash = bytes32(0);
            if (fault == 6) a.issuedAt = oracle.proposal(id).deadline - 1 hours - 1;
            if (fault == 7) a.quorum = 6;
            if (fault == 8) a.expiresAt = a.issuedAt - 1;
            bytes memory sig = _signature(a);
            vm.prank(address(intake));
            vm.expectRevert(BoundaryOracle.InvalidAnswer.selector);
            oracle.onOracleResult(rid, a, sig);
            assertEq(_snapshot(id), beforeState);
            assertFalse(oracle.usedAttestations(a.requestId));
            (,,, bool pending) = oracle.requests(rid);
            assertTrue(pending);
        }
        _deliver(rid, 1000e18);
        assertEq(oracle.proposal(id).received, 1);
    }

    function test_attestationUuidCannotBeReusedForAnotherPoolEvenIfSigned() public {
        bytes32 id = _disputed(2e18);
        BoundaryOracle.Proposal memory p = oracle.proposal(id);
        _deliver(p.requests[0], 1000e18);
        BoundaryOracle.Attestation memory a = _answer(p.requests[1], 2000e6);
        a.requestId = _answer(p.requests[0], 1000e18).requestId;
        bytes memory sig = _signature(a);
        vm.prank(address(intake));
        vm.expectRevert(BoundaryOracle.InvalidAnswer.selector);
        oracle.onOracleResult(p.requests[1], a, sig);
        assertEq(oracle.proposal(id).received, 1);
        _deliver(p.requests[1], 2000e6);
        assertEq(oracle.price(1, BOUNDARY), 2e18);
    }

    function test_signatureForDifferentConsumerIsInvalid() public {
        bytes32 id = _disputed(2e18);
        bytes32 rid = oracle.proposal(id).requests[0];
        BoundaryOracle.Attestation memory a = _answer(rid, 1000e18);
        BoundaryOracle other = new BoundaryOracle(registry, BoundaryProofVerifier(address(verifier)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(FIXTURE_KEY, other.digest(a));
        vm.prank(address(intake));
        vm.expectRevert(BoundaryOracle.InvalidAnswer.selector);
        oracle.onOracleResult(rid, a, abi.encodePacked(r, s, v));
        assertEq(oracle.proposal(id).received, 0);
    }

    function test_answerAtTimeoutRejectedButBondsStillRecoverable() public {
        bytes32 id = _disputed(2e18);
        bytes32 rid = oracle.proposal(id).requests[0];
        vm.warp(BOUNDARY + 3 days);
        BoundaryOracle.Attestation memory a = _answer(rid, 1000e18);
        bytes memory sig = _signature(a);
        vm.prank(address(intake));
        vm.expectRevert(BoundaryOracle.InvalidAnswer.selector);
        oracle.onOracleResult(rid, a, sig);
        oracle.timeout(1, BOUNDARY);
        assertEq(oracle.credit(proposer), 10e18);
        assertEq(oracle.credit(challenger), 10e18);
    }

    function testFuzz_unusedDisputeBudgetIsRefundedExactly(uint64 rawBudget, bool correct) public {
        uint256 maximum = bound(rawBudget, 1e18, 10e18);
        bytes32 id = _propose(correct ? 2e18 : 1e18);
        vm.prank(challenger);
        oracle.dispute(1, BOUNDARY, maximum);
        assertEq(oracle.credit(challenger), maximum - 1e18);
        BoundaryOracle.Proposal memory p = oracle.proposal(id);
        _deliver(p.requests[1], 2000e6);
        _deliver(p.requests[0], 1000e18);
        assertEq(oracle.credit(proposer), correct ? 19e18 : 0);
        assertEq(oracle.credit(challenger), correct ? maximum : maximum + 19e18);
        assertEq(imd.balanceOf(address(oracle)), oracle.credit(proposer) + oracle.credit(challenger));
    }
}
