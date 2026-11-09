// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library MarketTypes {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    uint256 internal constant SHARE = 1e6;
    uint256 internal constant MAX_PRICE = 1e30;

    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct Asset {
        address token;
        uint128 unitsPerShare;
        uint128 maxOpenPairs;
        uint8 hops;
        PoolKey[3] path;
    }

    function poolId(PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function slot(PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId(key), uint256(6)));
    }
}
