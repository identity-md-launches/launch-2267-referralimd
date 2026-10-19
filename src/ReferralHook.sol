// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReferralIMD} from "./ReferralIMD.sol";
import {RewardDistributor} from "./RewardDistributor.sol";

/// @notice Immutable 2% gross-IMD-side trading levy; all collected IMD backs holder rewards.
contract ReferralHook {
    uint256 public constant FEE_BPS = 200;
    uint256 public constant BPS = 10_000;
    uint24 public constant LP_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;

    IPoolManager public immutable poolManager;
    ReferralIMD public immutable token;
    Currency public immutable pairedCurrency;
    address public immutable factory;
    RewardDistributor public immutable distributor;
    bool public initialized;

    error OnlyPoolManager();
    error InvalidAddress();
    error InvalidPool();
    error OnlyFactory();
    error AlreadyInitialized();
    error NotInitialized();
    error InvalidAmount();
    error PartialFill();

    event PoolBound(PoolId indexed poolId);
    event FeeCollected(uint256 amount, bool buy, bool exactInput);

    constructor(IPoolManager manager_, ReferralIMD token_, Currency pair_, address factory_) {
        address pair = Currency.unwrap(pair_);
        address launchToken = address(token_);
        address manager = address(manager_);
        if (
            manager == address(0) || launchToken == address(0) || pair == address(0) || factory_ == address(0)
                || manager == launchToken || manager == pair || launchToken == pair || manager == factory_
                || launchToken == factory_ || pair == factory_ || manager == address(this)
                || launchToken == address(this) || pair == address(this) || manager == address(0xdEaD)
                || launchToken == address(0xdEaD) || pair == address(0xdEaD) || factory_ == address(0xdEaD)
        ) revert InvalidAddress();
        poolManager = manager_;
        token = token_;
        pairedCurrency = pair_;
        factory = factory_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        distributor = new RewardDistributor(manager_, token_, pair_, address(this));
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwapReturnDelta = true;
    }

    function poolKey() public view returns (PoolKey memory key) {
        Currency launchToken = Currency.wrap(address(token));
        (Currency c0, Currency c1) = address(token) < Currency.unwrap(pairedCurrency)
            ? (launchToken, pairedCurrency)
            : (pairedCurrency, launchToken);
        return PoolKey(c0, c1, LP_FEE, TICK_SPACING, IHooks(address(this)));
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (sender != factory) revert OnlyFactory();
        if (initialized) revert AlreadyInitialized();
        _validatePool(key);
        initialized = true;
        emit PoolBound(key.toId());
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _validateSwap(key, params);
        uint256 fee;
        if (_pairIsSpecified(key, params)) {
            fee = _specifiedFee(params.amountSpecified);
            _collect(fee, _isBuy(key, params), params.amountSpecified < 0);
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(SafeCast.toInt128(int256(fee)), 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        _validateSwap(key, params);
        int128 pairDelta = key.currency0 == pairedCurrency ? delta.amount0() : delta.amount1();
        if (_pairIsSpecified(key, params)) {
            // The beforeSwap fee assumes full execution. A bounded partial fill cannot
            // refund the specified currency in afterSwap, so fail atomically instead.
            int256 expected = params.amountSpecified + int256(_specifiedFee(params.amountSpecified));
            if (int256(pairDelta) != expected) revert PartialFill();
            return (IHooks.afterSwap.selector, 0);
        }
        bool buy = _isBuy(key, params);
        uint256 fee;
        if (buy) {
            if (pairDelta > 0) revert InvalidAmount();
            fee = Math.mulDiv(uint256(-int256(pairDelta)), FEE_BPS, BPS - FEE_BPS, Math.Rounding.Ceil);
        } else {
            if (pairDelta < 0) revert InvalidAmount();
            fee = uint256(uint128(pairDelta)) * FEE_BPS / BPS;
        }
        int128 feeDelta = SafeCast.toInt128(int256(fee));
        _collect(fee, buy, params.amountSpecified < 0);
        return (IHooks.afterSwap.selector, feeDelta);
    }

    function _collect(uint256 fee, bool buy, bool exactInput) private {
        if (fee == 0) return;
        // No token transfer inside swaps, including on a manager without prefunded IMD.
        poolManager.mint(address(distributor), pairedCurrency.toId(), fee);
        distributor.recordFee(fee);
        emit FeeCollected(fee, buy, exactInput);
    }

    function _specifiedFee(int256 amount) private pure returns (uint256) {
        return amount < 0
            ? uint256(-amount) * FEE_BPS / BPS
            : Math.mulDiv(uint256(amount), FEE_BPS, BPS - FEE_BPS, Math.Rounding.Ceil);
    }

    function _pairIsSpecified(PoolKey calldata key, SwapParams calldata params) private view returns (bool) {
        bool specifiedIs0 = params.zeroForOne == (params.amountSpecified < 0);
        return (key.currency0 == pairedCurrency) == specifiedIs0;
    }

    function _isBuy(PoolKey calldata key, SwapParams calldata params) private view returns (bool) {
        return (key.currency0 == pairedCurrency) == params.zeroForOne;
    }

    function _validateSwap(PoolKey calldata key, SwapParams calldata params) private view {
        if (!initialized) revert NotInitialized();
        _validatePool(key);
        // Reserve headroom for gross-up and avoid signed minimum negation/unsafe casts.
        if (
            params.amountSpecified == 0 || params.amountSpecified > type(int128).max / 2
                || params.amountSpecified < -int256(type(int128).max / 2)
        ) revert InvalidAmount();
    }

    function _validatePool(PoolKey calldata key) private view {
        PoolKey memory expected = poolKey();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(expected.toId())) revert InvalidPool();
    }
}
