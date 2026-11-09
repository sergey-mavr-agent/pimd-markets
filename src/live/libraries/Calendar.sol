// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Gregorian UTC month boundaries. All arithmetic is bounded to years 1970..9999.
library Calendar {
    function leap(uint256 y) internal pure returns (bool) {
        return y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
    }

    function yearStart(uint256 y) internal pure returns (uint256) {
        uint256 z = y - 1;
        return ((y - 1970) * 365 + (z / 4 - z / 100 + z / 400) - 477) * 1 days;
    }

    function monthBounds(uint256 t) internal pure returns (uint64 start, uint64 end) {
        require(t < 253402300800, "calendar range");
        uint256 y = 1970 + t / 365 days;
        while (yearStart(y) > t) --y;
        uint256 s = yearStart(y);
        uint256[12] memory lengths = [uint256(31), 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
        if (leap(y)) lengths[1] = 29;
        for (uint256 i; i < 12; ++i) {
            uint256 e = s + lengths[i] * 1 days;
            if (t < e) return (uint64(s), uint64(e));
            s = e;
        }
        revert("calendar");
    }
}
