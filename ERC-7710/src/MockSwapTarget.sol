// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title MockSwapTarget
 * @notice ERC-7579 account가 호출할 수 있는 단순 swap target mock입니다.
 * @dev 실제 토큰 전송은 하지 않고, 고정 비율로 계산한 output amount를 recipient별 장부에 기록합니다.
 */
contract MockSwapTarget {
    uint256 public constant RATE_BPS = 20_000;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    error ZeroAmount();
    error InvalidRecipient();
    error SlippageExceeded(uint256 amountOut, uint256 minAmountOut);

    event SwapExecuted(
        address indexed caller,
        address indexed recipient,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    address public lastCaller;
    address public lastRecipient;
    address public lastTokenIn;
    address public lastTokenOut;
    uint256 public lastAmountIn;
    uint256 public lastAmountOut;

    mapping(address recipient => mapping(address token => uint256 amount)) public creditedAmount;

    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut) {
        if (amountIn == 0) {
            revert ZeroAmount();
        }
        if (recipient == address(0)) {
            revert InvalidRecipient();
        }

        amountOut = amountIn * RATE_BPS / BPS_DENOMINATOR;
        if (amountOut < minAmountOut) {
            revert SlippageExceeded(amountOut, minAmountOut);
        }

        lastCaller = msg.sender;
        lastRecipient = recipient;
        lastTokenIn = tokenIn;
        lastTokenOut = tokenOut;
        lastAmountIn = amountIn;
        lastAmountOut = amountOut;
        creditedAmount[recipient][tokenOut] += amountOut;

        emit SwapExecuted(msg.sender, recipient, tokenIn, tokenOut, amountIn, amountOut);
    }
}
