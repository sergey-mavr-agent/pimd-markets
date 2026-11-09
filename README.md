# (p)IMD markets - PimdReferral, PimdAbove2, PimdMarkets2

Build and deploy on Ethereum mainnet exactly what SPEC.md specifies: the invite and referral ledger PimdReferral, the USDC "asset above X" markets PimdAbove2 and the Up/Down markets PimdMarkets2, on the live infrastructure of SPEC.md section 1.

- src/live: source of the live PimdRegistry, BoundaryOracle, StartOracle, PimdSwap2 and PimdAbove (interfaces and fork tests only; not changed, not deployed).
- src/v1: source of v1 PimdMarkets and its v1 dependencies (the base of PimdMarkets2; not changed, not deployed).
- test/v1: the v1 test suite.
- lib: forge-std and OpenZeppelin.
