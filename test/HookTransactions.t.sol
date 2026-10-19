// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {InspectingSwapRouter} from "./helpers/InspectingSwapRouter.sol";
import {ReferralHook} from "src/ReferralHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

abstract contract HookTransactionBehavior is Fixture {
    using StateLibrary for IPoolManager;
    InspectingSwapRouter internal probe;

    function _setUpTransactions(bool pairFirst) internal {
        _deploy(pairFirst);
        _seed();
        probe = new InspectingSwapRouter(manager, rewards);
        token.approve(address(probe), 1_000_000 ether);
        imd.approve(address(probe), 1_000_000 ether);
        vm.roll(101);
    }

    function testFuzz_batchAllFourSwapModesConservesActualAssets(uint96 rawAmount, bool reverse) public {
        uint256 amount = bound(rawAmount, 100, 1000 ether);
        SwapParams[] memory swaps = new SwapParams[](4);
        for (uint256 i; i < 4; ++i) {
            uint256 mode = reverse ? 3 - i : i;
            swaps[i] = _params(mode < 2, mode % 2 == 0, amount);
        }
        uint256 beforeFees = rewards.totalFees();
        uint256 beforeBacking = manager.balanceOf(address(rewards), uint160(address(imd)));
        uint256 beforeIMD = imd.balanceOf(address(this));
        uint256 beforeRIMD = token.balanceOf(address(this));
        (BalanceDelta[] memory deltas, uint256[] memory fees) = probe.batch(key, swaps, 100_000 ether, 100_000 ether, 0);
        int256 netIMD;
        int256 netRIMD;
        uint256 totalFee;
        for (uint256 i; i < 4; ++i) {
            _assertEconomicFee(deltas[i], swaps[i], fees[i], amount);
            netIMD += _pairDelta(deltas[i]);
            netRIMD += _tokenDelta(deltas[i]);
            totalFee += fees[i];
        }
        assertGt(totalFee, 0);
        assertEq(int256(imd.balanceOf(address(this))) - int256(beforeIMD), netIMD);
        assertEq(int256(token.balanceOf(address(this))) - int256(beforeRIMD), netRIMD);
        assertEq(rewards.totalFees() - beforeFees, totalFee);
        assertEq(manager.balanceOf(address(rewards), uint160(address(imd))) - beforeBacking, totalFee);
        assertEq(token.balanceOf(address(probe)), 0);
        assertEq(imd.balanceOf(address(probe)), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(rewards.indexCheckpointCount(), 1);
    }

    function _assertEconomicFee(BalanceDelta delta, SwapParams memory params, uint256 fee, uint256 amount)
        private
        view
    {
        bool buy = (key.currency0 == Currency.wrap(address(imd))) == params.zeroForOne;
        bool exactInput = params.amountSpecified < 0;
        int256 pairDelta = _pairDelta(delta);
        int256 tokenDelta = _tokenDelta(delta);
        uint256 grossIMD = buy ? uint256(-pairDelta) : uint256(pairDelta) + fee;
        // Characterize the allowed rounding error directly as a 2% ratio.
        if (exactInput) {
            assertLe(fee * 50, grossIMD);
            assertLt(grossIMD - fee * 50, 50);
        } else {
            assertGe(fee * 50, grossIMD);
            assertLt(fee * 50 - grossIMD, 49);
        }
        if (buy) {
            assertLt(pairDelta, 0);
            assertGt(tokenDelta, 0);
            assertEq(exactInput ? uint256(-pairDelta) : uint256(tokenDelta), amount);
        } else {
            assertGt(pairDelta, 0);
            assertLt(tokenDelta, 0);
            assertEq(exactInput ? uint256(-tokenDelta) : uint256(pairDelta), amount);
        }
    }

    function test_oneUnitUnderpaymentRollsBackEverySwapAndFee() public {
        _assertSettlementRollback(1);
    }

    function test_missingSettlementCannotLeaveUnbackedRewards() public {
        _assertSettlementRollback(2);
    }

    function _assertSettlementRollback(uint8 mode) private {
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, uint24(1000 | (1000 << 12)));
        SwapParams[] memory swaps = new SwapParams[](2);
        swaps[0] = _params(true, true, 100 ether);
        swaps[1] = _params(true, false, 50 ether);
        bytes32 beforeState = _stateFingerprint();
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        probe.batch(key, swaps, 1000 ether, 1000 ether, mode);
        assertEq(_stateFingerprint(), beforeState, "failed unlock must roll back every effect");
        // Failure did not poison a later transaction's settlement or fee collection.
        (, uint256[] memory fees) = probe.batch(key, swaps, 1000 ether, 1000 ether, 0);
        assertGt(fees[0] + fees[1], 0);
        assertEq(rewards.totalFees(), fees[0] + fees[1]);
    }

    function test_zeroSwapThroughRealManagerCannotRecordFees() public {
        SwapParams[] memory swaps = new SwapParams[](1);
        swaps[0] = _params(true, true, 0);
        bytes32 beforeState = _stateFingerprint();
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        probe.batch(key, swaps, 1000 ether, 1000 ether, 0);
        assertEq(_stateFingerprint(), beforeState);
    }

    function test_feesRemainRedeemableAfterAllLiquidityIsRemoved() public {
        token.transfer(alice, 100_000 ether);
        vm.roll(102);
        _trade(true, true, 100 ether);
        _trade(false, true, 200 ether);
        uint256 backing = manager.balanceOf(address(rewards), uint160(address(imd)));
        router.modify(
            key,
            ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), -int256(LIQUIDITY), bytes32(0)
            ),
            0,
            0
        );
        assertEq(IPoolManager(address(manager)).getLiquidity(key.toId()), 0);
        assertGe(imd.balanceOf(address(manager)), backing);
        vm.roll(103);
        uint256 alicePaid = rewards.claimFor(alice, 64);
        uint256 deployerPaid = rewards.claim(64);
        assertGt(alicePaid, 0);
        assertGt(deployerPaid, 0);
        assertEq(backing - alicePaid - deployerPaid, manager.balanceOf(address(rewards), uint160(address(imd))));
        assertEq(imd.balanceOf(alice), alicePaid);
    }

    function test_wrongPoolFieldsRejectBeforeAnyFeeCanBeMinted() public {
        SwapParams memory params = _params(true, true, 1 ether);
        for (uint256 field; field < 5; ++field) {
            PoolKey memory wrong = hook.poolKey();
            if (field == 0) wrong.currency0 = Currency.wrap(alice);
            if (field == 1) wrong.currency1 = Currency.wrap(bob);
            if (field == 2) wrong.fee = 12_501;
            if (field == 3) wrong.tickSpacing = 120;
            if (field == 4) wrong.hooks = IHooks(carol);
            vm.prank(address(manager));
            vm.expectRevert(ReferralHook.InvalidPool.selector);
            hook.beforeSwap(alice, wrong, params, "");
            vm.prank(address(manager));
            vm.expectRevert(ReferralHook.InvalidPool.selector);
            hook.afterSwap(alice, wrong, params, toBalanceDelta(-1, 1), "");
        }
        assertEq(rewards.totalFees(), 0);
        assertEq(manager.balanceOf(address(rewards), uint160(address(imd))), 0);
    }

    function test_invalidSignedAmountBoundariesRejectInBothCallbacks() public {
        int256 cap = type(int128).max / 2;
        int256[7] memory amounts = [
            int256(0),
            cap + 1,
            -cap - 1,
            int256(type(int128).max),
            int256(type(int128).min),
            type(int256).max,
            type(int256).min
        ];
        for (uint256 i; i < amounts.length; ++i) {
            SwapParams memory params = _params(true, true, 1);
            params.amountSpecified = amounts[i];
            vm.prank(address(manager));
            vm.expectRevert(ReferralHook.InvalidAmount.selector);
            hook.beforeSwap(alice, key, params, "");
            vm.prank(address(manager));
            vm.expectRevert(ReferralHook.InvalidAmount.selector);
            hook.afterSwap(alice, key, params, toBalanceDelta(-1, 1), "");
        }
        assertEq(rewards.totalFees(), 0);
    }

    function _params(bool buy, bool exactInput, uint256 amount) private view returns (SwapParams memory) {
        bool zeroForOne = (key.currency0 == Currency.wrap(address(imd))) == buy;
        return SwapParams(
            zeroForOne,
            exactInput ? -int256(amount) : int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function _stateFingerprint() private view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) =
            IPoolManager(address(manager)).getSlot0(key.toId());
        bytes32 poolState = keccak256(
            abi.encode(
                price,
                tick,
                protocolFee,
                lpFee,
                manager.protocolFeesAccrued(key.currency0),
                manager.protocolFeesAccrued(key.currency1)
            )
        );
        bytes32 rewardState = keccak256(
            abi.encode(
                rewards.totalFees(),
                rewards.pendingFees(),
                rewards.rewardIndex(),
                rewards.indexCheckpointCount(),
                manager.balanceOf(address(rewards), uint160(address(imd)))
            )
        );
        bytes32 balances = keccak256(
            abi.encode(
                token.balanceOf(address(this)),
                imd.balanceOf(address(this)),
                token.balanceOf(address(manager)),
                imd.balanceOf(address(manager)),
                token.balanceOf(address(probe)),
                imd.balanceOf(address(probe)),
                token.checkpointCount(address(this)),
                token.checkpointCount(address(probe))
            )
        );
        return keccak256(
            abi.encode(
                poolState,
                rewardState,
                balances,
                token.allowance(address(this), address(probe)),
                imd.allowance(address(this), address(probe))
            )
        );
    }
}

/// forge-config: default.fuzz.runs = 1000
contract HookTransactionsPairFirstTest is HookTransactionBehavior {
    function setUp() public {
        _setUpTransactions(true);
    }
}

/// forge-config: default.fuzz.runs = 1000
contract HookTransactionsPairSecondTest is HookTransactionBehavior {
    function setUp() public {
        _setUpTransactions(false);
    }
}
