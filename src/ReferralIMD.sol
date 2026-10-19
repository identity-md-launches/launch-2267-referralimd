// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Fixed supply ERC20 with passive balance history, without privileged functions.
/// @dev History makes rewards independent of a mutable token-to-distributor registration.
contract ReferralIMD is ERC20 {
    using Checkpoints for Checkpoints.Trace208;

    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint256 public immutable deploymentBlock;
    mapping(address => Checkpoints.Trace208) private _balancesHistory;

    error FutureLookup();

    constructor() ERC20("ReferralIMD", "RIMD") {
        deploymentBlock = block.number;
        _mint(msg.sender, SUPPLY);
    }

    function getPastBalance(address account, uint256 atBlock) external view returns (uint256) {
        if (atBlock >= block.number) revert FutureLookup();
        return _balancesHistory[account].upperLookupRecent(SafeCast.toUint48(atBlock));
    }

    function getPastTotalSupply(uint256 atBlock) external view returns (uint256) {
        if (atBlock >= block.number) revert FutureLookup();
        return atBlock < deploymentBlock ? 0 : SUPPLY;
    }

    function checkpointCount(address account) external view returns (uint256) {
        return _balancesHistory[account].length();
    }

    function checkpointAt(address account, uint32 position) external view returns (uint48 atBlock, uint208 balance) {
        Checkpoints.Checkpoint208 memory point = _balancesHistory[account].at(position);
        return (point._key, point._value);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        // Zero/self transfers cannot create checkpoint spam for someone else's account.
        if (value == 0 || from == to) return;
        uint48 currentBlock = SafeCast.toUint48(block.number);
        if (from != address(0)) _balancesHistory[from].push(currentBlock, SafeCast.toUint208(balanceOf(from)));
        if (to != address(0)) _balancesHistory[to].push(currentBlock, SafeCast.toUint208(balanceOf(to)));
    }
}
