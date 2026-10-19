// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReferralIMD} from "../src/ReferralIMD.sol";

contract TokenTest is Test {
    ReferralIMD token;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.roll(10);
        token = new ReferralIMD();
    }

    function testSupplyAndMetadata() public view {
        assertEq(token.name(), "ReferralIMD");
        assertEq(token.symbol(), "RIMD");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testTransfersAndHistoricalBalances() public {
        token.transfer(alice, 100 ether);
        token.transfer(alice, 50 ether);
        assertEq(token.checkpointCount(alice), 1);
        vm.roll(11);
        vm.prank(alice);
        token.transfer(bob, 30 ether);
        assertEq(token.getPastBalance(alice, 10), 150 ether);
        assertEq(token.getPastBalance(bob, 10), 0);
        vm.roll(12);
        assertEq(token.getPastBalance(alice, 11), 120 ether);
        assertEq(token.getPastBalance(bob, 11), 30 ether);
        assertEq(token.getPastBalance(alice, 9), 0);
        assertEq(token.getPastTotalSupply(9), 0);
        assertEq(token.getPastTotalSupply(10), 1e27);
        vm.expectRevert(ReferralIMD.FutureLookup.selector);
        token.getPastBalance(alice, 12);
    }

    function testAllowanceAndFailures() public {
        token.approve(alice, 25 ether);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 25 ether);
        assertEq(token.balanceOf(bob), 25 ether);
        assertEq(token.allowance(address(this), alice), 0);
        vm.prank(alice);
        vm.expectRevert();
        token.transferFrom(address(this), bob, 1);
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 1);
        vm.expectRevert();
        token.transfer(address(0), 1);
    }

    function testZeroAndSelfTransfersDoNotCreateHistory() public {
        token.transfer(alice, 1);
        vm.roll(11);
        token.transfer(alice, 0);
        vm.prank(alice);
        token.transfer(alice, 1);
        assertEq(token.checkpointCount(alice), 1);
    }

    function testNoAdminOrMintSelectors() public {
        bytes4[8] memory selectors = [
            bytes4(keccak256("owner()")),
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("setOwner(address)")),
            bytes4(keccak256("upgradeTo(address)")),
            bytes4(keccak256("initialize(address)")),
            bytes4(keccak256("blacklist(address)")),
            bytes4(keccak256("setTax(uint256)"))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSelector(selectors[i], alice, 1 ether));
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), 1e27);
    }

    function testFuzzTransferConservation(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(alice), token.totalSupply());
        vm.roll(11);
        assertEq(token.getPastBalance(alice, 10), amount);
    }
}
