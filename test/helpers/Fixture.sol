// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ReferralIMD} from "../../src/ReferralIMD.sol";
import {ReferralHook} from "../../src/ReferralHook.sol";
import {RewardDistributor} from "../../src/RewardDistributor.sol";
import {PrepareLaunch} from "../../script/PrepareLaunch.s.sol";
import {MockIMD} from "./MockIMD.sol";
import {PoolHarness} from "./PoolHarness.sol";

abstract contract Fixture is Test {
    ReferralIMD internal token;
    MockIMD internal imd;
    PoolManager internal manager;
    ReferralHook internal hook;
    RewardDistributor internal rewards;
    PoolHarness internal router;
    PoolKey internal key;
    address internal alice = makeAddr("Alice");
    address internal bob = makeAddr("Bob");
    address internal carol = makeAddr("Carol");
    uint160 internal constant PRICE = 1 << 96;
    uint256 internal constant LIQUIDITY = 1_000_000 ether;

    function _deploy(bool pairIs0) internal {
        vm.roll(100);
        token = new ReferralIMD();
        for (uint256 i;; ++i) {
            imd = new MockIMD{salt: bytes32(i)}();
            if ((address(imd) < address(token)) == pairIs0) break;
        }
        manager = new PoolManager(address(this));
        router = new PoolHarness(manager);
        PrepareLaunch preparer = new PrepareLaunch();
        (bytes32 salt, address predicted,) =
            preparer.mine(manager, token, Currency.wrap(address(imd)), address(this), 0, 200_000);
        hook = new ReferralHook{salt: salt}(manager, token, Currency.wrap(address(imd)), address(this));
        assertEq(address(hook), predicted);
        rewards = hook.distributor();
        key = hook.poolKey();
        manager.initialize(key, PRICE);
        imd.mint(address(this), 1e30);
        token.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
    }

    function _seed() internal {
        router.modify(
            key,
            ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(LIQUIDITY), bytes32(0)
            ),
            2_000_000 ether,
            2_000_000 ether
        );
    }

    function _trade(bool buy, bool exactInput, uint256 amount) internal returns (BalanceDelta delta, uint256 fee) {
        bool zeroForOne = (key.currency0 == Currency.wrap(address(imd))) == buy;
        uint256 beforeFees = rewards.totalFees();
        delta = router.swap(
            key,
            SwapParams(
                zeroForOne,
                exactInput ? -int256(amount) : int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            amount * 10 + 10 ether,
            ""
        );
        fee = rewards.totalFees() - beforeFees;
    }

    function _pairDelta(BalanceDelta delta) internal view returns (int128) {
        return key.currency0 == Currency.wrap(address(imd)) ? delta.amount0() : delta.amount1();
    }

    function _tokenDelta(BalanceDelta delta) internal view returns (int128) {
        return key.currency0 == Currency.wrap(address(token)) ? delta.amount0() : delta.amount1();
    }
}
