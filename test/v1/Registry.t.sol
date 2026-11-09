// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PimdRegistry} from "../../src/v1/PimdRegistry.sol";
import {MarketTypes as T} from "../../src/v1/libraries/MarketTypes.sol";

contract RegistryTest is Test {
    PimdRegistry internal r;

    function setUp() public {
        r = new PimdRegistry(address(this));
    }

    function test_defaultPoolIdsAndEnumeration() public view {
        assertEq(r.assetCount(), 1);
        assertEq(r.periodCount(), 4);
        T.Asset memory a = r.asset(1);
        assertEq(a.token, T.IMD);
        assertEq(a.unitsPerShare, 1e18);
        assertEq(T.poolId(a.path[0]), 0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3);
        assertEq(T.poolId(a.path[1]), 0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27);
    }

    function test_hourDayAndMonday() public view {
        (uint64 s, uint64 e) = r.bounds(0, 1_800_000_123);
        assertEq(s, 1_800_000_000);
        assertEq(e - s, 3600);
        (s, e) = r.bounds(1, 1_800_000_123);
        assertEq(s % 86400, 0);
        assertEq(e - s, 86400);
        (s, e) = r.bounds(2, 1_800_000_123);
        assertEq((s / 86400 + 3) % 7, 0);
        assertEq(e - s, 604800);
    }

    function test_calendarLeapYearsAndCentury() public view {
        (uint64 s, uint64 e) = r.bounds(3, 1_709_251_200); // 2024-03-01
        assertEq(s, 1_709_251_200);
        assertEq(e - s, 31 days);
        (s, e) = r.bounds(3, 1_706_745_600); // 2024-02-01
        assertEq(s, 1_706_745_600);
        assertEq(e - s, 29 days);
        (s, e) = r.bounds(3, 4_105_123_200); // 2100-02-01
        assertEq(e - s, 28 days);
        (s, e) = r.bounds(3, 949_363_200); // 2000-02-01
        assertEq(e - s, 29 days);
        (s, e) = r.bounds(3, 0);
        assertEq(s, 0);
        assertEq(e, 31 days);
    }

    function testFuzz_calendarContainsTimestamp(uint64 raw) public view {
        uint64 t = uint64(bound(raw, 0, 253402300799));
        (uint64 s, uint64 e) = r.bounds(3, t);
        assertLe(s, t);
        assertGt(e, t);
        assertGe(e - s, 28 days);
        assertLe(e - s, 31 days);
    }

    function test_versioningAndAuthorization() public {
        T.Asset memory a = r.asset(1);
        a.maxOpenPairs = 100e6;
        a.unitsPerShare = 2e18;
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(PimdRegistry.Unauthorized.selector);
        r.configureAsset(a);
        assertEq(r.configureAsset(a), 2);
        assertEq(r.asset(1).unitsPerShare, 1e18);
        assertEq(r.asset(2).unitsPerShare, 2e18);
        assertEq(r.currentVersion(T.IMD), 2);
        assertEq(r.assetCount(), 1);
    }

    function test_rejectBadPathAndUnits() public {
        T.Asset memory a = r.asset(1);
        a.unitsPerShare = 1e18 + 1;
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        r.configureAsset(a);
        a = r.asset(1);
        a.path[1].currency1 = T.IMD;
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        r.configureAsset(a);
        a = r.asset(1);
        a.path[0].hooks = address(this);
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        r.configureAsset(a);
    }

    function test_customPeriodAndBoundary() public {
        uint32 id = r.addPeriod(900, 12);
        (uint64 s, uint64 e) = r.bounds(id, 1812);
        assertEq(s, 1812);
        assertEq(e, 2712);
        assertTrue(r.isBoundary(s));
        assertFalse(r.isBoundary(1813));
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        r.addPeriod(900, 12);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(PimdRegistry.Unauthorized.selector);
        r.addPeriod(1200, 1);
    }

    function test_futureAssetAllowsInitializationGuardButRejectsSwapHooks() public {
        T.Asset memory a;
        a.token = makeAddr("future-asset");
        a.unitsPerShare = 1e6;
        a.maxOpenPairs = 100e6;
        a.hops = 1;
        (address c0, address c1) = a.token < T.USDC ? (a.token, T.USDC) : (T.USDC, a.token);
        a.path[0] = T.PoolKey(c0, c1, 12500, 60, address(uint160(1 << 13)));
        uint32 version = r.configureAsset(a);
        assertEq(r.asset(version).token, a.token);
        a.path[0].hooks = address(uint160(1 << 7));
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        r.configureAsset(a);
    }
}
