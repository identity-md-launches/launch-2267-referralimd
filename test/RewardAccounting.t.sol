// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FundedRewardsFixture} from "./helpers/FundedRewards.sol";
import {RewardDistributor} from "src/RewardDistributor.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";

contract NestedClaimAttempt is IUnlockCallback {
    IPoolManager private immutable manager;
    RewardDistributor private immutable rewards;

    constructor(IPoolManager manager_, RewardDistributor rewards_) {
        manager = manager_;
        rewards = rewards_;
    }

    function attempt(address holder) external {
        manager.unlock(abi.encode(holder));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        rewards.claimFor(abi.decode(data, (address)), 64);
        return "";
    }
}

contract RewardAccountingTest is FundedRewardsFixture {
    function test_transferredEntireBalanceRetainsOnlyEarnedRewards() public {
        _give(alice, 8);
        vm.roll(101);
        source.record(80);
        vm.prank(alice);
        token.transfer(bob, 8);
        source.record(40); // Still belongs to the previous block's holder.
        vm.roll(102);
        source.record(24);
        vm.roll(103);
        vm.prank(carol);
        assertEq(rewards.claimFor(alice, 64), 120);
        vm.prank(carol);
        assertEq(rewards.claimFor(bob, 64), 24);
        assertEq(token.balanceOf(alice), 0);
        assertEq(imd.balanceOf(carol), 0);
        assertEq(_backing(), 0);
    }

    function test_sameBlockFeeUpdatesCoalesceAndNeverRewriteFinalizedIndex() public {
        _give(alice, 8);
        vm.roll(101);
        source.record(16);
        uint256 first = rewards.rewardIndex();
        source.record(24);
        assertEq(rewards.indexCheckpointCount(), 1);
        assertEq(rewards.indexAt(100), 0);
        assertEq(rewards.indexAt(101), 5 * rewards.SCALE());
        assertGt(rewards.rewardIndex(), first);
        RewardDistributor.IndexCheckpoint memory point = rewards.indexCheckpointAt(0);
        assertEq(point.atBlock, 101);
        assertEq(point.index, rewards.rewardIndex());
        vm.roll(105);
        source.record(8);
        assertEq(rewards.indexCheckpointCount(), 2);
        assertEq(rewards.indexAt(101), 5 * rewards.SCALE());
        assertEq(rewards.indexAt(104), 5 * rewards.SCALE());
        assertEq(rewards.indexAt(105), 6 * rewards.SCALE());
        assertEq(rewards.claimFor(alice, 64), 40);
        vm.roll(106);
        assertEq(rewards.claimFor(alice, 64), 8);
    }

    function test_pendingFeesCanBeAssignedExactlyOnceWithoutAnotherTrade() public {
        source.record(16);
        source.record(24);
        assertEq(rewards.pendingFees(), 40);
        assertEq(rewards.indexCheckpointCount(), 0);
        _give(alice, 6);
        _give(bob, 2);
        rewards.distribute(); // Current-block balances cannot assign the fees yet.
        assertEq(rewards.pendingFees(), 40);
        vm.roll(101);
        vm.prank(carol);
        rewards.distribute();
        uint256 index = rewards.rewardIndex();
        rewards.distribute();
        rewards.distribute();
        assertEq(rewards.rewardIndex(), index);
        assertEq(rewards.pendingFees(), 0);
        assertEq(rewards.indexCheckpointCount(), 1);
        vm.roll(102);
        assertEq(rewards.claimFor(alice, 64), 30);
        assertEq(rewards.claimFor(bob, 64), 10);
        assertEq(rewards.claimFor(alice, 64), 0);
        assertEq(rewards.totalFees(), 40);
        assertEq(rewards.totalClaimed(), 40);
        assertEq(_backing(), 0);
    }

    function test_maximumAndMinimumBatchesYieldIdenticalLifetimePayoutAndFraction() public {
        _give(alice, 1);
        _give(bob, 2);
        for (uint256 i = 1; i <= 140; ++i) {
            vm.roll(100 + i);
            source.record(1 + i % 11);
            vm.prank(i % 2 == 0 ? alice : bob);
            token.transfer(i % 2 == 0 ? bob : alice, 1);
        }
        vm.roll(242);
        assertGt(token.checkpointCount(alice), 128);
        uint256 snapshot = vm.snapshotState();
        _drain(alice, 64);
        _drain(bob, 64);
        uint256 aliceBulk = imd.balanceOf(alice);
        uint256 bobBulk = imd.balanceOf(bob);
        bytes32 aliceProgress = _accountHash(alice);
        bytes32 bobProgress = _accountHash(bob);
        uint256 bulkBacking = _backing();
        assertGt(aliceBulk, 0);
        assertGt(bobBulk, 0);

        assertTrue(vm.revertToState(snapshot));
        _drain(alice, 1);
        _drain(bob, 1);
        assertEq(imd.balanceOf(alice), aliceBulk);
        assertEq(imd.balanceOf(bob), bobBulk);
        assertEq(_accountHash(alice), aliceProgress);
        assertEq(_accountHash(bob), bobProgress);
        assertEq(_backing(), bulkBacking);
        assertEq(rewards.totalClaimed() + _backing(), rewards.totalFees());
    }

    function test_zeroPayoutPageDoesNotMeanLaterPagesHaveNoRewards() public {
        _give(alice, 1);
        vm.roll(101);
        vm.prank(alice);
        token.transfer(bob, 1);
        vm.roll(102);
        vm.prank(bob);
        token.transfer(alice, 1);
        vm.roll(103);
        source.record(11);
        vm.roll(104);
        assertEq(rewards.claimFor(alice, 1), 0);
        assertEq(rewards.claimFor(alice, 1), 0);
        assertEq(rewards.claimFor(alice, 1), 11);
        assertEq(rewards.claimFor(alice, 1), 0);
        assertEq(imd.balanceOf(alice), 11);
    }

    function test_failedClaimRollsBackPreviouslyAdvancedProgressAndCanRetry() public {
        _give(alice, 1);
        _give(bob, 2);
        vm.roll(101);
        source.record(1);
        vm.prank(bob);
        token.transfer(alice, 1);
        vm.roll(102);
        source.record(30);
        vm.roll(103);
        rewards.claimFor(alice, 1);
        (uint32 cursor,, uint256 fraction) = rewards.accounts(alice);
        assertGt(cursor, 0);
        assertGt(fraction, 0);
        bytes32 progress = _accountHash(alice);
        uint256 backing = _backing();
        uint256 totalPaid = rewards.totalClaimed();
        (uint256 due,) = rewards.previewClaim(alice, 64);
        assertGt(due, 0);
        imd.setFailure(true);
        vm.expectRevert(); // Currency.transfer wraps the external ERC20's failure.
        rewards.claimFor(alice, 64);
        assertEq(_accountHash(alice), progress);
        assertEq(_backing(), backing);
        assertEq(rewards.totalClaimed(), totalPaid);
        imd.setFailure(false);
        assertEq(rewards.claimFor(alice, 64), due);
        assertEq(imd.balanceOf(alice), due);
    }

    function test_nestedManagerUnlockCannotConsumeEntitlement() public {
        _give(alice, 8);
        vm.roll(101);
        source.record(80);
        vm.roll(102);
        NestedClaimAttempt caller = new NestedClaimAttempt(manager, rewards);
        bytes32 progress = _accountHash(alice);
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        caller.attempt(alice);
        assertEq(_accountHash(alice), progress);
        assertEq(rewards.totalClaimed(), 0);
        assertEq(_backing(), 80);
        assertEq(rewards.claimFor(alice, 64), 80);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_invalidBatchCannotConsumeRewards(uint256 rawBatch) public {
        _give(alice, 1);
        vm.roll(101);
        source.record(17);
        vm.roll(102);
        uint256 batch = rawBatch == 0 ? 0 : bound(rawBatch, 65, type(uint256).max);
        bytes32 progress = _accountHash(alice);
        vm.expectRevert(RewardDistributor.InvalidBatch.selector);
        rewards.previewClaim(alice, batch);
        vm.prank(carol);
        vm.expectRevert(RewardDistributor.InvalidBatch.selector);
        rewards.claimFor(alice, batch);
        assertEq(_accountHash(alice), progress);
        assertEq(_backing(), 17);
        assertEq(rewards.totalClaimed(), 0);
        assertEq(rewards.claimFor(alice, 1), 17);
    }

    /// @dev Non-power-of-two weights exercise both global and account rounding.
    /// One fee can lose less than one minor unit for a holder; all value stays backed.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_proRataAcrossFullSupply(uint256 rawA, uint256 rawB, uint256 rawFee) public {
        uint256 supply = token.totalSupply();
        uint256 a = bound(rawA, 1, supply - 1);
        uint256 b = bound(rawB, 1, supply - a);
        uint256 fee = bound(rawFee, 1, 1e27);
        _give(alice, a);
        _give(bob, b);
        vm.roll(101);
        source.record(fee);
        vm.roll(102);
        uint256 paidA = rewards.claimFor(alice, 64);
        uint256 paidB = rewards.claimFor(bob, 64);
        // Products fit uint256 under the explicit bounds; this oracle uses the
        // direct balance ratio, not the contract's index or checkpoint math.
        uint256 fairA = fee * a / (a + b);
        uint256 fairB = fee * b / (a + b);
        assertLe(paidA, fairA);
        assertLe(paidB, fairB);
        assertLe(fairA - paidA, 1);
        assertLe(fairB - paidB, 1);
        assertEq(imd.balanceOf(alice), paidA);
        assertEq(imd.balanceOf(bob), paidB);
        assertEq(paidA + paidB + _backing(), fee);
        assertEq(rewards.claimFor(alice, 64), 0);
        assertEq(rewards.claimFor(bob, 64), 0);
    }

    function _drain(address holder, uint256 batch) private {
        uint256 attempts = token.checkpointCount(holder) / batch + 2;
        for (uint256 i; i < attempts; ++i) {
            (uint256 preview, RewardDistributor.Account memory progress) = rewards.previewClaim(holder, batch);
            uint256 beforeBalance = imd.balanceOf(holder);
            assertEq(rewards.claimFor(holder, batch), preview);
            assertEq(imd.balanceOf(holder) - beforeBalance, preview);
            assertEq(
                _accountHash(holder), keccak256(abi.encode(progress.cursor, progress.throughBlock, progress.fraction))
            );
        }
        (uint256 remaining,) = rewards.previewClaim(holder, 64);
        assertEq(remaining, 0);
    }
}
