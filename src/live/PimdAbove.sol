// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./vendor/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "./vendor/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "./vendor/openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "./vendor/openzeppelin/contracts/utils/math/Math.sol";
import {MarketTypes as T} from "./libraries/MarketTypes.sol";
import {PimdRegistry} from "./PimdRegistry.sol";
import {BoundaryOracle} from "./BoundaryOracle.sol";

/// @notice "IMD above $X" markets: USDC only, no token, pool or swap. A pair of 1 YES + 1 NO is backed
/// by exactly 1 USDC. YES and NO each have a buy and a sell book priced in USDC per share.
/// @dev Shares and USDC have 6 decimals; prices are USDC per share with tick 0.0001 (100 units).
/// A buy at price p for N shares locks exactly N*p USDC with the fee inside: it spends at most the
/// lock and receives (amount - fee)/p shares, stopping at N. A sell locks only its N shares and
/// receives N*p minus the fee. The maker (earlier order) fills at exactly its price; the taker pays
/// or receives the rest of 1 USDC (mint or burn) or the maker's price (move) within its limit.
/// The gap of each taker fill (limit cost minus actual cost on a buy, net proceeds over the limit on
/// a sell) is paid in that fill to the transaction sender: the taker itself in `place`, else the
/// `matchMarket` caller. A buy's lock that is still unspent when the order closes always returns to
/// its trader.
/// Fee = k*(1-q) of the amount, q = the fill price per share clamped to 0.01..0.99, taker k = K,
/// maker k = Km, credited to the owner; none on cancel, expiry, split, merge or claim.
contract PimdAbove is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error Unauthorized();
    error InvalidMarket();
    error InvalidOrder();
    error InsufficientBalance();
    error InvalidTransfer();
    error InvalidRate();
    error MissingPrice();

    uint256 public constant SHARE = 1e6;
    uint256 public constant TICK = 100;
    uint256 public constant MIN_PRICE = 100; // 0.0001
    uint256 public constant MAX_PRICE = 999_900; // 0.9999
    uint256 public constant MIN_NOTIONAL = 1e6; // 1 USDC
    uint256 public constant MIN_EXPIRY = 5 minutes;
    uint256 public constant VOID_DELAY = 3 days;
    uint256 public constant MAX_STEPS = 64;
    uint256 public constant MAX_ORDER_FILLS = 1024;
    uint256 public constant RATE_ONE = 1e4; // fee rates in 1/10000
    uint256 public constant MAX_TAKER_RATE = 1000; // 0.10
    uint256 public constant MAX_MAKER_RATE = 500; // 0.05
    uint256 internal constant Q_MIN = 1e4; // 0.01
    uint256 internal constant Q_MAX = 99e4; // 0.99
    uint256 internal constant R = 1e10; // rate (1e4) times price (1e6)

    PimdRegistry public immutable registry;
    BoundaryOracle public immutable oracle;
    /// @notice Receives every fee as free USDC balance; no other power.
    address public immutable owner;
    /// @notice Creates markets, sets the fee rates and may hand its role on; no other power.
    address public admin;
    uint256 public takerRate = 500; // K = 0.05
    uint256 public makerRate = 100; // Km = 0.01

    enum Outcome {
        Active,
        Yes,
        No,
        Half
    }

    struct Market {
        uint32 version;
        uint32 period;
        uint64 end;
        // USD at 18 decimals per unitsPerShare of the version's token: the scale BoundaryOracle records
        // (USD per token only where unitsPerShare is 1e18, as for version 1, U = 1 IMD).
        uint256 threshold;
        uint256 close;
        uint256 pairs;
        Outcome outcome;
    }

    struct Position {
        uint256 yes;
        uint256 no;
    }

    struct Order {
        bytes32 market;
        address trader;
        bool yes;
        bool buy;
        bool resting;
        uint64 expiry;
        uint64 previous;
        uint64 next;
        uint16 fills;
        uint128 price;
        uint128 remaining; // shares still wanted (buy) or still offered (sell)
        uint256 lock; // USDC still locked (buy only)
    }

    struct OrderInput {
        bool yes;
        bool buy;
        uint128 quantity; // shares; 0 on an amount-based market buy
        uint256 amount; // USDC for an amount-based market buy, else 0
        uint128 price; // limit price or the worst price of a market order
        uint64 expiry; // limit orders only
        bool market; // market order: the unfilled rest returns in this transaction
    }

    mapping(bytes32 => Market) private markets;
    bytes32[] public marketIds;
    mapping(address => uint256) public balance;
    mapping(bytes32 => mapping(address => Position)) public positions;
    mapping(uint64 => Order) private orders;
    // live (resting) orders per trader and market; an order leaves the list when it closes
    mapping(bytes32 => mapping(address => uint64[])) private traderOrders;
    mapping(uint64 => uint256) private listIndex;
    // heads: market => yes? => buy? => order id
    mapping(bytes32 => mapping(bool => mapping(bool => uint64))) public best;
    uint64 public nextOrderId = 1;

    event MarketCreated(
        bytes32 indexed market, uint32 indexed version, uint32 indexed period, uint64 end, uint256 threshold
    );
    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event Split(bytes32 indexed market, address indexed account, uint256 quantity);
    event Merged(bytes32 indexed market, address indexed account, uint256 quantity);
    event OrderPlaced(
        uint64 indexed order,
        bytes32 indexed market,
        address indexed trader,
        bool yes,
        bool buy,
        uint128 quantity,
        uint128 price,
        uint256 lock,
        uint64 expiry
    );
    event OrderClosed(uint64 indexed order, uint8 reason, uint256 refund);
    event Fill(
        bytes32 indexed market,
        uint64 indexed maker,
        uint64 indexed taker,
        uint256 quantity,
        uint256 makerAmount,
        uint256 takerAmount,
        uint256 makerFee,
        uint256 takerFee
    );
    event GapReturned(uint64 indexed order, address indexed to, uint256 amount);
    event Settled(bytes32 indexed market, Outcome outcome, uint256 close);
    event Claimed(bytes32 indexed market, address indexed account, uint256 yes, uint256 no, uint256 usdc);
    event RatesSet(uint256 takerRate, uint256 makerRate);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    constructor(PimdRegistry registry_, BoundaryOracle oracle_, address admin_, address owner_) {
        if (
            address(registry_) == address(0) || address(oracle_) == address(0) || admin_ == address(0)
                || owner_ == address(0)
        ) revert InvalidMarket();
        registry = registry_;
        oracle = oracle_;
        admin = admin_;
        owner = owner_;
        emit AdminTransferred(address(0), admin_);
        emit RatesSet(takerRate, makerRate);
    }

    // ---------------------------------------------------------------- admin

    function transferAdmin(address newAdmin) external {
        if (msg.sender != admin) revert Unauthorized();
        if (newAdmin == address(0)) revert InvalidMarket();
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    /// @notice Sets K (taker) and Km (maker) in 1/10000, for later fills only. K <= 0.10, Km <= 0.05.
    function setRates(uint256 taker, uint256 maker) external {
        if (msg.sender != admin) revert Unauthorized();
        if (taker > MAX_TAKER_RATE || maker > MAX_MAKER_RATE) revert InvalidRate();
        takerRate = taker;
        makerRate = maker;
        emit RatesSet(taker, maker);
    }

    function marketId(uint32 version, uint32 period, uint64 end, uint256 threshold) public pure returns (bytes32) {
        return keccak256(abi.encode(version, period, end, threshold));
    }

    /// @notice Creates "asset above threshold at end" for a registry version and period; end must be a
    /// boundary of that period after now. One market per threshold and end; a ladder is several thresholds.
    /// `threshold` is on BoundaryOracle's price scale: USD at 18 decimals per unitsPerShare of the version's
    /// token (per 1 IMD for version 1). For a version with U = 10,000 tokens, "above 0.0001 USD per token"
    /// is threshold 1e18.
    function createMarket(uint32 version, uint32 period, uint64 end, uint256 threshold)
        external
        nonReentrant
        returns (bytes32 id)
    {
        if (msg.sender != admin) revert Unauthorized();
        registry.asset(version);
        (uint64 start,) = registry.bounds(period, end);
        if (start != end || end <= block.timestamp || threshold == 0 || threshold > T.MAX_PRICE) {
            revert InvalidMarket();
        }
        id = marketId(version, period, end, threshold);
        if (markets[id].end != 0) revert InvalidMarket();
        Market storage m = markets[id];
        m.version = version;
        m.period = period;
        m.end = end;
        m.threshold = threshold;
        marketIds.push(id);
        emit MarketCreated(id, version, period, end, threshold);
    }

    // ---------------------------------------------------------------- views

    function market(bytes32 id) external view returns (Market memory) {
        return markets[id];
    }

    function order(uint64 id) external view returns (Order memory) {
        return orders[id];
    }

    function marketCount() external view returns (uint256) {
        return marketIds.length;
    }

    /// @notice The trader's resting orders in the market; closed orders are no longer listed.
    function ordersOf(bytes32 id, address trader) external view returns (uint64[] memory) {
        return traderOrders[id][trader];
    }

    // ---------------------------------------------------------------- balances

    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidTransfer();
        uint256 beforeBalance = IERC20(T.USDC).balanceOf(address(this));
        IERC20(T.USDC).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(T.USDC).balanceOf(address(this)) - beforeBalance != amount) revert InvalidTransfer();
        balance[msg.sender] += amount;
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidTransfer();
        _debit(msg.sender, amount);
        IERC20(T.USDC).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function _debit(address account, uint256 amount) private {
        if (balance[account] < amount) revert InsufficientBalance();
        balance[account] -= amount;
    }

    // ---------------------------------------------------------------- split / merge

    function split(bytes32 id, uint256 quantity) external nonReentrant {
        Market storage m = markets[id];
        if (m.end == 0 || quantity == 0 || m.outcome != Outcome.Active) revert InvalidMarket();
        _debit(msg.sender, quantity);
        m.pairs += quantity;
        positions[id][msg.sender].yes += quantity;
        positions[id][msg.sender].no += quantity;
        emit Split(id, msg.sender, quantity);
    }

    function merge(bytes32 id, uint256 quantity) external nonReentrant {
        Market storage m = markets[id];
        Position storage p = positions[id][msg.sender];
        if (m.end == 0 || quantity == 0 || m.outcome != Outcome.Active) revert InvalidMarket();
        if (p.yes < quantity || p.no < quantity) revert InsufficientBalance();
        p.yes -= quantity;
        p.no -= quantity;
        m.pairs -= quantity;
        balance[msg.sender] += quantity;
        emit Merged(id, msg.sender, quantity);
    }

    // ---------------------------------------------------------------- orders

    function place(bytes32 mid, OrderInput calldata input) external nonReentrant returns (uint64 id) {
        Market storage m = markets[mid];
        if (m.end == 0 || m.outcome != Outcome.Active) revert InvalidMarket();
        if (
            input.price < MIN_PRICE || input.price > MAX_PRICE || input.price % TICK != 0
                || (input.amount != 0 && (!input.buy || !input.market || input.quantity != 0))
        ) revert InvalidOrder();
        if (!input.market && (input.expiry < block.timestamp + MIN_EXPIRY)) revert InvalidOrder();
        id = nextOrderId++;
        Order storage o = orders[id];
        o.market = mid;
        o.trader = msg.sender;
        o.yes = input.yes;
        o.buy = input.buy;
        o.price = input.price;
        o.expiry = input.market ? type(uint64).max : input.expiry;
        if (input.buy) {
            if (input.amount != 0) {
                o.lock = input.amount;
                o.remaining = type(uint128).max;
            } else {
                o.lock = Math.mulDiv(input.quantity, input.price, SHARE);
                o.remaining = input.quantity;
            }
            if (o.lock < MIN_NOTIONAL) revert InvalidOrder();
            _debit(msg.sender, o.lock);
        } else {
            if (Math.mulDiv(input.quantity, input.price, SHARE) < MIN_NOTIONAL) revert InvalidOrder();
            Position storage p = positions[mid][msg.sender];
            if (input.yes) {
                if (p.yes < input.quantity) revert InsufficientBalance();
                p.yes -= input.quantity;
            } else {
                if (p.no < input.quantity) revert InsufficientBalance();
                p.no -= input.quantity;
            }
            o.remaining = input.quantity;
        }
        listIndex[id] = traderOrders[mid][msg.sender].length;
        traderOrders[mid][msg.sender].push(id);
        emit OrderPlaced(id, mid, msg.sender, input.yes, input.buy, o.remaining, input.price, o.lock, o.expiry);
        _insert(id);
        _match(mid);
        if (o.resting && (input.market || _underMin(o))) _close(id, input.market ? 4 : 3);
    }

    /// @notice Matches resting crossed orders, by anyone, any time before settlement. The gap between a
    /// taker's limit and each of its fills goes to the caller; the taker's unspent lock stays its own.
    function matchMarket(bytes32 mid) external nonReentrant returns (uint256 fills) {
        Market storage m = markets[mid];
        if (m.end == 0 || m.outcome != Outcome.Active) revert InvalidMarket();
        return _match(mid);
    }

    function cancel(uint64 id) external nonReentrant {
        Order storage o = orders[id];
        if (o.trader != msg.sender || !o.resting) revert Unauthorized();
        _close(id, 5);
    }

    // ---------------------------------------------------------------- settlement

    function settle(bytes32 id) external nonReentrant {
        _settle(id);
    }

    /// @dev Before voiding a market to Half, an unchallenged proposal whose window has elapsed is finalized
    /// here, so its close is used: BoundaryOracle.finalize has no upper time bound and always succeeds for
    /// such a proposal (its deadline is before end + 3 days by construction).
    function _settle(bytes32 id) private {
        Market storage m = markets[id];
        if (m.end == 0 || m.outcome != Outcome.Active || block.timestamp < m.end) revert InvalidMarket();
        uint256 close = oracle.price(m.version, m.end);
        if (close == 0 && block.timestamp >= uint256(m.end) + VOID_DELAY) {
            BoundaryOracle.Proposal memory p = oracle.proposal(oracle.proposalId(m.version, m.end));
            if (p.proposer != address(0) && !p.finished && p.challenger == address(0)) {
                oracle.finalize(m.version, m.end);
                close = oracle.price(m.version, m.end);
            }
        }
        if (close == 0) {
            if (block.timestamp < uint256(m.end) + VOID_DELAY) revert MissingPrice();
            m.outcome = Outcome.Half;
        } else {
            m.outcome = close > m.threshold ? Outcome.Yes : close < m.threshold ? Outcome.No : Outcome.Half;
        }
        m.close = close;
        emit Settled(id, m.outcome, close);
    }

    /// @notice Redeems the caller's shares after the end, settling first if needed and cancelling the
    /// caller's resting orders in the market. A winner redeems 1 USDC, a loser 0; a tie or no close
    /// within 3 days redeems 0.5 USDC per share.
    function claim(bytes32 id) external nonReentrant returns (uint256 usdc) {
        Market storage m = markets[id];
        if (m.outcome == Outcome.Active) _settle(id);
        uint64[] storage mine = traderOrders[id][msg.sender];
        // only resting orders are listed; closing one pops it, so walk from the end
        for (uint256 i = mine.length; i > 0; --i) {
            uint64 oid = mine[i - 1];
            if (orders[oid].resting) _close(oid, 5);
        }
        Position storage p = positions[id][msg.sender];
        uint256 yes = p.yes;
        uint256 no = p.no;
        if (yes + no == 0) revert InsufficientBalance();
        p.yes = 0;
        p.no = 0;
        if (m.outcome == Outcome.Yes) usdc = yes;
        else if (m.outcome == Outcome.No) usdc = no;
        else usdc = (yes + no) / 2;
        balance[msg.sender] += usdc;
        emit Claimed(id, msg.sender, yes, no, usdc);
    }

    // ---------------------------------------------------------------- fees

    /// @dev Fee rate in R units (1e10) for a fill price q (1e6) clamped to 0.01..0.99: k*(1-q).
    function _rate(uint256 q, bool taker) private view returns (uint256) {
        q = Math.min(Q_MAX, Math.max(Q_MIN, q));
        return (taker ? takerRate : makerRate) * (SHARE - q);
    }

    /// @dev Amount a buyer spends for `quantity` shares at `price` with the fee inside: base / (1 - rate).
    function _buyCost(uint256 quantity, uint256 price, uint256 rate)
        private
        pure
        returns (uint256 amount, uint256 fee)
    {
        uint256 base = Math.mulDiv(quantity, price, SHARE, Math.Rounding.Ceil);
        fee = Math.mulDiv(base, rate, R - rate, Math.Rounding.Ceil);
        amount = base + fee;
    }

    /// @dev Shares a buyer with `lock` USDC can take at `price` with the fee inside.
    function _affordable(uint256 lock, uint256 price, uint256 rate) private pure returns (uint256 n) {
        n = Math.mulDiv(Math.mulDiv(lock, R - rate, R), SHARE, price);
        while (n > 0) {
            (uint256 amount,) = _buyCost(n, price, rate);
            if (amount <= lock) break;
            --n;
        }
    }

    /// @notice Quotes the fee for a fill of `quantity` shares at `price` for a taker or maker.
    function feeQuote(uint256 quantity, uint256 price, bool taker, bool buy) external view returns (uint256) {
        uint256 rate = _rate(price, taker);
        if (buy) {
            (, uint256 fee) = _buyCost(quantity, price, rate);
            return fee;
        }
        return Math.mulDiv(Math.mulDiv(quantity, price, SHARE), rate, R, Math.Rounding.Ceil);
    }

    // ---------------------------------------------------------------- matching

    /// @dev A rest is under the minimum when its notional N*p is below 1 USDC; a buy also when its lock
    /// (which carries the fee) can no longer pay for a single share. An amount-based market buy has no
    /// share count and is judged by its lock alone.
    function _underMin(Order storage o) private view returns (bool) {
        if (o.buy) {
            if (o.lock < MIN_NOTIONAL || _affordable(o.lock, o.price, _rate(o.price, false)) == 0) return true;
            return o.remaining != type(uint128).max && Math.mulDiv(o.remaining, o.price, SHARE) < MIN_NOTIONAL;
        }
        return Math.mulDiv(o.remaining, o.price, SHARE) < MIN_NOTIONAL;
    }

    /// @dev Four crossings per market: YES buy/sell and NO buy/sell (move), YES buy with NO buy (mint),
    /// YES sell with NO sell (burn). The earliest order of a crossing pair is the maker.
    function _match(bytes32 mid) private returns (uint256 fills) {
        for (uint256 steps; steps < MAX_STEPS; ++steps) {
            if (_expireHeads(mid)) continue;
            (uint64 a, uint64 b) = _cross(mid);
            if (a == 0) break;
            uint64 makerId = a < b ? a : b;
            uint64 takerId = a < b ? b : a;
            if (!_fill(mid, makerId, takerId)) break;
            ++fills;
        }
    }

    function _expireHeads(bytes32 mid) private returns (bool any) {
        uint64[4] memory heads =
            [best[mid][true][true], best[mid][true][false], best[mid][false][true], best[mid][false][false]];
        for (uint256 i; i < 4; ++i) {
            if (heads[i] != 0 && orders[heads[i]].expiry <= block.timestamp) {
                _close(heads[i], 1);
                any = true;
            }
        }
    }

    function _cross(bytes32 mid) private view returns (uint64, uint64) {
        uint64 yb = best[mid][true][true];
        uint64 ys = best[mid][true][false];
        uint64 nb = best[mid][false][true];
        uint64 ns = best[mid][false][false];
        if (yb != 0 && ys != 0 && orders[yb].price >= orders[ys].price) return (yb, ys);
        if (nb != 0 && ns != 0 && orders[nb].price >= orders[ns].price) return (nb, ns);
        if (yb != 0 && nb != 0 && uint256(orders[yb].price) + orders[nb].price >= SHARE) return (yb, nb);
        if (ys != 0 && ns != 0 && uint256(orders[ys].price) + orders[ns].price <= SHARE) return (ys, ns);
        return (0, 0);
    }

    struct FillVars {
        uint256 makerPrice;
        uint256 takerPrice;
        uint256 n;
        uint256 makerAmount;
        uint256 takerAmount;
        uint256 makerFee;
        uint256 takerFee;
        uint256 makerRate;
        uint256 takerRate;
    }

    /// @dev Returns false when nothing could fill (a side exhausted); the caller then stops.
    /// The taker's gap on this fill alone goes to msg.sender: on a buy, the limit cost n*p of the shares
    /// bought minus what they cost, taken out of the lock, so the lock keeps covering the remaining
    /// shares; on a sell, the net proceeds over n*p. An amount-based market buy has no share limit and
    /// no per-fill gap: its unspent amount returns to its trader in its own transaction.
    function _fill(bytes32 mid, uint64 makerId, uint64 takerId) private returns (bool) {
        Order storage mk = orders[makerId];
        Order storage tk = orders[takerId];
        Market storage m = markets[mid];
        FillVars memory v;
        v.makerPrice = mk.price;
        bool mint = mk.buy && tk.buy;
        bool burn = !mk.buy && !tk.buy;
        v.takerPrice = (mint || burn) ? SHARE - v.makerPrice : v.makerPrice;
        v.makerRate = _rate(v.makerPrice, false);
        v.takerRate = _rate(v.takerPrice, true);
        // quantity: bounded by each side's remaining shares and, for buyers, affordable shares
        v.n = Math.min(mk.remaining, tk.remaining);
        if (mk.buy) v.n = Math.min(v.n, _affordable(mk.lock, v.makerPrice, v.makerRate));
        if (tk.buy) v.n = Math.min(v.n, _affordable(tk.lock, v.takerPrice, v.takerRate));
        if (v.n == 0) {
            // the exhausted buyer rests no more: close it and let matching continue
            if (mk.buy && _affordable(mk.lock, v.makerPrice, v.makerRate) == 0) _close(makerId, 3);
            else if (tk.buy) _close(takerId, 3);
            else return false;
            return true;
        }
        // maker
        if (mk.buy) {
            (v.makerAmount, v.makerFee) = _buyCost(v.n, v.makerPrice, v.makerRate);
            mk.lock -= v.makerAmount;
        } else {
            v.makerAmount = Math.mulDiv(v.n, v.makerPrice, SHARE);
            v.makerFee = Math.mulDiv(v.makerAmount, v.makerRate, R, Math.Rounding.Ceil);
            balance[mk.trader] += v.makerAmount - v.makerFee;
        }
        // taker
        uint256 limitAmount = Math.mulDiv(v.n, tk.price, SHARE);
        if (tk.buy) {
            if (mint) {
                // the rest of 1 USDC per pair after the maker's share, fee inside
                uint256 base = v.n - (v.makerAmount - v.makerFee);
                v.takerFee = Math.mulDiv(base, v.takerRate, R - v.takerRate, Math.Rounding.Ceil);
                v.takerAmount = base + v.takerFee;
                if (v.takerAmount > tk.lock) {
                    // rounding pushed over the lock: the taker can afford no whole share here
                    _close(takerId, 3);
                    return true;
                }
            } else {
                (v.takerAmount, v.takerFee) = _buyCost(v.n, v.takerPrice, v.takerRate);
            }
            tk.lock -= v.takerAmount;
            if (tk.remaining != type(uint128).max && limitAmount > v.takerAmount) {
                uint256 gap = Math.min(limitAmount - v.takerAmount, tk.lock);
                tk.lock -= gap;
                balance[msg.sender] += gap;
                emit GapReturned(takerId, msg.sender, gap);
            }
        } else {
            v.takerAmount = burn ? v.n - v.makerAmount : Math.mulDiv(v.n, v.takerPrice, SHARE);
            v.takerFee = Math.mulDiv(v.takerAmount, v.takerRate, R, Math.Rounding.Ceil);
            uint256 net = v.takerAmount - v.takerFee;
            uint256 toTrader = Math.min(net, limitAmount);
            balance[tk.trader] += toTrader;
            if (net > toTrader) {
                balance[msg.sender] += net - toTrader;
                emit GapReturned(takerId, msg.sender, net - toTrader);
            }
        }
        // shares and pairs
        if (mint) m.pairs += v.n;
        if (burn) m.pairs -= v.n;
        _credit(mk, mid, v.n);
        _credit(tk, mid, v.n);
        if (mk.remaining != type(uint128).max) mk.remaining -= uint128(v.n);
        if (tk.remaining != type(uint128).max) tk.remaining -= uint128(v.n);
        ++mk.fills;
        ++tk.fills;
        balance[owner] += v.makerFee + v.takerFee;
        emit Fill(mid, makerId, takerId, v.n, v.makerAmount, v.takerAmount, v.makerFee, v.takerFee);
        _afterFill(makerId);
        _afterFill(takerId);
        return true;
    }

    function _credit(Order storage o, bytes32 mid, uint256 n) private {
        if (!o.buy) return;
        if (o.yes) positions[mid][o.trader].yes += n;
        else positions[mid][o.trader].no += n;
    }

    /// @dev Closes a filled order, a sub-minimum rest (lock refunded) or one at its fill cap.
    function _afterFill(uint64 id) private {
        Order storage o = orders[id];
        if (!o.resting) return;
        if (o.remaining == 0 || o.fills >= MAX_ORDER_FILLS) {
            _close(id, 0);
        } else if (_underMin(o)) {
            _close(id, 3);
        }
    }

    // ---------------------------------------------------------------- book

    function _before(uint64 a, uint64 b) private view returns (bool) {
        Order storage x = orders[a];
        Order storage y = orders[b];
        if (x.price == y.price) return a < b;
        return x.buy ? x.price > y.price : x.price < y.price;
    }

    function _insert(uint64 id) private {
        Order storage o = orders[id];
        uint64 prev;
        uint64 next = best[o.market][o.yes][o.buy];
        while (next != 0 && _before(next, id)) {
            prev = next;
            next = orders[next].next;
        }
        o.previous = prev;
        o.next = next;
        o.resting = true;
        if (prev != 0) orders[prev].next = id;
        else best[o.market][o.yes][o.buy] = id;
        if (next != 0) orders[next].previous = id;
    }

    /// @dev reason: 0 filled, 1 expired, 3 rest under the minimum, 4 market order rest, 5 cancelled.
    /// A buy's unspent lock always returns to its trader: the gap of every fill was already paid to
    /// that fill's transaction sender in `_fill`. Removes the order from the book and its trader's list.
    function _close(uint64 id, uint8 reason) private {
        Order storage o = orders[id];
        if (o.resting) {
            if (o.previous != 0) orders[o.previous].next = o.next;
            else best[o.market][o.yes][o.buy] = o.next;
            if (o.next != 0) orders[o.next].previous = o.previous;
            uint64[] storage mine = traderOrders[o.market][o.trader];
            uint256 i = listIndex[id];
            uint64 last = mine[mine.length - 1];
            mine[i] = last;
            listIndex[last] = i;
            mine.pop();
            delete listIndex[id];
        }
        uint256 refund;
        if (o.buy) {
            refund = o.lock;
            o.lock = 0;
            if (refund != 0) balance[o.trader] += refund;
        } else if (o.remaining != 0) {
            if (o.yes) positions[o.market][o.trader].yes += o.remaining;
            else positions[o.market][o.trader].no += o.remaining;
        }
        o.remaining = 0;
        o.resting = false;
        o.previous = 0;
        o.next = 0;
        emit OrderClosed(id, reason, refund);
    }
}
