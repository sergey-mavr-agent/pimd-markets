// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RLP} from "./RLP.sol";

/// @notice Inclusion proofs for Ethereum's secure hexary trie; accepts inline and hashed children.
/// @dev Missing accounts/slots are deliberately rejected: a pool price must be present and nonzero.
library MerklePatricia {
    error InvalidProof();

    function value(bytes32 root, bytes32 key, bytes[] memory proof) internal pure returns (bytes memory) {
        if (proof.length == 0 || proof.length > 65) revert InvalidProof();
        bytes memory expected = abi.encode(root);
        uint256 used;
        uint256 path;
        for (uint256 step; step < 65; ++step) {
            bytes memory node;
            if (expected.length == 32) {
                if (used == proof.length) revert InvalidProof();
                node = proof[used++];
                if (keccak256(node) != bytes32(expected)) revert InvalidProof();
                if (step != 0 && node.length < 32) revert InvalidProof();
            } else {
                if (expected.length == 0 || expected.length >= 32) revert InvalidProof();
                node = expected;
                // Clients may include an inline node as a redundant proof entry.
                if (used < proof.length && keccak256(proof[used]) == keccak256(node)) ++used;
            }
            RLP.Item[] memory parts = RLP.list(node);
            if (parts.length == 17) {
                if (path == 64) {
                    if (used != proof.length) revert InvalidProof();
                    return RLP.data(node, parts[16]);
                }
                expected = child(node, parts[nibble(key, path++)]);
            } else if (parts.length == 2) {
                bytes memory compact = RLP.data(node, parts[0]);
                if (compact.length == 0) revert InvalidProof();
                uint8 flag = uint8(compact[0]) >> 4;
                if (flag > 3 || (flag % 2 == 0 && uint8(compact[0]) % 16 != 0)) revert InvalidProof();
                uint256 skip = flag % 2 == 1 ? 1 : 2;
                uint256 n = compact.length * 2 - skip;
                if (path + n > 64 || (flag < 2 && n == 0)) revert InvalidProof();
                for (uint256 i; i < n; ++i) {
                    uint256 j = i + skip;
                    uint8 v = j % 2 == 0 ? uint8(compact[j / 2]) >> 4 : uint8(compact[j / 2]) & 15;
                    if (v != nibble(key, path++)) revert InvalidProof();
                }
                if (flag >= 2) {
                    if (path != 64 || used != proof.length) revert InvalidProof();
                    return RLP.data(node, parts[1]);
                }
                expected = child(node, parts[1]);
            } else {
                revert InvalidProof();
            }
        }
        revert InvalidProof();
    }

    function child(bytes memory node, RLP.Item memory part) private pure returns (bytes memory r) {
        if (part.list) {
            r = RLP.encoded(node, part);
            if (r.length >= 32) revert InvalidProof();
        } else {
            r = RLP.data(node, part);
            if (r.length != 32) revert InvalidProof();
        }
    }

    function nibble(bytes32 key, uint256 p) private pure returns (uint8) {
        return uint8(uint256(key) >> ((63 - p) * 4)) & 15;
    }
}
