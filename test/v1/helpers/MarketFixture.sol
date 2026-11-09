// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PimdRegistry} from "../../../src/v1/PimdRegistry.sol";
import {PimdMarkets} from "../../../src/v1/PimdMarkets.sol";
import {BoundaryOracle} from "../../../src/v1/BoundaryOracle.sol";
import {PimdSwap} from "../../../src/v1/PimdSwap.sol";
import {MarketTypes as T} from "../../../src/v1/libraries/MarketTypes.sol";
import {MockToken, MockPrices, MockSwap} from "./Mocks.sol";

abstract contract MarketFixture is Test {
    PimdRegistry internal registry;
    PimdMarkets internal markets;
    MockPrices internal prices;
    MockSwap internal swapper;
    MockToken internal usdc;
    MockToken internal imd;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal owner = makeAddr("owner");
    uint64 internal start = 1_800_000_000;
    PimdMarkets.MarketSpec internal spec;
    bytes32 internal mid;

    function setUp() public virtual {
        vm.chainId(1);
        vm.warp(start + 60);
        vm.roll(27_000_000);
        MockToken u = new MockToken(6);
        MockToken a = new MockToken(18);
        vm.etch(T.USDC, address(u).code);
        vm.etch(T.IMD, address(a).code);
        usdc = MockToken(T.USDC);
        imd = MockToken(T.IMD);
        registry = new PimdRegistry(owner);
        prices = new MockPrices();
        swapper = new MockSwap();
        markets = new PimdMarkets(owner, registry, BoundaryOracle(address(prices)), PimdSwap(address(swapper)));
        prices.record(1, start, 1e18);
        spec = PimdMarkets.MarketSpec(T.IMD, 0, start, 0);
        mid = markets.marketId(spec);
        _fund(alice);
        _fund(bob);
        _fund(carol);
        usdc.mint(address(swapper), 1_000_000e6);
    }

    function _fund(address user) internal {
        usdc.mint(user, 1_000_000e6);
        imd.mint(user, 1_000_000e18);
        vm.startPrank(user);
        usdc.approve(address(markets), 1_000_000e6);
        imd.approve(address(markets), 1_000_000e18);
        markets.deposit(T.USDC, 100_000e6);
        markets.deposit(T.IMD, 100_000e18);
        vm.stopPrank();
    }

    function _input(PimdMarkets.Action action, uint128 quantity, uint128 price_)
        internal
        view
        returns (PimdMarkets.OrderInput memory i)
    {
        i.action = action;
        i.quantity = quantity;
        i.limitPrice = price_;
        i.expiry = start + 3600;
        i.feeBudget = (action == PimdMarkets.Action.BuyDown || action == PimdMarkets.Action.SellDown) ? 100e18 : 100e6;
        i.maxSteps = 64;
    }

    function _place(address who, PimdMarkets.Action action, uint128 quantity, uint128 price_)
        internal
        returns (uint64)
    {
        PimdMarkets.OrderInput memory i = _input(action, quantity, price_);
        vm.prank(who);
        return markets.place(spec, i);
    }

    function _split(address who, uint128 quantity) internal {
        vm.prank(who);
        markets.split(spec, quantity);
    }

    function _assertConservation(uint64 maxOrder) internal view {
        uint256 cash;
        uint256 asset;
        address[4] memory users = [alice, bob, carol, owner];
        for (uint256 i; i < users.length; ++i) {
            cash += markets.balance(users[i], T.USDC);
            asset += markets.balance(users[i], T.IMD);
        }
        for (uint64 i = 1; i <= maxOrder; ++i) {
            PimdMarkets.Order memory o = markets.order(i);
            cash += o.cash;
            asset += o.asset + o.swapBudget;
            if (o.action == PimdMarkets.Action.BuyDown || o.action == PimdMarkets.Action.SellDown) asset += o.fee;
            else cash += o.fee;
        }
        for (uint256 i; i < markets.marketCount(); ++i) {
            PimdMarkets.Market memory m = markets.market(markets.marketIds(i));
            cash += m.reserveUSDC;
            asset += m.reserveAsset;
        }
        assertEq(usdc.balanceOf(address(markets)), cash, "USDC conservation");
        assertEq(imd.balanceOf(address(markets)), asset, "asset conservation");
    }
}
