// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FundedRewardsFixture} from "./helpers/FundedRewards.sol";
import {RewardDistributor} from "src/RewardDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev A RIMD custodian (multisig, vesting vault, Merkle distributor) that can claim and forward.
contract ClaimingCustodian {
    RewardDistributor public immutable rewards;

    constructor(RewardDistributor rewards_) {
        rewards = rewards_;
    }

    function claimSelf(uint256 maxIntervals) external returns (uint256) {
        return rewards.claim(maxIntervals);
    }

    function claimForOther(address account, uint256 maxIntervals) external returns (uint256) {
        return rewards.claimFor(account, maxIntervals);
    }

    function forward(IERC20 asset, address to, uint256 amount) external {
        asset.transfer(to, amount);
    }
}

/// @dev Minimal 7702 delegate: an EOA that delegates to it keeps signing its own transactions.
contract DelegateWallet {
    function ping() external pure returns (bool) {
        return true;
    }
}

contract ContractHolderClaimsTest is FundedRewardsFixture {
    ClaimingCustodian internal custodian;

    function setUp() public override {
        super.setUp();
        custodian = new ClaimingCustodian(rewards);
    }

    function _snapshot(address holder) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                _accountHash(holder),
                rewards.totalClaimed(),
                _backing(),
                imd.balanceOf(holder),
                rewards.rewardIndex(),
                rewards.pendingFees()
            )
        );
    }

    function test_thirdPartyRefusalLeavesProgressAndBackingUntouched() public {
        _give(address(custodian), 3);
        _give(alice, 1);
        for (uint256 i = 1; i <= 5; ++i) {
            vm.roll(100 + i);
            source.record(40);
        }
        vm.roll(106);
        bytes32 before = _snapshot(address(custodian));
        vm.prank(carol);
        vm.expectRevert(RewardDistributor.ContractMustClaimItself.selector);
        rewards.claimFor(address(custodian), 64);
        assertEq(_snapshot(address(custodian)), before);
        // A different contract is refused too: the rule is "the account itself", not "any EOA".
        ClaimingCustodian other = new ClaimingCustodian(rewards);
        vm.expectRevert(RewardDistributor.ContractMustClaimItself.selector);
        other.claimForOther(address(custodian), 64);
        assertEq(_snapshot(address(custodian)), before);
        // Nothing accrued was forfeited by the refusals.
        assertEq(custodian.claimSelf(64), 150);
        assertEq(imd.balanceOf(address(custodian)), 150);
        custodian.forward(IERC20(address(imd)), bob, 150);
        assertEq(imd.balanceOf(bob), 150);
        assertEq(rewards.claimFor(alice, 64), 50);
        assertEq(_backing(), 0);
    }

    function test_refusalAppliesEvenWhenNothingIsDue() public {
        _give(address(custodian), 1);
        vm.roll(101);
        (uint256 due,) = rewards.previewClaim(address(custodian), 64);
        assertEq(due, 0);
        vm.prank(carol);
        vm.expectRevert(RewardDistributor.ContractMustClaimItself.selector);
        rewards.claimFor(address(custodian), 64);
        assertEq(custodian.claimSelf(64), 0);
    }

    function test_validationErrorsTakePrecedenceOverContractRule() public {
        _give(address(custodian), 1);
        vm.roll(101);
        vm.startPrank(carol);
        vm.expectRevert(RewardDistributor.InvalidBatch.selector);
        rewards.claimFor(address(custodian), 0);
        vm.expectRevert(RewardDistributor.InvalidBatch.selector);
        rewards.claimFor(address(custodian), 65);
        // Excluded contracts report exclusion, never a claimable-by-itself hint.
        vm.expectRevert(RewardDistributor.ExcludedAccount.selector);
        rewards.claimFor(address(rewards), 64);
        vm.expectRevert(RewardDistributor.ExcludedAccount.selector);
        rewards.claimFor(address(manager), 64);
        vm.expectRevert(RewardDistributor.ExcludedAccount.selector);
        rewards.claimFor(address(source), 64);
        vm.stopPrank();
        // The excluded fee source cannot claim itself either.
        vm.prank(address(source));
        vm.expectRevert(RewardDistributor.ExcludedAccount.selector);
        rewards.claim(64);
    }

    function test_contractRelayerMayStillPayGasForWallets() public {
        _give(alice, 1);
        _give(bob, 3);
        vm.roll(101);
        source.record(80);
        vm.roll(102);
        assertEq(custodian.claimForOther(alice, 64), 20);
        assertEq(custodian.claimForOther(bob, 64), 60);
        assertEq(imd.balanceOf(alice), 20);
        assertEq(imd.balanceOf(bob), 60);
        assertEq(imd.balanceOf(address(custodian)), 0);
        assertEq(custodian.claimForOther(alice, 64), 0);
    }

    function test_counterfactualAddressIsPushableUntilCodeIsDeployed() public {
        bytes32 salt = keccak256("rIMD custodian");
        bytes memory initCode = abi.encodePacked(type(ClaimingCustodian).creationCode, abi.encode(rewards));
        address predicted = vm.computeCreate2Address(salt, keccak256(initCode), address(this));
        assertEq(predicted.code.length, 0);
        _give(predicted, 1);
        _give(alice, 3);
        vm.roll(101);
        source.record(40);
        vm.roll(102);
        vm.prank(carol);
        assertEq(rewards.claimFor(predicted, 64), 10);
        assertEq(imd.balanceOf(predicted), 10);

        ClaimingCustodian deployed = new ClaimingCustodian{salt: salt}(rewards);
        assertEq(address(deployed), predicted);
        source.record(40);
        vm.roll(103);
        vm.prank(carol);
        vm.expectRevert(RewardDistributor.ContractMustClaimItself.selector);
        rewards.claimFor(predicted, 64);
        assertEq(deployed.claimSelf(64), 10);
        // IMD pushed before deployment is spendable by the deployed code.
        deployed.forward(IERC20(address(imd)), bob, 20);
        assertEq(imd.balanceOf(bob), 20);
        assertEq(rewards.claimFor(alice, 64), 60);
        assertEq(_backing(), 0);
    }

    /// @dev EIP-7702 wallets carry delegation code, so only the wallet itself can claim.
    /// Entitlement is not lost: reported as an informational finding, not a fund-loss defect.
    function test_eip7702DelegatedWalletKeepsEntitlementThroughSelfClaim() public {
        (address wallet, uint256 key) = makeAddrAndKey("7702 wallet");
        DelegateWallet implementation = new DelegateWallet();
        _give(wallet, 1);
        _give(alice, 1);
        vm.roll(101);
        source.record(30);
        vm.signAndAttachDelegation(address(implementation), key);
        assertGt(wallet.code.length, 0);
        vm.roll(102);
        vm.prank(carol);
        vm.expectRevert(RewardDistributor.ContractMustClaimItself.selector);
        rewards.claimFor(wallet, 64);
        vm.prank(wallet, wallet);
        assertEq(rewards.claim(64), 15);
        assertEq(imd.balanceOf(wallet), 15);
    }

    /// @dev A custodian that never claims keeps diluting wallets and its share stays locked.
    function test_unclaimedCustodianShareStaysBackedAndDilutesWallets() public {
        _give(address(custodian), 1);
        _give(alice, 9);
        for (uint256 i = 1; i <= 4; ++i) {
            vm.roll(100 + i);
            source.record(100);
        }
        vm.roll(105);
        assertEq(rewards.claimFor(alice, 64), 360);
        assertEq(_backing(), 40);
        (uint256 due,) = rewards.previewClaim(address(custodian), 64);
        assertEq(due, 40);
        // Once the custodian releases its RIMD it stops diluting from the next block on.
        vm.prank(address(custodian));
        token.transfer(alice, 1);
        source.record(100);
        vm.roll(106);
        source.record(100);
        vm.roll(107);
        assertEq(rewards.claimFor(alice, 64), 190);
        assertEq(custodian.claimSelf(64), 50);
        assertEq(_backing(), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_mixedHoldersShareExactlyOnceRegardlessOfWhoClaims(
        uint256 rawWallet,
        uint256 rawCustodian,
        uint256 rawFee,
        bool walletSelf
    ) public {
        uint256 walletBalance = bound(rawWallet, 1, 4e26);
        uint256 custodianBalance = bound(rawCustodian, 1, 4e26);
        uint256 fee = bound(rawFee, 0, 1e30);
        _give(alice, walletBalance);
        _give(address(custodian), custodianBalance);
        vm.roll(101);
        source.record(fee);
        vm.roll(102);
        vm.prank(bob);
        vm.expectRevert(RewardDistributor.ContractMustClaimItself.selector);
        rewards.claimFor(address(custodian), 64);
        uint256 walletPaid;
        if (walletSelf) {
            vm.prank(alice);
            walletPaid = rewards.claim(64);
        } else {
            vm.prank(bob);
            walletPaid = rewards.claimFor(alice, 64);
        }
        uint256 custodianPaid = custodian.claimSelf(64);
        uint256 total = walletBalance + custodianBalance;
        // The index is floored before each balance multiplies it, so each payout may be one wei
        // below its exact pro-rata share (never above); that dust stays backed in the distributor.
        uint256 walletExact = fee * walletBalance / total;
        uint256 custodianExact = fee * custodianBalance / total;
        assertLe(walletPaid, walletExact);
        assertLe(walletExact - walletPaid, 1);
        assertLe(custodianPaid, custodianExact);
        assertLe(custodianExact - custodianPaid, 1);
        assertLe(fee - walletPaid - custodianPaid, 3);
        assertEq(imd.balanceOf(bob), 0);
        assertEq(rewards.totalClaimed() + _backing(), fee);
    }
}
