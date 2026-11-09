// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PimdSwap} from "../../src/v1/PimdSwap.sol";
import {PimdRegistry} from "../../src/v1/PimdRegistry.sol";
import {MarketTypes as T} from "../../src/v1/libraries/MarketTypes.sol";
import {IPoolManager} from "../../src/v1/interfaces/IPoolManager.sol";
import {MockToken} from "./helpers/Mocks.sol";

contract MockPoolManager {
    bool public partialOutput;
    bool public reenter;
    bool public reentrySucceeded;
    bytes4 public reentryError;
    address public caller;
    uint256 public input;
    uint256 public output;
    uint256 public middleDebt;
    uint256 public middleCredit;
    uint256 private beforeBalance;

    function configure(bool p, bool r) external {
        partialOutput = p;
        reenter = r;
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        caller = msg.sender;
        input = 0;
        output = 0;
        middleDebt = 0;
        middleCredit = 0;
        if (reenter) {
            bytes memory reason;
            (reentrySucceeded, reason) =
                msg.sender.call(abi.encodeCall(PimdSwap.exactOutput, (uint32(1), uint256(1e6), uint256(1e18))));
            if (reason.length >= 4) reentryError = bytes4(reason);
        }
        result = PimdSwap(msg.sender).unlockCallback(data);
        require(middleDebt == middleCredit, "unsettled intermediate");
        caller = address(0);
    }

    function swap(T.PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        returns (int256)
    {
        require(msg.sender == caller && params.amountSpecified > 0, "exact output only");
        uint256 out = uint256(params.amountSpecified);
        uint256 paid;
        if (key.currency1 == T.USDC) {
            require(params.zeroForOne && key.fee == 500 && key.tickSpacing == 10 && key.hooks == address(0));
            paid = out * 1e12;
            middleDebt += paid;
            output = out;
        } else {
            require(
                !params.zeroForOne && key.currency1 == T.IMD && key.fee == 10000 && key.tickSpacing == 200
                    && key.hooks == address(0)
            );
            paid = out;
            middleCredit += out;
            input = paid;
        }
        if (partialOutput) out -= 1;
        int128 d0 = params.zeroForOne ? -int128(int256(paid)) : int128(int256(out));
        int128 d1 = params.zeroForOne ? int128(int256(out)) : -int128(int256(paid));
        return (int256(d0) << 128) | int256(uint256(uint128(d1)));
    }

    function sync(address currency) external {
        require(currency == T.IMD);
        beforeBalance = MockToken(T.IMD).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 received) {
        received = MockToken(T.IMD).balanceOf(address(this)) - beforeBalance;
        require(received == input, "input");
    }

    function take(address currency, address to, uint256 amount) external {
        require(currency == T.USDC && amount == output);
        MockToken(T.USDC).transfer(to, amount);
    }
}

contract SwapTest is Test {
    PimdRegistry internal registry;
    PimdSwap internal swapper;
    MockPoolManager internal manager;
    MockToken internal imd;
    MockToken internal usdc;

    function setUp() public {
        MockToken a = new MockToken(18);
        MockToken u = new MockToken(6);
        vm.etch(T.IMD, address(a).code);
        vm.etch(T.USDC, address(u).code);
        imd = MockToken(T.IMD);
        usdc = MockToken(T.USDC);
        MockPoolManager m = new MockPoolManager();
        vm.etch(T.MANAGER, address(m).code);
        manager = MockPoolManager(T.MANAGER);
        registry = new PimdRegistry(address(this));
        swapper = new PimdSwap(registry);
        imd.mint(address(this), 100e18);
        usdc.mint(T.MANAGER, 100e6);
        imd.approve(address(swapper), 100e18);
    }

    function test_exactOutputUsesBothPoolsAndReturnsUnusedInput() public {
        uint256 spent = swapper.exactOutput(1, 4e6, 5e18);
        assertEq(spent, 4e18);
        assertEq(usdc.balanceOf(address(this)), 4e6);
        assertEq(imd.balanceOf(address(this)), 96e18);
        assertEq(imd.balanceOf(address(swapper)), 0);
        assertEq(usdc.balanceOf(address(swapper)), 0);
        assertEq(manager.middleDebt(), manager.middleCredit());
    }

    function test_limitAndPartialOutputRevertAtomically() public {
        vm.expectRevert(PimdSwap.InvalidSwap.selector);
        swapper.exactOutput(1, 4e6, 3e18);
        assertEq(imd.balanceOf(address(this)), 100e18);
        assertEq(usdc.balanceOf(address(this)), 0);
        manager.configure(true, false);
        vm.expectRevert(PimdSwap.InvalidSwap.selector);
        swapper.exactOutput(1, 4e6, 5e18);
        assertEq(imd.balanceOf(address(this)), 100e18);
    }

    function test_callbackAuthenticationAndReentrancy() public {
        vm.expectRevert(PimdSwap.InvalidSwap.selector);
        swapper.unlockCallback("");
        vm.prank(T.MANAGER);
        vm.expectRevert(PimdSwap.InvalidSwap.selector);
        swapper.unlockCallback("");
        manager.configure(false, true);
        swapper.exactOutput(1, 4e6, 5e18);
        assertFalse(manager.reentrySucceeded());
        assertEq(manager.reentryError(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
    }

    function test_feeOnTransferInputAndMissingVersionRejected() public {
        imd.configure(false, true);
        vm.expectRevert(PimdSwap.InvalidSwap.selector);
        swapper.exactOutput(1, 4e6, 5e18);
        vm.expectRevert();
        swapper.exactOutput(2, 4e6, 5e18);
    }

    function testFuzz_exactOutputConservesInput(uint32 raw) public {
        uint256 amount = bound(raw, 1, 50e6);
        uint256 max = amount * 1e12 + 1e18;
        uint256 spent = swapper.exactOutput(1, amount, max);
        assertEq(imd.balanceOf(address(this)) + spent, 100e18);
        assertEq(usdc.balanceOf(address(this)), amount);
    }
}
