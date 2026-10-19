// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Test-only router. Pulls only the entry-point caller's tokens; callback settles own balance.
contract PoolHarness is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable manager;
    bytes32 private active;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params, uint256 maxInput, bytes memory hookData)
        external
        returns (BalanceDelta delta)
    {
        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        IERC20(Currency.unwrap(input)).safeTransferFrom(msg.sender, address(this), maxInput);
        bytes memory data = abi.encode(uint8(0), key, abi.encode(params, hookData));
        active = keccak256(data);
        delta = abi.decode(manager.unlock(data), (BalanceDelta));
        active = bytes32(0);
        _refund(key.currency0, msg.sender);
        _refund(key.currency1, msg.sender);
    }

    function modify(PoolKey memory key, ModifyLiquidityParams memory params, uint256 max0, uint256 max1)
        external
        returns (BalanceDelta delta)
    {
        IERC20(Currency.unwrap(key.currency0)).safeTransferFrom(msg.sender, address(this), max0);
        IERC20(Currency.unwrap(key.currency1)).safeTransferFrom(msg.sender, address(this), max1);
        bytes memory data = abi.encode(uint8(1), key, abi.encode(params));
        active = keccak256(data);
        delta = abi.decode(manager.unlock(data), (BalanceDelta));
        active = bytes32(0);
        _refund(key.currency0, msg.sender);
        _refund(key.currency1, msg.sender);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager) && active == keccak256(data), "invalid callback");
        (uint8 action, PoolKey memory key, bytes memory params) = abi.decode(data, (uint8, PoolKey, bytes));
        BalanceDelta delta;
        if (action == 0) {
            (SwapParams memory swapParams, bytes memory hookData) = abi.decode(params, (SwapParams, bytes));
            delta = manager.swap(key, swapParams, hookData);
        } else {
            (delta,) = manager.modifyLiquidity(key, abi.decode(params, (ModifyLiquidityParams)), "");
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(manager), uint256(-int256(amount)));
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    function _refund(Currency currency, address recipient) private {
        IERC20 asset = IERC20(Currency.unwrap(currency));
        uint256 amount = asset.balanceOf(address(this));
        if (amount != 0) asset.safeTransfer(recipient, amount);
    }
}
