// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Strings} from "../vendor/openzeppelin/contracts/utils/Strings.sol";
import {MarketTypes as T} from "./MarketTypes.sol";

library OracleRequest {
    using Strings for uint256;

    /// @dev Each hop is quoted as currency1 atomic units per HOP_BASE currency0 atomic units. The wide
    /// base keeps a nonzero, precise answer for a hop whose currency0 is worth far less than one
    /// currency1 atomic unit per 1e18 units; the largest v4 ratio times HOP_BASE still fits uint256.
    uint256 internal constant HOP_BASE = 1e36;

    function question(
        T.Asset memory a,
        uint256 hop,
        uint64 boundary,
        uint64 firstBlock,
        address consumer,
        uint32 version
    ) internal pure returns (string memory) {
        T.PoolKey memory p = a.path[hop];
        return string.concat(
            "What is the median currency1 atomic units per 1e36 currency0 atomic units for Uniswap v4 pool ",
            Strings.toHexString(uint256(T.poolId(p)), 32),
            " on Ethereum, over blocks ",
            uint256(firstBlock).toString(),
            " through ",
            uint256(firstBlock + 2).toString(),
            "? Use univ4-spot, all three blocks, sqrtPriceX96 squared times 1e36 divided by 2^192, rounded down. ",
            "Verify timestamp(firstBlock) <= ",
            uint256(boundary).toString(),
            " < timestamp(firstBlock+1); refuse if false. PoolManager 0x000000000004444c5dc75cb358380d2e3de08a90. Consumer ",
            Strings.toHexString(consumer),
            "; asset version ",
            uint256(version).toString(),
            "."
        );
    }

    function questionHash(string memory q, uint64 firstBlock) internal pure returns (bytes32) {
        return keccak256(
            bytes(
                string.concat(
                    '{"answerType":"uint256","chainId":1,"question":"',
                    q,
                    '","v":1,"window":{"fromBlock":',
                    uint256(firstBlock).toString(),
                    ',"toBlock":',
                    uint256(firstBlock + 2).toString(),
                    "}}"
                )
            )
        );
    }

    function body(string memory q, uint64 firstBlock, address consumer) internal pure returns (bytes memory) {
        return bytes(
            string.concat(
                '{"v":1,"question":"',
                q,
                '","chainId":1,"window":{"fromBlock":',
                uint256(firstBlock).toString(),
                ',"toBlock":',
                uint256(firstBlock + 2).toString(),
                '},"answerType":"uint256","evidence":"chain","panelSize":5,"quorum":4,',
                '"toleranceBps":0,"validForSeconds":86400,"consumer":{"chainId":1,"verifyingContract":"',
                Strings.toHexString(consumer),
                '"}}'
            )
        );
    }
}
