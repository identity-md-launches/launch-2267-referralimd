# ReferralIMD / RIMD

Immutable fixed-supply ERC-20, Uniswap v4 trading hook, and permissionless IMD holder rewards. This repository is the source deliverable for an IdentityMD `custom_token` / `univ4_hook` launch on Ethereum, chain ID **1**. The final explicit metadata in the request, **ReferralIMD / RIMD**, takes precedence over the earlier “Referral IMD / rIMD” spelling.

No mainnet launch transaction has been sent by this project. IdentityMD's subsequent manifest, attestation, independent contributor review and factory deployment steps produce the actual addresses and transaction hashes. There is deliberately no `launch.json`, fabricated receipt, private key, or signing/broadcast script here.

## Contracts

| Contract | Responsibility | Constructor arguments |
| --- | --- | --- |
| [`ReferralIMD`](src/ReferralIMD.sol) | ERC-20 and passive historical balances | None |
| [`ReferralHook`](src/ReferralHook.sol) | Bind the launch pool; levy 2% in IMD | `IPoolManager manager_`, `ReferralIMD token_`, `Currency pair_`, `address factory_` |
| [`RewardDistributor`](src/RewardDistributor.sol) | Account for every eligible holder and redeem IMD rewards | Created internally by the hook; exposed as `hook.distributor()` |

The token mints **1,000,000,000 × 10^18** minor units once to its deploying factory. It has 18 decimals and no owner, external mint/burn, administrative configuration, pause, blacklist, tax, proxy, or upgrade mechanism. Transfers and approvals follow OpenZeppelin ERC-20 behavior. Balance checkpoints add storage accounting, without external calls or transfer deductions.

The **factory**, in the same launch transaction, makes the requested allocation:

| Allocation | RIMD |
| --- | ---: |
| Swarm's launch MerkleDistributor | 100,000,000 (10%) |
| Uniswap v4 liquidity | 850,000,000 (85%) |
| Launch payer/requester's wallet | 50,000,000 (5%) |

The requester allocation is unrestricted and is not committed to liquidity. The token cannot hardcode this split because the factory must first verify that it holds the complete supply. Neither the hook nor its rewards contract receives an allocation. The launch's factory implementation and final transaction are responsible for proving the allocation, including how any liquidity rounding residue is handled.

## Pool and deployment parameters

| Parameter | Required value |
| --- | --- |
| Network | Ethereum, chain ID 1 |
| IMD / pair | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, 18 decimals, supplied in the task |
| PoolManager constructor argument | `$poolManager`; the launch supplies the genuine chain manager |
| Token constructor argument | `$token`; the token deployed immediately before the hook |
| Factory constructor argument | `$factory`; the factory that deploys and initializes the hook |
| Pair constructor argument | The IMD address above, one complete address argument |
| Pool LP fee | `12500` pips = **1.25%**, fixed launch policy |
| Tick spacing | `60` |
| Manifest initialPrice field | `"79228162514264337593543950336"`, as specified by the launch policy |
| Actual opening price | Factory derives it from **2,500 IMD** opening market cap, the fixed supply, and actual currency ordering |
| Hook flags | `0x20cc` = `8396` |
| Owner/admin arguments | None; no contract in this project has an owner or admin |

The policy's named owner/payer address is `0x3ed212257958724579f13b3dba74a07ac6007903`. It is a launch allocation detail, not a privileged contract role or a constructor argument here. The factory supplies the swarm allocation contract; no swarm wallet is invented.

Pool currencies must be sorted numerically. `hook.poolKey()` returns the exact currency order, LP fee, tick spacing and hook address. The pool ID is `keccak256(abi.encode(poolKey))`. Initialization requires the configured PoolManager and factory; it accepts the factory's valid opening price and checks the entire pool key. The hook has no price setter and cannot be attached to another pool. Liquidity callbacks are disabled, so normal LP adds, removals and the factory's zero-liquidity fee collection remain available.

The factory must deploy the hook with CREATE2 so its low 14 address bits equal `0x20cc`. [`PrepareLaunch`](script/PrepareLaunch.s.sol) computes the constructor-dependent init-code hash and mines a salt from explicit arguments, without environment access or broadcasts. It assumes CREATE2 is executed by the configured factory. All constructor arguments are known from the launch placeholders; constructors do not call existing contracts or require deployed external code. A wrong immutable argument cannot be repaired: verify it against the actual factory deployment transaction.

## The 2% trading fee

**The 2% is an additional hook levy on the gross IMD side of each swap in this pool.** The policy's 1.25% LP fee remains separate, along with any manager protocol fee and price impact. The hook never overrides the LP fee or diverts a portion of its own revenue to a wallet. All hook fee receipts back holder rewards. The network/payer LP fee split is performed by the launch factory, outside these contracts.

Taking IMD from the paired side already produces the requested reward asset. An additional buy/sell conversion would add cost and slippage without changing the asset, so there is no conversion market, oracle, keeper, allowance, or rIMD fallback path.

| Swap | IMD hook fee | Core swap and final result |
| --- | --- | --- |
| Buy RIMD, exact IMD input `G` | `floor(G × 2 / 100)` before swap | Core receives `G − fee`; total input stays `G` |
| Buy exact RIMD output; core requires IMD `P` | `ceil(P × 2 / 98)` after swap | Total input is `P + fee` |
| Sell exact RIMD input; core returns IMD `G` | `floor(G × 2 / 100)` after swap | Holder receives `G − fee` |
| Sell for exact net IMD output `N` | `ceil(N × 2 / 98)` before swap | Core supplies `N + fee`; holder receives `N` |

ERC-20 minor units are indivisible. Floors apply when gross IMD is known; gross-ups round upward when net IMD is known. Thus the difference from the real-number 2% formula is less than one IMD minor unit; sufficiently small gross-side trades pay zero. No minimum fee is added. Specified amounts are bounded to half the positive `int128` range for safe gross-up accounting.

An exact-input buy or exact-output sell that cannot fill its adjusted specified amount **reverts atomically**. The before-swap return delta cannot later refund the specified currency, so charging a requested-but-unexecuted amount would be incorrect. The other two modes charge actual executed IMD and can partially fill according to v4 behavior. Routers must enforce their users' minimum output, maximum input and price limits, and surface/requote a rejected partial fill. Arbitrary hook data and router identities cannot disable the fee.

The hook mints matching **ERC-6909 IMD claims** to the distributor during the swap instead of transferring IMD before the router settles. This works on a fresh manager without prefunded IMD or native ETH. The positive hook delta pays for the minted claims; all transient balances must settle before the unlock ends. Claims are redeemed into actual IMD only when a holder claims rewards in a separate manager unlock.

This levy covers swaps in this hook's pool. A freely transferable immutable ERC-20 cannot impose it on independently created venues or peer-to-peer transfers.

## Holder rewards and independently reproducible math

Every eligible address participates, including small balances and contract wallets; no registration, staking, delegation, holder enumeration, top-N ranking, Merkle proof, signer or off-chain balance list is involved.

For fees assigned in block `B`, the weights are balances at the **end of block `B − 1`**. Rewards become claimable after block `B` ends. New balances start earning in the following block; a seller retains entitlement for the block of its sale. Transfers never transfer already-earned rewards. This fixed one-block rule prevents atomic flash-balance capture, while holdings acquired across block boundaries still qualify.

These addresses are excluded from both numerator and denominator:

- The configured PoolManager, which holds the v4 pool's RIMD liquidity.
- The conventional burn address `0x000000000000000000000000000000000000dEaD`.
- The hook (fee collector) and this hook's reward distributor.
- The zero address, which the token cannot transfer to.

v4 uses singleton custody: **all** RIMD held by the configured manager is excluded, including balances underlying ERC-6909 claims or other pools. An LP NFT is not an RIMD wallet balance. Other contracts holding RIMD are eligible, including a swarm MerkleDistributor while allocations remain unclaimed; their rewards are paid to the holding contract. Beneficiaries can recover those rewards only if that contract supports forwarding IMD. The token cannot infer beneficial owners or look through custody.

Let `S_B` be historical total supply minus the four nonzero excluded balances, `F` the collected IMD fee and `Q = 2^128`:

```text
index increment = floor(F × Q / S_B)
rewardIndex     = previous index + increment

holder balance b recorded at block t, next balance change at block u:
scaled entitlement = b × (indexAt(u) − indexAt(t))
```

That balance earns fees from blocks `t + 1` through `u`, inclusive. Partial claims replace `t` with the already-processed `throughBlock`, and stop at `block.number − 1`. A holder's fractional remainder is carried across claims and balance intervals; claiming more often does not lose it. `Math.mulDiv` and `mulmod` avoid intermediate-product overflow.

The cumulative index is checkpointed once per fee-bearing block, coalescing that block's updates. Token balances likewise coalesce multiple transfers in the same block. Claims visit the holder's own balance intervals, with binary searches of the index history, so a quiet holder does not have to iterate over every swap or every block. Each call processes **1–64** intervals; large histories require several calls. Positive dust transfers can add a recipient checkpoint once per block, at the sender's expense; zero/self transfers do not.

If eligible supply is zero, the fee remains in `pendingFees`, fully backed. The next fee or anyone's `distribute()` call assigns it once a past-block eligible balance exists. No fee is swept to an owner. The per-update global index rounding residue is less than `10^27 / 2^128` IMD minor units; sub-unit holder fractions and conservative global rounding remain backed in the distributor. There is no rounding-dust withdrawal, claim expiry, or administrative forfeiture.

The public `getPastBalance`, `getPastTotalSupply`, token checkpoint getters, `indexAt`, index checkpoint getters, `eligibleSupplyAt`, `accounts`, `totalFees`, `totalClaimed` and `pendingFees` make the calculation reproducible. Logs expose each fee, distribution and claim. No token price is used in reward allocation.

## After launch

There are **no owner-settable settings** and no required keeper. The launch operator and front end should:

1. Record the actual token/hook/distributor addresses, `poolKey()`, pool ID, opening price, deployment block, runtime-code hashes and every factory/deployment/initialization/allocation transaction hash. Publish them after the factory transaction succeeds; none exists yet in this deliverable.
2. Verify source and constructor arguments for the token, hook and constructor-created distributor, permission bits, initialization sender, exact supply and 10%/85%/5% allocations against receipts. Confirm the genuine manager and the supplied IMD contract on chain. A fork simulation of the actual launch factory at its derived opening price remains part of launch acceptance.
3. Complete the required network's full swarm review and attestation before release. The three local adversarial reviews included here are supporting evidence, not a statement that the entire contributor network approved the launch.
4. Offer `distributor.previewClaim(holder, 64)` and `claim(64)`. Anyone may instead call `claimFor(holder, 64)`; payment always goes to `holder`. Repeat bounded calls for a long transfer history, inspecting the returned progress rather than assuming a zero payout means no remaining intervals. No approval is needed to claim.
5. Optionally call `distribute()` when pending fees exist after a zero-eligible-supply period. Ordinary swaps distribute into the index automatically. Triggering a distribution or someone else's claim earns no bounty.

Positive-payout claims must run outside a currently unlocked PoolManager session. A failing IMD transfer reverts the payout and accounting together, leaving the holder able to retry. IMD is an external bridged asset with its own administration and bridge risk; immutability of these contracts does not remove that asset risk. Do not send tokens or ERC-6909 claims directly to the distributor: unsolicited transfers are not registered trading rewards and there is no rescue function.

## Verification and reviews

All required dependencies are pinned and vendored as ordinary source files under `lib/`; see [dependency versions and licenses](lib/DEPENDENCIES.md). Default compilation and tests need no network, RPC endpoint, key, environment configuration, FFI or filesystem permissions. The compiler is pinned to `0.8.26`, EVM Cancun, optimizer 200 runs, and `bytecode_hash = "none"`.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x1a118de9f34d24ae397f6b2961275c7487461451106fbb7d428e8920caa50b30 forge test
forge fmt --check
```

The same fuzz seed is also pinned in `foundry.toml`. Durable tests cover token behavior/history and administrative-selector refusal; real-manager trades in both currency orderings and all modes; fee and protocol-fee accounting; fresh-manager operation; partial fills; authorized callbacks and initialization; LP fee collection and withdrawal; pro-rata rewards; >100 holders; rounding carry; malicious reentry; failed transfer rollback; changing eligible supply; bounded claims over long histories; and stateful conservation/solvency with actual swaps, transfers, burns and claims.

An optional, network-dependent rehearsal is isolated from the default offline suite:

```sh
FOUNDRY_PROFILE=mainnet forge test \
  --fork-url https://ethereum-rpc.publicnode.com \
  --fork-block-number 26229338
```

It uses the real Ethereum IMD bytecode at the pinned block documented in [mainnet verification](docs/mainnet-verification.json), with synthetic local funding and a fresh manager. It does not send transactions or attest the launch factory.

Independent review records:

- [Token and rewards](docs/audit-rewards.md)
- [Hook and Uniswap accounting](docs/audit-hook.md)
- [Integration and mainnet asset](docs/audit-integration.md)
- [Release verification record](docs/verification.md)

## Hook configuration record

The implementation directly uses the v4 interfaces and permission validation; it does not depend on a mutable base hook or owner. `access: "none"` records the deliberate no-admin design outside the Wizard's ownership presets. Settlement uses ERC-6909 mint/burn/take directly.

```json
{
  "hook": "BaseHook",
  "name": "ReferralHook",
  "pausable": false,
  "currencySettler": false,
  "safeCast": true,
  "transientStorage": false,
  "shares": { "options": false },
  "permissions": {
    "beforeInitialize": true,
    "afterInitialize": false,
    "beforeAddLiquidity": false,
    "afterAddLiquidity": false,
    "beforeRemoveLiquidity": false,
    "afterRemoveLiquidity": false,
    "beforeSwap": true,
    "afterSwap": true,
    "beforeDonate": false,
    "afterDonate": false,
    "beforeSwapReturnDelta": true,
    "afterSwapReturnDelta": true,
    "afterAddLiquidityReturnDelta": false,
    "afterRemoveLiquidityReturnDelta": false
  },
  "inputs": {},
  "access": "none",
  "info": { "license": "MIT" }
}
```

The initialization callback is added to prevent pre-deployment initialization of the predicted pool and authenticate its factory. Both swap callbacks and return-delta permissions are necessary to charge the IMD side in all four modes. The before-swap delta is limited to the fee: it never consumes or replaces the entire swap. All unused callbacks remain disabled.
