// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MarketFixture} from "./helpers/MarketFixture.sol";
import {PimdMarkets} from "../../src/v1/PimdMarkets.sol";
import {MarketTypes as T} from "../../src/v1/libraries/MarketTypes.sol";

contract MarketHandler is Test {
    PimdMarkets internal markets;
    PimdMarkets.MarketSpec internal spec;
    address[3] internal users;
    bytes32 internal id;
    uint256 public successfulOrders;
    uint256 public successfulSplits;

    constructor(PimdMarkets m, PimdMarkets.MarketSpec memory s, address a, address b, address c) {
        markets = m;
        spec = s;
        users = [a, b, c];
        id = m.marketId(s);
    }

    function split(uint8 who, uint128 raw) external {
        uint128 q = uint128(bound(raw, 1, 200e6));
        vm.prank(users[who % 3]);
        try markets.split(spec, q) {
            ++successfulSplits;
        } catch {}
    }

    function merge(uint8 who, uint128 raw) external {
        address user = users[who % 3];
        (uint256 up, uint256 down) = markets.positions(id, user);
        uint256 max = up < down ? up : down;
        if (max == 0) return;
        uint128 q = uint128(bound(raw, 1, max));
        vm.prank(user);
        markets.merge(id, q);
    }

    function trade(uint8 who, uint8 side, uint128 rawQ, uint32 rawPrice, bool ioc, bool assetOnly) external {
        PimdMarkets.OrderInput memory i;
        i.action = PimdMarkets.Action(side % 4);
        i.quantity = uint128(bound(rawQ, 10e6, 200e6));
        i.limitPrice = uint128(bound(rawPrice, 1000, 30000) * 100);
        i.expiry = spec.start + 3600;
        i.maxSteps = 8;
        i.immediateOrCancel = ioc;
        i.assetOnly = assetOnly && i.action == PimdMarkets.Action.BuyDown;
        i.maxSwapInput = 200e18;
        i.feeBudget = (side % 4 == 1 || side % 4 == 3) ? 10e18 : 10e6;
        vm.prank(users[who % 3]);
        try markets.place(spec, i) returns (uint64) {
            ++successfulOrders;
        } catch {}
    }

    function cancel(uint64 raw) external {
        uint64 count = markets.nextOrderId() - 1;
        if (count == 0) return;
        uint64 orderId = uint64(bound(raw, 1, count));
        PimdMarkets.Order memory o = markets.order(orderId);
        if (!o.resting) return;
        vm.prank(o.trader);
        markets.cancel(orderId);
    }

    function withdraw(uint8 who, uint128 raw, bool asset) external {
        address user = users[who % 3];
        address token = asset ? T.IMD : T.USDC;
        uint256 free = markets.balance(user, token);
        if (free == 0) return;
        uint256 amount = bound(raw, 1, free);
        vm.prank(user);
        markets.withdraw(token, amount);
    }

    function deposit(uint8 who, bool asset) external {
        address user = users[who % 3];
        vm.prank(user);
        try markets.deposit(asset ? T.IMD : T.USDC, asset ? 1e18 : 1e6) {} catch {}
    }

    function continueMatching(uint8 steps) external {
        markets.matchMarket(id, uint8(bound(steps, 1, 64)));
    }
}

contract AccountingInvariantTest is MarketFixture {
    MarketHandler internal handler;

    function setUp() public override {
        super.setUp();
        _split(alice, 10e6);
        handler = new MarketHandler(markets, spec, alice, bob, carol);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.split.selector;
        selectors[1] = handler.merge.selector;
        selectors[2] = handler.trade.selector;
        selectors[3] = handler.cancel.selector;
        selectors[4] = handler.withdraw.selector;
        selectors[5] = handler.deposit.selector;
        selectors[6] = handler.continueMatching.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_everyCoinBelongsToFreeEscrowFeeOrCollateral() public view {
        _assertConservation(markets.nextOrderId() - 1);
    }

    function invariant_everyShareHasExactBacking() public view {
        uint256 up;
        uint256 down;
        address[3] memory users = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            (uint256 u, uint256 d) = markets.positions(mid, users[i]);
            up += u;
            down += d;
        }
        for (uint64 i = 1; i < markets.nextOrderId(); ++i) {
            PimdMarkets.Order memory o = markets.order(i);
            if (o.action == PimdMarkets.Action.SellUp) up += o.remaining;
            if (o.action == PimdMarkets.Action.SellDown) down += o.remaining;
        }
        PimdMarkets.Market memory m = markets.market(mid);
        assertEq(up, m.pairs);
        assertEq(down, m.pairs);
        assertEq(m.reserveUSDC, m.pairs);
        assertEq(m.reserveAsset, m.pairs * m.factor);
    }

    function invariant_bookIsSortedAndLinked() public view {
        uint64 bid = markets.bestBid(mid);
        uint64 ask = markets.bestAsk(mid);
        _book(bid, true);
        _book(ask, false);
    }

    function _book(uint64 id, bool bid) private view {
        uint64 previous;
        uint256 visited;
        while (id != 0) {
            PimdMarkets.Order memory o = markets.order(id);
            assertTrue(o.resting);
            assertEq(o.previous, previous);
            if (previous != 0) {
                PimdMarkets.Order memory p = markets.order(previous);
                if (bid) assertGe(p.limitPrice, o.limitPrice);
                else assertLe(p.limitPrice, o.limitPrice);
                if (p.limitPrice == o.limitPrice) assertLt(previous, id);
            }
            previous = id;
            id = o.next;
            assertLt(++visited, markets.nextOrderId());
        }
    }
}
