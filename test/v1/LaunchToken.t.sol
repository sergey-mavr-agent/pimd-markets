// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../../src/v1/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;

    function setUp() public {
        token = new LaunchToken();
    }

    function test_fixedSupplyAndMetadata() public view {
        assertEq(token.name(), "pIMD");
        assertEq(token.symbol(), "pIMD");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzz_transferAndAllowance(uint128 raw) public {
        uint256 amount = bound(raw, 1, 1e27);
        address a = makeAddr("a");
        address b = makeAddr("b");
        token.transfer(a, amount);
        vm.prank(a);
        token.approve(b, amount);
        vm.prank(b);
        token.transferFrom(a, b, amount);
        assertEq(token.balanceOf(b), amount);
        assertEq(token.allowance(a, b), 0);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_cannotMintOrTransferToZeroOrOverspend() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(ok);
        vm.expectRevert();
        token.transfer(address(0), 1);
        vm.prank(makeAddr("empty"));
        vm.expectRevert();
        token.transfer(address(this), 1);
        assertEq(token.totalSupply(), 1e27);
    }
}
