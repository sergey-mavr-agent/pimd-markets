// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketTypes as T} from "./libraries/MarketTypes.sol";
import {Calendar} from "./libraries/Calendar.sol";

/// @notice Append-only asset configurations and period definitions. Markets pin their version.
contract PimdRegistry {
    error Unauthorized();
    error InvalidConfiguration();
    uint128 public constant DEFAULT_MAX_OPEN_PAIRS = 1_000_000e6;
    uint128 public constant MAX_UNITS_PER_SHARE = 1e24;
    uint128 public constant MAX_OPEN_PAIRS = 1e24;
    uint32 public constant MAX_PERIODS = 32;
    uint32 public constant MIN_CUSTOM_PERIOD = 5 minutes;
    uint32 public constant MAX_CUSTOM_PERIOD = 366 days;
    uint160 internal constant NON_INITIALIZATION_HOOK_FLAGS = (1 << 12) - 1;
    address public immutable owner;
    uint32 public assetVersionCount;
    address[] public assets;
    mapping(address => uint32) public currentVersion;
    mapping(uint32 => T.Asset) private versions;

    struct Period {
        uint32 secondsPerRound;
        uint32 offset;
        bool calendarMonth;
    }
    Period[] public periods;

    event AssetConfigured(address indexed token, uint32 indexed version, uint128 unitsPerShare, uint128 maxOpenPairs);
    event PeriodAdded(uint32 indexed id, uint32 secondsPerRound, uint32 offset, bool calendarMonth);

    constructor(address owner_) {
        if (owner_ == address(0)) revert InvalidConfiguration();
        owner = owner_;
        _period(3600, 0, false);
        _period(86400, 0, false);
        _period(604800, 345600, false); // Unix epoch Thursday; first Monday Jan 5.
        _period(0, 0, true);
        T.Asset memory a;
        a.token = T.IMD;
        a.unitsPerShare = 1e18;
        a.maxOpenPairs = DEFAULT_MAX_OPEN_PAIRS;
        a.hops = 2;
        a.path[0] = T.PoolKey(address(0), T.IMD, 10000, 200, address(0));
        a.path[1] = T.PoolKey(address(0), T.USDC, 500, 10, address(0));
        _configure(a);
    }

    function configureAsset(T.Asset calldata a) external returns (uint32) {
        if (msg.sender != owner) revert Unauthorized();
        return _configure(a);
    }

    function _configure(T.Asset memory a) private returns (uint32 v) {
        if (
            a.token == address(0) || a.token == T.USDC || a.unitsPerShare < 1e6 || a.unitsPerShare > MAX_UNITS_PER_SHARE
                || a.unitsPerShare % 1e6 != 0 || a.maxOpenPairs < 1e6 || a.maxOpenPairs > MAX_OPEN_PAIRS || a.hops == 0
                || a.hops > 3
        ) revert InvalidConfiguration();
        address cursor = a.token;
        address[4] memory seen;
        seen[0] = cursor;
        for (uint256 i; i < a.hops; ++i) {
            T.PoolKey memory k = a.path[i];
            if (
                k.currency0 >= k.currency1 || k.fee > 100_000 || k.tickSpacing <= 0
                    || (uint160(k.hooks) & NON_INITIALIZATION_HOOK_FLAGS) != 0
            ) {
                revert InvalidConfiguration();
            }
            if (cursor == k.currency0) cursor = k.currency1;
            else if (cursor == k.currency1) cursor = k.currency0;
            else revert InvalidConfiguration();
            for (uint256 j; j <= i; ++j) {
                if (seen[j] == cursor) revert InvalidConfiguration();
            }
            seen[i + 1] = cursor;
        }
        if (cursor != T.USDC) revert InvalidConfiguration();
        if (
            a.token == T.IMD
                && (a.hops != 2
                    || T.poolId(a.path[0]) != 0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3
                    || T.poolId(a.path[1]) != 0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27)
        ) {
            revert InvalidConfiguration();
        }
        if (currentVersion[a.token] == 0) assets.push(a.token);
        v = ++assetVersionCount;
        versions[v] = a;
        currentVersion[a.token] = v;
        emit AssetConfigured(a.token, v, a.unitsPerShare, a.maxOpenPairs);
    }

    function addPeriod(uint32 duration, uint32 offset) external returns (uint32) {
        if (msg.sender != owner) revert Unauthorized();
        if (
            duration < MIN_CUSTOM_PERIOD || duration > MAX_CUSTOM_PERIOD || offset >= duration
                || periods.length >= MAX_PERIODS
        ) {
            revert InvalidConfiguration();
        }
        for (uint256 i; i < periods.length; ++i) {
            if (!periods[i].calendarMonth && periods[i].secondsPerRound == duration && periods[i].offset == offset) {
                revert InvalidConfiguration();
            }
        }
        return _period(duration, offset, false);
    }

    function _period(uint32 duration, uint32 offset, bool monthly) private returns (uint32 id) {
        id = uint32(periods.length);
        periods.push(Period(duration, offset, monthly));
        emit PeriodAdded(id, duration, offset, monthly);
    }

    function asset(uint32 version) external view returns (T.Asset memory) {
        if (version == 0 || version > assetVersionCount) revert InvalidConfiguration();
        return versions[version];
    }

    function assetCount() external view returns (uint256) {
        return assets.length;
    }

    function periodCount() external view returns (uint256) {
        return periods.length;
    }

    function isBoundary(uint64 timestamp) external view returns (bool) {
        for (uint32 i; i < periods.length; ++i) {
            if (!periods[i].calendarMonth && timestamp < periods[i].offset) continue;
            (uint64 start,) = bounds(i, timestamp);
            if (start == timestamp) return true;
        }
        return false;
    }

    function bounds(uint32 period, uint64 timestamp) public view returns (uint64 start, uint64 end) {
        Period memory p = periods[period];
        if (p.calendarMonth) return Calendar.monthBounds(timestamp);
        if (timestamp < p.offset) revert InvalidConfiguration();
        start = uint64((timestamp - p.offset) / p.secondsPerRound * p.secondsPerRound + p.offset);
        end = start + p.secondsPerRound;
    }
}
