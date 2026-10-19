// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReferralIMD} from "src/ReferralIMD.sol";
import {RewardDistributor} from "src/RewardDistributor.sol";
import {FundedRewardsFixture, FundedFeeSource} from "./helpers/FundedRewards.sol";
import {MockIMD} from "./helpers/MockIMD.sol";

/// @dev A deliberately different accounting model: record earnings directly for
/// each holder at each fee event. It never reads rewardIndex, indexAt, a claim
/// cursor, or a token checkpoint to calculate an entitlement.
///
/// Eligible supply is either 2^64 or zero, and each fee is a multiple of 2^64.
/// Therefore fee / supply is integral and there is no rounding tolerance that
/// could hide an incorrect recipient, omitted interval, or duplicate payout.
contract RewardLedgerHandler is Test {
    uint256 public constant UNITS = 1 << 64;
    ReferralIMD public immutable token;
    MockIMD public immutable imd;
    FundedFeeSource public immutable source;
    RewardDistributor public immutable rewards;
    address[3] public holders;
    address[4] public sinks;
    uint256[3] public liveBalance;
    uint256[3] public previousBalance;
    uint256[3] public earnedFinalized;
    uint256[3] public earnedThisBlock;
    uint256[3] public paid;
    uint256[4] public sinkBalance;
    uint256 public funded;
    uint256 public pending;
    uint256 public feeCalls;
    uint256 public successfulPayouts;

    constructor(ReferralIMD token_, MockIMD imd_, FundedFeeSource source_, address[3] memory holders_) {
        token = token_;
        imd = imd_;
        source = source_;
        rewards = source_.rewards();
        holders = holders_;
        sinks = [address(source_), address(source_.manager()), address(rewards), rewards.BURN()];
        sinkBalance[0] = token_.totalSupply();
    }

    function enter(uint256 who) public {
        uint256 live = liveBalance[0] + liveBalance[1] + liveBalance[2];
        if (live != 0) return;
        uint256 i = who % 3;
        vm.prank(address(source));
        token.transfer(holders[i], UNITS);
        liveBalance[i] = UNITS;
        sinkBalance[0] -= UNITS;
    }

    function exitAll(uint256 destination) external {
        uint256 sink = destination % 4;
        for (uint256 i; i < 3; ++i) {
            uint256 amount = liveBalance[i];
            vm.prank(holders[i]);
            token.transfer(sinks[sink], amount);
            sinkBalance[sink] += amount;
            liveBalance[i] = 0;
        }
    }

    function move(uint256 fromSeed, uint256 toSeed, uint256 rawAmount, bool delegated) external {
        uint256 from = fromSeed % 3;
        uint256 to = toSeed % 3;
        uint256 amount = bound(rawAmount, 0, liveBalance[from]);
        if (delegated) {
            vm.prank(holders[from]);
            token.approve(address(this), amount);
            token.transferFrom(holders[from], holders[to], amount);
            assertEq(token.allowance(holders[from], address(this)), 0);
        } else {
            vm.prank(holders[from]);
            token.transfer(holders[to], amount);
        }
        liveBalance[from] -= amount;
        liveBalance[to] += amount;
    }

    function advance(uint256 rawBlocks) public {
        for (uint256 i; i < 3; ++i) {
            earnedFinalized[i] += earnedThisBlock[i];
            earnedThisBlock[i] = 0;
            previousBalance[i] = liveBalance[i];
        }
        vm.roll(block.number + bound(rawBlocks, 1, 5));
    }

    function fee(uint256 rawUnits) external {
        uint256 amount = bound(rawUnits, 0, 1_000_000) * UNITS;
        uint256 beforeIndex = rewards.rewardIndex();
        source.record(amount);
        funded += amount;
        pending += amount;
        _assign();
        ++feeCalls;
        assertGe(rewards.rewardIndex(), beforeIndex);
    }

    function distribute() external {
        uint256 beforeIndex = rewards.rewardIndex();
        rewards.distribute();
        _assign();
        assertGe(rewards.rewardIndex(), beforeIndex);
    }

    function claim(uint256 who, uint256 rawBatch, bool byHolder) external {
        uint256 i = who % 3;
        uint256 batch = bound(rawBatch, 1, 64);
        uint256 beforeBalance = imd.balanceOf(holders[i]);
        uint256 amount;
        if (byHolder) {
            vm.prank(holders[i]);
            amount = rewards.claim(batch);
        } else {
            amount = rewards.claimFor(holders[i], batch);
        }
        _recordPayment(i, beforeBalance, amount);
    }

    function invalidClaim(uint256 who, bool zero) external {
        uint256 i = who % 3;
        (uint32 cursor, uint256 throughBlock, uint256 fraction) = rewards.accounts(holders[i]);
        vm.expectRevert(RewardDistributor.InvalidBatch.selector);
        rewards.claimFor(holders[i], zero ? 0 : type(uint256).max);
        (uint32 afterCursor, uint256 afterBlock, uint256 afterFraction) = rewards.accounts(holders[i]);
        assertEq(afterCursor, cursor);
        assertEq(afterBlock, throughBlock);
        assertEq(afterFraction, fraction);
        assertEq(imd.balanceOf(holders[i]), paid[i]);
    }

    /// @dev Called only by afterInvariant, never selected as a randomized action.
    /// Draining checks liveness and equality, so silently skipping payments cannot
    /// satisfy the conservation upper bounds checked after individual actions.
    function finishAndClaimAll() external {
        advance(1);
        for (uint256 i; i < 3; ++i) {
            uint256 calls = token.checkpointCount(holders[i]) / 64 + 2;
            for (uint256 j; j < calls; ++j) {
                uint256 beforeBalance = imd.balanceOf(holders[i]);
                uint256 amount = rewards.claimFor(holders[i], 64);
                _recordPayment(i, beforeBalance, amount);
            }
            assertEq(paid[i], earnedFinalized[i], "all earned IMD must be claimable");
            assertEq(rewards.claimFor(holders[i], 64), 0, "no double claim");
        }
    }

    function _assign() private {
        uint256 eligible = previousBalance[0] + previousBalance[1] + previousBalance[2];
        if (eligible == 0) return;
        assertEq(eligible, UNITS, "model eligible supply");
        assertEq(pending % UNITS, 0, "model exact divisibility");
        uint256 perUnit = pending / UNITS;
        for (uint256 i; i < 3; ++i) {
            earnedThisBlock[i] += previousBalance[i] * perUnit;
        }
        pending = 0;
    }

    function _recordPayment(uint256 i, uint256 beforeBalance, uint256 amount) private {
        paid[i] += amount;
        if (amount != 0) ++successfulPayouts;
        assertEq(imd.balanceOf(holders[i]) - beforeBalance, amount, "payment recipient");
        assertLe(paid[i], earnedFinalized[i], "no unearned or unfinalized rewards");
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 192
/// forge-config: default.invariant.fail-on-revert = true
contract RewardLedgerInvariantTest is FundedRewardsFixture {
    RewardLedgerHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new RewardLedgerHandler(token, imd, source, [alice, bob, carol]);
        // Every campaign starts with a real distribution and successful payout.
        // This also makes a selector/configuration mistake visible immediately.
        handler.enter(0);
        handler.move(0, 1, handler.UNITS() / 4, false);
        handler.move(0, 2, handler.UNITS() / 4, true);
        handler.advance(1);
        handler.fee(3);
        handler.advance(1);
        handler.claim(0, 64, true);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.enter.selector;
        selectors[1] = handler.exitAll.selector;
        selectors[2] = handler.move.selector;
        selectors[3] = handler.advance.selector;
        selectors[4] = handler.fee.selector;
        selectors[5] = handler.distribute.selector;
        selectors[6] = handler.claim.selector;
        selectors[7] = handler.invalidClaim.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_exactFundingAndRecipientAccounting() public view {
        uint256 paid;
        uint256 earned;
        for (uint256 i; i < 3; ++i) {
            paid += handler.paid(i);
            earned += handler.earnedFinalized(i) + handler.earnedThisBlock(i);
            assertEq(imd.balanceOf(handler.holders(i)), handler.paid(i));
            assertLe(handler.paid(i), handler.earnedFinalized(i));
        }
        assertEq(rewards.totalFees(), handler.funded());
        assertEq(rewards.pendingFees(), handler.pending());
        assertEq(rewards.totalClaimed(), paid);
        assertEq(paid + _backing(), handler.funded());
        assertEq(earned + handler.pending(), handler.funded());
        assertEq(imd.balanceOf(address(manager)), _backing());
        assertEq(imd.totalSupply(), handler.funded());
        assertEq(imd.balanceOf(address(handler)), 0);
        assertEq(imd.balanceOf(address(source)), 0);
    }

    function invariant_balancesAndPriorBlockEligibilityMatchIndependentLedger() public view {
        uint256 total;
        uint256 eligible;
        for (uint256 i; i < 3; ++i) {
            assertEq(token.balanceOf(handler.holders(i)), handler.liveBalance(i));
            assertEq(token.getPastBalance(handler.holders(i), block.number - 1), handler.previousBalance(i));
            total += handler.liveBalance(i);
            eligible += handler.previousBalance(i);
        }
        for (uint256 i; i < 4; ++i) {
            assertEq(token.balanceOf(handler.sinks(i)), handler.sinkBalance(i));
            assertTrue(rewards.excluded(handler.sinks(i)));
            total += handler.sinkBalance(i);
        }
        assertEq(total, 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(rewards.eligibleSupplyAt(block.number - 1), eligible);
    }

    function invariant_eachPreviewIsBoundedByThatHoldersEarnedRewards() public view {
        uint256 due;
        for (uint256 i; i < 3; ++i) {
            (uint256 amount, RewardDistributor.Account memory progress) = rewards.previewClaim(handler.holders(i), 64);
            assertLe(amount + handler.paid(i), handler.earnedFinalized(i));
            assertEq(progress.fraction, 0, "integral distributions must not lose fractions");
            due += amount;
        }
        assertLe(due, _backing());
    }

    function afterInvariant() public {
        assertGt(handler.feeCalls(), 0);
        assertGt(handler.successfulPayouts(), 0);
        handler.finishAndClaimAll();
        invariant_exactFundingAndRecipientAccounting();
        invariant_balancesAndPriorBlockEligibilityMatchIndependentLedger();
        invariant_eachPreviewIsBoundedByThatHoldersEarnedRewards();
    }
}
