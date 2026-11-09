// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MarketTypes as T} from "./libraries/MarketTypes.sol";
import {PimdRegistry} from "./PimdRegistry.sol";
import {IPoolManager} from "./interfaces/IPoolManager.sol";

/// @notice Exact-output v4 swaps, using only a registry version's immutable path.
/// @dev Intermediate currencies are netted inside the PoolManager unlock, including native ETH.
contract PimdSwap is ReentrancyGuard {
    using SafeERC20 for IERC20;
    error InvalidSwap();
    PimdRegistry public immutable registry;
    bytes32 private active;
    event Swapped(address indexed payer, uint32 indexed version, uint256 input, uint256 output);

    constructor(PimdRegistry registry_) {
        if (address(registry_) == address(0)) revert InvalidSwap();
        registry = registry_;
    }

    function exactOutput(uint32 version, uint256 output, uint256 maxInput)
        external
        nonReentrant
        returns (uint256 spent)
    {
        if (output == 0 || output > uint256(uint128(type(int128).max)) || maxInput == 0) {
            revert InvalidSwap();
        }
        T.Asset memory a = registry.asset(version);
        uint256 beforeInput = IERC20(a.token).balanceOf(address(this));
        uint256 beforeOutput = IERC20(T.USDC).balanceOf(address(this));
        IERC20(a.token).safeTransferFrom(msg.sender, address(this), maxInput);
        if (IERC20(a.token).balanceOf(address(this)) - beforeInput != maxInput) revert InvalidSwap();
        bytes memory data = abi.encode(a, output, maxInput);
        active = keccak256(data);
        spent = abi.decode(IPoolManager(T.MANAGER).unlock(data), (uint256));
        active = bytes32(0);
        if (
            spent > maxInput || IERC20(T.USDC).balanceOf(address(this)) - beforeOutput != output
                || IERC20(a.token).balanceOf(address(this)) != beforeInput + maxInput - spent
        ) revert InvalidSwap();
        IERC20(T.USDC).safeTransfer(msg.sender, output);
        if (maxInput > spent) IERC20(a.token).safeTransfer(msg.sender, maxInput - spent);
        emit Swapped(msg.sender, version, spent, output);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != T.MANAGER || active == bytes32(0) || active != keccak256(data)) revert InvalidSwap();
        active = bytes32(0); // A single authenticated callback; recursive callbacks cannot spend the escrow.
        (T.Asset memory a, uint256 output, uint256 maxInput) = abi.decode(data, (T.Asset, uint256, uint256));
        uint256 required = output;
        address desired = T.USDC;
        for (uint256 i = a.hops; i > 0; --i) {
            T.PoolKey memory k = a.path[i - 1];
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
        if (desired != a.token || required > maxInput) revert InvalidSwap();
        IPoolManager(T.MANAGER).sync(a.token);
        IERC20(a.token).safeTransfer(T.MANAGER, required);
        if (IPoolManager(T.MANAGER).settle() != required) revert InvalidSwap();
        IPoolManager(T.MANAGER).take(T.USDC, address(this), output);
        return abi.encode(required);
    }
}
