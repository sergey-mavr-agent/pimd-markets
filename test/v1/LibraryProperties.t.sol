// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RLP} from "src/v1/libraries/RLP.sol";
import {MerklePatricia} from "src/v1/libraries/MerklePatricia.sol";
import {PriceMath} from "src/v1/libraries/PriceMath.sol";

contract LibraryPropertyHarness {
    function integer(bytes memory encoded) external pure returns (uint256) {
        RLP.Item memory item = RLP.item(encoded, 0);
        if (item.end != encoded.length) revert RLP.InvalidRLP();
        return RLP.integer(encoded, item);
    }

    function stringValue(bytes memory encoded) external pure returns (bytes memory) {
        RLP.Item memory item = RLP.item(encoded, 0);
        if (item.end != encoded.length) revert RLP.InvalidRLP();
        return RLP.data(encoded, item);
    }

    function listSize(bytes memory encoded) external pure returns (uint256) {
        return RLP.list(encoded).length;
    }

    function trieValue(bytes32 root, bytes32 key, bytes[] memory proof) external pure returns (bytes memory) {
        return MerklePatricia.value(root, key, proof);
    }

    function quote(uint256 amount, uint160 sqrt, bool forward) external pure returns (uint256) {
        return PriceMath.quote(amount, sqrt, forward);
    }

    function median(uint256 a, uint256 b, uint256 c) external pure returns (uint256) {
        return PriceMath.median(a, b, c);
    }
}

/// @notice Algebraic tests use independently encoded inputs and exact power-of-two price vectors.
/// forge-config: default.fuzz.runs = 512
contract LibraryPropertiesTest is Test {
    LibraryPropertyHarness internal h;
    uint160 internal constant MIN_SQRT = 4295128739;
    uint160 internal constant MAX_SQRT = 1461446703485210103287273052203988822378723970342;

    function setUp() public {
        h = new LibraryPropertyHarness();
    }

    // Independent minimal RLP encoder, restricted to the bounded test payloads.
    function _string(bytes memory payload) internal pure returns (bytes memory) {
        if (payload.length == 1 && uint8(payload[0]) < 128) return payload;
        return bytes.concat(_prefix(payload.length, false), payload);
    }

    function _list(bytes memory payload) internal pure returns (bytes memory) {
        return bytes.concat(_prefix(payload.length, true), payload);
    }

    function _prefix(uint256 length, bool list) internal pure returns (bytes memory) {
        uint256 offset = list ? 192 : 128;
        if (length < 56) return abi.encodePacked(bytes1(uint8(offset + length)));
        if (length < 256) return abi.encodePacked(bytes1(uint8(offset + 56)), bytes1(uint8(length)));
        return abi.encodePacked(bytes1(uint8(offset + 57)), bytes2(uint16(length)));
    }

    function _uint(uint256 value) internal pure returns (bytes memory) {
        if (value == 0) return hex"80";
        uint256 copy = value;
        uint256 length;
        while (copy != 0) {
            ++length;
            copy >>= 8;
        }
        bytes memory payload = new bytes(length);
        for (uint256 i; i < length; ++i) {
            payload[length - 1 - i] = bytes1(uint8(value >> (i * 8)));
        }
        return _string(payload);
    }

    function test_integerEncodingEdges() public view {
        uint256[8] memory values = [uint256(0), 1, 127, 128, 255, 256, type(uint128).max, type(uint256).max];
        for (uint256 i; i < values.length; ++i) {
            assertEq(h.integer(_uint(values[i])), values[i]);
        }
    }

    function testFuzz_integerRoundTrip(uint256 value) public view {
        assertEq(h.integer(_uint(value)), value);
    }

    function testFuzz_rlpStringAndListLengthBoundaries(uint16 rawLength, bytes32 seed) public view {
        uint256 length = bound(rawLength, 0, 512);
        bytes memory payload = new bytes(length);
        for (uint256 i; i < length; ++i) {
            payload[i] = seed[i % 32];
        }
        bytes memory encoded = _string(payload);
        assertEq(h.stringValue(encoded), payload);
        assertEq(h.listSize(_list(bytes.concat(encoded, hex"80", encoded))), 3);
    }

    function test_rlpRejectsTruncationTrailingBytesAndNonminimalLists() public {
        bytes[9] memory bad = [
            bytes(hex"81"),
            hex"8201",
            hex"b83800",
            hex"b9003800",
            hex"c18000",
            hex"c181",
            hex"f80180",
            hex"f9003880",
            hex"f838c0"
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(RLP.InvalidRLP.selector);
            if (i < 4) h.stringValue(bad[i]);
            else h.listSize(bad[i]);
        }
        vm.expectRevert(RLP.InvalidRLP.selector);
        h.integer(bytes.concat(hex"a1", new bytes(33)));
        vm.expectRevert(RLP.InvalidRLP.selector);
        h.stringValue(hex"c0");
    }

    function testFuzz_leafProofBindsRootKeyAndValue(bytes32 key, uint256 value) public {
        bytes memory expected = _uint(value);
        bytes memory leaf = _list(bytes.concat(_string(abi.encodePacked(bytes1(0x20), key)), _string(expected)));
        bytes[] memory proof = new bytes[](1);
        proof[0] = leaf;
        assertEq(h.trieValue(keccak256(leaf), key, proof), expected);
        vm.expectRevert(MerklePatricia.InvalidProof.selector);
        h.trieValue(keccak256(leaf), bytes32(uint256(key) ^ 1), proof);
        vm.expectRevert(MerklePatricia.InvalidProof.selector);
        h.trieValue(bytes32(uint256(keccak256(leaf)) ^ 1), key, proof);
    }

    function test_trieRejectsBadCompactPathsExtraNodesAndOversizedProofs() public {
        bytes32 key = keccak256("secure trie key");
        bytes[] memory proof = new bytes[](1);
        for (uint8 flag = 4; flag < 8; ++flag) {
            proof[0] = _list(bytes.concat(_string(abi.encodePacked(bytes1(flag << 4), key)), hex"01"));
            vm.expectRevert(MerklePatricia.InvalidProof.selector);
            h.trieValue(keccak256(proof[0]), key, proof);
        }
        proof[0] = _list(bytes.concat(_string(abi.encodePacked(bytes1(0x21), key)), hex"01"));
        vm.expectRevert(MerklePatricia.InvalidProof.selector);
        h.trieValue(keccak256(proof[0]), key, proof);
        proof[0] = _list(bytes.concat(_string(abi.encodePacked(bytes1(0x20), key)), hex"01"));
        bytes[] memory extra = new bytes[](2);
        extra[0] = proof[0];
        extra[1] = hex"c0";
        vm.expectRevert(MerklePatricia.InvalidProof.selector);
        h.trieValue(keccak256(proof[0]), key, extra);
        vm.expectRevert(MerklePatricia.InvalidProof.selector);
        h.trieValue(keccak256(proof[0]), key, new bytes[](0));
        vm.expectRevert(MerklePatricia.InvalidProof.selector);
        h.trieValue(keccak256(proof[0]), key, new bytes[](66));
    }

    function testFuzz_powerOfTwoPricesMatchExactBinaryScaling(uint64 amount, uint8 rawExponent, bool forward)
        public
        view
    {
        uint256 exponent = bound(rawExponent, 33, 159);
        uint160 sqrt = uint160(uint256(1) << exponent);
        bool multiply = (exponent >= 96) == forward;
        uint256 shift = exponent >= 96 ? 2 * (exponent - 96) : 2 * (96 - exponent);
        uint256 expected = multiply ? uint256(amount) << shift : uint256(amount) >> shift;
        assertEq(h.quote(amount, sqrt, forward), expected);
    }

    function testFuzz_quoteRoundTripCannotCreateValue(uint64 amount, uint160 rawSqrt, bool forward) public view {
        uint160 sqrt = uint160(bound(rawSqrt, MIN_SQRT + 1, MAX_SQRT - 1));
        uint256 intermediate = h.quote(amount, sqrt, forward);
        assertLe(h.quote(intermediate, sqrt, !forward), amount);
        assertEq(h.quote(0, sqrt, forward), 0);
    }

    function testFuzz_quoteIsMonotoneInAmount(uint64 small, uint64 delta, uint160 rawSqrt, bool forward) public view {
        uint160 sqrt = uint160(bound(rawSqrt, MIN_SQRT + 1, MAX_SQRT - 1));
        assertLe(h.quote(small, sqrt, forward), h.quote(uint256(small) + delta, sqrt, forward));
    }

    function test_sqrtDomainEndpointsAndArithmeticBranchBoundary() public {
        vm.expectRevert(bytes("sqrt range"));
        h.quote(1, MIN_SQRT, true);
        vm.expectRevert(bytes("sqrt range"));
        h.quote(1, MAX_SQRT, false);
        vm.expectRevert(bytes("sqrt range"));
        h.quote(1, 0, true);
        assertEq(h.quote(type(uint128).max, uint160(1 << 96), true), type(uint128).max);
        assertEq(h.quote(1 << 64, uint160(1 << 128), false), 1);
        assertEq(h.quote(1 << 64, uint160(type(uint128).max), false), 1);
        assertEq(h.quote(1, uint160(1 << 128), true), 1 << 64);
    }

    function testFuzz_medianIsOrderIndependentAndIsAnInput(uint256 a, uint256 b, uint256 c) public view {
        uint256 m = h.median(a, b, c);
        assertTrue(m == a || m == b || m == c);
        assertTrue((a <= m && m <= b) || (b <= m && m <= a));
        assertTrue((a <= m && m <= c) || (c <= m && m <= a));
        assertTrue((b <= m && m <= c) || (c <= m && m <= b));
        assertEq(h.median(b, c, a), m);
        assertEq(h.median(c, a, b), m);
        assertEq(h.median(a, a, c), a);
    }
}
