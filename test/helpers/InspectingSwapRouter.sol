// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {RewardDistributor} from "src/RewardDistributor.sol";

/// @dev Test-only router that checks transient accounting while the unlock is
/// still live. Reading transient storage from a later top-level call would only
/// see the transaction reset, and would not test the hook's accounting.
contract InspectingSwapRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    IPoolManager public immutable manager;
    RewardDistributor public immutable rewards;
    bytes32 private active;

    constructor(IPoolManager manager_, RewardDistributor rewards_) {
        manager = manager_;
        rewards = rewards_;
    }

    /// @param settlement 0 pays all debts, 1 underpays by one, 2 leaves debts open.
    function batch(PoolKey memory key, SwapParams[] memory swaps, uint256 max0, uint256 max1, uint8 settlement)
        external
        returns (BalanceDelta[] memory deltas, uint256[] memory fees)
    {
        IERC20(Currency.unwrap(key.currency0)).safeTransferFrom(msg.sender, address(this), max0);
        IERC20(Currency.unwrap(key.currency1)).safeTransferFrom(msg.sender, address(this), max1);
        bytes memory data = abi.encode(key, swaps, settlement);
        active = keccak256(data);
        (deltas, fees) = abi.decode(manager.unlock(data), (BalanceDelta[], uint256[]));
        active = bytes32(0);
        _refund(key.currency0, msg.sender);
        _refund(key.currency1, msg.sender);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager) && active == keccak256(data), "invalid callback");
        (PoolKey memory key, SwapParams[] memory swaps, uint8 settlement) =
            abi.decode(data, (PoolKey, SwapParams[], uint8));
        BalanceDelta[] memory deltas = new BalanceDelta[](swaps.length);
        uint256[] memory fees = new uint256[](swaps.length);
        int256 net0;
        int256 net1;
        assert(manager.isUnlocked());
        for (uint256 i; i < swaps.length; ++i) {
            uint256 beforeFees = rewards.totalFees();
            deltas[i] = manager.swap(key, swaps[i], "");
            fees[i] = rewards.totalFees() - beforeFees;
            net0 += deltas[i].amount0();
            net1 += deltas[i].amount1();
            assert(manager.currencyDelta(address(this), key.currency0) == net0);
            assert(manager.currencyDelta(address(this), key.currency1) == net1);
            assert(manager.currencyDelta(address(key.hooks), key.currency0) == 0);
            assert(manager.currencyDelta(address(key.hooks), key.currency1) == 0);
            assert(manager.currencyDelta(address(rewards), key.currency0) == 0);
            assert(manager.currencyDelta(address(rewards), key.currency1) == 0);
            assert(manager.getNonzeroDeltaCount() == (net0 == 0 ? 0 : 1) + (net1 == 0 ? 0 : 1));
        }
        if (settlement != 2) {
            _settle(key.currency0, net0, settlement == 1);
            _settle(key.currency1, net1, settlement == 1);
        }
        if (settlement == 0) {
            assert(manager.getNonzeroDeltaCount() == 0);
            assert(manager.currencyDelta(address(this), key.currency0) == 0);
            assert(manager.currencyDelta(address(this), key.currency1) == 0);
        }
        return abi.encode(deltas, fees);
    }

    function _settle(Currency currency, int256 amount, bool underpay) private {
        if (amount < 0) {
            uint256 payment = uint256(-amount) - (underpay ? 1 : 0);
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(manager), payment);
            assert(manager.settle() == payment);
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(amount));
        }
    }

    function _refund(Currency currency, address to) private {
        IERC20 asset = IERC20(Currency.unwrap(currency));
        uint256 balance = asset.balanceOf(address(this));
        if (balance != 0) asset.safeTransfer(to, balance);
    }
}
