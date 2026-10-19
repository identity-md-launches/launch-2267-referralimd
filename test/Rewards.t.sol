// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ReferralIMD} from "../src/ReferralIMD.sol";
import {RewardDistributor} from "../src/RewardDistributor.sol";

contract AdversarialRewardToken is ERC20 {
    address public blockedRecipient;
    address public reentryRecipient;
    RewardDistributor public reentryDistributor;
    bool public reentrySucceeded;
    constructor() ERC20("Review reward", "RR") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function blockRecipient(address to) external {
        blockedRecipient = to;
    }

    function setReentry(address to, RewardDistributor target) external {
        reentryRecipient = to;
        reentryDistributor = target;
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(to != blockedRecipient || to == address(0), "blocked recipient");
        super._update(from, to, amount);
        if (to == reentryRecipient && address(reentryDistributor) != address(0)) {
            (reentrySucceeded,) = address(reentryDistributor).call(abi.encodeCall(RewardDistributor.claimFor, (to, 64)));
        }
    }
}

contract RewardsTest is Test, IUnlockCallback {
    PoolManager private manager;
    ReferralIMD private token;
    AdversarialRewardToken private reward;
    RewardDistributor private distributor;
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);
    address private carol = address(0xCA401);
    uint256 private constant Q = 1 << 128;

    function setUp() public {
        vm.roll(1000);
        manager = new PoolManager(address(this));
        token = new ReferralIMD();
        reward = new AdversarialRewardToken();
        // This test contract is the fixed recorder/hook and an excluded token holder.
        distributor =
            new RewardDistributor(IPoolManager(address(manager)), token, Currency.wrap(address(reward)), address(this));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        uint256 amount = abi.decode(data, (uint256));
        manager.sync(Currency.wrap(address(reward)));
        reward.transfer(address(manager), amount);
        manager.settle();
        manager.mint(address(distributor), uint256(uint160(address(reward))), amount);
        return "";
    }

    function _fee(uint256 amount) private {
        reward.mint(address(this), amount);
        manager.unlock(abi.encode(amount));
        distributor.recordFee(amount);
    }

    function test_oneBlockLagAndLateCheckpointAfterClaim() public {
        token.transfer(alice, 100);
        vm.roll(1001);
        _fee(100);
        distributor.claimFor(alice, 64);
        assertEq(reward.balanceOf(alice), 0);
        vm.roll(1002);
        distributor.claimFor(alice, 64);
        assertEq(reward.balanceOf(alice), 100);
        vm.prank(alice);
        token.transfer(bob, 50);
        _fee(100);
        vm.roll(1003);
        _fee(100);
        distributor.claimFor(alice, 64);
        distributor.claimFor(bob, 64);
        assertEq(reward.balanceOf(alice), 200);
        assertEq(reward.balanceOf(bob), 0);
        vm.roll(1004);
        distributor.claimFor(alice, 64);
        distributor.claimFor(bob, 64);
        assertEq(reward.balanceOf(alice), 250);
        assertEq(reward.balanceOf(bob), 50);
        distributor.claimFor(alice, 64);
        distributor.claimFor(bob, 64);
        assertEq(distributor.totalClaimed(), 300);
    }

    function test_sameBlockRoundTripCannotBorrowRewards() public {
        token.transfer(alice, 100);
        vm.roll(1001);
        vm.prank(alice);
        token.transfer(bob, 100);
        _fee(200);
        vm.prank(bob);
        token.transfer(alice, 100);
        vm.roll(1002);
        _fee(200);
        vm.roll(1003);
        distributor.claimFor(alice, 64);
        distributor.claimFor(bob, 64);
        assertEq(reward.balanceOf(alice), 400);
        assertEq(reward.balanceOf(bob), 0);
    }

    function test_zeroSupplyPendingRestoresAndCannotBeRedirectedByCaller() public {
        _fee(100);
        assertEq(distributor.pendingFees(), 100);
        vm.roll(1001);
        distributor.distribute();
        assertEq(distributor.pendingFees(), 100);
        token.transfer(alice, 100);
        distributor.distribute();
        assertEq(distributor.pendingFees(), 100);
        vm.roll(1002);
        vm.prank(bob);
        distributor.distribute();
        assertEq(distributor.pendingFees(), 0);
        vm.roll(1003);
        vm.prank(bob);
        distributor.claimFor(alice, 64);
        assertEq(reward.balanceOf(alice), 100);
        assertEq(reward.balanceOf(bob), 0);
    }

    function test_allExcludedBalancesRemovedFromDenominator() public {
        address burn = distributor.BURN();
        token.transfer(alice, 100);
        token.transfer(address(manager), 100);
        token.transfer(address(distributor), 100);
        token.transfer(distributor.BURN(), 100);
        vm.roll(1001);
        assertEq(distributor.eligibleSupplyAt(1000), 100);
        _fee(100);
        vm.roll(1002);
        distributor.claimFor(alice, 64);
        assertEq(reward.balanceOf(alice), 100);
        vm.expectRevert(RewardDistributor.ExcludedAccount.selector);
        distributor.claimFor(address(manager), 64);
        vm.expectRevert(RewardDistributor.ExcludedAccount.selector);
        distributor.claimFor(address(this), 64);
        vm.expectRevert(RewardDistributor.ExcludedAccount.selector);
        distributor.claimFor(address(distributor), 64);
        vm.expectRevert(RewardDistributor.ExcludedAccount.selector);
        distributor.claimFor(burn, 64);
        vm.expectRevert(RewardDistributor.ExcludedAccount.selector);
        distributor.claimFor(address(0), 64);
    }

    function test_failedRewardTransferRollsBackCursorAndPreservesEntitlement() public {
        token.transfer(alice, 100);
        vm.roll(1001);
        _fee(100);
        vm.roll(1002);
        reward.blockRecipient(alice);
        vm.expectRevert();
        distributor.claimFor(alice, 64);
        assertEq(distributor.totalClaimed(), 0);
        assertEq(reward.balanceOf(alice), 0);
        (uint32 cursor, uint256 throughBlock, uint256 fraction) = distributor.accounts(alice);
        assertEq(cursor, 0);
        assertEq(throughBlock, 0);
        assertEq(fraction, 0);
        reward.blockRecipient(address(0));
        distributor.claimFor(alice, 64);
        assertEq(reward.balanceOf(alice), 100);
    }

    function test_rewardTransferReentryCannotDoubleClaim() public {
        token.transfer(alice, 100);
        vm.roll(1001);
        _fee(100);
        vm.roll(1002);
        reward.setReentry(alice, distributor);
        distributor.claimFor(alice, 64);
        assertFalse(reward.reentrySucceeded());
        assertEq(reward.balanceOf(alice), 100);
        assertEq(distributor.totalClaimed(), 100);
    }

    function test_invalidRecordAndCallbackCannotForgeRewards() public {
        vm.prank(alice);
        vm.expectRevert(RewardDistributor.OnlyHook.selector);
        distributor.recordFee(100);
        vm.expectRevert(RewardDistributor.InvalidCallback.selector);
        distributor.unlockCallback(abi.encode(alice, 100));
        vm.prank(address(manager));
        vm.expectRevert(RewardDistributor.InvalidCallback.selector);
        distributor.unlockCallback(abi.encode(alice, 100));
        assertEq(distributor.totalFees(), 0);
    }

    function test_emptyAccountsAndInvalidBatchSizes() public {
        assertEq(distributor.claimFor(alice, 64), 0);
        vm.expectRevert(RewardDistributor.InvalidBatch.selector);
        distributor.claimFor(alice, 0);
        vm.expectRevert(RewardDistributor.InvalidBatch.selector);
        distributor.claimFor(alice, 65);
        token.transfer(alice, 100);
        vm.roll(1001);
        _fee(100);
        vm.roll(1002);
        assertEq(distributor.claimFor(alice, 1), 100);
    }

    function test_noHolderRankingOrMinimumBalance() public {
        // The smallest holder is still included after 100 larger holders.
        for (uint256 i = 1; i <= 101; ++i) {
            token.transfer(address(uint160(10_000 + i)), i);
        }
        vm.roll(1001);
        _fee(5151 ether);
        vm.roll(1002);
        uint256 sum;
        for (uint256 i = 1; i <= 101; ++i) {
            address holder = address(uint160(10_000 + i));
            uint256 amount = distributor.claimFor(holder, 64);
            assertApproxEqAbs(amount, i * 1 ether, 1);
            sum += amount;
        }
        assertLe(sum, 5151 ether);
        assertLe(5151 ether - sum, 101);
    }

    function test_fractionCarryMakesFrequentClaimsEquivalent() public {
        token.transfer(alice, 1);
        token.transfer(bob, 2);
        for (uint256 i = 1001; i <= 1100; ++i) {
            vm.roll(i);
            distributor.claimFor(alice, 64);
            _fee(1);
        }
        vm.roll(1101);
        distributor.claimFor(alice, 64);
        distributor.claimFor(bob, 64);
        assertEq(reward.balanceOf(alice), 33);
        assertEq(reward.balanceOf(bob), 66);
        assertEq(manager.balanceOf(address(distributor), uint160(address(reward))), 1);
    }

    function testFuzz_referenceConservationAndBoundedCheckpointClaims(uint256 seed) public {
        address[3] memory users = [alice, bob, carol];
        uint256[3] memory scaled;
        uint256 funded;
        for (uint256 i; i < 3; ++i) {
            token.transfer(users[i], 1000);
        }
        for (uint256 step; step < 80; ++step) {
            vm.roll(1001 + step);
            uint256 random = uint256(keccak256(abi.encode(seed, step)));
            uint256 from = random % 3;
            uint256 to = (from + 1 + (random >> 8) % 2) % 3;
            uint256 move = (random >> 16) % (token.balanceOf(users[from]) + 1);
            vm.prank(users[from]);
            token.transfer(users[to], move);
            uint256 amount = 1 + ((random >> 32) % 1000);
            uint256 growth = amount * Q / 3000;
            for (uint256 j; j < 3; ++j) {
                scaled[j] += token.getPastBalance(users[j], block.number - 1) * growth;
            }
            _fee(amount);
            funded += amount;
        }
        vm.roll(1081);
        uint256 paid;
        for (uint256 i; i < 3; ++i) {
            // Deliberately exercise the smallest allowed batch through >64 blocks.
            for (uint256 j; j < 85; ++j) {
                distributor.claimFor(users[i], 1);
            }
            assertEq(reward.balanceOf(users[i]), scaled[i] / Q);
            (uint256 next,) = distributor.previewClaim(users[i], 64);
            assertEq(next, 0);
            paid += reward.balanceOf(users[i]);
        }
        assertLe(paid, funded);
        assertEq(distributor.totalClaimed(), paid);
        assertEq(manager.balanceOf(address(distributor), uint256(uint160(address(reward)))), funded - paid);
    }

    function testFuzz_changingEligibleSupplyAndInterleavedClaims(uint256 seed) public {
        address[4] memory users = [alice, bob, carol, address(this)];
        uint256[3] memory scaled;
        uint256 pending;
        for (uint256 i; i < 3; ++i) {
            token.transfer(users[i], 1000);
        }
        for (uint256 step; step < 40; ++step) {
            vm.roll(1001 + step);
            for (uint256 j; j < 3; ++j) {
                distributor.claimFor(users[j], 64);
                assertEq(reward.balanceOf(users[j]), scaled[j] / Q);
            }
            uint256 random = uint256(keccak256(abi.encode(seed, step)));
            uint256 from = random % 4;
            uint256 to = (from + 1 + (random >> 8) % 3) % 4;
            uint256 available = token.balanceOf(users[from]);
            if (from == 3) available = 1000;
            uint256 move = (random >> 16) % (available + 1);
            vm.prank(users[from]);
            token.transfer(users[to], move);
            uint256 amount1 = 1 + ((random >> 32) % 1000);
            uint256 amount2 = 1 + ((random >> 48) % 1000);
            uint256 eligible;
            uint256[3] memory oldBalances;
            for (uint256 j; j < 3; ++j) {
                oldBalances[j] = token.getPastBalance(users[j], block.number - 1);
                eligible += oldBalances[j];
            }
            if (eligible == 0) {
                pending += amount1 + amount2;
            } else {
                uint256 growth = (amount1 + pending) * Q / eligible + amount2 * Q / eligible;
                pending = 0;
                for (uint256 j; j < 3; ++j) {
                    scaled[j] += oldBalances[j] * growth;
                }
            }
            _fee(amount1);
            _fee(amount2);
            assertEq(distributor.pendingFees(), pending);
        }
        vm.roll(1041);
        for (uint256 j; j < 3; ++j) {
            distributor.claimFor(users[j], 64);
            assertEq(reward.balanceOf(users[j]), scaled[j] / Q);
        }
    }
}
