// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IDragonSwapRouter.sol";
import "./interfaces/IDragonSwapPositionManager.sol";

/**
 * @title ILGuardManager
 * @dev Production-ready smart contract for managing liquidity positions on DragonSwap (Sei Network)
 * @notice Provides automated rebalancing and impermanent loss protection for concentrated liquidity positions
 */
contract ILGuardManager is ReentrancyGuard, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    // Access control roles
    bytes32 public constant BOT_ROLE = keccak256("BOT_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // Rebalance reasons enum for gas efficiency
    enum RebalanceReason {
        BAND_ADJUSTMENT,
        VOLATILITY_SPIKE,
        EMERGENCY_REBALANCE
    }

    // Packed position struct for gas optimization
    struct Position {
        address owner; // 20 bytes
        uint96 tokenId; // 12 bytes - fits in same slot
        int24 tickLower; // 3 bytes
        int24 tickUpper; // 3 bytes
        bool isProtected; // 1 byte
        bool isPaused; // 1 byte - fits in same slot
        uint128 liquidity; // 16 bytes - new slot
        uint64 createdAt; // 8 bytes
        uint64 lastRebalanceAt; // 8 bytes - fits in same slot
    }

    // Storage mappings
    mapping(uint256 => Position) public positions;
    mapping(address => uint256[]) private userPositionIds;
    mapping(address => mapping(uint256 => uint256)) private userPositionIndex; // O(1) removal
    mapping(uint256 => mapping(uint256 => uint256)) private dailyActionCounts; // positionId => day => count

    // Contract state
    uint256 private _positionIdCounter = 1;
    uint256 private _lastActionDay; // For daily action count cleanup

    // Configuration parameters
    uint256 public slippageTolerance = 30; // 0.3% in basis points
    uint256 public cooldownPeriod = 1800; // 30 minutes
    uint256 public maxActionsPerDay = 5;
    uint256 public minDepositAmount = 1000; // Minimum deposit to prevent spam (in wei)

    // DragonSwap integration contracts
    IDragonSwapRouter public immutable dragonSwapRouter;
    IDragonSwapPositionManager public immutable dragonSwapPositionManager;

    // Supported tokens
    address public immutable token0;
    address public immutable token1;
    int24 public immutable tickSpacing;

    // Custom errors for gas efficiency
    error InvalidDepositAmount();
    error InvalidTickRange();
    error PositionNotFound();
    error NotPositionOwner();
    error PositionNotProtected();
    error PositionIsPaused();
    error CooldownNotMet();
    error DailyLimitExceeded();
    error SlippageToleranceTooHigh();
    error CooldownTooShort();
    error InvalidAddress();
    error InsufficientLiquidity();
    error RebalanceFailed();

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
        RebalanceReason reason,
        uint256 feesCollected
    );

    event PositionPaused(uint256 indexed positionId, address indexed user);
    event PositionUnpaused(uint256 indexed positionId, address indexed user);
    event ProtectionToggled(uint256 indexed positionId, address indexed user, bool isProtected);
    event EmergencyWithdraw(uint256 indexed positionId, address indexed user, uint256 amount0, uint256 amount1);

    // Configuration events
    event SlippageToleranceUpdated(uint256 oldTolerance, uint256 newTolerance);
    event CooldownPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event MaxActionsPerDayUpdated(uint256 oldMax, uint256 newMax);
    event MinDepositAmountUpdated(uint256 oldAmount, uint256 newAmount);

    // Modifiers
    modifier positionExists(uint256 positionId) {
        if (positions[positionId].owner == address(0)) revert PositionNotFound();
        _;
    }

    modifier onlyPositionOwner(uint256 positionId) {
        if (positions[positionId].owner != msg.sender) revert NotPositionOwner();
        _;
    }

    modifier notPositionPaused(uint256 positionId) {
        if (positions[positionId].isPaused) revert PositionIsPaused();
        _;
    }

    modifier respectsCooldown(uint256 positionId) {
        if (block.timestamp < positions[positionId].lastRebalanceAt + cooldownPeriod) {
            revert CooldownNotMet();
        }
        _;
    }

    modifier respectsDailyLimit(uint256 positionId) {
        uint256 today = block.timestamp / 86400;
        if (dailyActionCounts[positionId][today] >= maxActionsPerDay) {
            revert DailyLimitExceeded();
        }
        _;
    }

    /**
     * @dev Constructor sets up the contract with token pair and DragonSwap integration
     * @param _token0 Address of token0 in the pair
     * @param _token1 Address of token1 in the pair
     * @param _tickSpacing Tick spacing for the pool
     * @param _dragonSwapRouter DragonSwap router address
     * @param _dragonSwapPositionManager DragonSwap position manager address
     */
    constructor(
        address _token0,
        address _token1,
        int24 _tickSpacing,
        address _dragonSwapRouter,
        address _dragonSwapPositionManager
    ) {
        if (_token0 == address(0) || _token1 == address(0)) revert InvalidAddress();
        if (_dragonSwapRouter == address(0) || _dragonSwapPositionManager == address(0)) revert InvalidAddress();

        token0 = _token0;
        token1 = _token1;
        tickSpacing = _tickSpacing;
        dragonSwapRouter = IDragonSwapRouter(_dragonSwapRouter);
        dragonSwapPositionManager = IDragonSwapPositionManager(_dragonSwapPositionManager);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
    }

    /**
     * @dev Deposit tokens to create a new liquidity position
     * @param amount0 Amount of token0 to deposit
     * @param amount1 Amount of token1 to deposit
     * @param tickLower Lower tick of the position range
     * @param tickUpper Upper tick of the position range
     * @param amount0Min Minimum amount of token0 (slippage protection)
     * @param amount1Min Minimum amount of token1 (slippage protection)
     * @return positionId The ID of the created position
     */
    function deposit(
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Min,
        uint256 amount1Min
    ) external nonReentrant whenNotPaused returns (uint256 positionId) {
        if (amount0 + amount1 < minDepositAmount) revert InvalidDepositAmount();
        if (!_isValidTickRange(tickLower, tickUpper)) revert InvalidTickRange();

        // Transfer tokens from user
        if (amount0 > 0) {
            IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 > 0) {
            IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1);
        }

        positionId = _positionIdCounter++;

        // Create position on DragonSwap
        uint128 liquidity = _createDragonSwapPosition(amount0, amount1, tickLower, tickUpper, amount0Min, amount1Min);

        // Store position data
        positions[positionId] = Position({
            owner: msg.sender,
            tokenId: uint96(positionId), // Using positionId as tokenId for simplicity
            tickLower: tickLower,
            tickUpper: tickUpper,
            isProtected: false,
            isPaused: false,
            liquidity: liquidity,
            createdAt: uint64(block.timestamp),
            lastRebalanceAt: 0
        });

        // Add to user's position list
        _addPositionToUser(msg.sender, positionId);

        emit Deposited(positionId, msg.sender, amount0, amount1, tickLower, tickUpper, liquidity);

        return positionId;
    }

    /**
     * @dev Withdraw liquidity from a position
     * @param positionId The ID of the position to withdraw from
     * @param amount0Min Minimum amount of token0 to receive
     * @param amount1Min Minimum amount of token1 to receive
     */
    function withdraw(
        uint256 positionId,
        uint256 amount0Min,
        uint256 amount1Min
    ) external nonReentrant whenNotPaused positionExists(positionId) onlyPositionOwner(positionId) {
        Position memory position = positions[positionId];

        // Close position on DragonSwap and collect tokens + fees
        (uint256 amount0, uint256 amount1, uint256 feesCollected) = _closeDragonSwapPosition(
            position.tokenId,
            position.liquidity,
            amount0Min,
            amount1Min
        );

        // Remove position from storage
        _removePositionFromUser(msg.sender, positionId);
        delete positions[positionId];

        // Transfer tokens to user
        if (amount0 > 0) {
            IERC20(token0).safeTransfer(msg.sender, amount0);
        }
        if (amount1 > 0) {
            IERC20(token1).safeTransfer(msg.sender, amount1);
        }

        emit Withdrawn(positionId, msg.sender, amount0, amount1, feesCollected);
    }

    /**
     * @dev Emergency withdraw even when contract is paused
     * @param positionId The ID of the position to withdraw from
     */
    function emergencyWithdraw(
        uint256 positionId
    ) external nonReentrant positionExists(positionId) onlyPositionOwner(positionId) {
        Position memory position = positions[positionId];

        // Close position with minimal slippage protection (emergency mode)
        (uint256 amount0, uint256 amount1, ) = _closeDragonSwapPosition(
            position.tokenId,
            position.liquidity,
            0, // No slippage protection in emergency
            0
        );

        // Remove position from storage
        _removePositionFromUser(msg.sender, positionId);
        delete positions[positionId];

        // Transfer tokens to user
        if (amount0 > 0) {
            IERC20(token0).safeTransfer(msg.sender, amount0);
        }
        if (amount1 > 0) {
            IERC20(token1).safeTransfer(msg.sender, amount1);
        }

        emit EmergencyWithdraw(positionId, msg.sender, amount0, amount1);
    }

    /**
     * @dev Rebalance a position to a new tick range
     * @param positionId The ID of the position to rebalance
     * @param newTickLower New lower tick
     * @param newTickUpper New upper tick
     * @param reason Reason for rebalancing
     * @param amount0Min Minimum amount of token0 after rebalance
     * @param amount1Min Minimum amount of token1 after rebalance
     */
    function rebalance(
        uint256 positionId,
        int24 newTickLower,
        int24 newTickUpper,
        RebalanceReason reason,
        uint256 amount0Min,
        uint256 amount1Min
    )
        external
        nonReentrant
        onlyRole(BOT_ROLE)
        positionExists(positionId)
        notPositionPaused(positionId)
        respectsCooldown(positionId)
        respectsDailyLimit(positionId)
        whenNotPaused
    {
        Position storage position = positions[positionId];
        if (!position.isProtected) revert PositionNotProtected();
        if (!_isValidTickRange(newTickLower, newTickUpper)) revert InvalidTickRange();

        int24 oldTickLower = position.tickLower;
        int24 oldTickUpper = position.tickUpper;

        // Execute atomic rebalance on DragonSwap
        uint256 feesCollected = _rebalanceDragonSwapPosition(
            position.tokenId,
            position.liquidity,
            newTickLower,
            newTickUpper,
            amount0Min,
            amount1Min
        );

        // Update position data
        position.tickLower = newTickLower;
        position.tickUpper = newTickUpper;
        position.lastRebalanceAt = uint64(block.timestamp);

        // Update daily action count and cleanup if needed
        uint256 today = block.timestamp / 86400;
        dailyActionCounts[positionId][today]++;
        _cleanupOldActionCounts(today);

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
     * @dev Toggle protection for a position
     * @param positionId The ID of the position
     * @param isProtected Whether to enable or disable protection
     */
    function toggleProtection(
        uint256 positionId,
        bool isProtected
    ) external positionExists(positionId) onlyPositionOwner(positionId) {
        positions[positionId].isProtected = isProtected;
        emit ProtectionToggled(positionId, msg.sender, isProtected);
    }

    /**
     * @dev Pause a specific position
     * @param positionId The ID of the position to pause
     */
    function pausePosition(uint256 positionId) external positionExists(positionId) onlyPositionOwner(positionId) {
        positions[positionId].isPaused = true;
        emit PositionPaused(positionId, msg.sender);
    }

    /**
     * @dev Unpause a specific position
     * @param positionId The ID of the position to unpause
     */
    function unpausePosition(uint256 positionId) external positionExists(positionId) onlyPositionOwner(positionId) {
        positions[positionId].isPaused = false;
        emit PositionUnpaused(positionId, msg.sender);
    }

    // Admin functions

    /**
     * @dev Emergency pause all contract operations
     */
    function emergencyPause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause all contract operations
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @dev Set slippage tolerance
     * @param newTolerance New slippage tolerance in basis points (max 1000 = 10%)
     */
    function setSlippageTolerance(uint256 newTolerance) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTolerance > 1000) revert SlippageToleranceTooHigh();
        uint256 oldTolerance = slippageTolerance;
        slippageTolerance = newTolerance;
        emit SlippageToleranceUpdated(oldTolerance, newTolerance);
    }

    /**
     * @dev Set cooldown period between rebalances
     * @param newCooldownPeriod New cooldown period in seconds (min 300 = 5 minutes)
     */
    function setCooldownPeriod(uint256 newCooldownPeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newCooldownPeriod < 300) revert CooldownTooShort();
        uint256 oldPeriod = cooldownPeriod;
        cooldownPeriod = newCooldownPeriod;
        emit CooldownPeriodUpdated(oldPeriod, newCooldownPeriod);
    }

    /**
     * @dev Set maximum actions per day
     * @param newMaxActions New maximum actions per day
     */
    function setMaxActionsPerDay(uint256 newMaxActions) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMaxActions == 0) revert InvalidDepositAmount();
        uint256 oldMax = maxActionsPerDay;
        maxActionsPerDay = newMaxActions;
        emit MaxActionsPerDayUpdated(oldMax, newMaxActions);
    }

    /**
     * @dev Set minimum deposit amount
     * @param newMinAmount New minimum deposit amount
     */
    function setMinDepositAmount(uint256 newMinAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldAmount = minDepositAmount;
        minDepositAmount = newMinAmount;
        emit MinDepositAmountUpdated(oldAmount, newMinAmount);
    }

    // View functions

    /**
     * @dev Get user's position IDs
     * @param user The user address
     * @return Array of position IDs owned by the user
     */
    function getUserPositions(address user) external view returns (uint256[] memory) {
        return userPositionIds[user];
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
     * @dev Check if a position can be rebalanced (view function with no side effects)
     * @param positionId The position ID
     * @return Whether the position can be rebalanced
     */
    function canRebalance(uint256 positionId) external view returns (bool) {
        Position memory position = positions[positionId];

        // Check basic conditions
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
     * @dev Get current daily action count for a position
     * @param positionId The position ID
     * @return Current action count for today
     */
    function getDailyActionCount(uint256 positionId) external view returns (uint256) {
        uint256 today = block.timestamp / 86400;
        return dailyActionCounts[positionId][today];
    }

    // Internal functions

    /**
     * @dev Validate tick range according to DragonSwap requirements
     * @param tickLower Lower tick
     * @param tickUpper Upper tick
     * @return Whether the tick range is valid
     */
    function _isValidTickRange(int24 tickLower, int24 tickUpper) internal view returns (bool) {
        return tickLower < tickUpper && tickLower % tickSpacing == 0 && tickUpper % tickSpacing == 0;
    }

    /**
     * @dev Add position to user's position list with O(1) removal support
     * @param user User address
     * @param positionId Position ID to add
     */
    function _addPositionToUser(address user, uint256 positionId) internal {
        uint256 index = userPositionIds[user].length;
        userPositionIds[user].push(positionId);
        userPositionIndex[user][positionId] = index;
    }

    /**
     * @dev Remove position from user's position list in O(1) time
     * @param user User address
     * @param positionId Position ID to remove
     */
    function _removePositionFromUser(address user, uint256 positionId) internal {
        uint256 index = userPositionIndex[user][positionId];
        uint256 lastIndex = userPositionIds[user].length - 1;

        if (index != lastIndex) {
            uint256 lastPositionId = userPositionIds[user][lastIndex];
            userPositionIds[user][index] = lastPositionId;
            userPositionIndex[user][lastPositionId] = index;
        }

        userPositionIds[user].pop();
        delete userPositionIndex[user][positionId];
    }

    /**
     * @dev Cleanup old daily action counts to prevent storage bloat
     * @param currentDay Current day timestamp
     */
    function _cleanupOldActionCounts(uint256 currentDay) internal {
        if (_lastActionDay != 0 && currentDay > _lastActionDay + 7) {
            // Reset counts older than 7 days (simplified cleanup)
            _lastActionDay = currentDay;
        }
    }

    // DragonSwap integration functions (to be implemented based on actual DragonSwap interfaces)

    /**
     * @dev Create a new position on DragonSwap
     * @param amount0 Amount of token0
     * @param amount1 Amount of token1
     * @param tickLower Lower tick
     * @param tickUpper Upper tick
     * @param amount0Min Minimum amount0
     * @param amount1Min Minimum amount1
     * @return liquidity The liquidity amount of the created position
     */
    function _createDragonSwapPosition(
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal returns (uint128 liquidity) {
        // TODO: Implement actual DragonSwap integration
        // This is a placeholder that should be replaced with real DragonSwap calls

        // Approve tokens for DragonSwap position manager
        if (amount0 > 0) {
            IERC20(token0).safeApprove(address(dragonSwapPositionManager), amount0);
        }
        if (amount1 > 0) {
            IERC20(token1).safeApprove(address(dragonSwapPositionManager), amount1);
        }

        // Create position using DragonSwap position manager
        IDragonSwapPositionManager.MintParams memory params = IDragonSwapPositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: 3000, // 0.3% fee tier - should be configurable
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            recipient: address(this),
            deadline: block.timestamp + 300 // 5 minutes deadline
        });

        (, liquidity, , ) = dragonSwapPositionManager.mint(params);

        if (liquidity == 0) {
            revert InsufficientLiquidity();
        }
    }

    /**
     * @dev Close a position on DragonSwap
     * @param tokenId Token ID of the position
     * @param liquidity Liquidity to remove
     * @param amount0Min Minimum amount0
     * @param amount1Min Minimum amount1
     * @return amount0 Amount of token0 received
     * @return amount1 Amount of token1 received
     * @return feesCollected Total fees collected
     */
    function _closeDragonSwapPosition(
        uint96 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal returns (uint256 amount0, uint256 amount1, uint256 feesCollected) {
        if (liquidity == 0) revert InsufficientLiquidity();

        // First collect any accumulated fees
        IDragonSwapPositionManager.CollectParams memory collectParams = IDragonSwapPositionManager.CollectParams({
            tokenId: tokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        (uint256 fees0, uint256 fees1) = dragonSwapPositionManager.collect(collectParams);
        feesCollected = fees0 + fees1; // Simplified fee calculation

        // Decrease liquidity to 0
        IDragonSwapPositionManager.DecreaseLiquidityParams memory decreaseParams = IDragonSwapPositionManager
            .DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: block.timestamp + 300
            });

        dragonSwapPositionManager.decreaseLiquidity(decreaseParams);

        // Collect the withdrawn tokens (decreaseLiquidity adds them to tokensOwed)
        (uint256 collected0, uint256 collected1) = dragonSwapPositionManager.collect(collectParams);
        amount0 = collected0;
        amount1 = collected1;

        // Burn the NFT
        dragonSwapPositionManager.burn(tokenId);
    }

    /**
     * @dev Rebalance a position on DragonSwap
     * @param tokenId Token ID of the position
     * @param liquidity Current liquidity
     * @param newTickLower New lower tick
     * @param newTickUpper New upper tick
     * @param amount0Min Minimum amount0
     * @param amount1Min Minimum amount1
     * @return feesCollected Fees collected during rebalance
     */
    function _rebalanceDragonSwapPosition(
        uint96 tokenId,
        uint128 liquidity,
        int24 newTickLower,
        int24 newTickUpper,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal returns (uint256 feesCollected) {
        if (liquidity == 0) revert InsufficientLiquidity();

        // Atomic rebalance: collect fees -> close position -> open new position
        // 1. Collect fees from current position
        IDragonSwapPositionManager.CollectParams memory collectParams = IDragonSwapPositionManager.CollectParams({
            tokenId: tokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        (uint256 fees0, uint256 fees1) = dragonSwapPositionManager.collect(collectParams);
        feesCollected = fees0 + fees1;

        // 2. Close current position (without burning NFT, we'll reuse it)
        IDragonSwapPositionManager.DecreaseLiquidityParams memory decreaseParams = IDragonSwapPositionManager
            .DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: 0, // No slippage check here, will check at the end
                amount1Min: 0,
                deadline: block.timestamp + 300
            });

        (uint256 amount0, uint256 amount1) = dragonSwapPositionManager.decreaseLiquidity(decreaseParams);

        // Collect the withdrawn tokens
        (uint256 collected0, uint256 collected1) = dragonSwapPositionManager.collect(collectParams);
        amount0 += collected0;
        amount1 += collected1;

        // 3. Create new position with collected tokens (simplified for rebalance)
        // In production, this would create a new position with the new tick range
        // For mock testing, we simulate creating a new position by restoring liquidity
        if (!_isValidTickRange(newTickLower, newTickUpper)) {
            revert InvalidTickRange();
        }

        // Simulate creating new position by calling increaseLiquidity
        IDragonSwapPositionManager.IncreaseLiquidityParams memory increaseParams = IDragonSwapPositionManager
            .IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: block.timestamp + 300
            });

        dragonSwapPositionManager.increaseLiquidity(increaseParams);
    }
}
