// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ReferralIMD} from "src/ReferralIMD.sol";
import {RewardDistributor} from "src/RewardDistributor.sol";
import {MockIMD} from "./MockIMD.sol";

/// @dev Test-only fee source. Each call mints fully settled claims and records them
/// inside one manager unlock, just as a hook and its settling router do on a swap.
contract FundedFeeSource is IUnlockCallback {
    PoolManager public immutable manager;
    MockIMD public immutable imd;
    RewardDistributor public immutable rewards;

    constructor(PoolManager manager_, ReferralIMD token_, MockIMD imd_) {
        manager = manager_;
        imd = imd_;
        rewards = new RewardDistributor(manager_, token_, Currency.wrap(address(imd_)), address(this));
    }

    function record(uint256 amount) external {
        imd.mint(address(this), amount);
        manager.unlock(abi.encode(amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        uint256 amount = abi.decode(data, (uint256));
        Currency currency = Currency.wrap(address(imd));
        manager.mint(address(rewards), currency.toId(), amount);
        rewards.recordFee(amount);
        manager.sync(currency);
        imd.transfer(address(manager), amount);
        manager.settle();
        return "";
    }
}

abstract contract FundedRewardsFixture is Test {
    ReferralIMD internal token;
    MockIMD internal imd;
    PoolManager internal manager;
    FundedFeeSource internal source;
    RewardDistributor internal rewards;
    address internal alice = makeAddr("ledger Alice");
    address internal bob = makeAddr("ledger Bob");
    address internal carol = makeAddr("ledger Carol");

    function setUp() public virtual {
        vm.roll(100);
        token = new ReferralIMD();
        imd = new MockIMD();
        manager = new PoolManager(address(this));
        source = new FundedFeeSource(manager, token, imd);
        rewards = source.rewards();
        // The excluded source is a reserve for test allocations, not a holder.
        token.transfer(address(source), token.totalSupply());
    }

    function _give(address holder, uint256 amount) internal {
        vm.prank(address(source));
        token.transfer(holder, amount);
    }

    function _backing() internal view returns (uint256) {
        return manager.balanceOf(address(rewards), uint160(address(imd)));
    }

    function _accountHash(address holder) internal view returns (bytes32) {
        (uint32 cursor, uint256 throughBlock, uint256 fraction) = rewards.accounts(holder);
        return keccak256(abi.encode(cursor, throughBlock, fraction));
    }
}
