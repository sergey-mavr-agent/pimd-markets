// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./vendor/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "./vendor/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "./vendor/openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MarketTypes as T} from "./libraries/MarketTypes.sol";
import {PimdRegistry} from "./PimdRegistry.sol";
import {IPoolManager} from "./interfaces/IPoolManager.sol";

/// @notice Exact-output Uniswap v4 swaps USDC <-> asset, using only a registry version's immutable path
/// (1-3 pools of PoolManager 0x000000000004444c5dc75cb358380d2e3de08a90).
/// @dev Intermediate currencies, native ETH included, are netted inside one PoolManager unlock.
/// The caller pays `maxInput` of the input coin up front and receives exactly `output` of the other
/// coin plus the unspent input back; a path that cannot deliver the output within `maxInput` reverts.
contract PimdSwap2 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InvalidSwap();

    PimdRegistry public immutable registry;
    bytes32 private active;

    event Swapped(address indexed payer, uint32 indexed version, bool indexed toUSDC, uint256 input, uint256 output);

    constructor(PimdRegistry registry_) {
        if (address(registry_) == address(0)) revert InvalidSwap();
        registry = registry_;
    }

    /// @notice Pays the version's asset token for exactly `output` USDC.
    function exactOutput(uint32 version, uint256 output, uint256 maxInput) external nonReentrant returns (uint256) {
        return _swap(version, true, output, maxInput);
    }

    /// @notice Pays USDC for exactly `output` of the version's asset token.
    function exactOutputAsset(uint32 version, uint256 output, uint256 maxInput)
        external
        nonReentrant
        returns (uint256)
    {
        return _swap(version, false, output, maxInput);
    }

    function _swap(uint32 version, bool toUSDC, uint256 output, uint256 maxInput) private returns (uint256 spent) {
        if (output == 0 || output > uint256(uint128(type(int128).max)) || maxInput == 0) {
            revert InvalidSwap();
        }
        T.Asset memory a = registry.asset(version);
        address inCoin = toUSDC ? a.token : T.USDC;
        address outCoin = toUSDC ? T.USDC : a.token;
        uint256 beforeInput = IERC20(inCoin).balanceOf(address(this));
        uint256 beforeOutput = IERC20(outCoin).balanceOf(address(this));
        IERC20(inCoin).safeTransferFrom(msg.sender, address(this), maxInput);
        if (IERC20(inCoin).balanceOf(address(this)) - beforeInput != maxInput) revert InvalidSwap();
        bytes memory data = abi.encode(a, toUSDC, output, maxInput);
        active = keccak256(data);
        spent = abi.decode(IPoolManager(T.MANAGER).unlock(data), (uint256));
        active = bytes32(0);
        if (
            spent > maxInput || IERC20(outCoin).balanceOf(address(this)) - beforeOutput != output
                || IERC20(inCoin).balanceOf(address(this)) != beforeInput + maxInput - spent
        ) revert InvalidSwap();
        IERC20(outCoin).safeTransfer(msg.sender, output);
        if (maxInput > spent) IERC20(inCoin).safeTransfer(msg.sender, maxInput - spent);
        emit Swapped(msg.sender, version, toUSDC, spent, output);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != T.MANAGER || active == bytes32(0) || active != keccak256(data)) revert InvalidSwap();
        active = bytes32(0); // A single authenticated callback; recursive callbacks cannot spend the escrow.
        (T.Asset memory a, bool toUSDC, uint256 output, uint256 maxInput) =
            abi.decode(data, (T.Asset, bool, uint256, uint256));
        uint256 required = output;
        address desired = toUSDC ? T.USDC : a.token;
        address inCoin = toUSDC ? a.token : T.USDC;
        // Exact output walks the path from the output coin back to the input coin.
        for (uint256 n; n < a.hops; ++n) {
            T.PoolKey memory k = a.path[toUSDC ? a.hops - 1 - n : n];
            bool zeroForOne = desired == k.currency1;
            if (!zeroForOne && desired != k.currency0) revert InvalidSwap();
            if (required > uint256(uint128(type(int128).max))) revert InvalidSwap();
            int256 delta = IPoolManager(T.MANAGER)
                .swap(
                    k,
                    IPoolManager.SwapParams(
                        zeroForOne,
                        int256(required),
                        zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
                    ),
                    ""
                );
            int128 d0 = int128(delta >> 128);
            int128 d1 = int128(delta);
            int128 outDelta = zeroForOne ? d1 : d0;
            int128 inDelta = zeroForOne ? d0 : d1;
            if (outDelta <= 0 || uint128(outDelta) != required || inDelta >= 0) revert InvalidSwap();
            required = uint256(-int256(inDelta));
            desired = zeroForOne ? k.currency0 : k.currency1;
        }
        if (desired != inCoin || required > maxInput) revert InvalidSwap();
        IPoolManager(T.MANAGER).sync(inCoin);
        IERC20(inCoin).safeTransfer(T.MANAGER, required);
        if (IPoolManager(T.MANAGER).settle() != required) revert InvalidSwap();
        IPoolManager(T.MANAGER).take(toUSDC ? T.USDC : a.token, address(this), output);
        return abi.encode(required);
    }
}
