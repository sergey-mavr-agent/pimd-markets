// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PimdRegistry} from "src/v1/PimdRegistry.sol";
import {MarketTypes as T} from "src/v1/libraries/MarketTypes.sol";
import {MockToken} from "./helpers/Mocks.sol";

/// forge-config: default.fuzz.runs = 512
contract RegistryPropertiesTest is Test {
    PimdRegistry internal registry;
    address internal owner = makeAddr("registry-owner");

    function setUp() public {
        registry = new PimdRegistry(owner);
    }

    function test_everyOwnerMutationRejectsForeignCaller() public {
        T.Asset memory a = registry.asset(1);
        vm.expectRevert(PimdRegistry.Unauthorized.selector);
        registry.configureAsset(a);
        vm.expectRevert(PimdRegistry.Unauthorized.selector);
        registry.addPeriod(300, 0);
        assertEq(registry.assetVersionCount(), 1);
        assertEq(registry.periodCount(), 4);
        assertEq(registry.owner(), owner);
    }

    function test_invalidAssetConfigurationsNeverAppendVersions() public {
        bytes32 initial = keccak256(abi.encode(registry.asset(1)));
        for (uint8 fault; fault < 14; ++fault) {
            T.Asset memory a = registry.asset(1);
            if (fault == 0) a.token = address(0);
            if (fault == 1) a.token = T.USDC;
            if (fault == 2) a.unitsPerShare = 1e6 - 1;
            if (fault == 3) a.unitsPerShare = 1e24 + 1e6;
            if (fault == 4) a.unitsPerShare = 1e18 + 1;
            if (fault == 5) a.maxOpenPairs = 1e6 - 1;
            if (fault == 6) a.maxOpenPairs = 1e24 + 1;
            if (fault == 7) a.hops = 0;
            if (fault == 8) a.hops = 4;
            if (fault == 9) a.path[0].fee = 100_001;
            if (fault == 10) a.path[0].tickSpacing = 0;
            if (fault == 11) a.path[0].tickSpacing = -1;
            if (fault == 12) a.path[0].hooks = address(uint160(1));
            if (fault == 13) (a.path[0].currency0, a.path[0].currency1) = (a.path[0].currency1, a.path[0].currency0);
            vm.prank(owner);
            vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
            registry.configureAsset(a);
            assertEq(registry.assetVersionCount(), 1);
            assertEq(registry.currentVersion(T.IMD), 1);
            assertEq(registry.assetCount(), 1);
            assertEq(keccak256(abi.encode(registry.asset(1))), initial);
        }
    }

    function test_disconnectedCyclicAndNonUSDCRoutesAreRejected() public {
        MockToken token = new MockToken(18);
        T.Asset memory a;
        a.token = address(token);
        a.unitsPerShare = 1e18;
        a.maxOpenPairs = 1e12;
        a.hops = 1;
        a.path[0] = _key(address(token), T.IMD);
        vm.prank(owner);
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        registry.configureAsset(a); // Does not reach USDC.
        a.hops = 2;
        a.path[1] = _key(address(0), T.USDC);
        vm.prank(owner);
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        registry.configureAsset(a); // Disconnected second hop.
        a.hops = 3;
        a.path[1] = a.path[0];
        a.path[2] = _key(address(token), T.USDC);
        vm.prank(owner);
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        registry.configureAsset(a); // A -> IMD -> A -> USDC repeats the asset.
        assertEq(registry.assetCount(), 1);
    }

    function test_IMDRouteIsPinnedEvenForOwner() public {
        T.Asset memory a = registry.asset(1);
        a.path[0].fee = 500;
        vm.prank(owner);
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        registry.configureAsset(a);
        a = registry.asset(1);
        a.path[1].tickSpacing = 60;
        vm.prank(owner);
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        registry.configureAsset(a);
    }

    function test_periodLimitDuplicatesAndBoundsAreAtomic() public {
        vm.startPrank(owner);
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        registry.addPeriod(3600, 0);
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        registry.addPeriod(299, 0);
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        registry.addPeriod(366 days + 1, 0);
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        registry.addPeriod(300, 300);
        assertEq(registry.periodCount(), 4);
        for (uint32 i; i < 28; ++i) {
            assertEq(registry.addPeriod(300 + i, 0), 4 + i);
        }
        assertEq(registry.periodCount(), 32);
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        registry.addPeriod(400, 0);
        vm.stopPrank();
        assertEq(registry.periodCount(), 32);
    }

    function testFuzz_assetVersionsAreAppendOnly(uint64 rawUnits, uint128 rawCap) public {
        T.Asset memory original = registry.asset(1);
        T.Asset memory next = registry.asset(1);
        next.unitsPerShare = uint128(bound(rawUnits, 1, 1e18) * 1e6);
        next.maxOpenPairs = uint128(bound(rawCap, 1e6, 1e24));
        vm.prank(owner);
        uint32 version = registry.configureAsset(next);
        assertEq(version, 2);
        assertEq(keccak256(abi.encode(registry.asset(1))), keccak256(abi.encode(original)));
        assertEq(keccak256(abi.encode(registry.asset(2))), keccak256(abi.encode(next)));
        assertEq(registry.currentVersion(T.IMD), 2);
        assertEq(registry.assetCount(), 1);
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        registry.asset(0);
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        registry.asset(3);
    }

    function testFuzz_customPeriodPartitionsTime(uint32 rawDuration, uint32 rawOffset, uint64 rawTime) public {
        uint32 duration = uint32(bound(rawDuration, 300, 366 days));
        // Offset one or greater avoids duplicating the built-in hour/day/week definitions.
        uint32 offset = uint32(bound(rawOffset, 1, duration - 1));
        if (duration == 604800 && offset == 345600) ++offset;
        vm.prank(owner);
        uint32 id = registry.addPeriod(duration, offset);
        uint64 time = uint64(bound(rawTime, offset, 253370764799));
        (uint64 s, uint64 e) = registry.bounds(id, time);
        assertLe(s, time);
        assertGt(e, time);
        assertEq(e - s, duration);
        assertEq((s - offset) % duration, 0);
        (uint64 nextStart,) = registry.bounds(id, e);
        assertEq(nextStart, e);
        assertTrue(registry.isBoundary(s));
    }

    function testFuzz_calendarMonthsAreContiguousAndStableWithinRound(uint64 rawTime) public view {
        uint64 time = uint64(bound(rawTime, 0, 253370764799));
        (uint64 s, uint64 e) = registry.bounds(3, time);
        (uint64 atStart, uint64 endAtStart) = registry.bounds(3, s);
        (uint64 lastStart, uint64 lastEnd) = registry.bounds(3, e - 1);
        (uint64 nextStart, uint64 nextEnd) = registry.bounds(3, e);
        assertEq(s, atStart);
        assertEq(s, lastStart);
        assertEq(e, endAtStart);
        assertEq(e, lastEnd);
        assertEq(e, nextStart);
        assertGe(nextEnd - nextStart, 28 days);
        assertLe(nextEnd - nextStart, 31 days);
    }

    function _key(address a, address b) private pure returns (T.PoolKey memory) {
        return a < b ? T.PoolKey(a, b, 3000, 60, address(0)) : T.PoolKey(b, a, 3000, 60, address(0));
    }
}
