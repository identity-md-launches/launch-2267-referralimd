# Verification record

Verified on 2026-10-19 using Foundry 1.8.3 and Solidity **0.8.26**, with the committed compiler settings. This is local implementation/review evidence. It does not claim a production deployment, a network attestation, or completion of the IdentityMD network's full swarm acceptance process.

## Required checks

| Command | Result |
| --- | --- |
| `forge build --sizes` | Passed; no compiler errors or unresolved library links |
| `FOUNDRY_FUZZ_SEED=0x1a118de9f34d24ae397f6b2961275c7487461451106fbb7d428e8920caa50b30 forge test -vv` | **58 passed, 0 failed, 0 skipped** in seven suites |
| `forge fmt --check` | Passed |
| `forge fmt --check rehearsal/MainnetIMD.t.sol` | Passed |

The default tests run entirely locally, without the pinned input files or temporary reviewer scaffolding. They do not read or change environment variables, fork a network, use FFI, or require repository filesystem cheatcode permissions. The opt-in mainnet profile is separate.

There are five 256-run fuzz tests: token transfer conservation, four-mode swaps in each of two currency orders, and two independent historical reward allocation models. The stateful real-PoolManager suite ran **128 campaigns × 64 actions = 8,192 calls, with zero reverts**, checking four invariants together:

1. Payouts plus distributor ERC-6909 backing equal all collected hook fees.
2. No hook/router/distributor currency delta remains unsettled.
3. Token supply and balances are conserved; token transfers impose no tax.
4. Outstanding matured entitlements cannot exceed backing.

Actions include buys/sells, exact-input/output swaps, holder transfers, transfers to the burn address, advancement of blocks, and third-party claims. Failure tests exercise unauthorized callbacks, wrong initialization values, invalid constructor values, permission bits, invalid swap amounts, partial execution, insufficient balances/allowances, forged reward recording, failed payout rollback and malicious reentry. The supplied protected checks were read and their behavior is covered directly in the durable tests; the external verifier's environment-driven harness itself was not claimed as run here.

## Deployment sizes and immutability

| Contract | Runtime bytes | Creation-code bytes, excluding arguments |
| --- | ---: | ---: |
| ReferralIMD | 3,909 | 5,576 |
| ReferralHook | 4,728 | 12,434 |
| RewardDistributor | 5,966 | 6,350 |

All runtime sizes are below 24,576 bytes; creation code plus arguments is below 49,152 bytes. A push-aware opcode scan found no `CALLCODE`, `DELEGATECALL`, or `SELFDESTRUCT`. The launch tests also check code size, forbidden administrative selectors, construction without external deployed code, exact permission bits and factory/manager authentication. All called library functions are internal/inlined.

## Additional integration and performance checks

The mainnet rehearsal passed **2/2 tests**, with zero skips, using real IMD code at Ethereum block **26,229,338**:

```sh
FOUNDRY_PROFILE=mainnet forge test \
  --fork-url https://ethereum-rpc.publicnode.com \
  --fork-block-number 26229338 -vv
```

It validates exact real-IMD transfers, four swap modes on a newly deployed manager, fee backing and actual IMD reward payouts. Funding is synthetic and the local pool opens at 1:1. This is not a rehearsal of the external factory's production launch transaction or its market-cap-derived opening price. Asset/code evidence is recorded in [mainnet-verification.json](mainnet-verification.json).

The eight basic trade scenarios passed under `forge test --match-test 'test(Buy|Sell)Exact(Input|Output)' --gas-report`. The test router's cold `swap` calls measured 501,263–510,066 gas, including ERC-20 pulls, checkpoint writes, settlement and refunds. These are local scenario measurements, not estimates for every production router, liquidity state or holder history. Claims have a hard limit of 64 holder intervals per call; swaps never enumerate holders.

## Review and static-analysis scope

Three separate reviewer agents examined the token/rewards, hook/deltas, and complete integration respectively, with independent adversarial test harnesses. Their reports found no unresolved exploitable implementation defect in the reviewed scope. See [rewards review](audit-rewards.md), [hook review](audit-hook.md), and [integration review](audit-integration.md). Equivalent reward tests were preserved in the durable suite; temporary review scaffolding was removed before the final test run.

Foundry's built-in lint emitted advisory warnings that were reviewed rather than treated as security findings:

- Signed casts follow explicit sign tests and `int128` amount bounds; the final narrow fee casts use `SafeCast`.
- Solidity initializes local counters and fee accumulators to zero.
- Historical token calls inside the claim loop are read-only calls to the immutable project token, capped at 64 intervals.
- The child distributor receives validated addresses from the hook constructor; it is not an independently configurable launch component.
- The active callback marker is transient authorization state within a guarded claim, not a mutable admin role. Claims use effects-before-interactions and `nonReentrant`; fake callbacks, failure rollback and malicious token reentry were tested.
- Ignored return data from `PoolManager.unlock` carries no semantic result; successful return requires the manager's settlement invariant. The unused checkpoint balance field is intentionally omitted when only its boundary block is needed.
- Hook/distribution events follow calls to the fixed manager/distributor or read-only history functions. The claim event follows a guarded payout; no untrusted mutable receiver can change the entitlement before it is consumed.

Slither and Mythril executables were not available on this machine; neither was reported as run. Formal verification and a professional external audit were not performed. No transaction was signed or broadcast. The launch's own independent review, attestation, final factory simulation, source verification, receipt/address publication and supply-split checks remain the launch network's responsibilities.
