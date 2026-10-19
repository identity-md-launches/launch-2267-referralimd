// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {PrepareLaunch} from "../script/PrepareLaunch.s.sol";
import {ReferralHook} from "../src/ReferralHook.sol";
import {ReferralIMD} from "../src/ReferralIMD.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract LaunchChecksTest is Fixture {
    function testConstructorsDoNotDependOnExternalCode() public {
        IPoolManager absentManager = IPoolManager(makeAddr("Uninstalled manager for constructor check"));
        ReferralIMD absentToken = ReferralIMD(makeAddr("Uninstalled token for constructor check"));
        Currency absentPair = Currency.wrap(makeAddr("Uninstalled pair for constructor check"));
        assertEq(address(absentManager).code.length, 0);
        assertEq(address(absentToken).code.length, 0);
        assertEq(Currency.unwrap(absentPair).code.length, 0);
        PrepareLaunch prepare = new PrepareLaunch();
        (bytes32 salt,,) = prepare.mine(absentManager, absentToken, absentPair, address(this), 0, 200_000);
        ReferralHook built = new ReferralHook{salt: salt}(absentManager, absentToken, absentPair, address(this));
        assertGt(address(built.distributor()).code.length, 0);
        PoolKey memory pool = built.poolKey();
        vm.prank(address(absentManager));
        vm.expectRevert(ReferralHook.NotInitialized.selector);
        built.beforeSwap(address(this), pool, SwapParams(true, -1, 1 << 96), "");
        vm.prank(address(absentManager));
        vm.expectRevert(ReferralHook.OnlyFactory.selector);
        built.beforeInitialize(alice, pool, 1 << 96);
        PoolKey memory wrong = built.poolKey();
        wrong.fee = 3000;
        vm.prank(address(absentManager));
        vm.expectRevert(ReferralHook.InvalidPool.selector);
        built.beforeInitialize(address(this), wrong, 1 << 96);
        wrong = built.poolKey();
        wrong.tickSpacing = 1;
        vm.prank(address(absentManager));
        vm.expectRevert(ReferralHook.InvalidPool.selector);
        built.beforeInitialize(address(this), wrong, 1 << 96);
        vm.prank(address(absentManager));
        assertEq(built.beforeInitialize(address(this), pool, 1 << 96), IHooks.beforeInitialize.selector);
    }

    function testInvalidAddressesAndPermissionBitsRefused() public {
        IPoolManager absentManager = IPoolManager(makeAddr("absent manager"));
        ReferralIMD absentToken = ReferralIMD(makeAddr("absent token"));
        Currency absentPair = Currency.wrap(makeAddr("absent pair"));
        vm.expectRevert(ReferralHook.InvalidAddress.selector);
        new ReferralHook(IPoolManager(address(0)), absentToken, absentPair, address(this));
        vm.expectRevert(ReferralHook.InvalidAddress.selector);
        new ReferralHook(absentManager, absentToken, Currency.wrap(address(absentToken)), address(this));
        vm.expectRevert(ReferralHook.InvalidAddress.selector);
        new ReferralHook(absentManager, absentToken, absentPair, address(0));
        // A deliberately chosen CREATE2 address with incorrect permission bits.
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(ReferralHook).creationCode, abi.encode(absentManager, absentToken, absentPair, address(this))
            )
        );
        bytes32 salt;
        address expected;
        for (uint256 i;; ++i) {
            salt = bytes32(i);
            expected =
                address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), salt, initCodeHash)))));
            if (uint160(expected) & Hooks.ALL_HOOK_MASK != 0x20cc) break;
        }
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, expected));
        new ReferralHook{salt: salt}(absentManager, absentToken, absentPair, address(this));
    }

    function testRuntimeImmutabilityAndDeployableSizes() public {
        _deploy(true);
        _scan(address(token));
        _scan(address(hook));
        _scan(address(rewards));
        assertLe(type(ReferralHook).creationCode.length + 4 * 32, 49_152);
        bytes4[5] memory forbidden = [
            bytes4(keccak256("owner()")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("setFee(uint256)")),
            bytes4(keccak256("upgradeTo(address)")),
            bytes4(keccak256("withdraw(address,uint256)"))
        ];
        for (uint256 i; i < forbidden.length; ++i) {
            (bool hookOk,) = address(hook).call(abi.encodeWithSelector(forbidden[i], alice, 1));
            (bool rewardsOk,) = address(rewards).call(abi.encodeWithSelector(forbidden[i], alice, 1));
            assertFalse(hookOk);
            assertFalse(rewardsOk);
        }
    }

    function _scan(address deployed) private view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf2 && op != 0xf4 && op != 0xff);
        }
    }
}
