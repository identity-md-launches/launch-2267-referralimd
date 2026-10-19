# Independent hook review

Reviewed on 2026-10-19 by a separate review agent from the implementing agent. This is an independent source review within the contributor workflow, not a claim of a professional third-party audit or of mainnet deployment.

## Scope and evidence

Reviewed `src/ReferralHook.sol`, its interaction with `RewardDistributor` and `ReferralIMD`, the vendored v4-core `Hooks`, `PoolManager`, `ProtocolFees` and delta types, and the supplied protected hook/owner/token checks and security reference. Production source was not modified by this reviewer.

The independent adversarial suite used actual deployed v4 `PoolManager` contracts and CREATE2-mined hook addresses, not a mock manager. It ran with Solidity 0.8.26 and the repository's pinned fuzz seed `0x1a118de9f34d24ae397f6b2961275c7487461451106fbb7d428e8920caa50b30`.

Independent check result: **6 tests passed**, including 256 fuzz cases, with no unresolved exploitable hook defect found in this review. The scratch suite exercised:

- All four buy/sell and exact-input/output combinations, in both currency sorting orders, with arbitrary `hookData`.
- Exact fee formulas, physical trader balances, distributor claim credits and zero transient hook currency deltas after settlement.
- Every trade amount from 1 through 100 minor units in all eight mode/order combinations.
- Atomic rollback on specified-IMD partial fills; fees based on executed amounts for unspecified-IMD partial fills.
- Factory LP fee collection through a zero liquidity change.
- Protocol fees enabled at 1,000 pips in each direction, preserving the hook's fee calculation.

The reviewer used `forge test --match-contract HookReview --skip test/Hook.t.sol -vv` while the permanent integration suite was being edited. Temporary review scaffolding was under `test/scratch/hook-review/`, which the assignment removes before submission. The delivered project tests provide the persistent verification suite; the scratch tests are supplementary review evidence.

## Accounting and authorization conclusions

The low address bits are exactly `0x20cc`: before-initialize, before-swap, after-swap, and both swap return-delta permissions. Construction validates these bits against `getHookPermissions`. Only the configured manager can enter callbacks. Initialization additionally checks the configured factory and the complete immutable pool key; no alternate pair, fee, tick spacing or hook address can bind the instance.

Fees are measured against the gross IMD side. Let `G` denote gross IMD, `N` the desired net IMD output, and `P` the core pool's IMD input before the additional hook fee:

| Trade | Fee and callback |
| --- | --- |
| Buy, exact input | `floor(G / 50)` in `beforeSwap`; pool receives `G - fee` |
| Sell, exact output | `ceil(N / 49)` in `beforeSwap`; pool supplies `N + fee` |
| Buy, exact output | `ceil(P / 49)` in `afterSwap`; caller pays `P + fee` |
| Sell, exact input | `floor(G / 50)` in `afterSwap`; caller receives `G - fee` |

The hook's `mint(distributor, IMD, fee)` first debits its manager delta while creating an equal ERC-6909 credit for the distributor. The callback's positive fee delta offsets that debit and charges the trader. Redemption burns the distributor's own claim and takes the same currency and amount. No fee token must physically leave the manager during the swap, so collection does not depend on an already-funded IMD balance or on a native ETH transfer.

The before-swap delta cannot consume an entire exact-input order or reverse its sign. The exact-output gross-up increases the core order rather than replacing it. The amount bound prevents signed-minimum negation and reserves cast headroom. Both collection and fee assignment revert with any unsuccessful swap.

Neither router identity nor arbitrary `hookData` gives a fee exemption, payout destination, or accounting authority. The hook exposes no method that calls `PoolManager.swap`, so v4's self-call callback suppression does not create a reachable fee bypass through the hook. There are no LP removal callbacks, hence factory zero-liquidity fee collection is unaffected.

## Material design limitations and operational checks

1. **Specified-side partial fills revert.** Exact-input buys and exact-output sells with a restrictive price limit or insufficient available liquidity fail atomically. This avoids charging a fee calculated from an unexecuted requested amount. Routers must surface this behavior and retry with a smaller order or a deliberately changed price limit; they must still enforce user slippage constraints.
2. **The 2% is the hook levy.** The policy's immutable 1.25% LP fee, and any manager protocol fee, are additional pool charges. The total trading cost is consequently higher than 2%; it also includes price impact. Integer amounts require the rounding shown above, with small dust trades sometimes generating zero hook fee.
3. **Rewards use finalized balances.** Fees in block `b` use balances at the end of `b-1`, and are claimable after block `b` ends. This prevents atomic flash-balance capture, but a seller retains that block's prior-balance entitlement and a new buyer begins earning in the next block. Holdings across consecutive blocks can still be acquired strategically; this is a balance-snapshot reward design, not a guarantee against all MEV.
4. **Coverage is limited to this pool.** An immutable transferable ERC-20 cannot force independently created pools, peer-to-peer transfers or other venues to use this hook. Their transactions do not generate this levy.
5. **Manager custody is excluded as a whole.** v4 uses singleton custody. RIMD physically held by the configured manager is ineligible, including tokens represented by manager claims, rather than attempting to attribute individual pool balances inside the singleton.
6. **The pair is a deployment trust boundary.** The deployer must supply the stated Ethereum IMD address, a correct live v4 manager and the actual launch factory. The constructor intentionally does not demand external deployed code so the launch's empty-chain constructor checks work. There is no owner who can repair an incorrect constructor argument. A paused, rebasing or transfer-tax IMD token would introduce availability or accounting behavior outside the assumed standard ERC-20 pair.
7. **Review does not replace deployment verification.** No mainnet fork, live factory deployment, funded signing, external audit firm, formal proof, Slither or Mythril run was performed by this reviewer. The separate launch process must verify the final creation/runtime bytes, mined permissions, actual constructor arguments, pool parameters, supply split and resulting transaction receipts.

The current hook exposes no mutable fee, admin withdrawal, upgrade, owner switch, caller-supplied reward destination, token allowance, or arbitrary external call target. These conclusions apply to the reviewed source and vendored manager behavior, not to an unseen deployment or future changed code.
