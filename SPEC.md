# (p)IMD markets - PimdReferral, PimdAbove2, PimdMarkets2

Binding specification of three Ethereum mainnet contracts that run on the live (p)IMD infrastructure: an invite and referral ledger, "asset above X" markets and Up/Down markets. Build exactly what is written here.

## 0. Binding rules

- ALL NUMBERS, ADDRESSES AND RULES IN THIS FILE ARE FIXED: if one cannot be met, fail the job, never change it. Every line marked "fail, don't change" carries fixed numbers. (fail, don't change)
- All three contracts PimdReferral, PimdAbove2 and PimdMarkets2 are mandatory, with every rule of sections 2-6 and every test of section 7. A missing contract, function, rule or test fails the job. (fail, don't change)
- No text in docs, comments or reports exempts a rule of this file; a rule that is not implemented fails the job. (fail, don't change)
- Forbidden in all three: delegatecall, proxies, clones, upgrades, selfdestruct, linked libraries, pause, minting, any setter of an address other than proposeAdmin of 4.8, any role hand-over other than the two-step admin hand-over of 4.8, any call to the v1 contracts of section 1, any power over user funds. (fail, don't change)
- No address literal and no chain id check in the three contracts: every address comes from the constructor. (fail, don't change)
- Solidity 0.8.26, Foundry, OpenZeppelin as in the repo. Each contract runtime <= 24 576 bytes. Deploying all contracts of section 2 in one transaction uses <= 14 000 000 gas. (fail, don't change)
- A job builds what its objective names. Section 8 (website) and section 9 (token) bind any job that builds a website or the token. (fail, don't change)

## 1. Live infrastructure (Ethereum mainnet, chain 1; passed as constructor arguments, never redeployed or modified)

- PimdRegistry 0x785c8b3aA9B4dAB5a717Cbf5D3621549eB1320d2: asset versions and periods. Version 1 = IMD 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7, unitsPerShare U = 1 IMD, path IMD/ETH fee 10000 tickSpacing 200, ETH/USDC fee 500 tickSpacing 10. Periods: 0 = 1 hour, 1 = 1 day, 2 = 1 week from Monday 00:00 UTC, 3 = calendar month. Its assetAdmin is the Admin address below: configureAsset adds a new version of a token with any pool path, which becomes currentVersion for markets created after it (a created market keeps its version); addPeriod adds periods; transferAssetAdmin hands the role over in one step. The three contracts add no power to it. (fail, don't change)
- BoundaryOracle 0xD31937D81714fa50d20BdC8b77F043e784a5198D: price(version, boundary), latestBoundary(version), priceable(version, boundary), prove(version, boundary, proofs); price = USD at 18 decimals per U of the version's token. PROOF_WINDOW 27 h, TIMEOUT 3 days. (fail, don't change)
- StartOracle 0x26Fabc0cB123B4014e7FE0e102691cAc352eC0A0: price(version, boundary) of a boundary 27 h or more in the past, recorded by anyone through request(version, boundary, firstBlock), the caller pays BoundaryOracle.oracleCost(version) in IMD. (fail, don't change)
- PimdSwap2 0xaB901e99D5853486Bbd41b4308F306799108199F: exactOutput(version, usdcOut, maxAssetIn) swaps the version's token into exact USDC along the version's path; the unused input returns to the caller. (fail, don't change)
- USDC 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 (6 decimals). (fail, don't change)
- Treasury 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C: the deploying wallet ($owner); receives the protocol part of every fee and grants genesis invites; no other power. (fail, don't change)
- Admin 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981: the first admin of PimdAbove2 (fee rates, the featured list of 4.5 and the two-step admin hand-over of 4.8) and the assetAdmin of the live PimdRegistry above; no other power. (fail, don't change)
- v1 contracts PimdRegistry 0x99BF2c49b25bdFF7bAA36A248Bd27072C90dfA35, BoundaryOracle 0x2CED79eba39EE972c6C4F7Dd51A08f28DC034555, PimdMarkets 0x6804CA9b86731056Bb8E7976086C58E3E37047DB: never called by the new contracts. (fail, don't change)
- The source of the live contracts above is in the repo for interfaces and fork tests only; it is not changed and not deployed. (fail, don't change)

## 2. Contracts, deploy order (one transaction, all or nothing)

1. PimdReferral(treasury $owner). (fail, don't change)
2. PimdAbove2(registry 0x785c8b3aA9B4dAB5a717Cbf5D3621549eB1320d2, boundaryOracle 0xD31937D81714fa50d20BdC8b77F043e784a5198D, usdc 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, admin 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981, treasury $owner, referral $contract:PimdReferral). (fail, don't change)
3. PimdMarkets2(treasury $owner, registry 0x785c8b3aA9B4dAB5a717Cbf5D3621549eB1320d2, boundaryOracle 0xD31937D81714fa50d20BdC8b77F043e784a5198D, swap 0xaB901e99D5853486Bbd41b4308F306799108199F, startOracle 0x26Fabc0cB123B4014e7FE0e102691cAc352eC0A0, usdc 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, referral $contract:PimdReferral). (fail, don't change)
- Paths: src/PimdReferral.sol, src/PimdAbove2.sol, src/PimdMarkets2.sol; a helper of the size rule below as src/<contract>Math.sol; new tests under test/. (fail, don't change)
- Every constructor reverts on a zero address. The constructors of PimdAbove2 and PimdMarkets2 call referral.register(); the deploy transaction fails if either call fails. (fail, don't change)
- A runtime over 24 576 bytes: move only pure and view math (fee, quote, level math) into one helper contract per contract, deployed in the same transaction right before it and passed as a $contract: argument, called with CALL or STATICCALL; a helper holds no funds and no state. At most 2 helpers, at most 5 contracts in total. (fail, don't change)
- The gas and size report lists each contract's runtime bytes and the measured gas of the whole deploy transaction on a mainnet fork. (fail, don't change)

## 3. PimdReferral

### Roles and registration
- treasury: immutable; only grantInvites. (fail, don't change)
- register(): accepted only from a contract constructor in the block of PimdReferral's deployment and only twice; the two callers are the markets, readable as markets(0) and markets(1); any later call reverts Unauthorized. (fail, don't change)
- record(...) is accepted only from the two markets, else Unauthorized. (fail, don't change)

### Invites and binding
- Anyone trades without a code. A referrer = a wallet that holds invites: a wallet that used an invite code, or a genesis wallet. (fail, don't change)
- grantInvites(address[] wallets, uint256[] n): treasury only, else Unauthorized; equal lengths of 1 to 50 and every n[i] >= 1, else revert; adds n[i] invites to wallets[i] and marks it Genesis, one InvitesGranted event per wallet; at most 50 invites over all calls, over it the whole call reverts. No other effect. (fail, don't change)
- createInvite(bytes32 code): a referrer with an invite left turns one invite into the code; code != 0 and never seen before, else revert. (fail, don't change)
- useInvite(bytes32 code): binds the caller to the code's creator forever and spends the code. Reverts if the code is unknown or spent, the caller is the creator, the caller is already bound, or the caller already has a direct referral. Any time, also after the caller traded. (fail, don't change)
- A wallet that used a code becomes a referrer with 3 invites. (fail, don't change)
- Every referrer gets +3 invites for every full 25 USDC of fees paid by its direct referrals after their binding. Invites left = granted + 3 if bound by a code + 3 * floor(referral fees / 25 USDC) - codes created. (fail, don't change)

### Fee split (applied by both markets to every fee of every fill)
- f = the protocol fee a trader pays in a fill, in the fee's coin (PimdAbove2: the order's fee; PimdMarkets2: the maker fee, or the taker fee minus the maker rebate of 6.4). (fail, don't change)
- Trader not bound: all of f to the treasury. (fail, don't change)
- Trader bound: 5% of f back to the trader (discount); its referrer the level share of f; the referrer's own referrer 5% of f (second tier, no deeper tier); the treasury the rest, at least 60% of f. Each share rounds down, the treasury gets every rounding unit. (fail, don't change)
- Level shares: L1 10% from the start; L2 20% once direct referrals paid >= 50 USDC of fees after binding and >= 5 of them are active; L3 30% once >= 500 USDC and >= 20 active. Active referral = a direct referral that paid >= 5 USDC of fees in total. A level never drops. A fill uses the level stored before that fill is recorded. (fail, don't change)
- Shares are credited in the same fill, in the fee's coin (USDC for PimdAbove2 and UP fees, the asset token for DOWN fees), to the free balance of each receiver inside that market; withdraw any time. (fail, don't change)
- Only fills after a binding pay shares and count toward its referrer's thresholds and invites. (fail, don't change)
- In this section, fees = f. Fees count in USDC with 6 decimals: a USDC fee as is; an asset fee as fee * P / U, P = the price PimdMarkets2 uses for that fill (6.4). (fail, don't change)
- Example: fill of 100 USDC at 0.50 in PimdAbove2, taker fee 2.5 USDC. Bound trader with an L1 referrer that has a referrer: trader 0.125, referrer 0.25, second tier 0.125, treasury 2. L2: referrer 0.5, treasury 1.75. L3: referrer 0.75, treasury 1.5. Unbound trader: treasury 2.5. Bound trader whose referrer has no referrer, L1: trader 0.125, referrer 0.25, treasury 2.125. (fail, don't change)

### Points and views
- Points (6 decimals, 1 point = 1 USDC): a wallet's own fees in USDC + 10% of the fees its direct referrals paid after binding. Points are a view, not a token, never transferred. (fail, don't change)
- Views: referrerOf(wallet); stats(wallet) = (referrer, genesis, isReferrer, level, invitesLeft, ownFees, referralFees, directReferrals, activeReferrals, points); codeOf / creatorOf(code); referrerCount() and referrerAt(i) over every referrer, for leaderboards by referral fees; genesisGranted() = invites granted over all grantInvites calls, genesisLeft() = 50 - genesisGranted(). (fail, don't change)
- Events: InvitesGranted, InviteCreated, Bound, FeeRecorded(trader, coin, f, discount, referrer, referrerShare, secondTier, secondTierShare), LevelUp. (fail, don't change)

## 4. PimdAbove2 (USDC only, no token, pool or swap)

The code of the live PimdAbove (src/live/PimdAbove.sol), changed only so (4.1-4.8); every other rule of that code and of this section stays as is. (fail, don't change)

### Changes
- 4.1 No createMarket and no admin market creation. A market key = (version, period, end, threshold); place(key, order) and split(key, n) create the market when it does not exist, by anyone, in that transaction; the same key always gives the same market id. (fail, don't change)
- 4.2 A key is valid when: version = registry.currentVersion(token of that version); end is a boundary of that registry period and after now; threshold > 0 and <= 1e30, with at most 3 significant digits (after removing trailing zeros the number is <= 999); the version's path ends in the constructor's USDC. Else InvalidMarket. (fail, don't change)
- 4.3 Price improvement belongs to the order: every unit of a buy's lock that a fill does not spend stays in that order and returns to its trader when the order closes; a seller gets its whole proceeds minus the fee; matchMarket pays its caller nothing. (fail, don't change)
- 4.4 Fees split by PimdReferral as in section 3; the treasury part to the treasury's free balance. (fail, don't change)
- 4.5 Featured list: setFeatured(bytes32[] ids) by admin only, else Unauthorized; replaces the whole list; at most 32 ids, each an existing market, else revert; featured() returns it; event FeaturedSet. No other effect. (fail, don't change)
- 4.6 Volume: each market stores volume = the sum over its fills of the maker's and the taker's USDC amounts, fees inside. (fail, don't change)
- 4.7 Insertion: a new order walks at most 128 resting orders of its book; beyond that it needs an insertion hint (a resting order of the same book placed before it), else InsertionHintRequired. (fail, don't change)
- 4.8 USDC from the constructor; treasury immutable. Admin powers: setRates within the caps, setFeatured and the two-step admin hand-over only. Hand-over: proposeAdmin(newAdmin) by the admin only, else Unauthorized; newAdmin != 0, else revert; it replaces any pending proposal and changes nothing else; acceptAdmin() by the proposed address only, else Unauthorized, makes it the admin and clears the proposal; pendingAdmin() returns the proposal; events AdminProposed, AdminTransferred. PimdAbove2 has no transferAdmin. (fail, don't change)

### Market rules (unchanged)
- Market = asset version, registry period, end boundary, threshold X in USD at 18 decimals per U of the version's token. One market per key; a ladder = several thresholds on one end. No start price. (fail, don't change)
- Pair = 1 YES + 1 NO, backed by exactly 1 USDC; split(n): n USDC into n YES + n NO, merge(n) back. Shares have 6 decimals. (fail, don't change)
- Close = the version's price at the end boundary in BoundaryOracle. YES wins if close > X, NO if close < X: a winner redeems 1 USDC, a loser 0. Close = X, or no close 3 days after the end: every share redeems 0.5 USDC. (fail, don't change)
- YES and NO books, price p in USDC per share, 0.0001 to 0.9999, tick 0.0001. Buy N at p locks exactly N*p USDC, fee inside: it spends at most the lock, gets (amount - fee)/p shares, stops at N shares. Sell N locks only those N shares. (fail, don't change)
- Buy with Sell of the same side moves shares; Buy YES with Buy NO mints pairs, Sell YES with Sell NO burns pairs, exactly 1 USDC each. The maker (earlier order) fills at exactly its price, the taker pays or gets the rest of 1 USDC within its limit, else both rest. (fail, don't change)
- Price then time priority, partial fills, up to 64 fills per transaction, 1024 per order. Market orders: size or USDC amount + worst price, the unfilled rest returns in that transaction. Min order N*p >= 1 USDC; a partly filled order's rest under it is cancelled in that transaction, lock refunded. Limit expiry user-set, >= 5 minutes; a fill skips an expired order and moves its lock to its owner's free balance. Cancel any time; claim also cancels the caller's orders there. Resting orders match via matchMarket by anyone. (fail, don't change)
- Orders, fills, split and merge go on after the end until settlement; from settlement only cancel, claim and withdraw. Internal USDC balance: deposit credits exactly the amount received, else reverts; withdraw free balance any time. (fail, don't change)
- Fee (none on cancel, expiry, split, merge, claim) = k*(1-q) of the amount in USDC, q = the fill price per share clamped 0.01..0.99: taker k = 0.05, maker k = 0.01, no rebate. Admin sets taker k <= 0.10 and maker k <= 0.05, over a cap reverts, event, for later fills only. (fail, don't change)
- Example, both unbound: Dave's resting buy 10 YES at 0.4 (lock 4 USDC), Bob's market buy NO for 6 USDC, worst 0.62: 9.8 pairs. Bob q = 0.6, fee 0.12, gets 9.8 NO. Dave q = 0.4, pays 3.9437, fee 0.0237, gets 9.8 YES; his 0.0563 USDC rest under the min is refunded. Treasury gets 0.1437. X = 3: close 3.01 pays Dave 9.8 USDC, close 3 pays 4.9 each. (fail, don't change)

## 5. PimdMarkets2 (Up/Down)

The code of v1 PimdMarkets (src/v1/PimdMarkets.sol, the runtime of 0x6804CA9b86731056Bb8E7976086C58E3E37047DB), changed only so (5.1-5.9); every other rule of that code and of section 6 stays as is. (fail, don't change)

- 5.1 Registry, oracle and swap are the live PimdRegistry, BoundaryOracle and PimdSwap2 of section 1; USDC from the constructor; StartOracle and PimdReferral added as immutables. (fail, don't change)
- 5.2 No open pairs limit: the registry's maxOpenPairs (0 in every live version) is never read; mints are bounded only by the orders. (fail, don't change)
- 5.3 Up/Down only: MarketSpec.strike must be 0, else InvalidMarket; no ladder markets. (fail, don't change)
- 5.4 A market is created by the first place, placeWithProofs or split of anyone for any valid period start (registry.bounds(period, start).start = start, end after now) of any token with a registry version; the version's path must end in the constructor's USDC, else InvalidMarket. (fail, don't change)
- 5.5 Strike = BoundaryOracle.price(version, start) if not 0, else StartOracle.price(version, start). Orders, split and matchMarket revert while BoundaryOracle.priceable(version, start) is false and StartOracle.price(version, start) is 0; merge, cancel, expire and claim stay open. Once StartOracle records the start price, trading opens. (fail, don't change)
- 5.6 Settlement close = BoundaryOracle.price(version, end) only; a StartOracle price never closes a market. No strike or no close 3 days after the end: Refund. (fail, don't change)
- 5.7 Fees split by PimdReferral as in section 3, the treasury part to the treasury's free balance, in the fee's coin. (fail, don't change)
- 5.8 Every resting order's unspent lock returns to its own trader; no fill pays any part of an order's lock to anyone else, and matchMarket pays its caller nothing. (fail, don't change)
- 5.9 Volume: each market stores volume = the sum over its fills of filled shares * x, in USDC with 6 decimals (x = the fill price of 6.1), readable by market id; mint, move and burn fills all count. (fail, don't change)

## 6. Up/Down rules (v1, unchanged)

- Market = (token, registry period, start); it pins registry.currentVersion(token) at creation forever, U = its unitsPerShare. (fail, don't change)
- Pair = 1 UP + 1 DOWN, backed by exactly 1 USDC + U asset token. Up: an UP share redeems 1 USDC + U, DOWN 0; Down: a DOWN share redeems 1 USDC + U, UP 0; Refund (close = strike, or no strike or close 3 days after the end): an UP share redeems 1 USDC, a DOWN share U. Shares have 6 decimals. (fail, don't change)
- 6.1 One book, price x = USDC per UP share, tick 0.0001 USDC. Bids: BuyUp, SellDown; asks: SellUp, BuyDown. BuyUp locks N*x USDC; BuyDown locks N*U token and N*(1 - x) USDC when x < 1 (gets N*(x - 1) USDC when x > 1); an asset-only BuyDown swaps the USDC part from its token via PimdSwap2 at fill, budget >= the estimate + 5%. (fail, don't change)
- 6.2 Min order N*x >= 1 USDC. Up to 64 fills per transaction, 1024 per order; insertion walks at most 128 orders, beyond that a hint is required. Limit expiry >= 5 minutes and <= the market end; immediate-or-cancel orders close their rest in that transaction. Orders only before the end. (fail, don't change)
- 6.3 The maker (earlier order) fills at exactly its price. Buy with Buy mints pairs, Sell with Sell burns pairs, Buy with Sell moves shares. (fail, don't change)
- 6.4 P = BoundaryOracle.price(version, latestBoundary(version)), USD per U; no price = MissingPrice. V = 1 + P. q = x / V clamped 0.01..0.99. Fee per share = k * q * (1 - q) * V USDC, taker k = 0.07, maker k = 0.01; a DOWN-side order pays its fee in the asset token (fee in USDC * U / P). The maker gets a rebate of 1/4 of the taker fee, in the taker's coin. (fail, don't change)
- 6.5 Fee budget per order >= its own full fee at its limit price; placeWithProofs and claimWithProofs take at most 2 BoundaryOracle proofs, a boundary already priced is skipped. (fail, don't change)
- 6.6 Balances: internal USDC and each registry token; deposit credits exactly the amount received, else reverts; withdraw free balance any time. (fail, don't change)
- Example, IMD version 1, U = 1 IMD, P = 2.6758: a resting SellUp 5 at x = 1.8379 USDC and a BuyUp taker of 5: q = 0.5, taker fee 0.321633 USDC, maker fee 0.045948 USDC, rebate 0.080408 USDC to the maker, taker f = 0.241225 USDC. Taker bound, L1 referrer with a referrer: taker 0.012061, referrer 0.024122, second tier 0.012061, treasury 0.192981. A resting BuyUp 5 at 1.8379 and a BuyDown taker of 5 (mint): taker fee 0.120200500784812019 IMD, rebate 0.030050125196203004 IMD, f = 0.090150375588609015 IMD, counted as 0.241224 USDC. (fail, don't change)

## 7. Tests (Foundry; mainnet fork against section 1 unless stated)

- Deploy test: the three contracts in the order of section 2 with the section 1 addresses in one transaction on a mainnet fork; gas <= 14 000 000 and each runtime <= 24 576 bytes asserted and printed. (fail, don't change)
- Multichain test: on a local chain (chain id 31337) the three deploy with mock USDC, registry, oracles and swap at other addresses and use only those addresses. (fail, don't change)
- PimdReferral: grantInvites by anyone but the treasury reverts; one call grants 1 invite to each of 30 wallets and a second call 20 invites to 20 other wallets, all Genesis, genesisGranted() = 50, genesisLeft() = 0, then a grant of 1 reverts; unequal lengths, an empty array, 51 wallets and n = 0 revert; a call whose sum passes 50 reverts as a whole. A code user has 3 invites, the 4th createInvite reverts; a used or unknown code reverts; own code reverts; second binding reverts; a wallet with a direct referral cannot bind; binding after trading pays nothing on earlier fills. (fail, don't change)
- Levels: 49.99 USDC + 5 active = L1; 50 + 4 active = L1; 50 + 5 = L2; 499.99 + 20 = L2; 500 + 19 = L2; 500 + 20 = L3; active at 4.99 no, 5 yes; level after a later fill never lower. (fail, don't change)
- Invites: 24.99 USDC of referral fees = +0, 25 = +3, 50 = +6. Points: own fees 10 USDC = 10 points; direct referrals paid 100 USDC after binding = +10 points. (fail, don't change)
- Fee split: the section 3 example to the unit for L1, L2, L3, unbound, no second tier; a fuzz test over fees and levels: shares sum to f exactly and the treasury gets >= 60% of f. (fail, don't change)
- register: a third call, a call in a later block and a call from an EOA revert; record from any non-market reverts. (fail, don't change)
- PimdAbove2: a wallet that is not the admin creates a market by place and by split; the same key twice gives one market; end not a boundary, end in the past, threshold 0, 1e30 + 1, 3.255 USD and an old version revert; 3.25 USD accepted. Featured: non-admin reverts, 33 ids revert, an unknown id reverts, a second call replaces the list. Admin hand-over: proposeAdmin by a non-admin reverts, proposeAdmin(0) reverts, acceptAdmin by any wallet but the proposed one reverts; before acceptAdmin the old admin keeps setRates and setFeatured and the proposed one has neither; a second proposeAdmin replaces the first and acceptAdmin by the first address reverts; after acceptAdmin only the new admin calls setRates, setFeatured and proposeAdmin, the old admin reverts Unauthorized; transferAdmin does not exist. Volume equals the sum of fill amounts. (fail, don't change)
- PimdAbove2 price improvement: 1030 asks of 2 YES at 0.50 rest; Alice bids 6000 YES at 0.99 (lock 5940 USDC); Carol calls matchMarket 15 times until the 1024-fill cap: Carol gets 0 USDC, Alice gets back her whole lock minus the amounts and fees of her fills, exactly. (fail, don't change)
- PimdAbove2 unchanged rules: YES and NO payouts, tie and no close after 3 days 0.5 / 0.5; the Dave example to 4 decimals for both fees; mint, move and burn fills; orders before the end filling after it; expired order skipped, lock to owner's free balance; sub-min rest auto-cancelled; setRates only by admin, over a cap reverts, a new rate only for later fills; 1000 resting orders at one price: a hinted insert works, an unhinted one past 128 reverts InsertionHintRequired. (fail, don't change)
- PimdMarkets2: the v1 test suite (test/v1) adapted to 5.1-5.9, all green. (fail, don't change)
- PimdMarkets2 new: a wallet that is not the treasury or admin creates hour, day, week and month markets of IMD by place, placeWithProofs and split; strike != 0 reverts; 1 000 000 pairs mint with no cap; strike proved under 27 h; at 27 h with no price, place and split revert until a StartOracle price for the start is mocked, then trade; settle uses that StartOracle price as strike and BoundaryOracle at the end as close; no close 3 days after the end = Refund. (fail, don't change)
- PimdMarkets2 fees: the section 6 example to the unit, maker and taker sides; a DOWN taker's shares paid in IMD; referral thresholds counted from the IMD fee times P; a resting bid matched by a third party: the caller gets nothing, the bid's trader keeps its unspent lock. Volume equals the sum of shares * x over mint, move and burn fills. (fail, don't change)
- No test is skipped; a failing or skipped test fails the job. (fail, don't change)

## 8. Website

- Every page reads PimdReferral, PimdAbove2, PimdMarkets2, PimdRegistry, BoundaryOracle and StartOracle through public RPCs; the site stores, signs and relays nothing. No third-party script, font or frame loads before Connect. (fail, don't change)
- Addresses come from one config keyed by chain id; a network switch lists every configured network (Ethereum mainnet). (fail, don't change)
- Up/Down: the current hour, day and week market of every registry asset is always shown, also when it does not exist on chain yet (empty book; the first order or split creates it). "Price to beat <start date hour> UTC". (fail, don't change)
- Opening by proofs: an order on a market whose start has no BoundaryOracle price and is under 27 h in the past goes through placeWithProofs, which opens hour, day, week and month markets by any wallet; the site builds the BoundaryOracle proofs of that start in the browser from public RPC data and the wallet signs and sends them; the site stores and relays no proof. The order form shows "Opens with your order" and the proof gas in ETH and USD at the live gas price. (fail, don't change)
- Proof RPCs: the config lists at least two keyless public RPCs that answer eth_getProof for a block 8 200 blocks old and allow the site's origin (CORS), checked when the site is built (for example eth-mainnet.public.blastapi.io and rpc.mevblocker.io), plus any keyless public RPC for recent blocks; the site tries them in order and checks every built transaction by eth_call before the wallet signs; no RPC key anywhere in the site; Settings has a "Custom RPC" field kept only in the user's browser. (fail, don't change)
- Close by proofs: on a market whose end has no BoundaryOracle price and is under 27 h in the past, Claim proves the close in the same transaction (PimdMarkets2 claimWithProofs) or sends BoundaryOracle.prove right before claim (PimdAbove2), and any wallet sees a "Prove close" button there; the outcome is shown from the same proofs before signing. (fail, don't change)
- A market whose start is 27 h or more in the past and that has no strike in BoundaryOracle or StartOracle accepts no order on the site and is shown as "opens <start date of the next market of that period> UTC" in place of its price and order form. (fail, don't change)
- The site shows no StartOracle button and sends no StartOracle transaction anywhere. (fail, don't change)
- Above: per date every threshold "IMD above $X" with YES and NO prices in USDC; the main page shows the featured markets sorted by volume, or the most traded markets when the featured list is empty; tab "All" lists every market, all tradable; any wallet opens a new threshold by its first order or split. (fail, don't change)
- Every money field shows the balance with Max; an amount above the balance is blocked in plain English. (fail, don't change)
- Referral: an "Invite code" field, own codes with "Invites left N", the Genesis badge, the level with progress to the next one, points, and a leaderboard of referrers by referral fees. (fail, don't change)
- Page "Old contract": reads v1 PimdMarkets 0x6804CA9b86731056Bb8E7976086C58E3E37047DB, lists the wallet's free balance and open orders there, with Cancel and Withdraw buttons signed by the wallet. (fail, don't change)
- Tab pIMD: the token of section 9; 0xC89131eDC1dDf3503D2bd5f7E98a16c1C67Fa17B appears only there, as "old token, not supported". (fail, don't change)

## 9. Token

- Name "(p)IMD", symbol "pIMD", 18 decimals, total supply 1 000 000 000; no owner, mint, burn, fee, pause or upgrade. (fail, don't change)
- Tokenomics: 35% pool, 10% swarm, 55% to the owner, of which 50% of the supply burned to 0x000000000000000000000000000000000000dEaD by the owner after launch. (fail, don't change)
- The token holds no market rights: markets need no token address. (fail, don't change)
