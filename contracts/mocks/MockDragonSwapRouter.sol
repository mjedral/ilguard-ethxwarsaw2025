// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interfaces/IDragonSwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockDragonSwapRouter
 * @dev Mock implementation of DragonSwap Router for testing
 */
contract MockDragonSwapRouter is IDragonSwapRouter {
    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable override returns (uint256 amountOut) {
        // Transfer input token from sender
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);

        // Simplified swap calculation (1:1 ratio for testing)
        amountOut = params.amountIn;

        // Check slippage
        require(amountOut >= params.amountOutMinimum, "Insufficient output amount");

        // Transfer output token to recipient
        IERC20(params.tokenOut).transfer(params.recipient, amountOut);
    }

    function exactOutputSingle(
        ExactOutputSingleParams calldata params
    ) external payable override returns (uint256 amountIn) {
        // Simplified swap calculation (1:1 ratio for testing)
        amountIn = params.amountOut;

        // Check slippage
        require(amountIn <= params.amountInMaximum, "Excessive input amount");

        // Transfer input token from sender
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), amountIn);

        // Transfer output token to recipient
        IERC20(params.tokenOut).transfer(params.recipient, params.amountOut);
    }
}
