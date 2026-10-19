# Independent local review: token and holder rewards

## Scope and status

An independent agent reviewed `src/ReferralIMD.sol` and `src/RewardDistributor.sol`, and inspected `ReferralHook._collect` to establish how rewards are funded. This is a local adversarial review, not an external audit certification or a claim that the entire contributor swarm has approved deployment. The review did not deploy or broadcast anything.

No confirmed critical, high, medium, or low security finding was identified in the reviewed token and reward implementation. This conclusion is limited to the code and tests described below; it does not establish that the mainnet pair token or deployment configuration is correct.

The reviewed source SHA-256 hashes, before subsequent formatting, were:

| File | SHA-256 |
| --- | --- |
| `src/ReferralIMD.sol` | `209f498d19c1cdc55e9b2dbedb7006e5ddb4844a45d7c2d5f3f69e43294843b4` |
| `src/RewardDistributor.sol` | `5c0bd6e68fd97cc7b0dbea9f030736665da9e1cca2f67c828f592ddf3c6438da` |

## Accounting examined

The token mints its fixed supply once and has no external mint, burn, ownership, upgrade, fee, or configuration function. Its transfer override records post-transfer balances without making an external call. Multiple transfers in a block overwrite that block's checkpoint, and zero/self transfers cannot add checkpoints. Past queries reject the current and future blocks. Before deployment, both historical total supply and historical balances are zero.

Fees assigned in block `B` use balances at the end of `B - 1`. The denominator subtracts the same excluded addresses that claims reject: the PoolManager, the burn address, the hook, and this reward distributor. The zero address cannot hold tokens because the ERC-20 rejects transfers to zero.

For a balance checkpoint `b` at block `t`, followed by a checkpoint at `u`, that balance earns the reward-index increments in blocks `t + 1` through `u`, inclusive. The claim calculation correctly uses `b * (indexAt(u) - indexAt(t)) / 2^128`. A partial interval uses the stored `throughBlock` as its lower boundary, and claims only consume finalized blocks through `block.number - 1`.

The cursor remains at the current interval when its endpoint is the finalized block. Once a later checkpoint closes the interval, the next call advances to it without repeating already accounted rewards. A claim capped at one interval may need an additional call to advance a boundary already accounted in an earlier claim; this is a small gas inefficiency, not loss or duplication of entitlement.

Global index increments round down. Each account retains the fractional remainder from its own multiplication, so splitting claims or transfer intervals does not discard that account's fractional entitlement. With fixed supply `10^27`, global truncation is less than `10^27 / 2^128`, approximately `2.94e-12` IMD minor units, per index increment. Account fractions and global rounding residue remain backed by the distributor's ERC-6909 claims; there is no privileged dust withdrawal.

The hook mints a matching IMD claim before recording a fee. Reward accounting therefore does not depend on when underlying IMD is redeemed. Zero eligible supply leaves fees pending; the next eligible fee recording or a permissionless `distribute()` call assigns them using its prior-block denominator.

## Access control and external interactions

Only the immutable hook can record fees. `claimFor` pays the named beneficiary regardless of caller, updates claim progress before interacting with the manager, and is reentrancy guarded. A payout failure reverts the progress, claimed total, and manager claim burn atomically. The unlock callback requires the immutable manager, an active claim, and exactly the encoded active claim data; it clears the active marker before burning claims and taking IMD. No caller-selected token, manager, payout destination, or arbitrary call target is accepted.

The permissionless `distribute()` function can be called during a token callback but only changes current-block index data. Claims use strictly older blocks and cannot gain a second entitlement from that change.

## Tests performed

The reviewer created a separate scratch harness using a real vendored Uniswap v4 `PoolManager`, a fixed-supply production `ReferralIMD`, the production `RewardDistributor`, and an adversarial reward ERC-20. Rewards were fully funded through the manager's settlement and ERC-6909 mint mechanism. The production contracts were not modified.

`forge test --match-contract RewardsReviewTest -vv` passed nine tests with solc `0.8.26` and the configured seed `0x1a118de9f34d24ae397f6b2961275c7487461451106fbb7d428e8920caa50b30`:

1. Prior-block eligibility, repeated claims, and transfers after an earlier completed claim.
2. A full same-block transfer round trip cannot borrow reward eligibility.
3. Pending rewards survive zero eligible supply and later pay the eligible holder, irrespective of who triggers distribution or claims.
4. All excluded balances leave the denominator and all excluded addresses are refused by the claim entry point.
5. Failed reward transfers roll back accounting and preserve later claimability.
6. A reward-token callback cannot reenter to double claim.
7. Unauthorized fee recording and forged/unarmed unlock callbacks fail.
8. A 256-run reference-model fuzz test over 80 blocks and three holders, with randomized transfers and one-interval claim batches. Exact account payouts matched the independently calculated scaled entitlement, and paid rewards plus remaining manager claims equaled funding.
9. A 256-run reference-model fuzz test with changing eligible supply, two separate fees in each block, and interleaved claims. Payouts matched the independent per-block allocation model despite denominator changes and fractional carry.

Scratch tests are intentionally removed by the assignment's verifier. After this review, the implementation agent promoted equivalent versions of all nine tests into the delivered `test/Rewards.t.sol`, adapting names and imports, and reported that they passed. The scratch command and results above describe the independent reviewer's execution; the delivered suite preserves its boundary progression, changing-denominator, reentrancy/failure rollback, and conservation coverage.

## Operational and economic limitations

- Eligibility is a one-block-lagged balance rule. A newly acquired balance begins earning in the following block; a seller retains entitlement for the block in which it sells. Same-block flash borrowing does not earn rewards, but holding borrowed tokens across a block boundary can qualify. This rule should be visible to users.
- All nonexcluded contract addresses are eligible. Custodians, the launch factory while it holds tokens, and the swarm's allocation/Merkle distributor can therefore accrue rewards. A permissionless claim sends IMD to that contract; whether its beneficiaries can recover IMD depends on that contract's own functionality. The implementation cannot infer a contract's beneficial owners.
- Transfers of positive dust can add one checkpoint per recipient per block. An attacker pays transfer gas and spends tokens, while a claimant may need additional bounded calls. No unbounded loop or holder enumeration is required, and the attacker cannot add more than one checkpoint per account per block.
- Historical storage grows over time; index lookups remain logarithmic and claims process at most 64 account intervals. The 32-bit interval cursor's theoretical limit would require over four billion distinct transfer blocks for a single account and is not a practical mainnet lifetime concern.
- Claims with a positive payout must run outside an already unlocked PoolManager operation. Underlying IMD transfer restrictions or failure can prevent a particular payout; state remains retryable. Mainnet IMD behavior and manager authenticity need deployment-chain verification.
- Fees accumulated while there are no eligible holders necessarily wait for an eligible holder. If no eligible holder ever returns, those fees cannot be assigned. There is no administrator or rescue path.
- Unsolicited IMD or ERC-6909 transfers to the distributor are not automatically recorded as trading rewards. This does not affect the hook's funded fee path; users should not treat the distributor as a general deposit vault.

No mainnet fork, Slither/Mythril run, formal verification, or external professional audit was performed as part of this reviewer subtask. Those activities must not be reported as completed on the basis of this document.
