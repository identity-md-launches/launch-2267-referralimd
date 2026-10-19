// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ReferralIMD} from "./ReferralIMD.sol";

/// @notice IMD dividends for every eligible RIMD balance, with a one-block balance lag.
/// @dev The hook funds this contract with PoolManager ERC6909 claims. No staking, owner,
/// keeper, holder enumeration, off-chain proofs, or mutable configuration is needed.
contract RewardDistributor is IUnlockCallback, ReentrancyGuard {
    uint256 public constant SCALE = 1 << 128;
    uint256 public constant MAX_INTERVALS = 64;
    address public constant BURN = address(0x000000000000000000000000000000000000dEaD);

    IPoolManager public immutable poolManager;
    ReferralIMD public immutable token;
    Currency public immutable rewardCurrency;
    address public immutable hook;

    struct IndexCheckpoint {
        uint256 atBlock;
        uint256 index;
    }

    struct Account {
        uint32 cursor;
        uint256 throughBlock;
        uint256 fraction;
    }

    IndexCheckpoint[] private _indexHistory;
    mapping(address => Account) public accounts;
    uint256 public rewardIndex;
    uint256 public pendingFees;
    uint256 public totalFees;
    uint256 public totalClaimed;
    bytes32 private _activeClaim;

    error OnlyHook();
    error InvalidCallback();
    error ExcludedAccount();
    error InvalidBatch();
    error ContractMustClaimItself();

    event FeesRecorded(uint256 indexed atBlock, uint256 amount);
    event Distributed(uint256 indexed atBlock, uint256 amount, uint256 eligibleSupply, uint256 index);
    event Claimed(address indexed account, uint256 amount, uint256 throughBlock, uint32 cursor);

    constructor(IPoolManager manager_, ReferralIMD token_, Currency rewardCurrency_, address hook_) {
        poolManager = manager_;
        token = token_;
        rewardCurrency = rewardCurrency_;
        hook = hook_;
    }

    function excluded(address account) public view returns (bool) {
        return account == address(0) || account == BURN || account == address(poolManager) || account == hook
            || account == address(this);
    }

    function eligibleSupplyAt(uint256 atBlock) public view returns (uint256) {
        return token.getPastTotalSupply(atBlock) - token.getPastBalance(address(poolManager), atBlock)
            - token.getPastBalance(BURN, atBlock) - token.getPastBalance(hook, atBlock)
            - token.getPastBalance(address(this), atBlock);
    }

    /// @dev Called only after the hook minted the matching IMD ERC6909 claim to this contract.
    function recordFee(uint256 amount) external {
        if (msg.sender != hook) revert OnlyHook();
        totalFees += amount;
        pendingFees += amount;
        emit FeesRecorded(block.number, amount);
        _distribute();
    }

    /// @notice Assign fees held over from a block with no eligible supply. No caller reward.
    function distribute() external {
        _distribute();
    }

    function _distribute() private {
        uint256 amount = pendingFees;
        if (amount == 0 || block.number == 0) return;
        uint256 eligible = eligibleSupplyAt(block.number - 1);
        if (eligible == 0) return;
        pendingFees = 0;
        uint256 index = rewardIndex + Math.mulDiv(amount, SCALE, eligible);
        rewardIndex = index;
        uint256 length = _indexHistory.length;
        if (length != 0 && _indexHistory[length - 1].atBlock == block.number) {
            _indexHistory[length - 1].index = index;
        } else {
            _indexHistory.push(IndexCheckpoint(block.number, index));
        }
        emit Distributed(block.number, amount, eligible, index);
    }

    function indexCheckpointCount() external view returns (uint256) {
        return _indexHistory.length;
    }

    function indexCheckpointAt(uint256 position) external view returns (IndexCheckpoint memory) {
        return _indexHistory[position];
    }

    /// @notice Cumulative reward index through atBlock (current-block values can still change).
    function indexAt(uint256 atBlock) public view returns (uint256) {
        uint256 low;
        uint256 high = _indexHistory.length;
        while (low < high) {
            uint256 mid = low + (high - low) / 2;
            if (_indexHistory[mid].atBlock > atBlock) high = mid;
            else low = mid + 1;
        }
        return low == 0 ? 0 : _indexHistory[low - 1].index;
    }

    /// @notice Preview the next bounded claim, including its resulting progress cursor.
    function previewClaim(address account, uint256 maxIntervals)
        public
        view
        returns (uint256 amount, Account memory progress)
    {
        if (excluded(account)) revert ExcludedAccount();
        if (maxIntervals == 0 || maxIntervals > MAX_INTERVALS) revert InvalidBatch();
        progress = accounts[account];
        uint256 count = token.checkpointCount(account);
        if (count == 0 || block.number == 0) return (0, progress);
        uint256 finalizedBlock = block.number - 1;
        for (uint256 processed; processed < maxIntervals; ++processed) {
            (uint48 fromBlock, uint208 balance) = token.checkpointAt(account, progress.cursor);
            if (fromBlock >= finalizedBlock) break;
            bool hasNext = uint256(progress.cursor) + 1 < count;
            uint256 endBlock = finalizedBlock;
            if (hasNext) {
                (uint48 nextBlock,) = token.checkpointAt(account, progress.cursor + 1);
                if (nextBlock < endBlock) endBlock = nextBlock;
            }
            uint256 startBlock = Math.max(fromBlock, progress.throughBlock);
            if (endBlock > startBlock && balance != 0) {
                uint256 growth = indexAt(endBlock) - indexAt(startBlock);
                amount += Math.mulDiv(balance, growth, SCALE);
                uint256 fractions = progress.fraction + mulmod(balance, growth, SCALE);
                amount += fractions / SCALE;
                progress.fraction = fractions % SCALE;
            }
            progress.throughBlock = endBlock;
            if (!hasNext || endBlock == finalizedBlock) break;
            ++progress.cursor;
        }
    }

    function claim(uint256 maxIntervals) external returns (uint256) {
        return claimFor(msg.sender, maxIntervals);
    }

    /// @notice Anyone can pay claim gas for a wallet; IMD always goes to the entitled account. A contract
    /// account must claim itself, so nobody can push IMD into a custodian that has no way to move it.
    function claimFor(address account, uint256 maxIntervals) public nonReentrant returns (uint256 amount) {
        Account memory progress;
        (amount, progress) = previewClaim(account, maxIntervals);
        if (msg.sender != account && account.code.length != 0) revert ContractMustClaimItself();
        accounts[account] = progress;
        if (amount != 0) {
            totalClaimed += amount;
            bytes memory data = abi.encode(account, amount);
            _activeClaim = keccak256(data);
            poolManager.unlock(data);
            _activeClaim = bytes32(0);
        }
        emit Claimed(account, amount, progress.throughBlock, progress.cursor);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || _activeClaim == bytes32(0) || keccak256(data) != _activeClaim) {
            revert InvalidCallback();
        }
        _activeClaim = bytes32(0);
        (address account, uint256 amount) = abi.decode(data, (address, uint256));
        poolManager.burn(address(this), rewardCurrency.toId(), amount);
        poolManager.take(rewardCurrency, account, amount);
        return "";
    }
}
