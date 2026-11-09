// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "src/v1/LaunchToken.sol";

contract FixedSupplyHandler is Test {
    LaunchToken public immutable token;
    address[4] public users;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(LaunchToken t, address[4] memory actors) {
        token = t;
        users = actors;
        expectedBalance[actors[0]] = 1e27;
    }

    function transfer(uint8 from, uint8 to, uint256 raw) public {
        address sender = users[from % 4];
        address recipient = users[to % 4];
        uint256 amount = bound(raw, 0, expectedBalance[sender]);
        vm.prank(sender);
        assertTrue(token.transfer(recipient, amount));
        expectedBalance[sender] -= amount;
        expectedBalance[recipient] += amount;
    }

    function approve(uint8 who, uint8 spenderIndex, uint256 raw, bool unlimited) external {
        address owner = users[who % 4];
        address spender = users[spenderIndex % 4];
        uint256 allowance = unlimited ? type(uint256).max : bound(raw, 0, 1e27);
        vm.prank(owner);
        assertTrue(token.approve(spender, allowance));
        expectedAllowance[owner][spender] = allowance;
    }

    function transferFrom(uint8 who, uint8 spenderIndex, uint8 to, uint256 raw) external {
        address owner = users[who % 4];
        address spender = users[spenderIndex % 4];
        address recipient = users[to % 4];
        uint256 allowance = expectedAllowance[owner][spender];
        uint256 max = allowance < expectedBalance[owner] ? allowance : expectedBalance[owner];
        uint256 amount = bound(raw, 0, max);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, recipient, amount));
        expectedBalance[owner] -= amount;
        expectedBalance[recipient] += amount;
        if (allowance != type(uint256).max) expectedAllowance[owner][spender] -= amount;
    }

    function overdraw(uint8 who, uint8 to) external {
        address sender = users[who % 4];
        uint256 held = expectedBalance[sender];
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, sender, held, held + 1));
        token.transfer(users[to % 4], held + 1);
    }

    function exceedAllowance(uint8 who, uint8 spenderIndex, uint8 to) external {
        address owner = users[who % 4];
        address spender = users[spenderIndex % 4];
        uint256 allowed = expectedAllowance[owner][spender];
        if (allowed == type(uint256).max) return;
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, allowed + 1)
        );
        token.transferFrom(owner, users[to % 4], allowed + 1);
    }

    function forbiddenAdministrativeCall(uint8 who, uint8 action) external {
        string[7] memory signatures = [
            "mint(address,uint256)",
            "burn(uint256)",
            "pause()",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "setMinter(address)"
        ];
        vm.prank(users[who % 4]);
        (bool success,) = address(token).call(abi.encodeWithSignature(signatures[action % 7], users[who % 4], 1e27));
        assertFalse(success);
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract TokenInvariantTest is Test {
    LaunchToken internal token;
    FixedSupplyHandler internal handler;
    address[4] internal users;

    function setUp() public {
        token = new LaunchToken();
        users = [address(this), makeAddr("token-alice"), makeAddr("token-bob"), makeAddr("token-carol")];
        handler = new FixedSupplyHandler(token, users);
        handler.transfer(0, 1, 1e27 / 4);
        handler.transfer(0, 2, 1e27 / 4);
        handler.transfer(0, 3, 1e27 / 4);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.overdraw.selector;
        selectors[4] = handler.exceedAllowance.selector;
        selectors[5] = handler.forbiddenAdministrativeCall.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_fixedSupplyAndBalancesMatchIndependentTransferLedger() public view {
        uint256 sum;
        for (uint256 i; i < users.length; ++i) {
            uint256 actual = token.balanceOf(users[i]);
            assertEq(actual, handler.expectedBalance(users[i]));
            sum += actual;
            for (uint256 j; j < users.length; ++j) {
                assertEq(token.allowance(users[i], users[j]), handler.expectedAllowance(users[i], users[j]));
            }
        }
        assertEq(sum, 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(0)), 0);
    }
}

contract TokenEdgeTest is Test {
    LaunchToken internal token;
    address internal spender = makeAddr("spender");

    function setUp() public {
        token = new LaunchToken();
    }

    function test_zeroAndFullSupplySelfTransfersPreserveBalance() public {
        assertTrue(token.transfer(address(this), 0));
        assertTrue(token.transfer(address(this), 1e27));
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_failedTransferFromRestoresAllowanceAndBalances() public {
        token.approve(spender, type(uint256).max - 1);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), uint256(1e27), uint256(1e27 + 1)
            )
        );
        token.transferFrom(address(this), spender, 1e27 + 1);
        assertEq(token.allowance(address(this), spender), type(uint256).max - 1);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.balanceOf(spender), 0);
    }

    function test_zeroRecipientAndSpenderCannotBurnOrConsumeAllowance() public {
        token.approve(spender, 1e27);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(address(this), address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        assertEq(token.allowance(address(this), spender), 1e27);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_infiniteAllowancePersistsButFiniteAllowanceIsConsumed() public {
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(address(this), spender, 1e27 / 2);
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        token.approve(spender, 1e27 / 2);
        vm.prank(spender);
        token.transferFrom(address(this), spender, 1e27 / 2);
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(spender), 1e27);
    }
}
