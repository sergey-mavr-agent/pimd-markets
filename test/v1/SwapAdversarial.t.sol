// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockToken} from "./helpers/Mocks.sol";
import {AdversarialPoolManager as Manager} from "./helpers/AdversarialPoolManager.sol";
import {PimdRegistry} from "src/v1/PimdRegistry.sol";
import {PimdSwap} from "src/v1/PimdSwap.sol";
import {MarketTypes as T} from "src/v1/libraries/MarketTypes.sol";

abstract contract SwapAdversarialFixture is Test {
    MockToken internal imd;
    MockToken internal usdc;
    PimdRegistry internal registry;
    PimdSwap internal swapper;
    Manager internal manager;

    function setUp() public virtual {
        MockToken input = new MockToken(18);
        MockToken output = new MockToken(6);
        vm.etch(T.IMD, address(input).code);
        vm.etch(T.USDC, address(output).code);
        imd = MockToken(T.IMD);
        usdc = MockToken(T.USDC);
        Manager implementation = new Manager();
        vm.etch(T.MANAGER, address(implementation).code);
        manager = Manager(T.MANAGER);
        registry = new PimdRegistry(address(this));
        swapper = new PimdSwap(registry);
        manager.setRoute(registry.asset(1));
        imd.mint(address(this), 10_000e18);
        usdc.mint(T.MANAGER, 1_000_000e6);
        imd.approve(address(swapper), type(uint256).max);
    }
}

/// forge-config: default.fuzz.runs = 512
contract SwapAdversarialTest is SwapAdversarialFixture {
    function _balances() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                imd.balanceOf(address(this)),
                usdc.balanceOf(address(this)),
                imd.balanceOf(address(swapper)),
                usdc.balanceOf(address(swapper)),
                imd.balanceOf(T.MANAGER),
                usdc.balanceOf(T.MANAGER),
                imd.allowance(address(this), address(swapper))
            )
        );
    }

    function test_invalidAmountsRejectBeforeMovingTokens() public {
        bytes32 beforeBalances = _balances();
        vm.expectRevert(PimdSwap.InvalidSwap.selector);
        swapper.exactOutput(1, 0, 1e18);
        vm.expectRevert(PimdSwap.InvalidSwap.selector);
        swapper.exactOutput(1, uint256(uint128(type(int128).max)) + 1, 1e18);
        vm.expectRevert(PimdSwap.InvalidSwap.selector);
        swapper.exactOutput(1, 1, 0);
        assertEq(_balances(), beforeBalances);
    }

    function test_invalidManagerResponsesRevertEveryTokenMovement() public {
        bytes32 beforeBalances = _balances();
        for (uint8 i = 1; i <= uint8(Manager.Mode.WrongResult); ++i) {
            if (i == uint8(Manager.Mode.Replay)) continue;
            manager.configure(Manager.Mode(i));
            vm.expectRevert(PimdSwap.InvalidSwap.selector);
            swapper.exactOutput(1, 4e6, 5e18);
            assertEq(_balances(), beforeBalances, "rejected swap moved funds");
        }
    }

    function test_authenticationIsConsumedOnceAndNestedSwapIsRejected() public {
        manager.configure(Manager.Mode.Replay);
        swapper.exactOutput(1, 4e6, 5e18);
        assertFalse(manager.secondCallSucceeded());
        assertEq(manager.secondCallError(), PimdSwap.InvalidSwap.selector);
        manager.configure(Manager.Mode.Reenter);
        swapper.exactOutput(1, 4e6, 5e18);
        assertFalse(manager.secondCallSucceeded());
        assertEq(manager.secondCallError(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        vm.prank(T.MANAGER);
        vm.expectRevert(PimdSwap.InvalidSwap.selector);
        swapper.unlockCallback("");
    }

    function test_donatedBalancesCannotSubsidizeInputLimitOrBeRefundedToCaller() public {
        imd.mint(address(swapper), 1e18);
        usdc.mint(address(swapper), 1e6);
        bytes32 beforeBalances = _balances();
        vm.expectRevert(PimdSwap.InvalidSwap.selector);
        swapper.exactOutput(1, 4e6, 4e18 - 1);
        assertEq(_balances(), beforeBalances);
        uint256 spent = swapper.exactOutput(1, 4e6, 5e18);
        assertEq(spent, 4e18);
        assertEq(imd.balanceOf(address(swapper)), 1e18);
        assertEq(usdc.balanceOf(address(swapper)), 1e6);
        assertEq(usdc.balanceOf(address(this)), 4e6);
    }

    function test_oneAndThreeHopRoutesWithSixDecimalAsset() public {
        MockToken asset = new MockToken(6);
        MockToken intermediate = new MockToken(18);
        asset.mint(address(this), 100e6);
        asset.approve(address(swapper), type(uint256).max);
        T.Asset memory a;
        a.token = address(asset);
        a.unitsPerShare = 1e6;
        a.maxOpenPairs = 1e12;
        a.hops = 1;
        a.path[0] = _key(address(asset), T.USDC);
        uint32 version = registry.configureAsset(a);
        manager.setRoute(a);
        assertEq(swapper.exactOutput(version, 7e6, 10e6), 7e6);
        a.hops = 3;
        a.path[0] = _key(address(asset), address(intermediate));
        a.path[1] = _key(address(intermediate), address(0));
        a.path[2] = _key(address(0), T.USDC);
        version = registry.configureAsset(a);
        manager.setRoute(a);
        assertEq(swapper.exactOutput(version, 13e6, 20e6), 13e6);
        assertEq(asset.balanceOf(address(this)), 80e6);
        assertEq(usdc.balanceOf(address(this)), 20e6);
        assertEq(asset.balanceOf(address(swapper)), 0);
        assertEq(usdc.balanceOf(address(swapper)), 0);
        assertEq(manager.debt(address(intermediate)), 0);
        assertEq(manager.debt(address(0)), 0);
    }

    function _key(address a, address b) private pure returns (T.PoolKey memory) {
        return a < b ? T.PoolKey(a, b, 3000, 60, address(0)) : T.PoolKey(b, a, 3000, 60, address(0));
    }
}

contract SwapSequenceHandler is Test {
    PimdSwap public immutable swapper;
    Manager public immutable manager;
    MockToken internal immutable imd;
    MockToken internal immutable usdc;
    address[3] public users;
    uint256 public spent;
    uint256 public received;
    uint256 public donatedInput;
    uint256 public donatedOutput;

    constructor(PimdSwap s, Manager m, address[3] memory actors) {
        swapper = s;
        manager = m;
        imd = MockToken(T.IMD);
        usdc = MockToken(T.USDC);
        users = actors;
    }

    function swap(uint8 who, uint64 raw, uint64 extra, bool replay) external {
        address user = users[who % 3];
        uint256 held = imd.balanceOf(user);
        if (held < 1e12) return;
        uint256 maxOutput = held / 1e12;
        if (maxOutput > 50e6) maxOutput = 50e6;
        uint256 output = bound(raw, 1, maxOutput);
        uint256 required = output * 1e12;
        uint256 maximum = required + bound(extra, 0, held - required);
        manager.configure(replay ? Manager.Mode.Replay : Manager.Mode.Normal);
        uint256 inputBefore = imd.balanceOf(user);
        uint256 outputBefore = usdc.balanceOf(user);
        vm.prank(user);
        uint256 cost = swapper.exactOutput(1, output, maximum);
        assertEq(cost, required);
        assertLe(cost, maximum);
        assertEq(imd.balanceOf(user), inputBefore - cost);
        assertEq(usdc.balanceOf(user), outputBefore + output);
        if (replay) assertFalse(manager.secondCallSucceeded());
        spent += cost;
        received += output;
    }

    function rejectedSwap(uint8 who, uint64 raw, uint8 failure) external {
        address user = users[who % 3];
        uint256 maxOutput = imd.balanceOf(user) / 1e12;
        if (maxOutput == 0) return;
        if (maxOutput > 10e6) maxOutput = 10e6;
        uint256 output = bound(raw, 1, maxOutput);
        Manager.Mode[5] memory modes = [
            Manager.Mode.PartialOutput,
            Manager.Mode.BadSettlement,
            Manager.Mode.ShortTake,
            Manager.Mode.WrongData,
            Manager.Mode.WrongResult
        ];
        manager.configure(modes[failure % 5]);
        uint256 inputBefore = imd.balanceOf(user);
        uint256 outputBefore = usdc.balanceOf(user);
        vm.prank(user);
        vm.expectRevert(PimdSwap.InvalidSwap.selector);
        swapper.exactOutput(1, output, output * 1e12);
        assertEq(imd.balanceOf(user), inputBefore);
        assertEq(usdc.balanceOf(user), outputBefore);
    }

    function donate(uint8 who, uint64 raw, bool input) external {
        address user = users[who % 3];
        MockToken token = input ? imd : usdc;
        uint256 held = token.balanceOf(user);
        if (held == 0) return;
        uint256 cap = input ? 1e18 : 1e6;
        uint256 amount = bound(raw, 1, held < cap ? held : cap);
        vm.prank(user);
        token.transfer(address(swapper), amount);
        if (input) donatedInput += amount;
        else donatedOutput += amount;
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract SwapCustodyInvariantTest is SwapAdversarialFixture {
    SwapSequenceHandler internal handler;
    address[3] internal users;

    function setUp() public override {
        super.setUp();
        users = [makeAddr("swap-alice"), makeAddr("swap-bob"), makeAddr("swap-carol")];
        for (uint256 i; i < users.length; ++i) {
            imd.transfer(users[i], 1000e18);
            vm.prank(users[i]);
            imd.approve(address(swapper), type(uint256).max);
        }
        handler = new SwapSequenceHandler(swapper, manager, users);
        handler.swap(0, 1e6, 1e18, false);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.rejectedSwap.selector;
        selectors[2] = handler.donate.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_noEscrowRemainsAndDonationsCannotBeSpent() public view {
        assertEq(imd.balanceOf(address(swapper)), handler.donatedInput());
        assertEq(usdc.balanceOf(address(swapper)), handler.donatedOutput());
        assertEq(imd.balanceOf(T.MANAGER), handler.spent());
        assertEq(usdc.balanceOf(T.MANAGER) + handler.received(), 1_000_000e6);
        uint256 inputs;
        uint256 outputs;
        for (uint256 i; i < users.length; ++i) {
            inputs += imd.balanceOf(users[i]);
            outputs += usdc.balanceOf(users[i]);
        }
        assertEq(inputs + handler.spent() + handler.donatedInput(), 3000e18);
        assertEq(outputs + handler.donatedOutput(), handler.received());
        assertEq(manager.debt(T.IMD), 0);
        assertEq(manager.debt(T.USDC), 0);
        assertEq(manager.debt(address(0)), 0);
    }
}
