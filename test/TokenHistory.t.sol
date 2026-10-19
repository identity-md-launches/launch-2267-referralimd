// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReferralIMD} from "src/ReferralIMD.sol";

contract TokenHistoryTest is Test {
    ReferralIMD internal token;
    address internal alice = makeAddr("history Alice");
    address internal bob = makeAddr("history Bob");
    address internal spender = makeAddr("history spender");

    function setUp() public {
        vm.roll(100);
        token = new ReferralIMD();
    }

    function test_fullSupplyRoundTripPreservesOldSnapshots() public {
        uint256 supply = token.totalSupply();
        token.transfer(alice, supply);
        vm.roll(101);
        vm.prank(alice);
        token.transfer(bob, supply);
        vm.roll(102);
        vm.prank(bob);
        token.transfer(address(this), supply);
        vm.roll(103);

        assertEq(token.getPastBalance(alice, 100), supply);
        assertEq(token.getPastBalance(alice, 101), 0);
        assertEq(token.getPastBalance(bob, 100), 0);
        assertEq(token.getPastBalance(bob, 101), supply);
        assertEq(token.getPastBalance(bob, 102), 0);
        assertEq(token.getPastBalance(address(this), 100), 0);
        assertEq(token.getPastBalance(address(this), 102), supply);
        assertEq(token.totalSupply(), supply);
        assertEq(token.balanceOf(address(this)), supply);
    }

    function test_allowanceFailureDoesNotWriteHistoryOrConsumeAllowance() public {
        token.transfer(alice, 9);
        vm.prank(alice);
        token.approve(spender, 10);
        vm.roll(101);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 9, 10));
        token.transferFrom(alice, bob, 10);
        assertEq(token.allowance(alice, spender), 10);
        assertEq(token.checkpointCount(alice), 1);
        assertEq(token.checkpointCount(bob), 0);
        assertEq(token.getPastBalance(alice, 100), 9);

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 10, 11));
        token.transferFrom(alice, bob, 11);
        assertEq(token.allowance(alice, spender), 10);
        assertEq(token.balanceOf(alice), 9);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_infiniteAllowanceTransferFromCreatesCorrectCheckpoints() public {
        token.transfer(alice, 9);
        vm.prank(alice);
        token.approve(spender, type(uint256).max);
        vm.roll(101);
        vm.prank(spender);
        token.transferFrom(alice, bob, 4);
        vm.prank(spender);
        token.transferFrom(alice, bob, 5);
        assertEq(token.allowance(alice, spender), type(uint256).max);
        assertEq(token.checkpointCount(alice), 2);
        assertEq(token.checkpointCount(bob), 1);
        vm.roll(102);
        assertEq(token.getPastBalance(alice, 100), 9);
        assertEq(token.getPastBalance(alice, 101), 0);
        assertEq(token.getPastBalance(bob, 101), 9);
    }

    function test_zeroTransfersCannotCreateHistoryForAnEmptyWallet() public {
        vm.roll(101);
        vm.prank(alice);
        token.transfer(bob, 0);
        vm.prank(spender);
        token.transferFrom(alice, bob, 0);
        assertEq(token.checkpointCount(alice), 0);
        assertEq(token.checkpointCount(bob), 0);
        assertEq(token.checkpointCount(spender), 0);
        assertEq(token.checkpointCount(address(this)), 1);
    }

    function test_invalidRecipientsAndOversizedSelfTransferLeaveHistoryIntact() public {
        token.transfer(alice, 1);
        vm.roll(101);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1, 2));
        token.transfer(alice, 2);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        assertEq(token.checkpointCount(alice), 1);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.checkpointCount(address(0)), 0);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_currentAndFutureSupplyLookupsRejectLikeBalanceLookups() public {
        uint256[3] memory future = [block.number, block.number + 1, type(uint256).max];
        for (uint256 i; i < future.length; ++i) {
            vm.expectRevert(ReferralIMD.FutureLookup.selector);
            token.getPastBalance(alice, future[i]);
            vm.expectRevert(ReferralIMD.FutureLookup.selector);
            token.getPastTotalSupply(future[i]);
        }
        vm.expectRevert(); // Checkpoints.at rejects an out-of-range array index.
        token.checkpointAt(alice, 0);
    }

    /// @dev The oracle is an array of end-of-block balances, with no checkpoint search.
    /// Queries cover both the old and recent branches of upperLookupRecent.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_historyMatchesEndOfBlockLedger(uint256 seed) public {
        uint256[25] memory aliceAt;
        uint256[25] memory bobAt;
        token.transfer(alice, 1e24);
        aliceAt[0] = 1e24;
        for (uint256 i = 1; i < 25; ++i) {
            vm.roll(100 + i);
            uint256 random = uint256(keccak256(abi.encode(seed, i)));
            bool fromAlice = random & 1 == 0;
            address from = fromAlice ? alice : bob;
            address to = fromAlice ? bob : alice;
            uint256 available = fromAlice ? aliceAt[i - 1] : bobAt[i - 1];
            uint256 amount = bound(random >> 1, 0, available);
            vm.prank(from);
            token.transfer(to, amount);
            aliceAt[i] = fromAlice ? aliceAt[i - 1] - amount : aliceAt[i - 1] + amount;
            bobAt[i] = 1e24 - aliceAt[i];
            // A second write in the same block must replace, not append, history.
            uint256 returned = amount / 2;
            vm.prank(to);
            token.transfer(from, returned);
            if (fromAlice) {
                aliceAt[i] += returned;
                bobAt[i] -= returned;
            } else {
                aliceAt[i] -= returned;
                bobAt[i] += returned;
            }
        }
        vm.roll(130);
        for (uint256 i; i < 25; ++i) {
            assertEq(token.getPastBalance(alice, 100 + i), aliceAt[i], "historical Alice balance");
            assertEq(token.getPastBalance(bob, 100 + i), bobAt[i], "historical Bob balance");
            assertEq(token.getPastTotalSupply(100 + i), 1e27);
        }
        assertEq(token.getPastBalance(alice, 99), 0);
        assertEq(token.getPastBalance(alice, 129), aliceAt[24]);
        assertEq(token.getPastBalance(bob, 129), bobAt[24]);
    }
}
