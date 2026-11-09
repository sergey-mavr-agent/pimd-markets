// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleFixture} from "./helpers/OracleFixture.sol";
import {MockToken, MockIntake} from "./helpers/Mocks.sol";
import {BoundaryOracle} from "src/v1/BoundaryOracle.sol";
import {MarketTypes as T} from "src/v1/libraries/MarketTypes.sol";

contract OracleBondHandler is Test {
    BoundaryOracle public immutable oracle;
    MockIntake public immutable intake;
    MockToken public immutable token;
    uint256 internal immutable signingKey;
    address[4] public users;
    uint64 public constant BASE = 1_800_000_000;
    uint64 public constant FIRST = 26_000_000;
    uint256 public constant COUNT = 6;
    uint256 public paidIn;
    uint256 public withdrawn;
    uint256 public servicePaid;
    uint256 public donations;
    uint256 public successfulAnswers;
    uint256 public reopened;
    mapping(bytes32 => bool) public closed;
    mapping(uint64 => uint256) public finalPrices;

    constructor(BoundaryOracle o, MockIntake i, address[4] memory actors, uint256 key) {
        oracle = o;
        intake = i;
        token = MockToken(T.IMD);
        users = actors;
        signingKey = key;
    }

    function propose(uint8 which, uint8 who, bool correct) public {
        uint64 boundary = BASE + uint64(which % COUNT) * 3600;
        BoundaryOracle.Proposal memory p = oracle.proposal(oracle.proposalId(1, boundary));
        if (block.timestamp + 1 hours >= uint256(boundary) + 3 days || oracle.price(1, boundary) != 0) return;
        bytes32 id = oracle.proposalId(1, boundary);
        if (p.proposer != address(0) && !p.finished) {
            // A live proposal holds the slot.
            vm.prank(users[who % 4]);
            vm.expectRevert(BoundaryOracle.InvalidState.selector);
            oracle.propose(1, boundary, correct ? 2e18 : 1e18, FIRST);
            return;
        }
        // Either a fresh slot or one freed by a refund: both accept a new proposal.
        if (p.finished) ++reopened;
        vm.prank(users[who % 4]);
        oracle.propose(1, boundary, correct ? 2e18 : 1e18, FIRST);
        paidIn += 10e18;
        closed[id] = false;
    }

    function dispute(uint8 which, uint8 who) public {
        uint64 boundary = BASE + uint64(which % COUNT) * 3600;
        BoundaryOracle.Proposal memory p = oracle.proposal(oracle.proposalId(1, boundary));
        if (p.proposer == address(0) || p.finished || p.challenger != address(0) || block.timestamp >= p.deadline) {
            return;
        }
        address user = users[who % 4];
        if (user == p.proposer) user = users[(who % 4 + 1) % 4];
        uint256 beforeService = token.balanceOf(address(intake));
        vm.prank(user);
        oracle.dispute(1, boundary, 10e18);
        paidIn += 20e18;
        servicePaid += token.balanceOf(address(intake)) - beforeService;
    }

    function retry(uint8 which, uint8 who, uint64 rawBudget) external {
        uint64 boundary = BASE + uint64(which % COUNT) * 3600;
        BoundaryOracle.Proposal memory p = oracle.proposal(oracle.proposalId(1, boundary));
        if (p.challenger == address(0) || p.finished || p.requested || block.timestamp >= uint256(boundary) + 3 days) {
            return;
        }
        uint256 budget = bound(rawBudget, 0, 10e18);
        uint256 beforeService = token.balanceOf(address(intake));
        vm.prank(users[who % 4]);
        oracle.retryResolution(1, boundary, budget);
        paidIn += budget;
        servicePaid += token.balanceOf(address(intake)) - beforeService;
    }

    function configureService(uint8 feeChoice, bool priceUnavailable, bool requestUnavailable, bool failSecond) public {
        uint256 fee = feeChoice % 4 == 0 ? 0 : feeChoice % 4 == 1 ? 0.5e18 : feeChoice % 4 == 2 ? 5e18 : 6e18;
        intake.configure(fee, priceUnavailable, requestUnavailable);
        intake.setFailAt(failSecond ? intake.nonce() + 2 : 0);
    }

    function answer(uint8 which, uint8 whichHop) public {
        uint64 boundary = BASE + uint64(which % COUNT) * 3600;
        bytes32 id = oracle.proposalId(1, boundary);
        BoundaryOracle.Proposal memory p = oracle.proposal(id);
        if (!p.requested || p.finished || block.timestamp >= uint256(boundary) + 3 days) return;
        uint8 hop = whichHop % 2;
        bytes32 rid = p.requests[hop];
        (, bytes32 question,, bool pending) = oracle.requests(rid);
        if (!pending) return;
        BoundaryOracle.Attestation memory a;
        a.requestId = keccak256(abi.encode("bond-invariant-attestation", rid));
        a.chainId = 1;
        a.questionHash = question;
        a.answerType = 3;
        a.answer = abi.encode(hop == 0 ? uint256(1000e18) : uint256(2000e6));
        a.fromBlock = FIRST;
        a.toBlock = FIRST + 2;
        a.blockHash = keccak256("fixture-closing-block");
        a.panelJobId = keccak256("fixture-panel");
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 4;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signingKey, oracle.digest(a));
        vm.prank(address(intake));
        oracle.onOracleResult(rid, a, abi.encodePacked(r, s, v));
        ++successfulAnswers;
        if (p.received == 1) {
            assertEq(oracle.price(1, boundary), 2e18);
            closed[id] = true;
            finalPrices[boundary] = 2e18;
        }
    }

    function fail(uint8 which, bool statusOne) external {
        uint64 boundary = BASE + uint64(which % COUNT) * 3600;
        bytes32 id = oracle.proposalId(1, boundary);
        BoundaryOracle.Proposal memory p = oracle.proposal(id);
        if (!p.requested || p.finished) return;
        bytes32 rid = p.requests[0];
        (,,, bool pending) = oracle.requests(rid);
        if (!pending) rid = p.requests[1];
        vm.prank(address(intake));
        oracle.onFailure(rid, statusOne ? 1 : 2, bytes32(0), 5, 3, "");
        closed[id] = true;
        assertEq(oracle.price(1, boundary), 0);
    }

    function finalize(uint8 which) external {
        uint64 boundary = BASE + uint64(which % COUNT) * 3600;
        bytes32 id = oracle.proposalId(1, boundary);
        BoundaryOracle.Proposal memory p = oracle.proposal(id);
        // A late but unchallenged proposal still finalizes after the boundary's timeout.
        if (p.proposer == address(0) || p.finished || p.challenger != address(0) || block.timestamp < p.deadline) {
            return;
        }
        oracle.finalize(1, boundary);
        closed[id] = true;
        finalPrices[boundary] = p.proposed;
    }

    function timeout(uint8 which) external {
        uint64 boundary = BASE + uint64(which % COUNT) * 3600;
        bytes32 id = oracle.proposalId(1, boundary);
        BoundaryOracle.Proposal memory p = oracle.proposal(id);
        if (p.proposer == address(0) || p.finished || block.timestamp < uint256(boundary) + 3 days) return;
        if (p.challenger == address(0)) {
            // Never timed out: it is finalized instead.
            vm.expectRevert(BoundaryOracle.InvalidState.selector);
            oracle.timeout(1, boundary);
            return;
        }
        oracle.timeout(1, boundary);
        closed[id] = true;
    }

    function moveTime(uint16 raw) external {
        vm.warp(block.timestamp + bound(raw, 1, 2 hours));
    }

    function withdraw(uint8 who) external {
        address user = users[who % 4];
        uint256 amount = oracle.credit(user);
        if (amount == 0) return;
        uint256 beforeBalance = token.balanceOf(user);
        vm.prank(user);
        oracle.withdrawCredit();
        assertEq(token.balanceOf(user), beforeBalance + amount);
        assertEq(oracle.credit(user), 0);
        withdrawn += amount;
    }

    function donate(uint8 who, uint64 raw) external {
        uint256 amount = bound(raw, 1, 1e18);
        vm.prank(users[who % 4]);
        token.transfer(address(oracle), amount);
        donations += amount;
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract OracleBondInvariantTest is OracleFixture {
    OracleBondHandler internal handler;

    function setUp() public override {
        super.setUp();
        vm.warp(BOUNDARY + 5 hours + 27 hours + 1);
        handler = new OracleBondHandler(oracle, intake, [proposer, challenger, sponsor, stranger], FIXTURE_KEY);
        handler.propose(0, 0, true);
        handler.propose(1, 1, false);
        handler.dispute(1, 2);
        handler.answer(1, 1);
        handler.propose(2, 2, true);
        handler.configureService(1, false, true, false);
        handler.dispute(2, 3);
        handler.configureService(1, false, false, false);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.propose.selector;
        selectors[1] = handler.dispute.selector;
        selectors[2] = handler.retry.selector;
        selectors[3] = handler.configureService.selector;
        selectors[4] = handler.answer.selector;
        selectors[5] = handler.fail.selector;
        selectors[6] = handler.finalize.selector;
        selectors[7] = handler.timeout.selector;
        selectors[8] = handler.moveTime.selector;
        selectors[9] = handler.withdraw.selector;
        selectors[10] = handler.donate.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function test_handlerReopensRefundedSlotAndFinalizesLateProposal() public {
        // Boundary 2 was disputed with the intake unavailable: retry, then fail it so the slot is refunded.
        handler.retry(2, 0, 10e18);
        handler.fail(2, true);
        assertTrue(oracle.proposal(oracle.proposalId(1, BOUNDARY + 7200)).finished);
        handler.propose(2, 1, true);
        assertEq(handler.reopened(), 1);
        assertEq(oracle.proposal(oracle.proposalId(1, BOUNDARY + 7200)).proposer, challenger);
        vm.warp(BOUNDARY + 7200 + 3 days + 1);
        handler.timeout(2);
        handler.finalize(2);
        assertEq(oracle.price(1, BOUNDARY + 7200), 2e18);
        invariant_allBondsCreditsFeesAndDonationsAreAccountedFor();
        invariant_finalPricesStayImmutableAndRequestsAreConsumedOnce();
        afterInvariant();
    }

    function invariant_allBondsCreditsFeesAndDonationsAreAccountedFor() public view {
        uint256 obligations;
        address[4] memory users = [proposer, challenger, sponsor, stranger];
        for (uint256 i; i < users.length; ++i) {
            obligations += oracle.credit(users[i]);
        }
        for (uint64 i; i < 6; ++i) {
            BoundaryOracle.Proposal memory p = oracle.proposal(oracle.proposalId(1, BOUNDARY + i * 3600));
            if (p.proposer == address(0) || p.finished) continue;
            obligations += p.challenger == address(0) ? 10e18 : 20e18;
        }
        assertEq(imd.balanceOf(address(oracle)), obligations + handler.donations());
        assertEq(imd.balanceOf(address(intake)), handler.servicePaid());
        assertEq(
            imd.balanceOf(address(oracle)) + handler.servicePaid() + handler.withdrawn(),
            handler.paidIn() + handler.donations()
        );
        assertEq(imd.allowance(address(oracle), address(intake)), 0, "no lingering service allowance");
    }

    function invariant_finalPricesStayImmutableAndRequestsAreConsumedOnce() public view {
        uint64 latest;
        for (uint64 i; i < 6; ++i) {
            uint64 boundary = BOUNDARY + i * 3600;
            bytes32 id = oracle.proposalId(1, boundary);
            BoundaryOracle.Proposal memory p = oracle.proposal(id);
            assertEq(oracle.price(1, boundary), handler.finalPrices(boundary));
            if (oracle.price(1, boundary) != 0) latest = boundary;
            if (handler.closed(id)) assertTrue(p.finished);
            assertLe(p.received, 2);
            uint256 pending;
            if (p.requested) {
                for (uint8 j; j < 2; ++j) {
                    (bytes32 parent, bytes32 qh, uint8 hop, bool active) = oracle.requests(p.requests[j]);
                    assertEq(parent, id);
                    assertTrue(qh != bytes32(0));
                    assertEq(hop, j);
                    if (active) ++pending;
                }
                assertEq(pending, p.finished ? 0 : 2 - p.received);
            }
        }
        assertEq(oracle.latestBoundary(1), latest);
    }

    function afterInvariant() public {
        uint256 deadline = BOUNDARY + 5 hours + 3 days;
        if (block.timestamp < deadline) vm.warp(deadline);
        for (uint64 i; i < 6; ++i) {
            uint64 boundary = BOUNDARY + i * 3600;
            BoundaryOracle.Proposal memory p = oracle.proposal(oracle.proposalId(1, boundary));
            if (p.proposer == address(0) || p.finished) continue;
            if (p.challenger == address(0)) oracle.finalize(1, boundary);
            else oracle.timeout(1, boundary);
        }
        address[4] memory users = [proposer, challenger, sponsor, stranger];
        for (uint256 i; i < users.length; ++i) {
            if (oracle.credit(users[i]) == 0) continue;
            vm.prank(users[i]);
            oracle.withdrawCredit();
            assertEq(oracle.credit(users[i]), 0);
        }
        assertEq(imd.balanceOf(address(oracle)), handler.donations(), "all bonds remain withdrawable");
        uint256 total = imd.balanceOf(address(oracle)) + imd.balanceOf(address(intake));
        for (uint256 i; i < users.length; ++i) {
            total += imd.balanceOf(users[i]);
        }
        assertEq(total, 40_000e18);
    }
}
