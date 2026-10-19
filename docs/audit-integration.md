# Independent integration and accounting review

Reviewed on 2026-10-19 by a separate review agent from the implementation agent. This is a bounded source and integration review, not a guarantee that no vulnerabilities exist.

## Scope and conclusion

Reviewed all three production contracts (`ReferralIMD`, `ReferralHook`, and the hook-created `RewardDistributor`), the deployment preparation helper, the pinned admission tests, and the dependency paths used for ERC20 balances, checkpoints, arithmetic, reentrancy protection, Uniswap callbacks, and ERC6909 settlement. The review considered deployment on an initially empty chain, constructor arguments, address permission bits, historical accounting, repeated claims, supply conservation, and the actual mainnet reward asset.

No critical or high-severity implementation defect was found in this scope. The explicit limitations below remain relevant to deployment and holder expectations. This review does not independently audit every unused source file in the vendored dependency trees or the external launch factory.

## Accounting reasoning

The balance used for rewards generated in block `b` is the balance at the end of `b - 1`. The token stores one final balance checkpoint per account per block, and transfers have no external calls. Self-transfers and zero transfers do not add checkpoints. The mint checkpoint and fixed historical total supply are consistent from the deployment block onward.

At each distribution, let `E` be the previous block's eligible supply, `F` the accumulated IMD fee, and `Q = 2^128`. The reward index increases by `floor(F * Q / E)`. For a holder whose constant balance is `B`, multiplying the index change by `B` gives the holder's scaled entitlement. The claim loop processes the interval after that account's checkpoint through its next checkpoint, including the latter block's rewards because they still use the preceding block's balance. Current-block index changes are not claimable until the next block.

The account cursor and `throughBlock` prevent repeated collection of any interval. Fractional scaled entitlements carry across claims and across balance changes. Carrying the fraction does not create extra value: each account eventually receives the floor of its cumulative scaled entitlement, and the sum of all such payouts cannot exceed the cumulative funded fees because eligible balances sum to `E`. Index truncation and unfinished account fractions can leave dust in the distributor's ERC6909 claim balance; there is no privileged dust withdrawal.

The index is funded by the exact same fee amount minted as an ERC6909 claim before `recordFee` is called. A failed swap rolls back both changes. Only the immutable hook can record fees. Claims advance account state before unlocking the manager, are nonreentrant, authenticate the manager callback and expected encoded claim, burn the distributor's claim, and pay the entitled account directly. Permissionless `claimFor` cannot redirect rewards. A failed asset transfer or manager unlock reverts account progress and claimed totals atomically.

The sum of fixed excluded balances is subtracted from historical total supply: PoolManager, burn address, hook, and this reward distributor. The hook validates that supplied addresses are distinct where relevant. ERC20 transfers to the zero address revert, so the additional zero-address exclusion does not subtract an existing balance.

## Callback and deployment review

- All three enabled callbacks require the configured PoolManager as caller. Initialization also requires the immutable launch factory as the original sender and binds exactly the expected token/pair, fee `12500`, tick spacing `60`, and this hook.
- The required hook address bits are `0x20cc`: before-initialize, before-swap, after-swap, and both swap return-delta permissions. The constructor validates those bits.
- The specified-side delta only retains the defined fee. It cannot swallow an entire nonzero exact-input trade. The after-swap check rejects partial execution when the pair currency was specified, preventing a full-input fee from surviving a partial fill.
- A fee mint debits the hook's transient pair-currency balance. The returned hook delta credits the same amount. Claim redemption burns a claim for credit, then takes exactly that credit. The real PoolManager's unlock check enforces zero unsettled deltas.
- No liquidity callback is enabled; collecting accrued LP fees with zero liquidity change and withdrawing liquidity are not gated by an administrative switch.
- The token has no constructor arguments, mints exactly `10^27` units to its deployer, and exposes no owner, additional mint, burn, pause, blacklist, upgrade, or transfer-tax entry point. Metadata follows the brief's final explicit choice: `ReferralIMD` / `RIMD`.
- The hook accepts four manifest-compatible arguments and creates its distributor itself. Construction calls no outside contract or code-presence check. PoolManager and factory are supplied values rather than hardcoded deployment addresses.
- Source-level privileged escape hatches were absent. Compiler artifacts have no unresolved library links. A push-aware opcode scan equivalent to the pinned admission check found no `CALLCODE`, `DELEGATECALL`, or `SELFDESTRUCT` in any production runtime.

With Solidity 0.8.26, optimizer 200, and metadata hash disabled, the reviewed runtime sizes were 3,909 bytes (token), 4,728 bytes (hook), and 5,966 bytes (distributor). The largest creation code was 12,434 bytes. All are below EIP-170/EIP-3860 limits. Rebuild after any code or compiler-setting change; these figures describe the reviewed build.

## Independent checks performed

`forge build --sizes` passed. In a scratch-only independent model, eight holders performed random transfers, including self/zero transfers, multiple operations in one block, fee accrual, and bounded claims. The model accumulated each holder's entitlement independently at fee time from the prior block's balances, rather than reconstructing the production claim cursor. After all intervals finalized, actual total payment to every holder equaled that independent entitlement exactly. At every intermediate claim, payment was no greater than entitlement, lifetime payouts did not exceed fees, and backing plus payouts equaled recorded fees.

The model test ran 64 fuzz cases, each with 240 actions, with the assignment's pinned seed. A separate test exercised a claim stopping exactly at a balance-checkpoint boundary and then resuming. Both passed. Scratch tests are not part of the deliverable; the submitted suite provides the reproducible offline tests.

## Mainnet IMD evidence and fork rehearsal

The task-supplied reward currency is `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` on Ethereum chain 1. Read-only RPC checks at block **26,229,338** confirmed name `Identity.md`, symbol `IMD`, and 18 decimals. Its 22,990-byte runtime had keccak256:

```text
0x79a1ae149d27d4aae006d4dd75cb834222c9623799bbf34359428aaf66fec3bf
```

The RPC bytecode matched the fully verified runtime returned by [Blockscout's contract endpoint](https://eth.blockscout.com/api/v2/smart-contracts/0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7). [Blockscout's token endpoint](https://eth.blockscout.com/api/v2/tokens/0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7) also reported the same metadata. The verified contract is named `BridgedFP`, a LayerZero OFT inheriting ordinary OpenZeppelin ERC20 transfers. The inspected inheritance path does not override ERC20 transfer accounting to impose a transfer fee, rebase, blacklist, or pause.

IMD is an external asset with separate trust assumptions: bridging burns and mints its supply, and its owner can change metadata and bridge configuration. The observed owner was `0x047f606fd5b2baa5f5c6c4ab8958e45cb6b054b7`. Those external powers are not powers over ReferralIMD, its hook, or its distributor. The reviewed source was not marked as a proxy. Metadata strings are not a security identity; the configured chain and address identify the reward asset.

The preserved opt-in fork rehearsal is `rehearsal/MainnetIMD.t.sol`; its compact evidence record is `docs/mainnet-verification.json`. It runs separately from the offline test profile:

```sh
FOUNDRY_PROFILE=mainnet forge test --match-contract MainnetIMDReviewTest \
  --fork-url https://ethereum-rpc.publicnode.com \
  --fork-block-number 26229338 -vv
```

Both tests passed. They exercised exact `transfer` and `transferFrom` behavior on real IMD; deployed a new PoolManager, ReferralIMD, and correctly mined ReferralHook on the fork; seeded a pool; executed buys and sells in all four exact-input/exact-output combinations; verified claimed-fee backing; paid real IMD to a holder pro rata; and rejected a second payout for the same entitlement. Test funding used a local `deal` balance adjustment and a one-to-one pool price. No transaction was signed or broadcast. This verifies asset integration, not the production factory's opening-price calculation, actual liquidity seeding balances, or launch transaction.

Direct Etherscan requests returned HTTP 403. Initial Python RPC requests with its default user-agent also returned 403; requests with a browser user-agent and normal Foundry RPC requests succeeded. The completed evidence therefore does not rely on those failed requests. No account, key, or private endpoint was needed.

## Explicit residual limitations

1. **Historical eligibility is deliberate.** A balance change takes effect for rewards in the following block, and current-block rewards become claimable one block later. Same-transaction flash transfers cannot capture rewards, but this is not a holding-period lock or time-weighted stake mechanism. Fees from a block with zero eligible supply wait for a later eligible snapshot.
2. **Contract custody is literal.** Apart from the fixed exclusions, smart contracts holding RIMD receive entitlement just like wallets. Their beneficial users do not receive it separately. In particular, the swarm's launch MerkleDistributor may hold unclaimed RIMD; if it cannot forward IMD, an IMD payment to that contract can remain inaccessible. Custodians and contract wallets must support receiving and recovering the reward asset.
3. **Checkpoint history has a gas cost.** Claims process at most 64 balance intervals. A holder with many transfers may need multiple transactions; anyone can pay that gas with `claimFor`. Positive dust transfers can add history for another account, but each additional checkpoint costs the sender a transaction and cannot invalidate entitlement or create an unbounded single-claim loop.
4. **Fee semantics are explicit.** The hook's 2% levy is on the gross IMD side, in addition to the mandatory 1.25% pool LP fee and any configured Uniswap protocol share. Integer rounding is required. Specified-IMD partial fills revert atomically; routers must quote the full hook behavior and account for their resulting total input/output.
5. **External and operational scope remains.** The production launch factory, its supply split/Merkle distribution, its opening-price calculation, and any other pools users create are outside these contracts. The hook governs its single bound pool. Claims run as standalone manager unlocks; a caller already inside a PoolManager unlock cannot nest a nonzero claim. Mainnet addresses and transaction hashes must come from the separate actual launch, not this review.

No Slither/Mythril run, formal verification, deployed-contract explorer verification, or production launch was performed as part of this review.
