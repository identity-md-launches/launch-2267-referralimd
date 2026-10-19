# Additional adversarial tests

These tests extend the existing suite without changing production contracts or configuration. They use the vendored Uniswap v4 PoolManager and a local ERC-20 for IMD. They need no network, fork, FFI, environment mutation, or extra dependency.

| File | Additional checks |
| --- | --- |
| `AtomicInitialization.t.sol` | Initialization before hook deployment, atomic CREATE2 deployment and initialization, invalid-price rollback, unauthorized factories and managers, repeated initialization, and uninitialized swap callbacks. |
| `HookTransactions.t.sol` | All four swap modes batched into one unlock, both currency orders, the 2% fee's integer rounding bounds, actual token movements and claim backing, underpayment and missing settlement rollback, invalid amounts and pool keys, and reward redemption after all LP liquidity is removed. |
| `RewardAccounting.t.sol` | Complete balance transfers, index coalescing, delayed pending fees, 140 balance intervals claimed in batches of 1 versus 64, zero-payment pages, failed payout rollback after cursor/fraction progress, nested unlock refusal and retry, invalid batches, and pro-rata arithmetic across the full supply. |
| `RewardLedgerInvariant.t.sol` | Random transfers and delegated transfers, complete exits to each excluded address, reentry, fees, block advancement, permissionless distributions, self/third-party claims, and invalid claims. |
| `TokenHistory.t.sol` | End-of-block history against a separate balance ledger, full-supply round trips, delegated transfers, failed-transfer rollback, zero-transfer history spam, and current/future lookup rejection. |

`InspectingSwapRouter` asserts transient deltas **inside** the active unlock callback, after each swap and after settlement. This avoids mistaking the automatic clearing of transient storage between top-level transactions for evidence of correct settlement. Its deliberately unpaid swaps must revert with `CurrencyNotSettled`; tests compare the pool, balances, allowances, checkpoints, fee index and ERC-6909 backing before and after the failed transaction.

`FundedFeeSource` is a test-only stand-in for the hook's fee-recording authority. Every recorded amount is backed by real ERC-6909 claims, with IMD paid to the real manager in the same unlock. Tests never fabricate backing by editing storage or impersonating the manager for successful payouts.

The reward invariant's oracle keeps its own current and prior-block balances and credits each holder directly at every distribution. It does not derive entitlements from the implementation's reward index, claim cursor, or checkpoint search. Eligible supply alternates between zero and `2^64`; fees are multiples of `2^64`. This makes expected rewards integral, so all finalized payouts must match exactly. Separate fuzz tests cover nonintegral ratios and fractional carry. At the end of **every** invariant run, all holders' finalized earnings must be fully claimable through bounded pagination, even if some intermediate pages pay zero.

Inline configuration sets the new fuzz properties to 1,000 runs and the new invariant campaign to 256 runs at depth 192. The repository's pinned seed is also used explicitly when checking:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x1a118de9f34d24ae397f6b2961275c7487461451106fbb7d428e8920caa50b30 forge test
```

Scope limits: the small factory helper tests only hook deployment/initialization boundaries. It is not the production launch factory and cannot attest the 10%/85%/5% launch allocation, live IMD behavior, mainnet deployment addresses, or transaction receipts. The mainnet/factory rehearsal and launch verification remain external checks. The reward tests exercise the implementation's documented one-block balance lag. No new production defect was reproduced by this suite.
