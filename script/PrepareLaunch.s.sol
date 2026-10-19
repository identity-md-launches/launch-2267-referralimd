// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReferralHook} from "../src/ReferralHook.sol";
import {ReferralIMD} from "../src/ReferralIMD.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @notice Pure launch preparation, without credentials, broadcasts or environment reads.
contract PrepareLaunch {
    uint160 public constant FLAGS = 0x20cc;
    error SaltNotFound();

    function mine(
        IPoolManager manager,
        ReferralIMD token,
        Currency pair,
        address factory,
        uint256 firstSalt,
        uint256 attempts
    ) external pure returns (bytes32 salt, address predicted, bytes32 initCodeHash) {
        initCodeHash = keccak256(
            abi.encodePacked(type(ReferralHook).creationCode, abi.encode(manager, token, pair, factory))
        );
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(firstSalt + i);
            predicted = address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", factory, salt, initCodeHash)))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == FLAGS) return (salt, predicted, initCodeHash);
        }
        revert SaltNotFound();
    }
}
