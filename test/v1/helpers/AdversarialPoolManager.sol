// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PimdSwap} from "src/v1/PimdSwap.sol";
import {IPoolManager} from "src/v1/interfaces/IPoolManager.sol";
import {MarketTypes as T} from "src/v1/libraries/MarketTypes.sol";

/// @dev A deterministic manager double, not an AMM pricing model. Each currency unit is worth $1.
/// Every hop accrues signed currency debts; the unlock must end with every currency settled.
contract AdversarialPoolManager {
    enum Mode {
        Normal,
        WrongData,
        Replay,
        NoCallback,
        ZeroOutput,
        NegativeOutput,
        PositiveInput,
        PartialOutput,
        BadSettlement,
        ShortTake,
        WrongResult,
        Reenter
    }
    Mode public mode;
    T.Asset internal route;
    address internal caller;
    uint256 internal remainingHops;
    uint256 internal inputBefore;
    mapping(address => int256) public debt;
    bool public secondCallSucceeded;
    bytes4 public secondCallError;

    function setRoute(T.Asset calldata a) external {
        route = a;
    }

    function configure(Mode m) external {
        mode = m;
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(caller == address(0), "nested manager unlock");
        caller = msg.sender;
        remainingHops = route.hops;
        if (mode == Mode.NoCallback) {
            caller = address(0);
            return abi.encode(uint256(0));
        }
        if (mode == Mode.WrongData) return PimdSwap(msg.sender).unlockCallback(bytes.concat(data, hex"01"));
        if (mode == Mode.Reenter) {
            _secondCall(abi.encodeCall(PimdSwap.exactOutput, (uint32(1), uint256(1), uint256(1))));
        }
        result = PimdSwap(msg.sender).unlockCallback(data);
        if (mode == Mode.Replay) _secondCall(abi.encodeCall(PimdSwap.unlockCallback, (data)));
        require(remainingHops == 0, "missing hop");
        require(debt[route.token] == 0, "input debt");
        for (uint256 j; j < route.hops; ++j) {
            require(debt[route.path[j].currency0] == 0 && debt[route.path[j].currency1] == 0, "unsettled currency");
        }
        caller = address(0);
        if (mode == Mode.WrongResult) return abi.encode(abi.decode(result, (uint256)) + 1);
    }

    function _secondCall(bytes memory data) private {
        bytes memory reason;
        (secondCallSucceeded, reason) = caller.call(data);
        if (reason.length >= 4) secondCallError = bytes4(reason);
    }

    function swap(T.PoolKey calldata key, IPoolManager.SwapParams calldata p, bytes calldata hookData)
        external
        returns (int256)
    {
        require(msg.sender == caller && remainingHops != 0 && p.amountSpecified > 0, "swap context");
        require(hookData.length == 0 && T.poolId(key) == T.poolId(route.path[--remainingHops]), "route mismatch");
        require(
            p.sqrtPriceLimitX96 == (p.zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341),
            "price limit"
        );
        address output = p.zeroForOne ? key.currency1 : key.currency0;
        address input = p.zeroForOne ? key.currency0 : key.currency1;
        uint256 wanted = uint256(p.amountSpecified);
        uint256 owed = (wanted * _units(input) + _units(output) - 1) / _units(output);
        debt[input] -= int256(owed);
        debt[output] += int256(wanted);
        int128 outDelta = int128(int256(wanted));
        int128 inDelta = -int128(int256(owed));
        if (mode == Mode.ZeroOutput) outDelta = 0;
        if (mode == Mode.NegativeOutput) outDelta = -outDelta;
        if (mode == Mode.PositiveInput) inDelta = -inDelta;
        if (mode == Mode.PartialOutput) --outDelta;
        int128 d0 = p.zeroForOne ? inDelta : outDelta;
        int128 d1 = p.zeroForOne ? outDelta : inDelta;
        return (int256(d0) << 128) | int256(uint256(uint128(d1)));
    }

    function _units(address currency) private view returns (uint256) {
        if (currency == T.USDC) return 1e6;
        if (currency == route.token) return route.unitsPerShare;
        return 1e18;
    }

    function sync(address currency) external {
        require(msg.sender == caller && currency == route.token, "sync");
        inputBefore = IERC20(currency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 received) {
        require(msg.sender == caller, "settle caller");
        received = IERC20(route.token).balanceOf(address(this)) - inputBefore;
        debt[route.token] += int256(received);
        if (mode == Mode.BadSettlement) return received + 1;
    }

    function take(address currency, address to, uint256 amount) external {
        require(msg.sender == caller && currency == T.USDC, "take");
        debt[currency] -= int256(amount);
        IERC20(currency).transfer(to, mode == Mode.ShortTake ? amount - 1 : amount);
    }
}
