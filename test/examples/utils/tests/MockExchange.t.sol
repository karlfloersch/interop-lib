// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {MockExchange} from "../MockExchange.sol";
import {MockSuperchainERC20} from "../MockSuperchainERC20.sol";

contract MockExchangeTest is Test {
    MockExchange public exchange;
    MockSuperchainERC20 public tokenA;
    MockSuperchainERC20 public tokenB;
    MockSuperchainERC20 public tokenC;
    
    address public user1;
    address public user2;
    address public liquidity_provider;

    function setUp() public {
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        liquidity_provider = makeAddr("liquidity_provider");
        
        exchange = new MockExchange();
        
        // Create test tokens
        tokenA = new MockSuperchainERC20("Token A", "TKNA", 0, address(0));
        tokenB = new MockSuperchainERC20("Token B", "TKNB", 0, address(0));
        tokenC = new MockSuperchainERC20("Token C", "TKNC", 0, address(0));
        
        // Mint tokens to users and liquidity provider
        tokenA.setAuthorizedMinter(address(this));
        tokenB.setAuthorizedMinter(address(this));
        tokenC.setAuthorizedMinter(address(this));
        
        // User1 gets Token A
        tokenA.crosschainMint(user1, 1000 ether);
        
        // User2 gets Token B  
        tokenB.crosschainMint(user2, 1000 ether);
        
        // Liquidity provider gets all tokens for the exchange
        tokenA.crosschainMint(liquidity_provider, 10000 ether);
        tokenB.crosschainMint(liquidity_provider, 10000 ether);
        tokenC.crosschainMint(liquidity_provider, 10000 ether);
        
        // Provide liquidity to exchange
        vm.startPrank(liquidity_provider);
        tokenA.approve(address(exchange), 10000 ether);
        tokenB.approve(address(exchange), 10000 ether);
        tokenC.approve(address(exchange), 10000 ether);
        
        exchange.provideLiquidity(address(tokenA), 5000 ether);
        exchange.provideLiquidity(address(tokenB), 5000 ether);
        exchange.provideLiquidity(address(tokenC), 5000 ether);
        vm.stopPrank();
        
        // Add supported pairs (1:1 rates)
        exchange.addPair(address(tokenA), address(tokenB), 10000); // 1:1
        exchange.addPair(address(tokenB), address(tokenC), 10000); // 1:1
        exchange.addPair(address(tokenA), address(tokenC), 15000); // 1.5:1
    }

    function test_AddPair() public {
        assertTrue(exchange.isPairSupported(address(tokenA), address(tokenB)));
        assertEq(exchange.exchangeRates(address(tokenA), address(tokenB)), 10000);
    }

    function test_RemovePair() public {
        exchange.removePair(address(tokenA), address(tokenB));
        assertFalse(exchange.isPairSupported(address(tokenA), address(tokenB)));
        assertEq(exchange.exchangeRates(address(tokenA), address(tokenB)), 0);
    }

    function test_GetQuote() public {
        uint256 quote = exchange.getQuote(address(tokenA), address(tokenB), 100 ether);
        assertEq(quote, 100 ether); // 1:1 rate
        
        quote = exchange.getQuote(address(tokenA), address(tokenC), 100 ether);
        assertEq(quote, 150 ether); // 1.5:1 rate
    }

    function test_Swap_Success() public {
        vm.startPrank(user1);
        tokenA.approve(address(exchange), 100 ether);
        
        uint256 initialBalanceA = tokenA.balanceOf(user1);
        uint256 initialBalanceB = tokenB.balanceOf(user1);
        
        uint256 amountOut = exchange.swap(address(tokenA), address(tokenB), 100 ether);
        
        assertEq(amountOut, 100 ether);
        assertEq(tokenA.balanceOf(user1), initialBalanceA - 100 ether);
        assertEq(tokenB.balanceOf(user1), initialBalanceB + 100 ether);
        vm.stopPrank();
    }

    function test_Swap_UnsupportedPair() public {
        // Try to swap tokens with no supported pair
        vm.startPrank(user1);
        tokenA.approve(address(exchange), 100 ether);
        
        vm.expectRevert(
            abi.encodeWithSelector(
                MockExchange.UnsupportedPair.selector,
                address(tokenB),
                address(tokenA)
            )
        );
        exchange.swap(address(tokenB), address(tokenA), 100 ether);
        vm.stopPrank();
    }

    function test_Swap_InsufficientBalance() public {
        vm.startPrank(user1);
        tokenA.approve(address(exchange), 2000 ether);
        
        vm.expectRevert(
            abi.encodeWithSelector(
                MockExchange.InsufficientBalance.selector,
                address(tokenA),
                2000 ether,
                1000 ether
            )
        );
        exchange.swap(address(tokenA), address(tokenB), 2000 ether);
        vm.stopPrank();
    }

    function test_Swap_InsufficientLiquidity() public {
        // Add a pair with limited liquidity
        MockSuperchainERC20 tokenD = new MockSuperchainERC20("Token D", "TKND", 0, address(0));
        tokenD.setAuthorizedMinter(address(this));
        tokenD.crosschainMint(address(exchange), 50 ether); // Only 50 tokens in exchange
        
        exchange.addPair(address(tokenA), address(tokenD), 10000);
        
        vm.startPrank(user1);
        tokenA.approve(address(exchange), 100 ether);
        
        vm.expectRevert(
            abi.encodeWithSignature("SwapFailedError(string)", "Insufficient exchange liquidity")
        );
        exchange.swap(address(tokenA), address(tokenD), 100 ether);
        vm.stopPrank();
    }

    function test_SetFailureMode() public {
        // Set failure mode for a pair
        exchange.setFailureMode(address(tokenA), address(tokenB), true);
        
        vm.startPrank(user1);
        tokenA.approve(address(exchange), 100 ether);
        
        vm.expectRevert(
            abi.encodeWithSignature("SwapFailedError(string)", "Forced failure for testing")
        );
        exchange.swap(address(tokenA), address(tokenB), 100 ether);
        vm.stopPrank();
        
        // Disable failure mode
        exchange.setFailureMode(address(tokenA), address(tokenB), false);
        
        // Should work now
        vm.startPrank(user1);
        uint256 amountOut = exchange.swap(address(tokenA), address(tokenB), 100 ether);
        assertEq(amountOut, 100 ether);
        vm.stopPrank();
    }

    function test_ProvideLiquidity() public {
        uint256 initialBalance = exchange.getBalance(address(tokenA));
        
        vm.startPrank(liquidity_provider);
        tokenA.approve(address(exchange), 1000 ether);
        exchange.provideLiquidity(address(tokenA), 1000 ether);
        vm.stopPrank();
        
        assertEq(exchange.getBalance(address(tokenA)), initialBalance + 1000 ether);
    }

    function test_WithdrawLiquidity() public {
        uint256 initialBalance = exchange.getBalance(address(tokenA));
        uint256 userInitialBalance = tokenA.balanceOf(liquidity_provider);
        
        vm.prank(liquidity_provider);
        exchange.withdrawLiquidity(address(tokenA), 1000 ether);
        
        assertEq(exchange.getBalance(address(tokenA)), initialBalance - 1000 ether);
        assertEq(tokenA.balanceOf(liquidity_provider), userInitialBalance + 1000 ether);
    }

    function test_ComplexSwapSequence() public {
        // Test user1 swapping A -> B, then user2 swapping B -> C
        
        // User1: A -> B
        vm.startPrank(user1);
        tokenA.approve(address(exchange), 200 ether);
        uint256 amountOut1 = exchange.swap(address(tokenA), address(tokenB), 200 ether);
        assertEq(amountOut1, 200 ether);
        assertEq(tokenB.balanceOf(user1), 200 ether);
        vm.stopPrank();
        
        // User2: B -> C (user2 starts with 1000 TokenB)
        vm.startPrank(user2);
        tokenB.approve(address(exchange), 150 ether);
        uint256 amountOut2 = exchange.swap(address(tokenB), address(tokenC), 150 ether);
        assertEq(amountOut2, 150 ether);
        assertEq(tokenC.balanceOf(user2), 150 ether);
        assertEq(tokenB.balanceOf(user2), 850 ether); // 1000 - 150
        vm.stopPrank();
    }
} 