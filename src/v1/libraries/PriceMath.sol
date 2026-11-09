// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library PriceMath {
    function quote(uint256 amount, uint160 sqrt, bool zeroForOne) internal pure returns (uint256) {
        require(sqrt > 4295128739 && sqrt < 1461446703485210103287273052203988822378723970342, "sqrt range");
        if (sqrt <= type(uint128).max) {
            uint256 ratio = uint256(sqrt) * sqrt;
            return zeroForOne ? Math.mulDiv(amount, ratio, 1 << 192) : Math.mulDiv(amount, 1 << 192, ratio);
        }
        uint256 ratio128 = Math.mulDiv(sqrt, sqrt, 1 << 64);
        return zeroForOne ? Math.mulDiv(amount, ratio128, 1 << 128) : Math.mulDiv(amount, 1 << 128, ratio128);
    }

    function median(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        if (a > b) (a, b) = (b, a);
        if (b > c) (b, c) = (c, b);
        return a > b ? a : b;
    }
}
