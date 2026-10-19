// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "../test/helpers/Fixture.sol";
import {MockIMD} from "../test/helpers/MockIMD.sol";
import {PoolHarness} from "../test/helpers/PoolHarness.sol";
import {ReferralIMD} from "../src/ReferralIMD.sol";
import {ReferralHook} from "../src/ReferralHook.sol";
import {PrepareLaunch} from "../script/PrepareLaunch.s.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// Opt-in mainnet rehearsal: run with the mainnet profile and --fork-url; never broadcasts.
contract MainnetIMDReviewTest is Fixture {
    address private constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;

    function setUp() public {
        // A default offline test invocation must not fetch data or silently simulate the real asset.
        if (IMD.code.length == 0) {
            vm.skip(true);
            return;
        }
        assertEq(block.chainid, 1);
        imd = MockIMD(IMD);
        assertEq(imd.symbol(), "IMD");
        assertEq(imd.name(), "Identity.md");
        assertEq(imd.decimals(), 18);
        assertEq(IMD.codehash, 0x79a1ae149d27d4aae006d4dd75cb834222c9623799bbf34359428aaf66fec3bf);
        token = new ReferralIMD();
        manager = new PoolManager(address(this));
        router = new PoolHarness(manager);
        PrepareLaunch preparer = new PrepareLaunch();
        (bytes32 salt,,) = preparer.mine(manager, token, Currency.wrap(IMD), address(this), 0, 200_000);
        hook = new ReferralHook{salt: salt}(manager, token, Currency.wrap(IMD), address(this));
        rewards = hook.distributor();
        key = hook.poolKey();
        manager.initialize(key, PRICE);
        // Synthetic funding of this test only, using genuine forked IMD runtime and storage layout.
        deal(IMD, address(this), 3_000_000 ether);
        imd.approve(address(router), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        _seed();
        token.transfer(alice, 400_000_000 ether);
        vm.roll(block.number + 1);
    }

    function test_ActualIMDTransfersAreExact() public {
        uint256 sender = imd.balanceOf(address(this));
        uint256 recipient = imd.balanceOf(alice);
        imd.transfer(alice, 27 ether);
        assertEq(imd.balanceOf(address(this)), sender - 27 ether);
        assertEq(imd.balanceOf(alice), recipient + 27 ether);
        vm.prank(alice);
        imd.approve(bob, 13 ether);
        vm.prank(bob);
        imd.transferFrom(alice, carol, 13 ether);
        assertEq(imd.balanceOf(alice), recipient + 14 ether);
        assertEq(imd.balanceOf(carol), 13 ether);
    }

    function test_AllSwapModesAndActualIMDRewards() public {
        uint256 firstFeeBlock = block.number;
        for (uint256 i; i < 4; ++i) {
            bool buy = i < 2;
            bool exactInput = i % 2 == 0;
            uint256 imdBefore = imd.balanceOf(address(this));
            (BalanceDelta delta, uint256 fee) = _trade(buy, exactInput, 100 ether);
            assertGt(fee, 0);
            assertEq(int256(imd.balanceOf(address(this))) - int256(imdBefore), _pairDelta(delta));
        }
        assertEq(manager.balanceOf(address(rewards), uint160(IMD)), rewards.totalFees());
        vm.roll(block.number + 1);
        uint256 beforeBalance = imd.balanceOf(alice);
        uint256 amount = rewards.claimFor(alice, 64);
        assertGt(amount, 0);
        assertEq(imd.balanceOf(alice) - beforeBalance, amount);
        assertEq(
            amount,
            Math.mulDiv(token.getPastBalance(alice, firstFeeBlock - 1), rewards.indexAt(firstFeeBlock), rewards.SCALE())
        );
        assertEq(rewards.claimFor(alice, 64), 0);
        assertEq(manager.balanceOf(address(rewards), uint160(IMD)), rewards.totalFees() - amount);
    }
}
