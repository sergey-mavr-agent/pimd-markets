// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MarketFixture} from "./helpers/MarketFixture.sol";
import {MockToken, MockPrices} from "./helpers/Mocks.sol";
import {PimdMarkets} from "src/v1/PimdMarkets.sol";
import {MarketTypes as T} from "src/v1/libraries/MarketTypes.sol";

contract MarketLifecycleHandler is Test {
    PimdMarkets public immutable markets;
    MockPrices public immutable prices;
    address[4] public users;
    PimdMarkets.MarketSpec[] internal specs;
    bytes32[] public ids;
    mapping(bytes32 => uint8) public terminalOutcome;
    uint256 public depositedCash;
    uint256 public depositedAsset;
    uint256 public withdrawnCash;
    uint256 public withdrawnAsset;
    uint256 public donatedCash;
    uint256 public donatedAsset;
    uint256 public trades;
    uint256 public claims;
    uint256 public frozenRefusals;

    constructor(PimdMarkets m, MockPrices p, address[4] memory actors, PimdMarkets.MarketSpec[] memory s) {
        markets = m;
        prices = p;
        users = actors;
        for (uint256 j; j < s.length; ++j) {
            specs.push(s[j]);
            ids.push(m.marketId(s[j]));
        }
    }

    function split(uint8 who, uint8 which, uint128 raw) external {
        uint256 k = which % ids.length;
        address user = users[who % 3];
        PimdMarkets.Market memory m = markets.market(ids[k]);
        if (m.outcome != PimdMarkets.Outcome.Active) return;
        uint256 max = _min(markets.balance(user, T.USDC), markets.balance(user, T.IMD) / m.factor);
        max = _min(max, _min(m.maxPairs - m.pairs, 50e6));
        if (max == 0) return;
        uint128 q = uint128(bound(raw, 1, max));
        bool frozen = m.ladderStrike == 0 && !prices.priceable(m.version, m.start);
        vm.prank(user);
        if (frozen) {
            // The start price can no longer exist: the market is a certain void and refuses new pairs.
            vm.expectRevert(PimdMarkets.InvalidMarket.selector);
            markets.split(specs[k], q);
            ++frozenRefusals;
            return;
        }
        markets.split(specs[k], q);
    }

    function merge(uint8 who, uint8 which, uint128 raw) external {
        bytes32 id = ids[which % ids.length];
        if (markets.market(id).outcome != PimdMarkets.Outcome.Active) return;
        address user = users[who % 3];
        (uint256 up, uint256 down) = markets.positions(id, user);
        uint256 max = _min(up, down);
        if (max == 0) return;
        uint128 q = uint128(bound(raw, 1, max));
        vm.prank(user);
        markets.merge(id, q);
    }

    function trade(uint8 who, uint8 which, uint8 action, uint128 rawQ, uint32 rawX, bool ioc) external {
        uint256 k = which % ids.length;
        PimdMarkets.Market memory m = markets.market(ids[k]);
        if (m.outcome != PimdMarkets.Outcome.Active || block.timestamp + 300 > m.end) return;
        address user = users[who % 3];
        // Enough for the largest generated notional, rounding reserve and fee budget.
        if (markets.balance(user, T.USDC) < 300e6 || markets.balance(user, T.IMD) < 500e18) return;
        PimdMarkets.OrderInput memory i;
        i.action = PimdMarkets.Action(action % 4);
        i.quantity = uint128(bound(rawQ, 10e6, 50e6));
        i.limitPrice = uint128(bound(rawX, 1000, 30000) * 100);
        i.expiry = m.end;
        i.maxSteps = 8;
        i.immediateOrCancel = ioc;
        i.feeBudget = action % 2 == 1 ? 100e18 : 100e6;
        (uint256 up, uint256 down) = markets.positions(ids[k], user);
        if (i.action == PimdMarkets.Action.SellUp && up < i.quantity) return;
        if (i.action == PimdMarkets.Action.SellDown && down < i.quantity) return;
        if (m.pairs + i.quantity > m.maxPairs) return;
        vm.prank(user);
        markets.place(specs[k], i);
        ++trades;
    }

    function cancel(uint64 raw) external {
        uint64 id = uint64(bound(raw, 1, markets.nextOrderId() - 1));
        PimdMarkets.Order memory o = markets.order(id);
        if (!o.resting) return;
        vm.prank(o.trader);
        markets.cancel(id);
    }

    function expire(uint64 raw) external {
        uint64[] memory batch = new uint64[](2);
        batch[0] = uint64(bound(raw, 1, markets.nextOrderId() - 1));
        batch[1] = batch[0]; // A repeated id must not refund twice.
        markets.expire(batch);
    }

    function continueMatching(uint8 which, uint8 steps) external {
        bytes32 id = ids[which % ids.length];
        PimdMarkets.Market memory m = markets.market(id);
        if (m.outcome != PimdMarkets.Outcome.Active || block.timestamp >= m.end) return;
        markets.matchMarket(id, uint8(bound(steps, 1, 64)));
    }

    function moveTime(uint16 secondsForward) external {
        vm.warp(block.timestamp + bound(secondsForward, 1, 900));
    }

    function publishClose(uint8 which, uint8 direction) external {
        bytes32 id = ids[which % ids.length];
        PimdMarkets.Market memory m = markets.market(id);
        if (block.timestamp < m.end) return;
        // The real oracle is tested separately; here it supplies immutable positive prices.
        if (prices.price(m.version, m.start) == 0) prices.record(m.version, m.start, 1e18);
        if (prices.price(m.version, m.end) == 0) {
            uint256 close = direction % 3 == 0 ? 0.5e18 : direction % 3 == 1 ? 1e18 : 2e18;
            prices.record(m.version, m.end, close);
        }
    }

    function settle(uint8 which, bool waitForVoid) external {
        bytes32 id = ids[which % ids.length];
        PimdMarkets.Market memory m = markets.market(id);
        if (m.outcome != PimdMarkets.Outcome.Active) return;
        if (waitForVoid && block.timestamp < uint256(m.end) + 3 days) vm.warp(uint256(m.end) + 3 days);
        if (!_ready(m)) return;
        markets.settle(id);
        terminalOutcome[id] = uint8(markets.market(id).outcome);
    }

    function claim(uint8 who, uint8 which, uint128 rawUp, uint128 rawDown) external {
        bytes32 id = ids[which % ids.length];
        PimdMarkets.Market memory m = markets.market(id);
        if (m.outcome == PimdMarkets.Outcome.Active && !_ready(m)) return;
        address user = users[who % 3];
        (uint256 up, uint256 down) = markets.positions(id, user);
        if (up + down == 0) return;
        uint256 takeUp = up == 0 ? 0 : bound(rawUp, 1, up);
        uint256 takeDown = down == 0 ? 0 : bound(rawDown, 1, down);
        vm.prank(user);
        markets.claim(id, takeUp, takeDown);
        terminalOutcome[id] = uint8(markets.market(id).outcome);
        ++claims;
    }

    function deposit(uint8 who, bool asset, uint128 raw) external {
        address user = users[who % 3];
        address coin = asset ? T.IMD : T.USDC;
        uint256 max = MockToken(coin).balanceOf(user);
        if (max == 0) return;
        uint256 amount = bound(raw, 1, _min(max, asset ? 100e18 : 100e6));
        vm.startPrank(user);
        MockToken(coin).approve(address(markets), amount);
        markets.deposit(coin, amount);
        vm.stopPrank();
        if (asset) depositedAsset += amount;
        else depositedCash += amount;
    }

    function withdraw(uint8 who, bool asset, uint128 raw) external {
        address user = users[who % 4]; // Includes the fee recipient, who has no special withdrawal privilege.
        address coin = asset ? T.IMD : T.USDC;
        uint256 max = markets.balance(user, coin);
        if (max == 0) return;
        uint256 amount = bound(raw, 1, max);
        vm.prank(user);
        markets.withdraw(coin, amount);
        if (asset) withdrawnAsset += amount;
        else withdrawnCash += amount;
    }

    function donate(uint8 who, bool asset, uint64 raw) external {
        address user = users[who % 3];
        address coin = asset ? T.IMD : T.USDC;
        uint256 max = MockToken(coin).balanceOf(user);
        if (max == 0) return;
        uint256 amount = bound(raw, 1, _min(max, asset ? 1e18 : 1e6));
        uint256 free = markets.balance(user, coin);
        vm.prank(user);
        MockToken(coin).transfer(address(markets), amount);
        assertEq(markets.balance(user, coin), free, "donation is not a deposit");
        if (asset) donatedAsset += amount;
        else donatedCash += amount;
    }

    function _ready(PimdMarkets.Market memory m) private view returns (bool) {
        if (block.timestamp < m.end) return false;
        return block.timestamp >= uint256(m.end) + 3 days
            || ((m.ladderStrike != 0 || prices.price(m.version, m.start) != 0) && prices.price(m.version, m.end) != 0);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}

/// @notice Checks all liabilities, including shares still escrowed when a market settles.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract MarketLifecycleInvariantTest is MarketFixture {
    MarketLifecycleHandler internal handler;
    bytes32[3] internal ids;
    uint32[3] internal versions;
    uint128[3] internal factors;
    uint256 internal initialCash;
    uint256 internal initialAsset;

    function setUp() public override {
        super.setUp();
        PimdMarkets.MarketSpec[] memory specs = new PimdMarkets.MarketSpec[](3);
        specs[0] = spec;
        specs[1] = PimdMarkets.MarketSpec(T.IMD, 0, start, 1.5e18);
        specs[2] = PimdMarkets.MarketSpec(T.IMD, 0, start + 3600, 0);
        for (uint256 j; j < 3; ++j) {
            if (j == 2) {
                T.Asset memory a = registry.asset(1);
                a.unitsPerShare = 2e18;
                vm.prank(owner);
                registry.configureAsset(a);
                prices.record(2, start, 1e18);
            }
            spec = specs[j];
            _split(alice, 20e6);
            _split(bob, 20e6);
            _split(carol, 20e6);
            _place(alice, PimdMarkets.Action.SellUp, 4e6, 2e6);
            _place(bob, PimdMarkets.Action.SellDown, 6e6, 200_000);
            ids[j] = markets.marketId(spec);
            versions[j] = markets.market(ids[j]).version;
            factors[j] = markets.market(ids[j]).factor;
        }
        initialCash = usdc.balanceOf(address(markets));
        initialAsset = imd.balanceOf(address(markets));
        handler = new MarketLifecycleHandler(markets, prices, [alice, bob, carol, owner], specs);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = handler.split.selector;
        selectors[1] = handler.merge.selector;
        selectors[2] = handler.trade.selector;
        selectors[3] = handler.cancel.selector;
        selectors[4] = handler.expire.selector;
        selectors[5] = handler.continueMatching.selector;
        selectors[6] = handler.moveTime.selector;
        selectors[7] = handler.publishClose.selector;
        selectors[8] = handler.settle.selector;
        selectors[9] = handler.claim.selector;
        selectors[10] = handler.deposit.selector;
        selectors[11] = handler.withdraw.selector;
        selectors[12] = handler.donate.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_custodyMatchesEveryLiabilityAndExternalFlow() public view {
        uint256 cash;
        uint256 asset;
        address[4] memory users = [alice, bob, carol, owner];
        for (uint256 j; j < users.length; ++j) {
            cash += markets.balance(users[j], T.USDC);
            asset += markets.balance(users[j], T.IMD);
        }
        for (uint64 j = 1; j < markets.nextOrderId(); ++j) {
            PimdMarkets.Order memory o = markets.order(j);
            cash += o.cash;
            asset += o.asset + o.swapBudget;
            if (uint8(o.action) % 2 == 1) asset += o.fee;
            else cash += o.fee;
            if (!o.resting) {
                assertEq(o.remaining, 0);
                assertEq(o.cash + o.asset + o.swapBudget + o.fee, 0);
                assertEq(o.previous, 0);
                assertEq(o.next, 0);
            }
        }
        for (uint256 j; j < ids.length; ++j) {
            PimdMarkets.Market memory m = markets.market(ids[j]);
            cash += m.reserveUSDC;
            asset += m.reserveAsset;
        }
        assertEq(usdc.balanceOf(address(markets)), cash + handler.donatedCash());
        assertEq(imd.balanceOf(address(markets)), asset + handler.donatedAsset());
        assertEq(
            usdc.balanceOf(address(markets)) + handler.withdrawnCash(),
            initialCash + handler.depositedCash() + handler.donatedCash()
        );
        assertEq(
            imd.balanceOf(address(markets)) + handler.withdrawnAsset(),
            initialAsset + handler.depositedAsset() + handler.donatedAsset()
        );
    }

    function test_handlerExercisesTradingWinningClaimsAndMissingPriceRefunds() public {
        handler.trade(2, 0, 0, 10e6, 20_000, false);
        assertEq(handler.trades(), 1);
        assertGt(markets.balance(owner, T.USDC), 0, "the seeded sell order must actually fill");
        for (uint256 j; j < 4; ++j) {
            handler.moveTime(900);
        }
        handler.publishClose(0, 2);
        handler.settle(0, false);
        assertEq(uint8(markets.market(ids[0]).outcome), uint8(PimdMarkets.Outcome.Up));
        handler.expire(2);
        assertFalse(markets.order(2).resting);
        handler.claim(2, 0, 10e6, 10e6);
        // Market 2 never got its start price and the proposal window has closed: new pairs are refused.
        vm.warp(uint256(start) + 7200 + 3 days);
        handler.split(0, 2, 1e6);
        assertEq(handler.frozenRefusals(), 1);
        handler.settle(2, true);
        assertEq(uint8(markets.market(ids[2]).outcome), uint8(PimdMarkets.Outcome.Refund));
        handler.claim(1, 2, 1, 1);
        assertEq(handler.claims(), 2);
        invariant_custodyMatchesEveryLiabilityAndExternalFlow();
        invariant_reservesCoverExactlyOutstandingClaimsAndSnapshotsStayPinned();
        afterInvariant();
    }

    function invariant_reservesCoverExactlyOutstandingClaimsAndSnapshotsStayPinned() public view {
        address[3] memory users = [alice, bob, carol];
        for (uint256 j; j < ids.length; ++j) {
            bytes32 id = ids[j];
            uint256 up;
            uint256 down;
            for (uint256 k; k < users.length; ++k) {
                (uint256 u, uint256 d) = markets.positions(id, users[k]);
                up += u;
                down += d;
            }
            for (uint64 k = 1; k < markets.nextOrderId(); ++k) {
                PimdMarkets.Order memory o = markets.order(k);
                if (o.market != id || !o.resting) continue;
                if (o.action == PimdMarkets.Action.SellUp) up += o.remaining;
                if (o.action == PimdMarkets.Action.SellDown) down += o.remaining;
            }
            PimdMarkets.Market memory m = markets.market(id);
            assertEq(m.version, versions[j]);
            assertEq(m.factor, factors[j]);
            assertLe(m.pairs, m.maxPairs);
            if (m.outcome == PimdMarkets.Outcome.Active) {
                assertEq(up, down);
                assertEq(up, m.pairs);
            }
            uint256 cashOwed = m.outcome == PimdMarkets.Outcome.Down ? down : up;
            uint256 assetOwed = (m.outcome == PimdMarkets.Outcome.Up ? up : down) * m.factor;
            assertEq(m.reserveUSDC, cashOwed, "USDC redemption liabilities");
            assertEq(m.reserveAsset, assetOwed, "asset redemption liabilities");
            if (handler.terminalOutcome(id) != 0) assertEq(uint8(m.outcome), handler.terminalOutcome(id));
        }
    }

    /// @dev Every campaign must actually close and withdraw all user obligations, including dust.
    function afterInvariant() public {
        for (uint64 j = 1; j < markets.nextOrderId(); ++j) {
            PimdMarkets.Order memory o = markets.order(j);
            if (!o.resting) continue;
            vm.prank(o.trader);
            markets.cancel(j);
        }
        uint256 finalTime = uint256(start) + 7200 + 3 days + 1;
        if (block.timestamp < finalTime) vm.warp(finalTime);
        address[4] memory users = [alice, bob, carol, owner];
        for (uint256 j; j < ids.length; ++j) {
            if (markets.market(ids[j]).outcome == PimdMarkets.Outcome.Active) markets.settle(ids[j]);
            for (uint256 k; k < users.length; ++k) {
                (uint256 up, uint256 down) = markets.positions(ids[j], users[k]);
                if (up + down == 0) continue;
                vm.prank(users[k]);
                markets.claim(ids[j], up, down);
            }
            assertEq(markets.market(ids[j]).reserveUSDC, 0);
            assertEq(markets.market(ids[j]).reserveAsset, 0);
            assertEq(markets.bestBid(ids[j]), 0);
            assertEq(markets.bestAsk(ids[j]), 0);
        }
        for (uint256 k; k < users.length; ++k) {
            uint256 cash = markets.balance(users[k], T.USDC);
            uint256 asset = markets.balance(users[k], T.IMD);
            vm.startPrank(users[k]);
            if (cash > 0) markets.withdraw(T.USDC, cash);
            if (asset > 0) markets.withdraw(T.IMD, asset);
            vm.stopPrank();
        }
        assertEq(usdc.balanceOf(address(markets)), handler.donatedCash());
        assertEq(imd.balanceOf(address(markets)), handler.donatedAsset());
    }
}
