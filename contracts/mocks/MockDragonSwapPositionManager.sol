// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interfaces/IDragonSwapPositionManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockDragonSwapPositionManager
 * @dev Mock implementation of DragonSwap Position Manager for testing
 */
contract MockDragonSwapPositionManager is IDragonSwapPositionManager {
    uint256 private _nextTokenId = 1;
    mapping(uint256 => Position) private _positions;

    struct Position {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    function mint(
        MintParams calldata params
    ) external payable override returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        tokenId = _nextTokenId++;

        // Transfer tokens from sender
        if (params.amount0Desired > 0) {
            IERC20(params.token0).transferFrom(msg.sender, address(this), params.amount0Desired);
        }
        if (params.amount1Desired > 0) {
            IERC20(params.token1).transferFrom(msg.sender, address(this), params.amount1Desired);
        }

        // Simplified liquidity calculation
        liquidity = uint128(params.amount0Desired + params.amount1Desired);
        amount0 = params.amount0Desired;
        amount1 = params.amount1Desired;

        // Store position
        _positions[tokenId] = Position({
            token0: params.token0,
            token1: params.token1,
            fee: params.fee,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: liquidity,
            feeGrowthInside0LastX128: 0,
            feeGrowthInside1LastX128: 0,
            tokensOwed0: uint128(liquidity / 100), // Mock fees
            tokensOwed1: uint128(liquidity / 100)
        });
    }

    function increaseLiquidity(
        IncreaseLiquidityParams calldata params
    ) external payable override returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        Position storage position = _positions[params.tokenId];
        require(position.token0 != address(0), "Position does not exist"); // Check if position exists, not liquidity

        liquidity = uint128(params.amount0Desired + params.amount1Desired);
        amount0 = params.amount0Desired;
        amount1 = params.amount1Desired;

        position.liquidity += liquidity;
    }

    function decreaseLiquidity(
        DecreaseLiquidityParams calldata params
    ) external payable override returns (uint256 amount0, uint256 amount1) {
        Position storage position = _positions[params.tokenId];
        require(position.liquidity >= params.liquidity, "Insufficient liquidity");

        position.liquidity -= params.liquidity;

        // Simplified calculation
        amount0 = params.liquidity / 2;
        amount1 = params.liquidity / 2;

        // Add to tokens owed
        position.tokensOwed0 += uint128(amount0);
        position.tokensOwed1 += uint128(amount1);
    }

    function collect(
        CollectParams calldata params
    ) external payable override returns (uint256 amount0, uint256 amount1) {
        Position storage position = _positions[params.tokenId];

        amount0 = position.tokensOwed0;
        amount1 = position.tokensOwed1;

        // Transfer tokens to recipient (check balance first)
        if (amount0 > 0) {
            uint256 balance0 = IERC20(position.token0).balanceOf(address(this));
            uint256 transferAmount0 = amount0 > balance0 ? balance0 : amount0;
            if (transferAmount0 > 0) {
                IERC20(position.token0).transfer(params.recipient, transferAmount0);
            }
            position.tokensOwed0 = 0;
        }
        if (amount1 > 0) {
            uint256 balance1 = IERC20(position.token1).balanceOf(address(this));
            uint256 transferAmount1 = amount1 > balance1 ? balance1 : amount1;
            if (transferAmount1 > 0) {
                IERC20(position.token1).transfer(params.recipient, transferAmount1);
            }
            position.tokensOwed1 = 0;
        }
    }

    function burn(uint256 tokenId) external payable override {
        Position storage position = _positions[tokenId];
        require(position.liquidity == 0, "Position still has liquidity");
        require(position.tokensOwed0 == 0 && position.tokensOwed1 == 0, "Uncollected tokens");

        delete _positions[tokenId];
    }

    function positions(
        uint256 tokenId
    )
        external
        view
        override
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        Position memory position = _positions[tokenId];
        return (
            0, // nonce
            address(0), // operator
            position.token0,
            position.token1,
            position.fee,
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            position.feeGrowthInside0LastX128,
            position.feeGrowthInside1LastX128,
            position.tokensOwed0,
            position.tokensOwed1
        );
    }
}
