// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MarketTypes as T} from "./libraries/MarketTypes.sol";
import {PimdRegistry} from "./PimdRegistry.sol";
import {BoundaryOracle} from "./BoundaryOracle.sol";
import {PimdSwap} from "./PimdSwap.sol";
import {BoundaryProofVerifier} from "./BoundaryProofVerifier.sol";

/// @notice One price/time book for both outcomes, backed by USDC and the market's asset.
contract PimdMarkets is ReentrancyGuard {
    using SafeERC20 for IERC20;
    error InvalidMarket();
    error InvalidOrder();
    error InsufficientBalance();
    error MissingPrice();
    error Unauthorized();
    error InvalidTransfer();
    error InsertionHintRequired();
    uint256 internal constant SHARE = 1e6;
    uint256 internal constant TICK = 100;
    uint256 internal constant MAX_STEPS = 64;
    uint256 internal constant MAX_INSERT_SCAN = 128;
    uint256 internal constant MIN_NOTIONAL = 1e6;
    uint256 internal constant MIN_EXPIRY = 5 minutes;
    uint256 internal constant VOID_DELAY = 3 days;
    uint256 internal constant SWAP_BUFFER_BPS = 500;
    uint256 internal constant MAX_ORDER_FILLS = 1024;
    uint256 internal constant ROUNDING_RESERVE = MAX_ORDER_FILLS;
    address public immutable owner;
    PimdRegistry public immutable registry;
    BoundaryOracle public immutable oracle;
    PimdSwap public immutable swapper;

    enum Outcome {
        Active,
        Up,
        Down,
        Refund
    }
    enum Action {
        BuyUp,
        BuyDown,
        SellUp,
        SellDown
    }

    struct MarketSpec {
        address token;
        uint32 period;
        uint64 start;
        uint256 strike;
    }

    struct Market {
        address token;
        uint32 version;
        uint64 start;
        uint64 end;
        uint128 factor;
        uint128 maxPairs;
        uint256 ladderStrike;
        uint256 strike;
        uint256 close;
        uint256 pairs;
        uint256 reserveUSDC;
        uint256 reserveAsset;
        Outcome outcome;
    }

    struct Position {
        uint256 up;
        uint256 down;
    }

    struct OrderInput {
        Action action;
        uint128 quantity;
        uint128 limitPrice;
        uint64 expiry;
        bool immediateOrCancel;
        bool assetOnly;
        uint256 maxSwapInput;
        uint256 feeBudget;
        uint64 insertionHint;
        uint8 maxSteps;
    }

    struct Order {
        bytes32 market;
        address trader;
        Action action;
        bool assetOnly;
        uint64 expiry;
        uint64 previous;
        uint64 next;
        uint128 remaining;
        uint128 limitPrice;
        uint256 cash;
        uint256 asset;
        uint256 fee;
        uint256 swapBudget;
        bool resting;
        uint16 fills;
    }

    struct ProofSubmission {
        uint32 version;
        uint64 boundary;
        BoundaryProofVerifier.BlockProof[3] proofs;
    }
    mapping(bytes32 => Market) private markets;
    mapping(address => mapping(address => uint256)) public balance;
    mapping(bytes32 => mapping(address => Position)) public positions;
    mapping(uint64 => Order) private orders;
    mapping(bytes32 => uint64) public bestBid;
    mapping(bytes32 => uint64) public bestAsk;
    uint64 public nextOrderId = 1;
    bytes32[] public marketIds;

    event Deposited(address indexed account, address indexed token, uint256 amount);
    event Withdrawn(address indexed account, address indexed token, uint256 amount);
    event MarketCreated(
        bytes32 indexed market,
        address indexed token,
        uint32 indexed period,
        uint64 start,
        uint64 end,
        uint256 ladderStrike,
        uint32 version
    );
    event Split(bytes32 indexed market, address indexed account, uint256 quantity);
    event Merged(bytes32 indexed market, address indexed account, uint256 quantity);
    event OrderPlaced(
        uint64 indexed order,
        bytes32 indexed market,
        address indexed trader,
        Action action,
        uint256 quantity,
        uint256 price,
        uint64 expiry
    );
    event OrderEscrowed(
        uint64 indexed order, uint256 cash, uint256 asset, uint256 fee, uint256 swapBudget, bool assetOnly
    );
    event OrderClosed(uint64 indexed order, uint256 unfilled, uint8 reason, uint256 cashRefund, uint256 assetRefund);
    event ShortFunded(uint64 indexed order, uint256 assetSpent, uint256 usdcOutput);
    event Trade(bytes32 indexed market, uint64 indexed maker, uint64 indexed taker, uint256 quantity, uint256 price);
    event FeePaid(uint64 indexed order, address indexed coin, uint256 amount, uint256 makerRebate);
    event Settled(bytes32 indexed market, Outcome outcome, uint256 strike, uint256 close);
    event Claimed(
        bytes32 indexed market, address indexed account, uint256 up, uint256 down, uint256 usdc, uint256 asset
    );

    constructor(address owner_, PimdRegistry registry_, BoundaryOracle oracle_, PimdSwap swapper_) {
        if (
            owner_ == address(0) || address(registry_) == address(0) || address(oracle_) == address(0)
                || address(swapper_) == address(0)
        ) revert InvalidMarket();
        owner = owner_;
        registry = registry_;
        oracle = oracle_;
        swapper = swapper_;
    }

    function marketId(MarketSpec memory spec) public pure returns (bytes32) {
        return keccak256(abi.encode(spec.token, spec.period, spec.start, spec.strike));
    }

    function market(bytes32 id) external view returns (Market memory) {
        return markets[id];
    }

    function order(uint64 id) external view returns (Order memory) {
        return orders[id];
    }

    function marketCount() external view returns (uint256) {
        return marketIds.length;
    }

    function deposit(address token, uint256 amount) external nonReentrant {
        if (amount == 0 || (token != T.USDC && registry.currentVersion(token) == 0)) revert InvalidTransfer();
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(token).balanceOf(address(this)) - beforeBalance != amount) revert InvalidTransfer();
        balance[msg.sender][token] += amount;
        emit Deposited(msg.sender, token, amount);
    }

    function withdraw(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidTransfer();
        _debit(msg.sender, token, amount);
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, token, amount);
    }

    function _debit(address account, address token, uint256 amount) private {
        if (balance[account][token] < amount) revert InsufficientBalance();
        balance[account][token] -= amount;
    }

    function _ensure(MarketSpec memory spec) private returns (bytes32 id) {
        id = marketId(spec);
        if (markets[id].token != address(0)) return id;
        (uint64 start, uint64 end) = registry.bounds(spec.period, spec.start);
        if (start != spec.start || end <= block.timestamp || !_ladder(spec.strike)) revert InvalidMarket();
        uint32 version = registry.currentVersion(spec.token);
        T.Asset memory a = registry.asset(version);
        Market storage m = markets[id];
        m.token = spec.token;
        m.version = version;
        m.start = start;
        m.end = end;
        m.factor = uint128(a.unitsPerShare / SHARE);
        m.maxPairs = a.maxOpenPairs;
        m.ladderStrike = spec.strike;
        marketIds.push(id);
        emit MarketCreated(id, spec.token, spec.period, start, end, spec.strike, version);
    }

    function _ladder(uint256 k) private pure returns (bool) {
        if (k > T.MAX_PRICE) return false;
        if (k == 0) return true;
        while (k % 10 == 0) k /= 10;
        return k <= 999;
    }

    /// @dev A normal market settles against the price at its start boundary. Once that price can no
    /// longer be recorded (no proof, no proposal, and the oracle's proposal window closed) the market is
    /// certain to void, so no new pairs, orders, or executions are accepted; merge and cancel remain.
    function _requireStrikeObtainable(Market storage m) private view {
        if (m.ladderStrike == 0 && !oracle.priceable(m.version, m.start)) revert InvalidMarket();
    }

    function split(MarketSpec calldata spec, uint128 quantity) external nonReentrant returns (bytes32 id) {
        id = _ensure(spec);
        Market storage m = markets[id];
        if (quantity == 0 || m.outcome != Outcome.Active) revert InvalidMarket();
        _requireStrikeObtainable(m);
        _debit(msg.sender, T.USDC, quantity);
        _debit(msg.sender, m.token, uint256(quantity) * m.factor);
        _mintPair(m, quantity);
        positions[id][msg.sender].up += quantity;
        positions[id][msg.sender].down += quantity;
        emit Split(id, msg.sender, quantity);
    }

    function merge(bytes32 id, uint128 quantity) external nonReentrant {
        Market storage m = markets[id];
        Position storage p = positions[id][msg.sender];
        if (m.token == address(0) || quantity == 0 || m.outcome != Outcome.Active) revert InvalidMarket();
        if (p.up < quantity || p.down < quantity) revert InsufficientBalance();
        p.up -= quantity;
        p.down -= quantity;
        _burnPair(m, quantity);
        balance[msg.sender][T.USDC] += quantity;
        balance[msg.sender][m.token] += uint256(quantity) * m.factor;
        emit Merged(id, msg.sender, quantity);
    }

    function _mintPair(Market storage m, uint256 quantity) private {
        if (m.pairs + quantity > m.maxPairs) revert InvalidMarket();
        m.pairs += quantity;
        m.reserveUSDC += quantity;
        m.reserveAsset += quantity * m.factor;
    }

    function _burnPair(Market storage m, uint256 quantity) private {
        m.pairs -= quantity;
        m.reserveUSDC -= quantity;
        m.reserveAsset -= quantity * m.factor;
    }

    function place(MarketSpec calldata spec, OrderInput calldata input) external nonReentrant returns (uint64 id) {
        return _place(_ensure(spec), input);
    }

    function placeWithProofs(MarketSpec calldata spec, OrderInput calldata input, ProofSubmission[] calldata proofs)
        external
        nonReentrant
        returns (uint64)
    {
        _prove(proofs);
        return _place(_ensure(spec), input);
    }

    /// @dev A boundary somebody else recorded first is skipped: the attached proof is then unnecessary.
    function _prove(ProofSubmission[] calldata proofs) private {
        if (proofs.length > 2) revert InvalidMarket();
        for (uint256 i; i < proofs.length; ++i) {
            if (oracle.price(proofs[i].version, proofs[i].boundary) != 0) continue;
            oracle.prove(proofs[i].version, proofs[i].boundary, proofs[i].proofs);
        }
    }

    function _place(bytes32 mid, OrderInput calldata input) private returns (uint64 id) {
        Market storage m = markets[mid];
        if (
            m.outcome != Outcome.Active || block.timestamp >= m.end || input.quantity == 0 || input.limitPrice == 0
                || input.limitPrice % TICK != 0 || input.maxSteps == 0 || input.maxSteps > MAX_STEPS
                || Math.mulDiv(input.quantity, input.limitPrice, SHARE) < MIN_NOTIONAL
                || (input.assetOnly && input.action != Action.BuyDown)
        ) revert InvalidOrder();
        if (!input.immediateOrCancel && (input.expiry < block.timestamp + MIN_EXPIRY || input.expiry > m.end)) {
            revert InvalidOrder();
        }
        _requireStrikeObtainable(m);
        // The budget must at least pay the order's own full execution at its limit price: the maker fee
        // for a resting order, the taker fee for an immediate one. Otherwise the order could never fill
        // and would only occupy book priority and takers' matching steps.
        bool down = _down(input.action);
        uint256 floor = _fee(m, input.limitPrice, input.quantity, _price(m.version), input.immediateOrCancel, down);
        if (input.feeBudget < floor) revert InvalidOrder();
        id = nextOrderId++;
        Order storage o = orders[id];
        o.market = mid;
        o.trader = msg.sender;
        o.action = input.action;
        o.assetOnly = input.assetOnly;
        o.expiry = input.immediateOrCancel ? m.end : input.expiry;
        o.remaining = input.quantity;
        o.limitPrice = input.limitPrice;
        o.fee = input.feeBudget;
        uint256 cash = Math.mulDiv(input.quantity, input.limitPrice, SHARE, Math.Rounding.Ceil);
        if (input.action == Action.BuyUp) {
            o.cash = cash + ROUNDING_RESERVE;
        } else if (input.action == Action.BuyDown) {
            o.asset = uint256(input.quantity) * m.factor;
            uint256 need = input.quantity > cash ? input.quantity - cash : 0;
            if (input.assetOnly && need != 0) {
                uint256 p = _price(m.version);
                uint256 estimate = Math.mulDiv(need, uint256(m.factor) * 1e18, p, Math.Rounding.Ceil);
                uint256 buffered = Math.mulDiv(estimate, 10000 + SWAP_BUFFER_BPS, 10000, Math.Rounding.Ceil);
                if (input.maxSwapInput < buffered) revert InvalidOrder();
                o.swapBudget = input.maxSwapInput;
            } else {
                o.cash = need + (input.limitPrice < SHARE ? ROUNDING_RESERVE : 0);
            }
        } else if (input.action == Action.SellUp) {
            Position storage p = positions[mid][msg.sender];
            if (p.up < input.quantity) revert InsufficientBalance();
            p.up -= input.quantity;
        } else {
            Position storage p = positions[mid][msg.sender];
            if (p.down < input.quantity) revert InsufficientBalance();
            p.down -= input.quantity;
            if (input.limitPrice > SHARE) o.cash = cash - input.quantity + ROUNDING_RESERVE;
        }
        _debit(msg.sender, T.USDC, o.cash + (down ? 0 : o.fee));
        _debit(msg.sender, m.token, o.asset + o.swapBudget + (down ? o.fee : 0));
        emit OrderPlaced(id, mid, msg.sender, o.action, input.quantity, input.limitPrice, o.expiry);
        emit OrderEscrowed(id, o.cash, o.asset, o.fee, o.swapBudget, o.assetOnly);
        _insert(id, input.insertionHint);
        _match(mid, input.maxSteps, id);
        if (input.immediateOrCancel && o.resting) _close(id, 0);
    }

    /// @notice Continue a capped sweep in price/time order. Limit remainders stay escrowed.
    function matchMarket(bytes32 mid, uint8 maxSteps) external nonReentrant returns (uint256 fills) {
        Market storage m = markets[mid];
        if (
            m.token == address(0) || m.outcome != Outcome.Active || block.timestamp >= m.end || maxSteps == 0
                || maxSteps > MAX_STEPS
        ) revert InvalidOrder();
        _requireStrikeObtainable(m);
        return _match(mid, maxSteps, 0);
    }

    function _match(bytes32 mid, uint256 maxSteps, uint64 incoming) private returns (uint256 fills) {
        Market storage m = markets[mid];
        for (uint256 steps; steps < maxSteps; ++steps) {
            uint64 bid = bestBid[mid];
            uint64 ask = bestAsk[mid];
            if (bid == 0 || ask == 0) break;
            if (orders[bid].expiry <= block.timestamp) {
                _close(bid, 1);
                continue;
            }
            if (orders[ask].expiry <= block.timestamp) {
                _close(ask, 1);
                continue;
            }
            if (orders[bid].limitPrice < orders[ask].limitPrice) break;
            // Among the best prices, the earlier order supplies liquidity; the later consumes it.
            uint64 makerId = bid < ask ? bid : ask;
            uint64 takerId = bid < ask ? ask : bid;
            Order storage maker = orders[makerId];
            Order storage taker = orders[takerId];
            uint256 quantity = Math.min(maker.remaining, taker.remaining);
            if (
                (maker.action == Action.BuyUp || maker.action == Action.BuyDown)
                    && (taker.action == Action.BuyUp || taker.action == Action.BuyDown)
            ) {
                quantity = Math.min(quantity, m.maxPairs - m.pairs);
                if (quantity == 0) break;
            }
            uint256 price_ = maker.limitPrice;
            uint256 p = _price(m.version);
            uint256 makerFee = _fee(m, price_, quantity, p, false, _down(maker.action));
            uint256 takerFee = _fee(m, price_, quantity, p, true, _down(taker.action));
            if (maker.fee < makerFee) {
                _close(makerId, 2);
                continue;
            }
            if (taker.fee < takerFee) {
                if (takerId == incoming) revert InsufficientBalance();
                _close(takerId, 2);
                continue;
            }
            uint256 cost = Math.mulDiv(quantity, price_, SHARE, Math.Rounding.Ceil);
            if (!_fundShort(makerId, quantity, cost)) {
                _close(makerId, 3);
                continue;
            }
            if (!_fundShort(takerId, quantity, cost)) {
                if (takerId == incoming) revert InvalidOrder();
                _close(takerId, 3);
                continue;
            }
            _fill(makerId, takerId, quantity, cost, makerFee, takerFee);
            emit Trade(mid, makerId, takerId, quantity, price_);
            ++fills;
            if (maker.remaining == 0 || maker.fills == MAX_ORDER_FILLS) _close(makerId, 0);
            if (taker.remaining == 0 || taker.fills == MAX_ORDER_FILLS) _close(takerId, 0);
        }
    }

    function _fundShort(uint64 id, uint256 quantity, uint256 cost) private returns (bool) {
        Order storage o = orders[id];
        if (!o.assetOnly || o.action != Action.BuyDown || cost >= quantity) return true;
        uint256 need = quantity - cost;
        uint256 budget = Math.mulDiv(o.swapBudget, quantity, o.remaining);
        if (budget == 0) return false;
        Market storage m = markets[o.market];
        IERC20(m.token).forceApprove(address(swapper), budget);
        uint256 beforeAsset = IERC20(m.token).balanceOf(address(this));
        uint256 beforeCash = IERC20(T.USDC).balanceOf(address(this));
        bool success;
        try swapper.exactOutput(m.version, need, budget) returns (uint256 spent) {
            if (
                spent > budget || beforeAsset - IERC20(m.token).balanceOf(address(this)) != spent
                    || IERC20(T.USDC).balanceOf(address(this)) - beforeCash != need
            ) revert InvalidTransfer();
            o.swapBudget -= spent;
            o.cash += need;
            success = true;
            emit ShortFunded(id, spent, need);
        } catch {
            success = false;
        }
        IERC20(m.token).forceApprove(address(swapper), 0);
        return success;
    }

    function _fill(uint64 makerId, uint64 takerId, uint256 quantity, uint256 cost, uint256 makerFee, uint256 takerFee)
        private
    {
        Order storage a = orders[makerId];
        Order storage b = orders[takerId];
        Market storage m = markets[a.market];
        bool newA = a.action == Action.BuyUp || a.action == Action.BuyDown;
        bool newB = b.action == Action.BuyUp || b.action == Action.BuyDown;
        if (newA && newB) _mintPair(m, quantity);
        if (!newA && !newB) _burnPair(m, quantity);
        _apply(a, m, quantity, cost);
        _apply(b, m, quantity, cost);
        a.remaining -= uint128(quantity);
        b.remaining -= uint128(quantity);
        ++a.fills;
        ++b.fills;
        a.fee -= makerFee;
        b.fee -= takerFee;
        address makerCoin = _down(a.action) ? m.token : T.USDC;
        address takerCoin = _down(b.action) ? m.token : T.USDC;
        uint256 rebate = takerFee / 4;
        balance[a.trader][takerCoin] += rebate;
        balance[owner][makerCoin] += makerFee;
        balance[owner][takerCoin] += takerFee - rebate;
        emit FeePaid(makerId, makerCoin, makerFee, 0);
        emit FeePaid(takerId, takerCoin, takerFee, rebate);
    }

    function _apply(Order storage o, Market storage m, uint256 quantity, uint256 cost) private {
        Position storage p = positions[o.market][o.trader];
        if (o.action == Action.BuyUp) {
            o.cash -= cost;
            p.up += quantity;
        } else if (o.action == Action.BuyDown) {
            o.asset -= quantity * m.factor;
            p.down += quantity;
            if (cost > quantity) balance[o.trader][T.USDC] += cost - quantity;
            else o.cash -= quantity - cost;
        } else if (o.action == Action.SellUp) {
            balance[o.trader][T.USDC] += cost;
        } else {
            balance[o.trader][m.token] += quantity * m.factor;
            if (cost > quantity) o.cash -= cost - quantity;
            else balance[o.trader][T.USDC] += quantity - cost;
        }
    }

    function _price(uint32 version) private view returns (uint256 p) {
        p = oracle.price(version, oracle.latestBoundary(version));
        if (p == 0) revert MissingPrice();
    }

    function feeQuote(bytes32 mid, uint256 price_, uint256 quantity, bool taker, bool down)
        external
        view
        returns (uint256)
    {
        Market storage m = markets[mid];
        if (m.token == address(0)) revert InvalidMarket();
        return _fee(m, price_, quantity, _price(m.version), taker, down);
    }

    function _fee(Market storage m, uint256 x, uint256 quantity, uint256 p, bool taker, bool down)
        private
        view
        returns (uint256)
    {
        uint256 v = 1e18 + p;
        uint256 q = Math.min(99e16, Math.max(1e16, Math.mulDiv(x, 1e30, v)));
        uint256 curve = Math.mulDiv(q, 1e18 - q, 1e18);
        uint256 perShare = Math.mulDiv(Math.mulDiv(curve, v, 1e18), taker ? 7 : 1, 100);
        if (down) return Math.mulDiv(quantity, perShare * uint256(m.factor), p, Math.Rounding.Ceil);
        return Math.mulDiv(quantity, perShare, 1e18, Math.Rounding.Ceil);
    }

    function _bid(Action a) private pure returns (bool) {
        return a == Action.BuyUp || a == Action.SellDown;
    }

    function _down(Action a) private pure returns (bool) {
        return a == Action.BuyDown || a == Action.SellDown;
    }

    function _before(uint64 a, uint64 b) private view returns (bool) {
        Order storage x = orders[a];
        Order storage y = orders[b];
        if (x.limitPrice == y.limitPrice) return a < b;
        return _bid(x.action) ? x.limitPrice > y.limitPrice : x.limitPrice < y.limitPrice;
    }

    function _insert(uint64 id, uint64 hint) private {
        Order storage o = orders[id];
        bool bid = _bid(o.action);
        uint64 head = bid ? bestBid[o.market] : bestAsk[o.market];
        uint64 prev = hint;
        uint64 next;
        if (hint != 0) {
            Order storage h = orders[hint];
            if (!h.resting || h.market != o.market || _bid(h.action) != bid || !_before(hint, id)) {
                revert InvalidOrder();
            }
            next = h.next;
        } else {
            next = head;
            uint256 scans;
            while (next != 0 && _before(next, id)) {
                prev = next;
                next = orders[next].next;
                if (++scans >= MAX_INSERT_SCAN) revert InsertionHintRequired();
            }
        }
        if (next != 0 && !_before(id, next)) revert InvalidOrder();
        o.previous = prev;
        o.next = next;
        o.resting = true;
        if (prev != 0) orders[prev].next = id;
        else if (bid) bestBid[o.market] = id;
        else bestAsk[o.market] = id;
        if (next != 0) orders[next].previous = id;
    }

    function cancel(uint64 id) external nonReentrant {
        if (orders[id].trader != msg.sender || !orders[id].resting) revert Unauthorized();
        _close(id, 5);
    }

    function expire(uint64[] calldata ids) external nonReentrant {
        if (ids.length > MAX_STEPS) revert InvalidOrder();
        for (uint256 i; i < ids.length; ++i) {
            Order storage o = orders[ids[i]];
            if (o.resting && (o.expiry <= block.timestamp || markets[o.market].outcome != Outcome.Active)) {
                _close(ids[i], 1);
            }
        }
    }

    function _close(uint64 id, uint8 reason) private {
        Order storage o = orders[id];
        Market storage m = markets[o.market];
        if (o.resting) {
            if (o.previous != 0) orders[o.previous].next = o.next;
            else if (_bid(o.action)) bestBid[o.market] = o.next;
            else bestAsk[o.market] = o.next;
            if (o.next != 0) orders[o.next].previous = o.previous;
        }
        uint256 unfilled = o.remaining;
        if (o.action == Action.SellUp) positions[o.market][o.trader].up += unfilled;
        if (o.action == Action.SellDown) positions[o.market][o.trader].down += unfilled;
        uint256 cashRefund = o.cash + (_down(o.action) ? 0 : o.fee);
        uint256 assetRefund = o.asset + o.swapBudget + (_down(o.action) ? o.fee : 0);
        balance[o.trader][T.USDC] += cashRefund;
        balance[o.trader][m.token] += assetRefund;
        o.cash = 0;
        o.asset = 0;
        o.fee = 0;
        o.swapBudget = 0;
        o.remaining = 0;
        o.resting = false;
        o.previous = 0;
        o.next = 0;
        emit OrderClosed(id, unfilled, reason, cashRefund, assetRefund);
    }

    function settle(bytes32 id) external nonReentrant {
        _settle(id);
    }

    function _settle(bytes32 id) private {
        Market storage m = markets[id];
        if (m.token == address(0) || m.outcome != Outcome.Active || block.timestamp < m.end) revert InvalidMarket();
        uint256 strike = m.ladderStrike != 0 ? m.ladderStrike : oracle.price(m.version, m.start);
        uint256 close = oracle.price(m.version, m.end);
        if (strike == 0 || close == 0) {
            if (block.timestamp < uint256(m.end) + VOID_DELAY) revert MissingPrice();
            m.outcome = Outcome.Refund;
        } else {
            m.outcome = close > strike ? Outcome.Up : close < strike ? Outcome.Down : Outcome.Refund;
        }
        m.strike = strike;
        m.close = close;
        emit Settled(id, m.outcome, strike, close);
    }

    function claim(bytes32 id, uint256 up, uint256 down) external nonReentrant {
        _claim(id, up, down);
    }

    function claimWithProofs(bytes32 id, uint256 up, uint256 down, ProofSubmission[] calldata proofs)
        external
        nonReentrant
    {
        _prove(proofs);
        _claim(id, up, down);
    }

    function claimAll(bytes32[] calldata ids) external nonReentrant {
        if (ids.length > MAX_STEPS) revert InvalidMarket();
        for (uint256 i; i < ids.length; ++i) {
            Position memory p = positions[ids[i]][msg.sender];
            if (p.up != 0 || p.down != 0) _claim(ids[i], p.up, p.down);
        }
    }

    function _claim(bytes32 id, uint256 up, uint256 down) private {
        Market storage m = markets[id];
        if (m.outcome == Outcome.Active) _settle(id);
        Position storage p = positions[id][msg.sender];
        if (up + down == 0 || p.up < up || p.down < down) revert InsufficientBalance();
        p.up -= up;
        p.down -= down;
        uint256 usdc;
        uint256 asset;
        if (m.outcome == Outcome.Up) {
            usdc = up;
            asset = up * m.factor;
        } else if (m.outcome == Outcome.Down) {
            usdc = down;
            asset = down * m.factor;
        } else {
            usdc = up;
            asset = down * m.factor;
        }
        m.reserveUSDC -= usdc;
        m.reserveAsset -= asset;
        balance[msg.sender][T.USDC] += usdc;
        balance[msg.sender][m.token] += asset;
        emit Claimed(id, msg.sender, up, down, usdc, asset);
    }
}
