// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";

/// @title MockExchange
/// @notice Simple mock exchange for testing swap operations with promise integration
/// @dev Provides 1:1 swaps with configurable failure modes for testing error handling
contract MockExchange {
    /// @notice Mapping to track exchange rates between tokens (tokenIn => tokenOut => rate)
    /// @dev Rate is in basis points (10000 = 1:1, 5000 = 0.5:1, 20000 = 2:1)
    mapping(address => mapping(address => uint256)) public exchangeRates;
    
    /// @notice Mapping to force failures for specific token pairs
    mapping(address => mapping(address => bool)) public forceFailure;
    
    /// @notice Mapping to track if a token pair is supported
    mapping(address => mapping(address => bool)) public supportedPairs;
    
    /// @notice Default exchange rate (1:1 in basis points)
    uint256 public constant DEFAULT_RATE = 10000;
    
    /// @notice Basis points denominator 
    uint256 public constant RATE_DENOMINATOR = 10000;

    /// @notice Event emitted when a swap is executed
    event SwapExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address indexed user
    );

    /// @notice Event emitted when a swap fails
    event SwapFailed(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        address indexed user,
        string reason
    );

    /// @notice Error thrown when swap fails
    error SwapFailedError(string reason);
    
    /// @notice Error thrown for unsupported token pairs
    error UnsupportedPair(address tokenIn, address tokenOut);
    
    /// @notice Error thrown for insufficient balance
    error InsufficientBalance(address token, uint256 required, uint256 available);

    /// @notice Add or update a supported token pair with exchange rate
    /// @param tokenIn Input token address
    /// @param tokenOut Output token address  
    /// @param rate Exchange rate in basis points (10000 = 1:1)
    function addPair(address tokenIn, address tokenOut, uint256 rate) external {
        supportedPairs[tokenIn][tokenOut] = true;
        exchangeRates[tokenIn][tokenOut] = rate;
    }

    /// @notice Remove a supported token pair
    /// @param tokenIn Input token address
    /// @param tokenOut Output token address
    function removePair(address tokenIn, address tokenOut) external {
        supportedPairs[tokenIn][tokenOut] = false;
        exchangeRates[tokenIn][tokenOut] = 0;
    }

    /// @notice Set failure mode for a specific token pair (for testing)
    /// @param tokenIn Input token address
    /// @param tokenOut Output token address
    /// @param shouldFail Whether swaps should fail for this pair
    function setFailureMode(address tokenIn, address tokenOut, bool shouldFail) external {
        forceFailure[tokenIn][tokenOut] = shouldFail;
    }

    /// @notice Execute a token swap
    /// @param tokenIn Address of input token
    /// @param tokenOut Address of output token
    /// @param amountIn Amount of input tokens to swap
    /// @return amountOut Amount of output tokens received
    function swap(address tokenIn, address tokenOut, uint256 amountIn) external returns (uint256 amountOut) {
        // Check if pair is supported
        if (!supportedPairs[tokenIn][tokenOut]) {
            revert UnsupportedPair(tokenIn, tokenOut);
        }
        
        // Check for forced failure (for testing)
        if (forceFailure[tokenIn][tokenOut]) {
            emit SwapFailed(tokenIn, tokenOut, amountIn, msg.sender, "Forced failure for testing");
            revert SwapFailedError("Forced failure for testing");
        }
        
        // Get exchange rate (default to 1:1 if not set)
        uint256 rate = exchangeRates[tokenIn][tokenOut];
        if (rate == 0) {
            rate = DEFAULT_RATE;
        }
        
        // Calculate output amount
        amountOut = (amountIn * rate) / RATE_DENOMINATOR;
        
        // Check user has enough input tokens
        uint256 userBalance = IERC20(tokenIn).balanceOf(msg.sender);
        if (userBalance < amountIn) {
            revert InsufficientBalance(tokenIn, amountIn, userBalance);
        }
        
        // Check exchange has enough output tokens
        uint256 exchangeBalance = IERC20(tokenOut).balanceOf(address(this));
        if (exchangeBalance < amountOut) {
            emit SwapFailed(tokenIn, tokenOut, amountIn, msg.sender, "Insufficient exchange liquidity");
            revert SwapFailedError("Insufficient exchange liquidity");
        }
        
        // Execute the swap
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(msg.sender, amountOut);
        
        emit SwapExecuted(tokenIn, tokenOut, amountIn, amountOut, msg.sender);
    }

    /// @notice Get quote for a swap without executing it
    /// @param tokenIn Address of input token
    /// @param tokenOut Address of output token
    /// @param amountIn Amount of input tokens
    /// @return amountOut Expected amount of output tokens
    function getQuote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut) {
        if (!supportedPairs[tokenIn][tokenOut]) {
            return 0;
        }
        
        uint256 rate = exchangeRates[tokenIn][tokenOut];
        if (rate == 0) {
            rate = DEFAULT_RATE;
        }
        
        amountOut = (amountIn * rate) / RATE_DENOMINATOR;
    }

    /// @notice Check if a token pair is supported
    /// @param tokenIn Input token address
    /// @param tokenOut Output token address
    /// @return supported Whether the pair is supported
    function isPairSupported(address tokenIn, address tokenOut) external view returns (bool supported) {
        return supportedPairs[tokenIn][tokenOut];
    }

    /// @notice Provide liquidity to the exchange (for testing)
    /// @param token Token address
    /// @param amount Amount to provide
    function provideLiquidity(address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }

    /// @notice Withdraw liquidity from the exchange (for testing)
    /// @param token Token address
    /// @param amount Amount to withdraw
    function withdrawLiquidity(address token, uint256 amount) external {
        IERC20(token).transfer(msg.sender, amount);
    }

    /// @notice Get exchange balance of a token
    /// @param token Token address
    /// @return balance Exchange balance
    function getBalance(address token) external view returns (uint256 balance) {
        return IERC20(token).balanceOf(address(this));
    }
} 