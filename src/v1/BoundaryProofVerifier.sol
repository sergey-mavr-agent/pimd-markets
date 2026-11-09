// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketTypes as T} from "./libraries/MarketTypes.sol";
import {RLP} from "./libraries/RLP.sol";
import {MerklePatricia} from "./libraries/MerklePatricia.sol";
import {PriceMath} from "./libraries/PriceMath.sol";

contract BoundaryProofVerifier {
    error InvalidHeaders();
    address public constant HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935;

    struct BlockProof {
        bytes header;
        bytes[] accountProof;
        bytes[][] storageProofs;
    }

    struct Header {
        bytes32 parent;
        bytes32 stateRoot;
        uint64 number;
        uint64 timestamp;
    }

    function header(bytes memory raw) public pure returns (Header memory h) {
        RLP.Item[] memory items = RLP.list(raw);
        if (items.length < 15) revert InvalidHeaders();
        uint256 n = RLP.integer(raw, items[8]);
        uint256 t = RLP.integer(raw, items[11]);
        if (n > type(uint64).max || t > type(uint64).max) revert InvalidHeaders();
        h = Header(RLP.word(raw, items[0]), RLP.word(raw, items[3]), uint64(n), uint64(t));
    }

    function verifyHeaders(uint64 boundary, bytes[3] memory raw) public view returns (Header[3] memory h) {
        for (uint256 i; i < 3; ++i) {
            h[i] = header(raw[i]);
        }
        if (
            h[0].timestamp > boundary || h[1].timestamp <= boundary || h[2].timestamp <= h[1].timestamp
                || h[1].number != h[0].number + 1 || h[2].number != h[1].number + 1 || h[1].parent != keccak256(raw[0])
                || h[2].parent != keccak256(raw[1])
        ) revert InvalidHeaders();
        (bool ok, bytes memory result) = HISTORY.staticcall(abi.encode(uint256(h[2].number)));
        if (!ok || result.length != 32 || abi.decode(result, (bytes32)) != keccak256(raw[2])) revert InvalidHeaders();
    }

    function verify(uint64 boundary, T.Asset calldata asset, BlockProof[3] calldata proofs)
        external
        view
        returns (uint256 price)
    {
        if (asset.hops == 0 || asset.hops > 3 || asset.unitsPerShare == 0) revert InvalidHeaders();
        bytes[3] memory raw = [proofs[0].header, proofs[1].header, proofs[2].header];
        Header[3] memory h = verifyHeaders(boundary, raw);
        uint256[3] memory prices;
        for (uint256 i; i < 3; ++i) {
            bytes memory account =
                MerklePatricia.value(h[i].stateRoot, keccak256(abi.encodePacked(T.MANAGER)), proofs[i].accountProof);
            RLP.Item[] memory fields = RLP.list(account);
            if (fields.length != 4 || proofs[i].storageProofs.length != asset.hops) revert InvalidHeaders();
            bytes32 storageRoot = RLP.word(account, fields[2]);
            uint256 amount = uint256(asset.unitsPerShare) * 1e12;
            address cursor = asset.token;
            for (uint256 j; j < asset.hops; ++j) {
                if (cursor != asset.path[j].currency0 && cursor != asset.path[j].currency1) revert InvalidHeaders();
                bytes memory v = MerklePatricia.value(
                    storageRoot, keccak256(abi.encode(T.slot(asset.path[j]))), proofs[i].storageProofs[j]
                );
                RLP.Item memory val = RLP.item(v, 0);
                if (val.end != v.length) revert InvalidHeaders();
                uint160 sqrt = uint160(RLP.integer(v, val));
                bool forward = cursor == asset.path[j].currency0;
                amount = PriceMath.quote(amount, sqrt, forward);
                cursor = forward ? asset.path[j].currency1 : asset.path[j].currency0;
            }
            if (cursor != T.USDC) revert InvalidHeaders();
            prices[i] = amount; // USDC's 6 decimals plus the extra 12 = USD at 1e18.
        }
        price = PriceMath.median(prices[0], prices[1], prices[2]);
        if (price == 0 || price > T.MAX_PRICE) revert InvalidHeaders();
    }
}
