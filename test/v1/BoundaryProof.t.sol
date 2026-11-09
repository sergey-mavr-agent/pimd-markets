// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BoundaryProofVerifier as V} from "../../src/v1/BoundaryProofVerifier.sol";
import {BoundaryOracle} from "../../src/v1/BoundaryOracle.sol";
import {PimdRegistry} from "../../src/v1/PimdRegistry.sol";
import {MarketTypes as T} from "../../src/v1/libraries/MarketTypes.sol";
import {RLP} from "../../src/v1/libraries/RLP.sol";
import {MerklePatricia} from "../../src/v1/libraries/MerklePatricia.sol";
import {MainnetFixture as F} from "./fixtures/MainnetFixture.sol";

contract HistoryFixture {
    fallback(bytes calldata data) external returns (bytes memory) {
        require(data.length == 32, "length");
        uint256 n = abi.decode(data, (uint256));
        require(n < block.number && block.number - n <= 8191 && n == F.LAST_BLOCK, "history range");
        return abi.encode(F.ANCHOR);
    }
}

contract RLPHarness {
    function integer(bytes memory b) external pure returns (uint256) {
        RLP.Item memory i = RLP.item(b, 0);
        require(i.end == b.length);
        return RLP.integer(b, i);
    }

    function proof(bytes32 root, bytes32 key, bytes[] memory p) external pure returns (bytes memory) {
        return MerklePatricia.value(root, key, p);
    }
}

contract BoundaryProofTest is Test {
    V internal verifier;
    PimdRegistry internal registry;
    T.Asset internal asset;
    BoundaryOracle internal oracle;

    function setUp() public {
        vm.chainId(1);
        vm.warp(F.BOUNDARY + 60);
        vm.roll(F.LAST_BLOCK + 3);
        verifier = new V();
        registry = new PimdRegistry(address(this));
        oracle = new BoundaryOracle(registry, verifier);
        asset = registry.asset(1);
        HistoryFixture h = new HistoryFixture();
        vm.etch(verifier.HISTORY(), address(h).code);
    }

    function test_mainnetProofAllThreeBlocksBothPools() public {
        V.BlockProof[3] memory p = F.proofs();
        assertEq(keccak256(p[2].header), F.ANCHOR);
        assertEq(verifier.verify(F.BOUNDARY, asset, p), F.PRICE);
        oracle.prove(1, F.BOUNDARY, p);
        assertEq(oracle.price(1, F.BOUNDARY), F.PRICE);
    }

    function test_corruptAccountProofRejected() public {
        V.BlockProof[3] memory p = F.proofs();
        p[0].accountProof[0][20] ^= bytes1(uint8(1));
        vm.expectRevert();
        verifier.verify(F.BOUNDARY, asset, p);
    }

    function test_corruptStorageProofRejected() public {
        V.BlockProof[3] memory p = F.proofs();
        p[1].storageProofs[0][0][20] ^= bytes1(uint8(1));
        vm.expectRevert();
        verifier.verify(F.BOUNDARY, asset, p);
    }

    function test_wrongPoolOrSwappedProofsRejected() public {
        V.BlockProof[3] memory p = F.proofs();
        T.Asset memory a = registry.asset(1);
        a.path[0].fee = 500;
        vm.expectRevert();
        verifier.verify(F.BOUNDARY, a, p);
        a = registry.asset(1);
        p[1].storageProofs[0] = p[0].storageProofs[0];
        vm.expectRevert();
        verifier.verify(F.BOUNDARY, a, p);
    }

    function test_wrongHeaderAnchorAndBrokenParentRejected() public {
        V.BlockProof[3] memory p = F.proofs();
        p[2].header[100] ^= bytes1(uint8(1));
        vm.expectRevert(V.InvalidHeaders.selector);
        verifier.verify(F.BOUNDARY, asset, p);
        p = F.proofs();
        p[0].header[100] ^= bytes1(uint8(1));
        vm.expectRevert(V.InvalidHeaders.selector);
        verifier.verify(F.BOUNDARY, asset, p);
    }

    function test_boundaryBracketAndHistoryWindowEnforced() public {
        V.BlockProof[3] memory p = F.proofs();
        vm.expectRevert(V.InvalidHeaders.selector);
        verifier.verify(F.BOUNDARY + 12, asset, p);
        vm.expectRevert(V.InvalidHeaders.selector);
        verifier.verify(F.BOUNDARY - 2, asset, p);
        vm.roll(F.LAST_BLOCK + 8192);
        vm.expectRevert(V.InvalidHeaders.selector);
        verifier.verify(F.BOUNDARY, asset, p);
    }

    function test_missingExtraAndMalformedNodesRejected() public {
        V.BlockProof[3] memory p = F.proofs();
        p[0].accountProof = new bytes[](0);
        vm.expectRevert();
        verifier.verify(F.BOUNDARY, asset, p);
        p = F.proofs();
        uint256 n = p[0].accountProof.length;
        bytes[] memory extra = new bytes[](n + 1);
        for (uint256 i; i < n; ++i) {
            extra[i] = p[0].accountProof[i];
        }
        extra[n] = hex"c0";
        p[0].accountProof = extra;
        vm.expectRevert();
        verifier.verify(F.BOUNDARY, asset, p);
    }

    function test_rlpRejectsNoncanonicalIntegersAndLengths() public {
        RLPHarness h = new RLPHarness();
        assertEq(h.integer(hex"80"), 0);
        assertEq(h.integer(hex"820100"), 256);
        vm.expectRevert();
        h.integer(hex"8101");
        vm.expectRevert();
        h.integer(hex"820001");
        vm.expectRevert();
        h.integer(hex"b80101");
        vm.expectRevert();
        h.integer(hex"b9003801");
        vm.expectRevert();
        h.integer(hex"00");
        vm.expectRevert();
        h.integer(hex"c0");
    }

    function test_inlineExtensionBranchLeafAndMissingKey() public {
        RLPHarness h = new RLPHarness();
        bytes memory branch = bytes.concat(hex"d5c22001c22002", hex"808080808080808080808080808080");
        bytes memory root = bytes.concat(hex"f7a010", new bytes(31), branch);
        bytes[] memory proof = new bytes[](1);
        proof[0] = root;
        assertEq(h.proof(keccak256(root), bytes32(0), proof), hex"01");
        assertEq(h.proof(keccak256(root), bytes32(uint256(1)), proof), hex"02");
        vm.expectRevert();
        h.proof(keccak256(root), bytes32(uint256(2)), proof);
        proof = new bytes[](3);
        proof[0] = root;
        proof[1] = branch;
        proof[2] = hex"c22001";
        assertEq(h.proof(keccak256(root), bytes32(0), proof), hex"01");
        root[2] = hex"40";
        proof = new bytes[](1);
        proof[0] = root;
        vm.expectRevert();
        h.proof(keccak256(root), bytes32(0), proof);
    }

    function testFuzz_corruptProofByteAlwaysRejected(uint16 raw) public {
        V.BlockProof[3] memory p = F.proofs();
        bytes memory node = p[2].storageProofs[1][0];
        uint256 index = bound(raw, 0, node.length - 1);
        node[index] ^= bytes1(uint8(1));
        p[2].storageProofs[1][0] = node;
        vm.expectRevert();
        verifier.verify(F.BOUNDARY, asset, p);
    }
}
