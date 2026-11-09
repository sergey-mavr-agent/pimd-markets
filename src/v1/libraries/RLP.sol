// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Strict RLP decoding, including canonical length and integer checks.
library RLP {
    error InvalidRLP();

    struct Item {
        uint256 start;
        uint256 payload;
        uint256 length;
        uint256 end;
        bool list;
    }

    function item(bytes memory b, uint256 p) internal pure returns (Item memory x) {
        if (p >= b.length) revert InvalidRLP();
        x.start = p;
        uint256 tag = uint8(b[p]);
        if (tag < 128) {
            x.payload = p;
            x.length = 1;
        } else if (tag <= 183) {
            x.payload = p + 1;
            x.length = tag - 128;
            if (x.length == 1 && x.payload < b.length && uint8(b[x.payload]) < 128) revert InvalidRLP();
        } else if (tag <= 191) {
            uint256 n = tag - 183;
            x.payload = p + 1 + n;
            x.length = lengthOf(b, p + 1, n);
            if (x.length < 56) revert InvalidRLP();
        } else if (tag <= 247) {
            x.list = true;
            x.payload = p + 1;
            x.length = tag - 192;
        } else {
            uint256 n = tag - 247;
            x.list = true;
            x.payload = p + 1 + n;
            x.length = lengthOf(b, p + 1, n);
            if (x.length < 56) revert InvalidRLP();
        }
        x.end = x.payload + x.length;
        if (x.end > b.length) revert InvalidRLP();
    }

    function lengthOf(bytes memory b, uint256 p, uint256 n) private pure returns (uint256 v) {
        if (n == 0 || n > 8 || p + n > b.length || b[p] == 0) revert InvalidRLP();
        for (uint256 i; i < n; ++i) {
            v = v * 256 + uint8(b[p + i]);
        }
    }

    function list(bytes memory b) internal pure returns (Item[] memory result) {
        Item memory root = item(b, 0);
        if (!root.list || root.end != b.length) revert InvalidRLP();
        uint256 p = root.payload;
        uint256 count;
        while (p < root.end) {
            p = item(b, p).end;
            ++count;
        }
        if (p != root.end) revert InvalidRLP();
        result = new Item[](count);
        p = root.payload;
        for (uint256 i; i < count; ++i) {
            result[i] = item(b, p);
            p = result[i].end;
        }
    }

    function data(bytes memory b, Item memory x) internal pure returns (bytes memory) {
        if (x.list) revert InvalidRLP();
        return slice(b, x.payload, x.length);
    }

    function encoded(bytes memory b, Item memory x) internal pure returns (bytes memory) {
        return slice(b, x.start, x.end - x.start);
    }

    function slice(bytes memory b, uint256 p, uint256 n) internal pure returns (bytes memory r) {
        if (p + n > b.length) revert InvalidRLP();
        r = new bytes(n);
        for (uint256 i; i < n; ++i) {
            r[i] = b[p + i];
        }
    }

    function integer(bytes memory b, Item memory x) internal pure returns (uint256 v) {
        if (x.list || x.length > 32 || (x.length != 0 && b[x.payload] == 0)) revert InvalidRLP();
        for (uint256 i; i < x.length; ++i) {
            v = v * 256 + uint8(b[x.payload + i]);
        }
    }

    function word(bytes memory b, Item memory x) internal pure returns (bytes32 v) {
        if (x.list || x.length != 32) revert InvalidRLP();
        uint256 p = x.payload;
        assembly ("memory-safe") { v := mload(add(add(b, 32), p)) }
    }
}
