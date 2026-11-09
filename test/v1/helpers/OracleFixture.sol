// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BoundaryOracle} from "src/v1/BoundaryOracle.sol";
import {BoundaryProofVerifier} from "src/v1/BoundaryProofVerifier.sol";
import {PimdRegistry} from "src/v1/PimdRegistry.sol";
import {MarketTypes as T} from "src/v1/libraries/MarketTypes.sol";
import {MockToken, MockIntake, MockSigner, MockVerifier} from "./Mocks.sol";

abstract contract OracleFixture is Test {
    BoundaryOracle internal oracle;
    PimdRegistry internal registry;
    MockToken internal imd;
    MockIntake internal intake;
    MockVerifier internal verifier;
    address internal proposer = makeAddr("bond-proposer");
    address internal challenger = makeAddr("bond-challenger");
    address internal sponsor = makeAddr("bond-sponsor");
    address internal stranger = makeAddr("bond-stranger");
    uint64 internal constant BOUNDARY = 1_800_000_000;
    uint64 internal constant FIRST_BLOCK = 26_000_000;
    // Only authenticates the local ERC-1271 mock. No live signer or funded key is used.
    uint256 internal constant FIXTURE_KEY = uint256(keccak256("oracle invariant fixture only"));

    function setUp() public virtual {
        vm.chainId(1);
        vm.roll(27_000_000);
        vm.warp(BOUNDARY + 27 hours + 1);
        MockToken token = new MockToken(18);
        vm.etch(T.IMD, address(token).code);
        imd = MockToken(T.IMD);
        registry = new PimdRegistry(address(this));
        verifier = new MockVerifier();
        oracle = new BoundaryOracle(registry, BoundaryProofVerifier(address(verifier)));
        MockIntake service = new MockIntake();
        vm.etch(oracle.INTAKE(), address(service).code);
        intake = MockIntake(oracle.INTAKE());
        intake.configure(0.5e18, false, false);
        MockSigner signer = new MockSigner(vm.addr(FIXTURE_KEY));
        vm.etch(oracle.SIGNER(), address(signer).code);
        address[4] memory users = [proposer, challenger, sponsor, stranger];
        for (uint256 i; i < users.length; ++i) {
            imd.mint(users[i], 10_000e18);
            vm.prank(users[i]);
            imd.approve(address(oracle), type(uint256).max);
        }
    }

    function _propose(uint256 value) internal returns (bytes32 id) {
        vm.prank(proposer);
        oracle.propose(1, BOUNDARY, value, FIRST_BLOCK);
        return oracle.proposalId(1, BOUNDARY);
    }

    function _disputed(uint256 value) internal returns (bytes32 id) {
        id = _propose(value);
        vm.prank(challenger);
        oracle.dispute(1, BOUNDARY, 1e18);
    }

    function _answer(bytes32 rid, uint256 value) internal view returns (BoundaryOracle.Attestation memory a) {
        (, bytes32 question,,) = oracle.requests(rid);
        a.requestId = keccak256(abi.encode("signed-uuid", rid));
        a.chainId = 1;
        a.questionHash = question;
        a.answerType = 3;
        a.answer = abi.encode(value);
        a.fromBlock = FIRST_BLOCK;
        a.toBlock = FIRST_BLOCK + 2;
        a.blockHash = keccak256("canonical-window-end");
        a.panelJobId = keccak256("test-panel");
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 4;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
    }

    function _signature(BoundaryOracle.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(FIXTURE_KEY, oracle.digest(a));
        return abi.encodePacked(r, s, v);
    }

    function _deliver(bytes32 rid, uint256 value) internal {
        BoundaryOracle.Attestation memory a = _answer(rid, value);
        bytes memory sig = _signature(a);
        vm.prank(address(intake));
        oracle.onOracleResult(rid, a, sig);
    }
}
