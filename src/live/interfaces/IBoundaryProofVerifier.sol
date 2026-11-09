// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketTypes as T} from "../libraries/MarketTypes.sol";

/// @notice The fixed mainnet BoundaryProofVerifier (0xa19a97B522cB379c2FB846A4b18589775F674Ee9), never redeployed.
interface IBoundaryProofVerifier {
    struct BlockProof {
        bytes header;
        bytes[] accountProof;
        bytes[][] storageProofs;
    }

    function verify(uint64 boundary, T.Asset calldata asset, BlockProof[3] calldata proofs)
        external
        view
        returns (uint256 price);
}
