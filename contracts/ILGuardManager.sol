// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ILGuardManager
 * @dev Core smart contract for managing liquidity positions and automated rebalancing
 * Provides deposit, withdraw, rebalance, and emergency pause functionality
 */
contract ILGuardManager is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // Position struct to track user liquidity positions
    struct Position {
        address owner;
        uint256 tokenId; // UniV3 NFT ID or position identifier
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bool isProtected; // Whether automated protection is enabled
        bool isPaused; // Individual position pause status
        uint256 createdAt;
        uint256 lastRebalanceAt;
    }

    // Mapping from position ID to Position struct
    mapping(uint256 => Position) public positions;

    // Mapping from user address to their position IDs
    mapping(address => uint256[]) public userPositions;

    // Counter for generating unique position IDs
    uint256 private _positionIdCounter;

    // Bot address authorized to perform rebalances
    address public botAddress;

    // Slippage tolerance (in basis points, e.g., 30 = 0.3%)
    uint256 public slippageTolerance = 30;

    // Minimum cooldown period between rebalances (in seconds)
    uint256 public cooldownPeriod = 1800; // 30 minutes

    // Maximum actions per day per position
    uint256 public maxActionsPerDay = 5;

    // Mapping to track daily action counts
    mapping(uint256 => mapping(uint256 => uint256)) public dailyActionCounts; // positionId => day => count

    // Events
    event Deposited(
        uint256 indexed positionId,
        address indexed user,
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );

    event Withdrawn(
        uint256 indexed positionId,
        address indexed user,
        uint256 amount0,
        uint256 amount1,
        uint256 feesCollected
    );

    event Rebalanced(
        uint256 indexed positionId,
        address indexed user,
        int24 oldTickLower,
        int24 oldTickUpper,
        int24 newTickLower,
        int24 newTickUpper,
        string reason,
        uint256 feesCollected
    );

    event PositionPaused(uint256 indexed positionId, address indexed user);
    event PositionUnpaused(uint256 indexed positionId, address indexed user);
    event ProtectionToggled(uint256 indexed positionId, address indexed user, bool isProtected);
    event BotAddressUpdated(address indexed oldBot, address indexed newBot);
    event SlippageToleranceUpdated(uint256 oldTolerance, uint256 newTolerance);

    // Modifiers
    modifier onlyBot() {
        require(msg.sender == botAddress, "ILGuardManager: caller is not the bot");
        _;
    }

    modifier onlyPositionOwner(uint256 positionId) {
        require(positions[positionId].owner == msg.sender, "ILGuardManager: not position owner");
        _;
    }

    modifier positionExists(uint256 positionId) {
        require(positions[positionId].owner != address(0), "ILGuardManager: position does not exist");
        _;
    }

    modifier notPositionPaused(uint256 positionId) {
        require(!positions[positionId].isPaused, "ILGuardManager: position is paused");
        _;
    }

    modifier respectsCooldown(uint256 positionId) {
        require(
            block.timestamp >= positions[positionId].lastRebalanceAt + cooldownPeriod,
            "ILGuardManager: cooldown period not met"
        );
        _;
    }

    modifier respectsDailyLimit(uint256 positionId) {
        uint256 today = block.timestamp / 86400; // Current day
        require(dailyActionCounts[positionId][today] < maxActionsPerDay, "ILGuardManager: daily action limit exceeded");
        _;
    }

    constructor() {
        _positionIdCounter = 1;
    }

    /**
     * @dev Deposit liquidity to create a new position
     * @param amount0 Amount of token0 to deposit
     * @param amount1 Amount of token1 to deposit
     * @param tickLower Lower tick of the position range
     * @param tickUpper Upper tick of the position range
     * @return positionId The ID of the created position
     */
    function deposit(
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper
    ) external nonReentrant whenNotPaused returns (uint256 positionId) {
        require(amount0 > 0 || amount1 > 0, "ILGuardManager: invalid deposit amounts");
        require(tickLower < tickUpper, "ILGuardManager: invalid tick range");

        positionId = _positionIdCounter++;

        // For MVP, we'll use a simplified liquidity calculation
        // In production, this would integrate with actual UniV3 position manager
        uint128 liquidity = uint128(amount0 + amount1); // Simplified calculation

        positions[positionId] = Position({
            owner: msg.sender,
            tokenId: positionId, // Using positionId as tokenId for MVP
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            isProtected: false, // Default to not protected
            isPaused: false,
            createdAt: block.timestamp,
            lastRebalanceAt: 0
        });

        userPositions[msg.sender].push(positionId);

        emit Deposited(positionId, msg.sender, amount0, amount1, tickLower, tickUpper, liquidity);

        return positionId;
    }

    /**
     * @dev Withdraw liquidity from a position
     * @param positionId The ID of the position to withdraw from
     */
    function withdraw(
        uint256 positionId
    ) external nonReentrant onlyPositionOwner(positionId) positionExists(positionId) {
        Position storage position = positions[positionId];

        uint256 amount0 = position.liquidity / 2; // Simplified calculation
        uint256 amount1 = position.liquidity / 2; // Simplified calculation
        uint256 feesCollected = 0; // Would collect actual fees in production

        // Remove position from user's position list
        _removePositionFromUser(msg.sender, positionId);

        // Clear the position
        delete positions[positionId];

        emit Withdrawn(positionId, msg.sender, amount0, amount1, feesCollected);
    }

    /**
     * @dev Rebalance a position to a new tick range
     * @param positionId The ID of the position to rebalance
     * @param newTickLower New lower tick
     * @param newTickUpper New upper tick
     * @param reason Reason for rebalancing ("band" or "speed")
     */
    function rebalance(
        uint256 positionId,
        int24 newTickLower,
        int24 newTickUpper,
        string calldata reason
    )
        external
        nonReentrant
        onlyBot
        positionExists(positionId)
        notPositionPaused(positionId)
        respectsCooldown(positionId)
        respectsDailyLimit(positionId)
        whenNotPaused
    {
        Position storage position = positions[positionId];
        require(position.isProtected, "ILGuardManager: position not protected");
        require(newTickLower < newTickUpper, "ILGuardManager: invalid new tick range");

        int24 oldTickLower = position.tickLower;
        int24 oldTickUpper = position.tickUpper;

        // Update position with new range
        position.tickLower = newTickLower;
        position.tickUpper = newTickUpper;
        position.lastRebalanceAt = block.timestamp;

        // Update daily action count
        uint256 today = block.timestamp / 86400;
        dailyActionCounts[positionId][today]++;

        uint256 feesCollected = 0; // Would collect actual fees in production

        emit Rebalanced(
            positionId,
            position.owner,
            oldTickLower,
            oldTickUpper,
            newTickLower,
            newTickUpper,
            reason,
            feesCollected
        );
    }

    /**
     * @dev Emergency pause a specific position
     * @param positionId The ID of the position to pause
     */
    function emergencyPausePosition(
        uint256 positionId
    ) external onlyPositionOwner(positionId) positionExists(positionId) {
        positions[positionId].isPaused = true;
        emit PositionPaused(positionId, msg.sender);
    }

    /**
     * @dev Unpause a specific position
     * @param positionId The ID of the position to unpause
     */
    function unpausePosition(uint256 positionId) external onlyPositionOwner(positionId) positionExists(positionId) {
        positions[positionId].isPaused = false;
        emit PositionUnpaused(positionId, msg.sender);
    }

    /**
     * @dev Toggle protection for a position
     * @param positionId The ID of the position
     * @param isProtected Whether to enable or disable protection
     */
    function toggleProtection(
        uint256 positionId,
        bool isProtected
    ) external onlyPositionOwner(positionId) positionExists(positionId) {
        positions[positionId].isProtected = isProtected;
        emit ProtectionToggled(positionId, msg.sender, isProtected);
    }

    /**
     * @dev Emergency pause all contract operations (only owner)
     */
    function emergencyPause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause all contract operations (only owner)
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Set the bot address authorized to perform rebalances
     * @param newBotAddress The new bot address
     */
    function setBotAddress(address newBotAddress) external onlyOwner {
        require(newBotAddress != address(0), "ILGuardManager: invalid bot address");
        address oldBot = botAddress;
        botAddress = newBotAddress;
        emit BotAddressUpdated(oldBot, newBotAddress);
    }

    /**
     * @dev Set slippage tolerance
     * @param newTolerance New slippage tolerance in basis points
     */
    function setSlippageTolerance(uint256 newTolerance) external onlyOwner {
        require(newTolerance <= 1000, "ILGuardManager: tolerance too high"); // Max 10%
        uint256 oldTolerance = slippageTolerance;
        slippageTolerance = newTolerance;
        emit SlippageToleranceUpdated(oldTolerance, newTolerance);
    }

    /**
     * @dev Set cooldown period between rebalances
     * @param newCooldownPeriod New cooldown period in seconds
     */
    function setCooldownPeriod(uint256 newCooldownPeriod) external onlyOwner {
        require(newCooldownPeriod >= 300, "ILGuardManager: cooldown too short"); // Min 5 minutes
        cooldownPeriod = newCooldownPeriod;
    }

    /**
     * @dev Set maximum actions per day
     * @param newMaxActions New maximum actions per day
     */
    function setMaxActionsPerDay(uint256 newMaxActions) external onlyOwner {
        require(newMaxActions > 0, "ILGuardManager: invalid max actions");
        maxActionsPerDay = newMaxActions;
    }

    /**
     * @dev Get user's position IDs
     * @param user The user address
     * @return Array of position IDs owned by the user
     */
    function getUserPositions(address user) external view returns (uint256[] memory) {
        return userPositions[user];
    }

    /**
     * @dev Get position details
     * @param positionId The position ID
     * @return The position struct
     */
    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }

    /**
     * @dev Check if a position can be rebalanced
     * @param positionId The position ID
     * @return Whether the position can be rebalanced
     */
    function canRebalance(uint256 positionId) external view returns (bool) {
        Position memory position = positions[positionId];

        if (position.owner == address(0) || !position.isProtected || position.isPaused || paused()) {
            return false;
        }

        // Check cooldown
        if (block.timestamp < position.lastRebalanceAt + cooldownPeriod) {
            return false;
        }

        // Check daily limit
        uint256 today = block.timestamp / 86400;
        if (dailyActionCounts[positionId][today] >= maxActionsPerDay) {
            return false;
        }

        return true;
    }

    /**
     * @dev Internal function to remove a position from user's position list
     * @param user The user address
     * @param positionId The position ID to remove
     */
    function _removePositionFromUser(address user, uint256 positionId) internal {
        uint256[] storage userPositionList = userPositions[user];
        for (uint256 i = 0; i < userPositionList.length; i++) {
            if (userPositionList[i] == positionId) {
                userPositionList[i] = userPositionList[userPositionList.length - 1];
                userPositionList.pop();
                break;
            }
        }
    }
}
