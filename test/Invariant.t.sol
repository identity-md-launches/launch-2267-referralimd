// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {PoolHarness} from "./helpers/PoolHarness.sol";
import {MockIMD} from "./helpers/MockIMD.sol";
import {ReferralIMD} from "../src/ReferralIMD.sol";
import {RewardDistributor} from "../src/RewardDistributor.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

contract TradingHandler is Test {
    ReferralIMD public immutable token;
    MockIMD public immutable imd;
    RewardDistributor public immutable rewards;
    PoolHarness public immutable router;
    PoolKey private _key;
    address[3] public holders;
    uint256 public successfulSwaps;
    uint256 public claims;

    constructor(
        ReferralIMD token_,
        MockIMD imd_,
        RewardDistributor rewards_,
        PoolHarness router_,
        PoolKey memory key_
    ) {
        token = token_;
        imd = imd_;
        rewards = rewards_;
        router = router_;
        _key = key_;
        holders = [address(this), makeAddr("Invariant holder A"), makeAddr("Invariant holder B")];
        token.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
    }

    function trade(bool buy, bool exactInput, uint256 rawAmount) external {
        uint256 balance = buy ? imd.balanceOf(address(this)) : token.balanceOf(address(this));
        if (balance < 20 ether) return;
        uint256 amount = bound(rawAmount, 1e6, 1 ether);
        bool zeroForOne = (_key.currency0 == Currency.wrap(address(imd))) == buy;
        router.swap(
            _key,
            SwapParams(
                zeroForOne,
                exactInput ? -int256(amount) : int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            10 ether,
            ""
        );
        successfulSwaps++;
    }

    function move(uint256 fromIndex, uint256 toIndex, uint256 rawAmount) external {
        address from = holders[fromIndex % 3];
        address to = holders[toIndex % 3];
        uint256 amount = bound(rawAmount, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function burn(uint256 holderIndex, uint256 rawAmount) external {
        address from = holders[holderIndex % 3];
        uint256 amount = bound(rawAmount, 0, token.balanceOf(from) / 10);
        address burnAddress = rewards.BURN();
        vm.prank(from);
        token.transfer(burnAddress, amount);
    }

    function advanceBlock(uint8 count) external {
        vm.roll(block.number + 1 + count);
    }

    function claimHolder(uint256 holderIndex, uint8 intervals) external {
        rewards.claimFor(holders[holderIndex % 3], 1 + intervals % 64);
        claims++;
    }
}

contract TradingInvariantTest is Fixture {
    using TransientStateLibrary for IPoolManager;
    TradingHandler internal handler;

    function setUp() public {
        _deploy(true);
        _seed();
        handler = new TradingHandler(token, imd, rewards, router, key);
        token.transfer(address(handler), 100_000 ether);
        imd.mint(address(handler), 100_000 ether);
        vm.roll(101);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = TradingHandler.trade.selector;
        selectors[1] = TradingHandler.move.selector;
        selectors[2] = TradingHandler.burn.selector;
        selectors[3] = TradingHandler.advanceBlock.selector;
        selectors[4] = TradingHandler.claimHolder.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariantRewardBackingAndLifetimeConservation() public view {
        uint256 claimBacking = manager.balanceOf(address(rewards), uint160(address(imd)));
        assertEq(rewards.totalClaimed() + claimBacking, rewards.totalFees());
        assertLe(claimBacking, imd.balanceOf(address(manager)));
        assertLe(rewards.pendingFees(), claimBacking);
    }

    function invariantNoUnsettledDeltas() public view {
        IPoolManager m = IPoolManager(address(manager));
        assertEq(m.currencyDelta(address(hook), key.currency0), 0);
        assertEq(m.currencyDelta(address(hook), key.currency1), 0);
        assertEq(m.currencyDelta(address(router), key.currency0), 0);
        assertEq(m.currencyDelta(address(router), key.currency1), 0);
        assertEq(m.currencyDelta(address(rewards), key.currency0), 0);
        assertEq(m.currencyDelta(address(rewards), key.currency1), 0);
    }

    function invariantTokenSupplyAndNoTransferTax() public view {
        uint256 sum = token.balanceOf(address(this)) + token.balanceOf(address(manager))
            + token.balanceOf(address(handler)) + token.balanceOf(handler.holders(1))
            + token.balanceOf(handler.holders(2)) + token.balanceOf(rewards.BURN());
        assertEq(sum, 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(rewards)), 0);
        assertEq(token.balanceOf(address(router)), 0);
    }

    function invariantOutstandingEntitlementsDoNotExceedBacking() public view {
        (uint256 sum,) = rewards.previewClaim(address(this), 64);
        for (uint256 i; i < 3; ++i) {
            (uint256 amount,) = rewards.previewClaim(handler.holders(i), 64);
            sum += amount;
        }
        assertLe(sum, manager.balanceOf(address(rewards), uint160(address(imd))));
    }
}
