// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {ReferralHook} from "../src/ReferralHook.sol";
import {RewardDistributor} from "../src/RewardDistributor.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

abstract contract HookBehavior is Fixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function testBuyExactInput() public {
        _assertTrade(true, true, 100 ether);
    }

    function testBuyExactOutput() public {
        _assertTrade(true, false, 100 ether);
    }

    function testSellExactInput() public {
        _assertTrade(false, true, 100 ether);
    }

    function testSellExactOutput() public {
        _assertTrade(false, false, 100 ether);
    }

    function testProtocolFeesPreserveHookCharge() public {
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, uint24(1000 | (1000 << 12)));
        _assertTrade(true, true, 1 ether);
        _assertTrade(true, false, 1 ether);
        _assertTrade(false, true, 1 ether);
        _assertTrade(false, false, 1 ether);
        assertGt(manager.protocolFeesAccrued(key.currency0), 0);
        assertGt(manager.protocolFeesAccrued(key.currency1), 0);
    }

    function testIntegerRoundingAtOneToOneHundredMinorUnits() public {
        for (uint256 amount = 1; amount <= 100; ++amount) {
            (BalanceDelta buyDelta, uint256 buyFee) = _trade(true, true, amount);
            assertEq(uint256(-int256(_pairDelta(buyDelta))), amount);
            assertEq(buyFee, amount / 50);
            (BalanceDelta sellDelta, uint256 sellFee) = _trade(false, false, amount);
            assertEq(uint256(uint128(_pairDelta(sellDelta))), amount);
            assertEq(sellFee, Math.mulDiv(amount, 2, 98, Math.Rounding.Ceil));
        }
    }

    function testFuzzFourModes(bool buy, bool exactInput, uint96 rawAmount) public {
        _assertTrade(buy, exactInput, bound(rawAmount, 1e6, 1000 ether));
    }

    function _assertTrade(bool buy, bool exactInput, uint256 amount) internal {
        uint256 imdBefore = imd.balanceOf(address(this));
        uint256 tokenBefore = token.balanceOf(address(this));
        uint256 claimsBefore = manager.balanceOf(address(rewards), uint160(address(imd)));
        (BalanceDelta delta, uint256 fee) = _trade(buy, exactInput, amount);
        int256 pairDelta = _pairDelta(delta);
        int256 tokenDelta = _tokenDelta(delta);
        assertGt(fee, 0);
        assertEq(int256(imd.balanceOf(address(this))) - int256(imdBefore), pairDelta);
        assertEq(int256(token.balanceOf(address(this))) - int256(tokenBefore), tokenDelta);
        if (buy) {
            assertLt(pairDelta, 0);
            assertGt(tokenDelta, 0);
            if (exactInput) {
                assertEq(uint256(-pairDelta), amount);
                assertEq(fee, amount * 2 / 100);
            } else {
                assertEq(uint256(tokenDelta), amount);
                uint256 poolInput = uint256(-pairDelta) - fee;
                assertEq(fee, Math.mulDiv(poolInput, 2, 98, Math.Rounding.Ceil));
            }
        } else {
            assertGt(pairDelta, 0);
            assertLt(tokenDelta, 0);
            if (exactInput) {
                assertEq(uint256(-tokenDelta), amount);
                assertEq(fee, (uint256(pairDelta) + fee) * 2 / 100);
            } else {
                assertEq(uint256(pairDelta), amount);
                assertEq(fee, Math.mulDiv(amount, 2, 98, Math.Rounding.Ceil));
            }
        }
        assertEq(manager.balanceOf(address(rewards), uint160(address(imd))) - claimsBefore, fee);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(IPoolManager(address(manager)).currencyDelta(address(hook), Currency.wrap(address(imd))), 0);
        assertEq(IPoolManager(address(manager)).currencyDelta(address(router), key.currency0), 0);
        assertEq(IPoolManager(address(manager)).currencyDelta(address(router), key.currency1), 0);
    }

    function testPermissionFlagsAndUnsupportedSelectors() public {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.beforeInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta
        );
        assertFalse(p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity || p.afterRemoveLiquidity);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, 0x20cc);
        (bool hasOwner,) = address(hook).call(abi.encodeWithSignature("owner()"));
        assertFalse(hasOwner);
    }

    function testEveryImplementedCallbackRejectsUnauthorizedCaller() public {
        vm.expectRevert(ReferralHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, PRICE);
        SwapParams memory params = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert(ReferralHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(ReferralHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, params, toBalanceDelta(-1, 1), "");
        vm.expectRevert(RewardDistributor.InvalidCallback.selector);
        rewards.unlockCallback(abi.encode(alice, 1 ether));
        vm.prank(address(manager));
        vm.expectRevert(RewardDistributor.InvalidCallback.selector);
        rewards.unlockCallback(abi.encode(alice, 1 ether));
    }

    function testDifferentPoolAndInvalidAmountRejected() public {
        PoolKey memory other = key;
        other.fee = 3000;
        SwapParams memory params = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.prank(address(manager));
        vm.expectRevert(ReferralHook.InvalidPool.selector);
        hook.beforeSwap(alice, other, params, "");
        params.amountSpecified = type(int256).min;
        vm.prank(address(manager));
        vm.expectRevert(ReferralHook.InvalidAmount.selector);
        hook.beforeSwap(alice, key, params, "");
        params.amountSpecified = 0;
        vm.prank(address(manager));
        vm.expectRevert(ReferralHook.InvalidAmount.selector);
        hook.beforeSwap(alice, key, params, "");
    }

    function testHookDataCannotChangeFeesOrRecipient() public {
        bool zeroForOne = key.currency0 == Currency.wrap(address(imd));
        uint256 beforeFees = rewards.totalFees();
        router.swap(
            key,
            SwapParams(zeroForOne, -100 ether, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            100 ether,
            abi.encode(alice, uint256(0), "skip fee", address(hook))
        );
        assertEq(rewards.totalFees() - beforeFees, 2 ether);
        assertEq(imd.balanceOf(alice), 0);
    }

    function testFactoryPositionCanCollectAndWithdraw() public {
        _trade(true, true, 100 ether);
        _trade(false, true, 100 ether);
        uint256 beforeFees = rewards.totalFees();
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 0, bytes32(0));
        BalanceDelta collect = router.modify(key, params, 0, 0);
        assertGe(collect.amount0(), 0);
        assertGe(collect.amount1(), 0);
        assertGt(uint256(uint128(collect.amount0())) + uint256(uint128(collect.amount1())), 0);
        params.liquidityDelta = -int256(LIQUIDITY);
        BalanceDelta withdrawal = router.modify(key, params, 0, 0);
        assertGt(withdrawal.amount0(), 0);
        assertGt(withdrawal.amount1(), 0);
        assertEq(rewards.totalFees(), beforeFees);
    }

    function testSpecifiedIMDPartialBuyRevertsAtomically() public {
        bool zeroForOne = key.currency0 == Currency.wrap(address(imd));
        uint160 limit = zeroForOne ? PRICE - 1e20 : PRICE + 1e20;
        uint256 beforeFees = rewards.totalFees();
        uint256 beforeClaims = manager.balanceOf(address(rewards), uint160(address(imd)));
        vm.expectRevert();
        router.swap(key, SwapParams(zeroForOne, -100_000 ether, limit), 100_000 ether, "");
        assertEq(rewards.totalFees(), beforeFees);
        assertEq(manager.balanceOf(address(rewards), uint160(address(imd))), beforeClaims);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, PRICE);
    }

    function testSpecifiedIMDPartialSellRevertsAtomically() public {
        bool zeroForOne = !(key.currency0 == Currency.wrap(address(imd)));
        uint160 limit = zeroForOne ? PRICE - 1e20 : PRICE + 1e20;
        uint256 beforeFees = rewards.totalFees();
        vm.expectRevert();
        router.swap(key, SwapParams(zeroForOne, 100_000 ether, limit), 300_000 ether, "");
        assertEq(rewards.totalFees(), beforeFees);
    }

    function testUnspecifiedIMDPartialSellChargesActualOutput() public {
        bool zeroForOne = !(key.currency0 == Currency.wrap(address(imd)));
        uint160 limit = zeroForOne ? PRICE - 1e20 : PRICE + 1e20;
        uint256 beforeFees = rewards.totalFees();
        BalanceDelta delta = router.swap(key, SwapParams(zeroForOne, -100_000 ether, limit), 100_000 ether, "");
        uint256 fee = rewards.totalFees() - beforeFees;
        assertLt(uint256(-int256(_tokenDelta(delta))), 100_000 ether);
        assertGt(_pairDelta(delta), 0);
        assertEq(fee, (uint256(uint128(_pairDelta(delta))) + fee) * 2 / 100);
    }

    function testUnspecifiedIMDPartialBuyChargesActualInput() public {
        bool zeroForOne = key.currency0 == Currency.wrap(address(imd));
        uint160 limit = zeroForOne ? PRICE - 1e20 : PRICE + 1e20;
        uint256 beforeFees = rewards.totalFees();
        BalanceDelta delta = router.swap(key, SwapParams(zeroForOne, 100_000 ether, limit), 300_000 ether, "");
        uint256 fee = rewards.totalFees() - beforeFees;
        assertLt(uint256(uint128(_tokenDelta(delta))), 100_000 ether);
        uint256 poolInput = uint256(-int256(_pairDelta(delta))) - fee;
        assertEq(fee, Math.mulDiv(poolInput, 2, 98, Math.Rounding.Ceil));
    }

    function testFeesClaimableInIMDWithoutKeeper() public {
        uint256 pastBalance = token.getPastBalance(address(this), 100);
        uint256 eligible = rewards.eligibleSupplyAt(100);
        (, uint256 fee) = _trade(true, true, 100 ether);
        assertEq(rewards.claim(64), 0);
        vm.roll(102);
        uint256 imdBefore = imd.balanceOf(address(this));
        uint256 amount = rewards.claim(64);
        assertApproxEqAbs(amount, Math.mulDiv(fee, pastBalance, eligible), 1);
        assertEq(imd.balanceOf(address(this)) - imdBefore, amount);
        assertEq(rewards.claim(64), 0);
        assertEq(manager.balanceOf(address(rewards), uint160(address(imd))), fee - amount);
    }
}

contract HookPairFirstTest is HookBehavior {
    function setUp() public {
        _deploy(true);
        _seed();
        vm.roll(101);
    }
}

contract HookPairSecondTest is HookBehavior {
    function setUp() public {
        _deploy(false);
        _seed();
        vm.roll(101);
    }
}

contract HookInitializationTest is Fixture {
    function testConstructorAndInitializationBinding() public {
        _deploy(true);
        assertTrue(hook.initialized());
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.factory(), address(this));
        assertEq(rewards.hook(), address(hook));
        vm.prank(address(manager));
        vm.expectRevert(ReferralHook.AlreadyInitialized.selector);
        hook.beforeInitialize(address(this), key, PRICE);
        vm.prank(address(manager));
        vm.expectRevert(ReferralHook.OnlyFactory.selector);
        hook.beforeInitialize(alice, key, PRICE);
    }

    function testNewManagerWithoutIMDReserveCanBuy() public {
        _deploy(true);
        // One-sided position at the current price: RIMD liquidity, zero IMD.
        // IMD is currency0; the position below current tick holds currency1 (RIMD).
        router.modify(key, ModifyLiquidityParams(-600, -60, int256(LIQUIDITY), bytes32(0)), 0, 1_000_000 ether);
        assertEq(imd.balanceOf(address(manager)), 0);
        assertEq(address(manager).balance, 0);
        vm.roll(101);
        (, uint256 fee) = _trade(true, true, 100 ether);
        assertEq(fee, 2 ether);
        assertEq(manager.balanceOf(address(rewards), uint160(address(imd))), fee);
        vm.roll(102);
        assertGt(rewards.claim(64), 0);
    }
}
