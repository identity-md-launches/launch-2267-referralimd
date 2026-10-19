// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReferralIMD} from "src/ReferralIMD.sol";
import {RewardDistributor} from "src/RewardDistributor.sol";
import {FundedRewardsFixture, FundedFeeSource} from "./helpers/FundedRewards.sol";
import {MockIMD} from "./helpers/MockIMD.sol";
import {ClaimingCustodian} from "./ContractHolderClaims.t.sol";

/// @dev Two wallets and two contract custodians share a fixed 2^64 RIMD float that never
/// leaves them, so every fee (a multiple of 2^64) splits integrally. Third parties claim for
/// everyone at random: contract claims must revert without side effects, wallet claims must pay
/// the wallet. The model credits earnings per holder at each fee and never reads the index.
contract ContractHolderHandler is Test {
    uint256 public constant UNITS = 1 << 64;
    ReferralIMD public immutable token;
    MockIMD public immutable imd;
    FundedFeeSource public immutable source;
    RewardDistributor public immutable rewards;
    address[4] public holders;
    uint256[4] public liveBalance;
    uint256[4] public previousBalance;
    uint256[4] public earnedFinalized;
    uint256[4] public earnedThisBlock;
    uint256[4] public paid;
    uint256 public funded;
    uint256 public refusals;
    uint256 public selfPayouts;

    constructor(ReferralIMD token_, MockIMD imd_, FundedFeeSource source_, address[4] memory holders_) {
        token = token_;
        imd = imd_;
        source = source_;
        rewards = source_.rewards();
        holders = holders_;
        vm.prank(address(source_));
        token_.transfer(holders_[0], UNITS);
        liveBalance[0] = UNITS;
    }

    function _isContract(uint256 i) internal pure returns (bool) {
        return i >= 2;
    }

    function move(uint256 fromSeed, uint256 toSeed, uint256 rawAmount) external {
        uint256 from = fromSeed % 4;
        uint256 to = toSeed % 4;
        uint256 amount = bound(rawAmount, 0, liveBalance[from]);
        vm.prank(holders[from]);
        token.transfer(holders[to], amount);
        liveBalance[from] -= amount;
        liveBalance[to] += amount;
    }

    function advance(uint256 rawBlocks) public {
        for (uint256 i; i < 4; ++i) {
            earnedFinalized[i] += earnedThisBlock[i];
            earnedThisBlock[i] = 0;
            previousBalance[i] = liveBalance[i];
        }
        vm.roll(block.number + bound(rawBlocks, 1, 4));
    }

    function fee(uint256 rawUnits) external {
        uint256 amount = bound(rawUnits, 0, 1_000_000) * UNITS;
        source.record(amount);
        funded += amount;
        // The float is placed before the first action, so the prior block always has UNITS eligible.
        for (uint256 i; i < 4; ++i) {
            earnedThisBlock[i] += previousBalance[i] * (amount / UNITS);
        }
    }

    /// @dev Callers are outsiders or other holders (wallets and contracts), never the account itself.
    function thirdPartyClaim(uint256 who, uint256 rawBatch, uint256 callerSeed) external {
        uint256 i = who % 4;
        uint256 pick = callerSeed % 4;
        address caller = pick == 3 ? address(0xBEEF) : holders[(i + 1 + pick) % 4];
        uint256 batch = bound(rawBatch, 1, 64);
        if (_isContract(i)) {
            _refused(holders[i], caller, batch);
            return;
        }
        uint256 beforeBalance = imd.balanceOf(holders[i]);
        uint256 callerBalance = imd.balanceOf(caller);
        vm.prank(caller);
        uint256 amount = rewards.claimFor(holders[i], batch);
        assertEq(imd.balanceOf(caller), callerBalance, "caller is never paid");
        _recordPayment(i, beforeBalance, amount);
    }

    function _refused(address holder, address caller, uint256 batch) private {
        bytes32 progress = _progress(holder);
        uint256 claimed = rewards.totalClaimed();
        uint256 beforeBalance = imd.balanceOf(holder);
        vm.prank(caller);
        vm.expectRevert(RewardDistributor.ContractMustClaimItself.selector);
        rewards.claimFor(holder, batch);
        assertEq(_progress(holder), progress);
        assertEq(rewards.totalClaimed(), claimed);
        assertEq(imd.balanceOf(holder), beforeBalance);
        ++refusals;
    }

    function _progress(address holder) private view returns (bytes32) {
        (uint32 cursor, uint256 throughBlock, uint256 fraction) = rewards.accounts(holder);
        return keccak256(abi.encode(cursor, throughBlock, fraction));
    }

    function selfClaim(uint256 who, uint256 rawBatch) external {
        uint256 i = who % 4;
        uint256 batch = bound(rawBatch, 1, 64);
        uint256 beforeBalance = imd.balanceOf(holders[i]);
        uint256 amount;
        if (_isContract(i)) {
            amount = ClaimingCustodian(holders[i]).claimSelf(batch);
        } else {
            vm.prank(holders[i]);
            amount = rewards.claim(batch);
        }
        if (amount != 0) ++selfPayouts;
        _recordPayment(i, beforeBalance, amount);
    }

    /// @dev Called only by afterInvariant: contracts must still be able to drain everything themselves.
    function finish() external {
        advance(1);
        for (uint256 i; i < 4; ++i) {
            uint256 calls = token.checkpointCount(holders[i]) / 64 + 2;
            for (uint256 j; j < calls; ++j) {
                uint256 beforeBalance = imd.balanceOf(holders[i]);
                uint256 amount =
                    _isContract(i) ? ClaimingCustodian(holders[i]).claimSelf(64) : rewards.claimFor(holders[i], 64);
                _recordPayment(i, beforeBalance, amount);
            }
            assertEq(paid[i], earnedFinalized[i], "every holder's earnings are claimable");
        }
    }

    function _recordPayment(uint256 i, uint256 beforeBalance, uint256 amount) private {
        paid[i] += amount;
        assertEq(imd.balanceOf(holders[i]) - beforeBalance, amount, "payment recipient");
        assertLe(paid[i], earnedFinalized[i], "no unearned or unfinalized rewards");
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract ContractHolderInvariantTest is FundedRewardsFixture {
    ContractHolderHandler internal handler;

    function setUp() public override {
        super.setUp();
        ClaimingCustodian vault = new ClaimingCustodian(rewards);
        ClaimingCustodian merkle = new ClaimingCustodian(rewards);
        handler = new ContractHolderHandler(token, imd, source, [alice, bob, address(vault), address(merkle)]);
        handler.move(0, 2, handler.UNITS() / 2);
        handler.advance(1);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.move.selector;
        selectors[1] = handler.advance.selector;
        selectors[2] = handler.fee.selector;
        selectors[3] = handler.thirdPartyClaim.selector;
        selectors[4] = handler.selfClaim.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_fundingEqualsPaidPlusBacking() public view {
        uint256 paid;
        for (uint256 i; i < 4; ++i) {
            paid += handler.paid(i);
            assertEq(imd.balanceOf(handler.holders(i)), handler.paid(i));
            assertLe(handler.paid(i), handler.earnedFinalized(i));
        }
        assertEq(rewards.totalFees(), handler.funded());
        assertEq(rewards.pendingFees(), 0);
        assertEq(rewards.totalClaimed(), paid);
        assertEq(paid + _backing(), handler.funded());
        assertEq(imd.totalSupply(), handler.funded());
    }

    function invariant_contractEntitlementOnlyMovesThroughSelfClaims() public view {
        for (uint256 i = 2; i < 4; ++i) {
            (uint256 amount,) = rewards.previewClaim(handler.holders(i), 64);
            assertLe(amount + handler.paid(i), handler.earnedFinalized(i));
        }
    }

    function afterInvariant() public {
        assertGt(handler.refusals(), 0, "third-party contract claims were exercised");
        handler.finish();
        invariant_fundingEqualsPaidPlusBacking();
        assertEq(_backing(), 0, "no IMD stranded once custodians claim");
    }
}
