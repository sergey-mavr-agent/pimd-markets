// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BoundaryOracle} from "../../src/v1/BoundaryOracle.sol";
import {BoundaryProofVerifier} from "../../src/v1/BoundaryProofVerifier.sol";
import {PimdRegistry} from "../../src/v1/PimdRegistry.sol";
import {MarketTypes as T} from "../../src/v1/libraries/MarketTypes.sol";
import {OracleRequest} from "../../src/v1/libraries/OracleRequest.sol";
import {MockToken, MockIntake, MockSigner, MockVerifier} from "./helpers/Mocks.sol";

contract OracleQuestionHarness {
    function hash(string calldata q, uint64 n) external pure returns (bytes32) {
        return OracleRequest.questionHash(q, n);
    }
}

contract BoundaryOracleTest is Test {
    BoundaryOracle internal oracle;
    PimdRegistry internal registry;
    MockToken internal imd;
    MockIntake internal intake;
    MockVerifier internal verifier;
    address internal alice = makeAddr("proposer");
    address internal bob = makeAddr("challenger");
    uint64 internal boundary = 1_800_000_000;
    uint64 internal n = 26_000_000;
    uint256 internal testSigningKey = 0x712;

    function setUp() public {
        vm.chainId(1);
        vm.warp(boundary + 100);
        vm.roll(27_000_000);
        MockToken token = new MockToken(18);
        vm.etch(T.IMD, address(token).code);
        imd = MockToken(T.IMD);
        MockIntake implementation = new MockIntake();
        vm.etch(0xa43e6F75ee006411F79Ac1C84120606C2330DE82, address(implementation).code);
        intake = MockIntake(0xa43e6F75ee006411F79Ac1C84120606C2330DE82);
        intake.configure(0.5e18, false, false);
        MockSigner signer = new MockSigner(vm.addr(testSigningKey));
        vm.etch(0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982, address(signer).code);
        registry = new PimdRegistry(address(this));
        verifier = new MockVerifier();
        oracle = new BoundaryOracle(registry, BoundaryProofVerifier(address(verifier)));
        imd.mint(alice, 100e18);
        imd.mint(bob, 100e18);
        vm.prank(alice);
        imd.approve(address(oracle), 100e18);
        vm.prank(bob);
        imd.approve(address(oracle), 100e18);
    }

    function _propose(uint256 p) internal {
        vm.warp(boundary + 27 hours + 1);
        vm.prank(alice);
        oracle.propose(1, boundary, p, n);
    }

    function _dispute(uint256 p) internal returns (bytes32 id) {
        _propose(p);
        vm.prank(bob);
        oracle.dispute(1, boundary, 1e18);
        id = oracle.proposalId(1, boundary);
    }

    function _attestation(bytes32 rid, uint256 value) internal view returns (BoundaryOracle.Attestation memory a) {
        (, bytes32 question,,) = oracle.requests(rid);
        a.requestId = keccak256(abi.encode("oracle-id", rid));
        a.chainId = 1;
        a.questionHash = question;
        a.answerType = 3;
        a.answer = abi.encode(value);
        a.fromBlock = n;
        a.toBlock = n + 2;
        a.blockHash = keccak256("pinned-block");
        a.panelJobId = keccak256("panel");
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 4;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
    }

    function _signature(BoundaryOracle.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(testSigningKey, oracle.digest(a));
        return abi.encodePacked(r, s, v);
    }

    function _deliver(bytes32 rid, uint256 value) internal {
        BoundaryOracle.Attestation memory a = _attestation(rid, value);
        bytes memory sig = _signature(a);
        vm.prank(address(intake));
        oracle.onOracleResult(rid, a, sig);
    }

    /// @dev Hop answers are currency1 atomic units per 1e36 currency0 atomic units: 1000 IMD per ETH
    /// and 2000 USDC per ETH compose to 2 USD per IMD.
    function _resolve(bytes32 id) internal {
        BoundaryOracle.Proposal memory p = oracle.proposal(id);
        _deliver(p.requests[1], 2000e24);
        _deliver(p.requests[0], 1000e36);
    }

    function test_proofRecordsOnceAndLatestNeverMovesBackwards() public {
        BoundaryProofVerifier.BlockProof[3] memory proof;
        oracle.prove(1, boundary, proof);
        assertEq(oracle.price(1, boundary), 1e18);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.prove(1, boundary, proof);
        oracle.prove(1, boundary - 3600, proof);
        assertEq(oracle.latestBoundary(1), boundary);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.prove(1, boundary + 1, proof);
    }

    function test_badExpiredAndFutureProofsRejected() public {
        BoundaryProofVerifier.BlockProof[3] memory proof;
        verifier.configure(1e18, true);
        vm.expectRevert();
        oracle.prove(1, boundary, proof);
        verifier.configure(1e18, false);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.prove(1, boundary + 3600, proof);
        vm.warp(boundary + 27 hours + 1);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.prove(1, boundary, proof);
    }

    function test_noEarlyOrDuplicateOrInvalidProposal() public {
        vm.prank(alice);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.propose(1, boundary, 1e18, n);
        _propose(1e18);
        vm.prank(alice);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.propose(1, boundary, 1e18, n);
        assertEq(imd.balanceOf(address(oracle)), 10e18);
    }

    function test_uncontestedProposalAndBondWithdrawal() public {
        _propose(2e18);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.finalize(1, boundary);
        vm.warp(block.timestamp + 1 hours);
        oracle.finalize(1, boundary);
        assertEq(oracle.price(1, boundary), 2e18);
        assertEq(oracle.credit(alice), 10e18);
        vm.prank(alice);
        oracle.withdrawCredit();
        assertEq(imd.balanceOf(alice), 100e18);
        vm.prank(alice);
        vm.expectRevert(BoundaryOracle.InvalidPayment.selector);
        oracle.withdrawCredit();
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.finalize(1, boundary);
    }

    function test_disputedCorrectPriceRewardsProposerAndChargesLosingBond() public {
        bytes32 id = _dispute(2e18);
        _resolve(id);
        assertEq(oracle.price(1, boundary), 2e18);
        assertEq(oracle.credit(alice), 19e18);
        assertEq(oracle.credit(bob), 1e18);
        assertEq(imd.balanceOf(address(intake)), 1e18);
        assertEq(imd.allowance(address(oracle), address(intake)), 0);
        assertEq(imd.balanceOf(address(oracle)), oracle.credit(alice) + oracle.credit(bob));
    }

    function test_disputedWrongPriceRewardsChallenger() public {
        bytes32 id = _dispute(1e18);
        _resolve(id);
        assertEq(oracle.credit(bob), 20e18);
        assertEq(oracle.credit(alice), 0);
        assertEq(oracle.price(1, boundary), 2e18);
    }

    function test_failureRefundsBothBondsAndIgnoresNoSignature() public {
        bytes32 id = _dispute(1e18);
        bytes32 rid = oracle.proposal(id).requests[0];
        vm.prank(address(intake));
        oracle.onFailure(rid, 2, keccak256("no consensus"), 5, 3, "");
        assertEq(oracle.credit(alice), 10e18);
        assertEq(oracle.credit(bob), 10e18);
        assertEq(oracle.price(1, boundary), 0);
        assertEq(imd.balanceOf(address(oracle)), 20e18);
        vm.prank(address(intake));
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.onFailure(rid, 2, bytes32(0), 0, 0, "");
    }

    function test_silentOracleTimeoutRefundsBothBonds() public {
        _dispute(1e18);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.timeout(1, boundary);
        vm.warp(boundary + 3 days);
        oracle.timeout(1, boundary);
        assertEq(oracle.credit(alice), 10e18);
        assertEq(oracle.credit(bob), 10e18);
        // The window is closed, so the released slot cannot be reused and the boundary stays unpriced.
        vm.prank(bob);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.propose(1, boundary, 2e18, n);
        assertFalse(oracle.priceable(1, boundary));
    }

    function test_refundedProposalFreesSlotAndStaleCallbacksAreIgnored() public {
        // A bogus window (block 1 cannot straddle the boundary) is disputed and refused by the panel.
        vm.warp(boundary + 27 hours + 1);
        vm.prank(alice);
        oracle.propose(1, boundary, 1, 1);
        vm.prank(bob);
        oracle.dispute(1, boundary, 1e18);
        bytes32 id = oracle.proposalId(1, boundary);
        bytes32 stale = oracle.proposal(id).requests[0];
        bytes32 staleSecond = oracle.proposal(id).requests[1];
        vm.prank(address(intake));
        oracle.onFailure(stale, 1, keccak256("refused: window does not straddle the boundary"), 5, 0, "");
        assertEq(oracle.credit(alice), 10e18);
        assertEq(oracle.credit(bob), 10e18);
        assertTrue(oracle.priceable(1, boundary), "window still open: boundary remains priceable");
        // The honest price can now be proposed for the rest of the window, by anyone.
        vm.prank(bob);
        oracle.propose(1, boundary, 2e18, n);
        BoundaryOracle.Proposal memory p = oracle.proposal(id);
        assertEq(p.proposer, bob);
        assertEq(p.challenger, address(0));
        assertEq(p.received, 0);
        assertEq(p.requests[0], bytes32(0));
        assertFalse(p.finished);
        // The refused proposal's requests are dead: neither a late answer nor a late failure touches the
        // new proposal.
        BoundaryOracle.Attestation memory a = _attestation(stale, 1000e36);
        bytes memory sig = _signature(a);
        vm.prank(address(intake));
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.onOracleResult(stale, a, sig);
        vm.prank(address(intake));
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.onFailure(staleSecond, 2, bytes32(0), 5, 3, "");
        // The live proposal still blocks a third one, and resolves normally when disputed.
        vm.prank(alice);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.propose(1, boundary, 3e18, n);
        vm.prank(alice);
        oracle.dispute(1, boundary, 1e18);
        _resolve(id);
        assertEq(oracle.price(1, boundary), 2e18);
        assertEq(oracle.credit(bob), 10e18 + 20e18 - 1e18);
        assertEq(oracle.credit(alice), 10e18 + 1e18);
        assertEq(imd.balanceOf(address(oracle)), oracle.credit(alice) + oracle.credit(bob));
        assertEq(imd.balanceOf(address(intake)), 2e18);
    }

    function test_lateUnchallengedProposalFinalizesAfterTimeoutAndCannotBeTimedOut() public {
        vm.warp(boundary + 3 days - 1 hours - 1);
        vm.prank(alice);
        oracle.propose(1, boundary, 123e16, n);
        vm.prank(alice);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.propose(1, boundary - 3600, 1e18, n); // the window for that earlier boundary is closed
        vm.warp(boundary + 3 days + 12 hours);
        assertTrue(oracle.priceable(1, boundary));
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.timeout(1, boundary);
        oracle.finalize(1, boundary);
        assertEq(oracle.price(1, boundary), 123e16);
        assertEq(oracle.credit(alice), 10e18);
    }

    function test_priceableFollowsProofWindowProposalWindowAndLiveProposals() public {
        assertTrue(oracle.priceable(1, boundary));
        assertTrue(oracle.priceable(1, boundary + 7 days));
        vm.warp(boundary + 27 hours + 1);
        assertTrue(oracle.priceable(1, boundary));
        vm.warp(boundary + 3 days - 1 hours);
        assertFalse(oracle.priceable(1, boundary));
        vm.warp(boundary + 3 days - 1 hours - 1);
        vm.prank(alice);
        oracle.propose(1, boundary, 2e18, n);
        vm.prank(bob);
        oracle.dispute(1, boundary, 1e18);
        vm.warp(boundary + 3 days - 1);
        assertTrue(oracle.priceable(1, boundary));
        vm.warp(boundary + 3 days);
        assertFalse(oracle.priceable(1, boundary));
        oracle.timeout(1, boundary);
        assertFalse(oracle.priceable(1, boundary));
        vm.warp(boundary + 7 days + 1);
        BoundaryProofVerifier.BlockProof[3] memory proof;
        oracle.prove(1, boundary + 7 days, proof);
        assertTrue(oracle.priceable(1, boundary + 7 days));
    }

    function test_lowValuedHopAnswerStaysNonzeroWithWideBase() public {
        // An 18-decimal token worth 4e-7 USD: 1e18 atomic units are 0.4 USDC atomic units, so a 1e18
        // base would floor to 0, while the 1e36 base asks for 4e17.
        T.Asset memory a;
        a.token = address(0x1234);
        a.unitsPerShare = 1e18;
        a.maxOpenPairs = 1e12;
        a.hops = 1;
        a.path[0] = T.PoolKey(a.token, T.USDC, 3000, 60, address(0));
        uint32 version = registry.configureAsset(a);
        vm.warp(boundary + 27 hours + 1);
        vm.prank(alice);
        oracle.propose(version, boundary, 4e11, n);
        vm.prank(bob);
        oracle.dispute(version, boundary, 0.5e18);
        bytes32 id = oracle.proposalId(version, boundary);
        bytes32 rid = oracle.proposal(id).requests[0];
        string memory q = OracleRequest.question(registry.asset(version), 0, boundary, n, address(oracle), version);
        assertTrue(bytes(q).length > 0);
        (, bytes32 stored,,) = oracle.requests(rid);
        assertEq(stored, OracleRequest.questionHash(q, n));
        _deliver(rid, 4e17);
        assertEq(oracle.price(version, boundary), 4e11);
        assertEq(oracle.credit(alice), 20e18 - 0.5e18);
    }

    function test_costFallbackCapAndAtomicRequestFailure() public {
        _propose(2e18);
        intake.configure(0, true, true);
        (uint256 per, uint256 total) = oracle.oracleCost(1);
        assertEq(per, 0.5e18);
        assertEq(total, 1e18);
        vm.prank(bob);
        oracle.dispute(1, boundary, 1e18);
        assertEq(imd.balanceOf(bob), 89e18);
        assertEq(oracle.credit(bob), 1e18);
        assertEq(oracle.proposal(oracle.proposalId(1, boundary)).challenger, bob);
        assertEq(intake.nonce(), 0);
        assertEq(imd.balanceOf(address(intake)), 0);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.finalize(1, boundary);
        intake.configure(6e18, false, false);
        vm.expectRevert(BoundaryOracle.InvalidPayment.selector);
        oracle.oracleCost(1);
        intake.configure(0.5e18, false, false);
        vm.prank(bob);
        oracle.retryResolution(1, boundary, 0.9e18);
        assertEq(oracle.credit(bob), 1.9e18);
        assertEq(intake.nonce(), 0);
        vm.prank(bob);
        oracle.retryResolution(1, boundary, 1e18);
        _resolve(oracle.proposalId(1, boundary));
        assertEq(oracle.price(1, boundary), 2e18);
    }

    function test_expensiveOracleCannotMakeBadPriceUnchallengeable() public {
        _propose(1e18);
        intake.configure(100e18, false, false);
        vm.prank(bob);
        oracle.dispute(1, boundary, 0);
        assertEq(oracle.proposal(oracle.proposalId(1, boundary)).challenger, bob);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.finalize(1, boundary);
        vm.warp(boundary + 3 days);
        oracle.timeout(1, boundary);
        assertEq(oracle.credit(alice), 10e18);
        assertEq(oracle.credit(bob), 10e18);
    }

    function test_oracleRequestSubcallIsNotPubliclyUsable() public {
        _propose(1e18);
        bytes32 id = oracle.proposalId(1, boundary);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.requestResolution(id, 1e18);
    }

    function test_secondRequestFailureRollsBackFirstPaymentAndCanRetry() public {
        _propose(2e18);
        intake.setFailAt(2);
        vm.prank(bob);
        oracle.dispute(1, boundary, 1e18);
        assertEq(intake.nonce(), 0);
        assertEq(imd.balanceOf(address(intake)), 0);
        assertEq(imd.allowance(address(oracle), address(intake)), 0);
        assertEq(imd.balanceOf(address(oracle)), 21e18);
        assertEq(oracle.credit(bob), 1e18);
        intake.setFailAt(0);
        vm.prank(alice);
        oracle.retryResolution(1, boundary, 1e18);
        _resolve(oracle.proposalId(1, boundary));
        assertEq(oracle.credit(alice), 20e18);
        assertEq(oracle.credit(bob), 1e18);
        assertEq(imd.balanceOf(address(oracle)), 21e18);
    }

    function test_availableOracleRequiresFundedChallengeBudget() public {
        _propose(2e18);
        vm.prank(bob);
        vm.expectRevert(BoundaryOracle.InvalidPayment.selector);
        oracle.dispute(1, boundary, 0);
        assertEq(oracle.proposal(oracle.proposalId(1, boundary)).challenger, address(0));
    }

    function test_callbacksRequireIntakeAndOwnPendingRequest() public {
        bytes32 id = _dispute(1e18);
        bytes32 rid = oracle.proposal(id).requests[0];
        BoundaryOracle.Attestation memory a = _attestation(rid, 1000e18);
        bytes memory sig = _signature(a);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.onOracleResult(rid, a, sig);
        vm.prank(address(intake));
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.onOracleResult(keccak256("foreign"), a, sig);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.onFailure(rid, 2, bytes32(0), 0, 0, "");
    }

    function test_wrongQuestionChainWindowTypeExpiryPanelAndSignatureRejected() public {
        bytes32 id = _dispute(1e18);
        bytes32 rid = oracle.proposal(id).requests[0];
        for (uint8 fault; fault < 11; ++fault) {
            BoundaryOracle.Attestation memory a = _attestation(rid, 1000e18);
            if (fault == 0) a.questionHash = keccak256("wrong question");
            if (fault == 1) a.chainId = 8453;
            if (fault == 2) a.fromBlock = n + 1;
            if (fault == 3) a.answerType = 0;
            if (fault == 4) a.expiresAt = uint64(block.timestamp - 1);
            if (fault == 5) a.panelSize = 4;
            if (fault == 6) a.quorum = 3;
            if (fault == 7) a.agreed = 3;
            if (fault == 8) a.agreed = 6;
            if (fault == 9) a.issuedAt = uint64(block.timestamp + 1);
            bytes memory sig = _signature(a);
            if (fault == 10) sig[0] = bytes1(uint8(sig[0]) ^ 1);
            vm.prank(address(intake));
            vm.expectRevert(BoundaryOracle.InvalidAnswer.selector);
            oracle.onOracleResult(rid, a, sig);
        }
        _resolve(id);
    }

    function test_duplicateAnswerAndDistinctIntakeOracleIds() public {
        bytes32 id = _dispute(2e18);
        bytes32 rid = oracle.proposal(id).requests[0];
        _deliver(rid, 1000e18);
        BoundaryOracle.Attestation memory a = _attestation(rid, 1000e18);
        bytes memory sig = _signature(a);
        assertTrue(a.requestId != rid);
        vm.prank(address(intake));
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.onOracleResult(rid, a, sig);
    }

    function test_poolAnswersMustAgreeOnPinnedClosingBlockHash() public {
        bytes32 id = _dispute(2e18);
        BoundaryOracle.Proposal memory p = oracle.proposal(id);
        _deliver(p.requests[0], 1000e18);
        BoundaryOracle.Attestation memory a = _attestation(p.requests[1], 2000e6);
        a.blockHash = keccak256("different branch");
        bytes memory sig = _signature(a);
        vm.prank(address(intake));
        vm.expectRevert(BoundaryOracle.InvalidAnswer.selector);
        oracle.onOracleResult(p.requests[1], a, sig);
        _deliver(p.requests[1], 2000e6);
        assertEq(oracle.price(1, boundary), 2e18);
    }

    function test_questionHashMatchesCanonicalDocumentAndBody() public {
        bytes32 id = _dispute(2e18);
        BoundaryOracle.Proposal memory p = oracle.proposal(id);
        string memory q = OracleRequest.question(registry.asset(1), 0, boundary, n, address(oracle), 1);
        bytes32 expected = OracleRequest.questionHash(q, n);
        (, bytes32 actual,,) = oracle.requests(p.requests[0]);
        assertEq(actual, expected);
        assertEq(intake.bodies(p.requests[0]), OracleRequest.body(q, n, address(oracle)));
        // Independent literal canonical JSON vector (chain evidence is omitted from the hash).
        OracleQuestionHarness h = new OracleQuestionHarness();
        assertEq(
            h.hash("Price?", 100),
            keccak256(
                bytes(
                    '{"answerType":"uint256","chainId":1,"question":"Price?","v":1,"window":{"fromBlock":100,"toBlock":102}}'
                )
            )
        );
    }
}
