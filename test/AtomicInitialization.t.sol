// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReferralIMD} from "src/ReferralIMD.sol";
import {ReferralHook} from "src/ReferralHook.sol";
import {PrepareLaunch} from "script/PrepareLaunch.s.sol";
import {MockIMD} from "./helpers/MockIMD.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";

/// @dev Models only the factory's hook deployment/initialization call boundaries.
/// It does not purport to implement the production factory or its allocations.
contract AtomicHookFactory {
    IPoolManager public immutable manager;
    ReferralIMD public immutable token;
    Currency public immutable pair;

    constructor(IPoolManager manager_, ReferralIMD token_, Currency pair_) {
        manager = manager_;
        token = token_;
        pair = pair_;
    }

    function deployOnly(bytes32 salt) public returns (ReferralHook) {
        return new ReferralHook{salt: salt}(manager, token, pair, address(this));
    }

    function deployAndInitialize(bytes32 salt, uint160 price) external returns (ReferralHook hook) {
        hook = deployOnly(salt);
        manager.initialize(hook.poolKey(), price);
    }

    function initialize(ReferralHook hook, uint160 price) external {
        manager.initialize(hook.poolKey(), price);
    }
}

contract AtomicInitializationTest is Test {
    using StateLibrary for IPoolManager;
    uint160 internal constant PRICE = 1 << 96;
    PoolManager internal manager;
    ReferralIMD internal token;
    MockIMD internal imd;
    AtomicHookFactory internal factory;
    bytes32 internal salt;
    address internal predicted;
    PoolKey internal key;

    function setUp() public {
        vm.roll(100);
        manager = new PoolManager(address(this));
        token = new ReferralIMD();
        imd = new MockIMD();
        factory = new AtomicHookFactory(manager, token, Currency.wrap(address(imd)));
        PrepareLaunch preparer = new PrepareLaunch();
        (salt, predicted,) = preparer.mine(manager, token, Currency.wrap(address(imd)), address(factory), 0, 200_000);
        (Currency c0, Currency c1) = address(token) < address(imd)
            ? (Currency.wrap(address(token)), Currency.wrap(address(imd)))
            : (Currency.wrap(address(imd)), Currency.wrap(address(token)));
        key = PoolKey(c0, c1, 12_500, 60, IHooks(predicted));
    }

    function test_predictedAddressCannotBeInitializedBeforeHookDeployment() public {
        assertEq(predicted.code.length, 0);
        vm.expectRevert(Hooks.InvalidHookResponse.selector);
        manager.initialize(key, PRICE);
        (uint160 beforePrice,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(beforePrice, 0);
        ReferralHook hook = factory.deployAndInitialize(salt, PRICE);
        assertEq(address(hook), predicted);
        assertTrue(hook.initialized());
        assertEq(hook.factory(), address(factory));
        assertEq(address(hook.distributor().poolManager()), address(manager));
        assertEq(hook.distributor().hook(), predicted);
        (uint160 afterPrice,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(afterPrice, PRICE);
    }

    function test_failedAtomicInitializationLeavesNoHalfDeployedHook() public {
        vm.expectRevert(abi.encodeWithSelector(TickMath.InvalidSqrtPrice.selector, uint160(0)));
        factory.deployAndInitialize(salt, 0);
        assertEq(predicted.code.length, 0);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, 0);
        // The same CREATE2 salt remains usable after the reverted transaction.
        ReferralHook hook = factory.deployAndInitialize(salt, PRICE);
        assertEq(address(hook), predicted);
        assertTrue(hook.initialized());
    }

    function test_failedPoolInitializationRollsBackTheBindingFlag() public {
        ReferralHook hook = factory.deployOnly(salt);
        vm.expectRevert(abi.encodeWithSelector(TickMath.InvalidSqrtPrice.selector, uint160(0)));
        factory.initialize(hook, 0);
        assertFalse(hook.initialized());
        factory.initialize(hook, PRICE);
        assertTrue(hook.initialized());
    }

    function test_unauthorizedFactoryCannotConsumeTheOneTimeInitialization() public {
        ReferralHook hook = factory.deployOnly(salt);
        vm.expectRevert(_wrapped(IHooks.beforeInitialize.selector, ReferralHook.OnlyFactory.selector));
        manager.initialize(key, PRICE);
        assertFalse(hook.initialized());
        factory.initialize(hook, PRICE);
        vm.expectRevert(_wrapped(IHooks.beforeInitialize.selector, ReferralHook.AlreadyInitialized.selector));
        factory.initialize(hook, PRICE + 1);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, PRICE);
    }

    function test_differentPoolManagerCannotBindTheHook() public {
        ReferralHook hook = factory.deployOnly(salt);
        PoolManager rogueManager = new PoolManager(address(this));
        vm.expectRevert(_wrapped(IHooks.beforeInitialize.selector, ReferralHook.OnlyPoolManager.selector));
        rogueManager.initialize(key, PRICE);
        assertFalse(hook.initialized());
        factory.initialize(hook, PRICE);
        assertTrue(hook.initialized());
    }

    function test_bothSwapCallbacksRejectAnUninitializedHook() public {
        ReferralHook hook = factory.deployOnly(salt);
        SwapParams memory params = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.prank(address(manager));
        vm.expectRevert(ReferralHook.NotInitialized.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.prank(address(manager));
        vm.expectRevert(ReferralHook.NotInitialized.selector);
        hook.afterSwap(address(this), key, params, BalanceDeltaLibrary.ZERO_DELTA, "");
        assertEq(hook.distributor().totalFees(), 0);
        assertFalse(hook.initialized());
    }

    function _wrapped(bytes4 callback, bytes4 reason) private view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            predicted,
            callback,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }
}
