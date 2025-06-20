// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Relayer} from "../../src/test/Relayer.sol";
import {Promise} from "../../src/Promise.sol";
import {Callback} from "../../src/Callback.sol";
import {PredeployAddresses} from "../../src/libraries/PredeployAddresses.sol";

// Import our example contracts
import {MockSuperchainERC20} from "./utils/MockSuperchainERC20.sol";
import {MockExchange} from "./utils/MockExchange.sol";
import {PromiseBridge} from "./utils/PromiseBridge.sol";

/// @title CrossChainSwapExample
/// @notice E2E test demonstrating cross-chain swap workflow using promise library
/// @dev Flow: (Chain A) swap -> bridge(burn) -> (Chain B) bridge(mint) -> swap
contract CrossChainSwapExampleTest is Test, Relayer {
    // Promise system contracts (deployed on both chains)
    Promise public promiseA;
    Promise public promiseB;
    Callback public callbackA;
    Callback public callbackB;
    
    // Application contracts
    MockExchange public exchangeA;
    MockExchange public exchangeB;
    PromiseBridge public bridgeA;
    PromiseBridge public bridgeB;
    
    // Test tokens (same addresses on both chains)
    MockSuperchainERC20 public token1; // Starting token (e.g., ETH)
    MockSuperchainERC20 public token2; // Bridge token (e.g., USDC) 
    MockSuperchainERC20 public token3; // Target token (e.g., OP)
    
    // Test participants
    address public user;
    address public liquidityProvider;
    
    // Test state tracking
    uint256 public initialToken1Balance;
    uint256 public initialToken3Balance;
    uint256 public swapAmount = 100 ether;

    string[] private rpcUrls = [
        vm.envOr("CHAIN_A_RPC_URL", string("https://interop-alpha-0.optimism.io")),
        vm.envOr("CHAIN_B_RPC_URL", string("https://interop-alpha-1.optimism.io"))
    ];

    constructor() Relayer(rpcUrls) {}

    function setUp() public {
        user = makeAddr("user");
        liquidityProvider = makeAddr("liquidityProvider");
        
        // Deploy promise system contracts using CREATE2 for same addresses
        vm.selectFork(forkIds[0]);
        promiseA = new Promise{salt: bytes32(0)}(
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        callbackA = new Callback{salt: bytes32(0)}(
            address(promiseA),
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        
        vm.selectFork(forkIds[1]);
        promiseB = new Promise{salt: bytes32(0)}(
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        callbackB = new Callback{salt: bytes32(0)}(
            address(promiseB),
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        
        // Verify same addresses
        require(address(promiseA) == address(promiseB), "Promise contracts must have same address");
        require(address(callbackA) == address(callbackB), "Callback contracts must have same address");
        
        // Deploy application contracts
        vm.selectFork(forkIds[0]);
        exchangeA = new MockExchange{salt: bytes32(0)}();
        bridgeA = new PromiseBridge{salt: bytes32(0)}(address(promiseA), address(callbackA));
        
        vm.selectFork(forkIds[1]);
        exchangeB = new MockExchange{salt: bytes32(0)}();
        bridgeB = new PromiseBridge{salt: bytes32(0)}(address(promiseB), address(callbackB));
        
        // Create tokens with large initial supply for testing and bridges as authorized minters
        vm.selectFork(forkIds[0]);
        token1 = new MockSuperchainERC20{salt: bytes32(0)}("Token1", "TK1", 100000 ether, address(bridgeA));
        token2 = new MockSuperchainERC20{salt: bytes32(0)}("Token2", "TK2", 100000 ether, address(bridgeA));
        token3 = new MockSuperchainERC20{salt: bytes32(0)}("Token3", "TK3", 100000 ether, address(bridgeA));
        
        vm.selectFork(forkIds[1]);
        // Deploy tokens with same addresses and bridge B as minter
        MockSuperchainERC20 token1B = new MockSuperchainERC20{salt: bytes32(0)}("Token1", "TK1", 100000 ether, address(bridgeB));
        MockSuperchainERC20 token2B = new MockSuperchainERC20{salt: bytes32(0)}("Token2", "TK2", 100000 ether, address(bridgeB));
        MockSuperchainERC20 token3B = new MockSuperchainERC20{salt: bytes32(0)}("Token3", "TK3", 100000 ether, address(bridgeB));
        
        // Verify same addresses
        require(address(token1) == address(token1B), "Token1 must have same address");
        require(address(token2) == address(token2B), "Token2 must have same address");
        require(address(token3) == address(token3B), "Token3 must have same address");
        
        // Set up initial token distribution and exchange liquidity
        setupTokensAndLiquidity();
        
        // Store initial balances
        vm.selectFork(forkIds[0]);
        initialToken1Balance = token1.balanceOf(user);
        initialToken3Balance = token3.balanceOf(user);
    }
    
    function setupTokensAndLiquidity() internal {
        // Chain A setup
        vm.selectFork(forkIds[0]);
        
        // Transfer initial tokens from test contract (which has 100k of each token)
        token1.transfer(user, 1000 ether);              // User starts with Token1 on Chain A
        token2.transfer(liquidityProvider, 20000 ether); // LP gets Token2 for both chains
        token1.transfer(liquidityProvider, 10000 ether); // LP gets Token1 for exchange
        
        // Setup Chain A exchange (Token1 <-> Token2)
        vm.startPrank(liquidityProvider);
        token1.approve(address(exchangeA), 5000 ether);
        token2.approve(address(exchangeA), 5000 ether);
        exchangeA.provideLiquidity(address(token1), 5000 ether);
        exchangeA.provideLiquidity(address(token2), 5000 ether);
        exchangeA.addPair(address(token1), address(token2), 10000); // 1:1 rate
        exchangeA.addPair(address(token2), address(token1), 10000); // Reverse pair for rollback
        vm.stopPrank();
        
        // Chain B setup  
        vm.selectFork(forkIds[1]);
        
        // Transfer tokens for Chain B from test contract (which has 100k of each token)
        token3.transfer(liquidityProvider, 10000 ether); // LP gets Token3 for exchange
        token2.transfer(liquidityProvider, 5000 ether);  // LP gets Token2 for Chain B exchange
        
        // Setup Chain B exchange (Token2 <-> Token3)
        vm.startPrank(liquidityProvider);
        token2.approve(address(exchangeB), 5000 ether);
        token3.approve(address(exchangeB), 5000 ether);
        exchangeB.provideLiquidity(address(token2), 5000 ether);
        exchangeB.provideLiquidity(address(token3), 5000 ether);
        exchangeB.addPair(address(token2), address(token3), 10000); // 1:1 rate
        vm.stopPrank();
    }

    /// @notice Test successful cross-chain swap flow
    /// @dev Flow: Token1 -> Token2 (Chain A) -> Bridge -> Token2 (Chain B) -> Token3  
    function test_CrossChainSwap_Success() public {
        vm.selectFork(forkIds[0]);
        
        console.log("=== Testing Successful Cross-Chain Swap ===");
        console.log("Flow: Token1 -> Token2 (Chain A) -> Bridge -> Token2 (Chain B) -> Token3");
        
        vm.startPrank(user);
        
        // Step 1: Swap Token1 for Token2 on Chain A
        console.log("Step 1: Swapping Token1 for Token2 on Chain A");
        token1.approve(address(exchangeA), swapAmount);
        uint256 token2Amount = exchangeA.swap(address(token1), address(token2), swapAmount);
        assertEq(token2Amount, swapAmount, "Should receive equal amount of Token2");
        assertEq(token2.balanceOf(user), swapAmount, "User should have Token2");
        console.log("Swapped Token1 for Token2");
        
        // Step 2: Bridge Token2 from Chain A to Chain B
        console.log("Step 2: Bridging Token2 from Chain A to Chain B");
        token2.approve(address(bridgeA), token2Amount);
        (uint256 bridgePromiseId, uint256 bridgeCallbackId) = bridgeA.bridgeTokens(
            address(token2),
            token2Amount,
            chainIdByForkId[forkIds[1]], // Destination: Chain B
            user                        // Recipient: same user
        );
        console.log("Bridge promise created");
        
        vm.stopPrank();
        
        // Step 3: Process cross-chain bridge messages
        console.log("Step 3: Processing cross-chain bridge messages");
        relayAllMessages();
        console.log("Bridge messages relayed");
        
        // Step 3b: Execute cross-chain callback on Chain B to mint tokens
        console.log("Step 3b: Executing cross-chain callback on Chain B");
        vm.selectFork(forkIds[1]);
        
        // Check if callback exists and is resolvable
        assertTrue(callbackB.exists(bridgeCallbackId), "Bridge callback should exist on Chain B");
        
        if (callbackB.canResolve(bridgeCallbackId)) {
            console.log("Executing bridge callback to mint tokens");
            callbackB.resolve(bridgeCallbackId);
            console.log("Bridge callback executed successfully");
        } else {
            console.log("Bridge callback is not yet resolvable");
            // Check if parent promise exists and its status
            if (promiseB.exists(bridgePromiseId)) {
                console.log("Parent promise exists on Chain B");
                uint8 status = uint8(promiseB.status(bridgePromiseId));
                console.log("Parent promise status:", status);
            } else {
                console.log("Parent promise does not exist on Chain B");
            }
        }
        
        // Verify bridge mint on Chain B
        assertEq(token2.balanceOf(user), token2Amount, "User should have Token2 on Chain B");
        console.log("Bridge completed - user has Token2 on Chain B");
        
        // Step 4: Swap Token2 for Token3 on Chain B
        console.log("Step 4: Swapping Token2 for Token3 on Chain B");
        vm.startPrank(user);
        token2.approve(address(exchangeB), token2Amount);
        uint256 token3Amount = exchangeB.swap(address(token2), address(token3), token2Amount);
        assertEq(token3Amount, token2Amount, "Should receive equal amount of Token3");
        assertEq(token3.balanceOf(user), token3Amount, "User should have Token3");
        console.log("Swapped Token2 for Token3");
        vm.stopPrank();
        
        // Step 5: Verify final state
        console.log("Step 5: Verifying final state");
        vm.selectFork(forkIds[0]);
        assertEq(token1.balanceOf(user), initialToken1Balance - swapAmount, "Token1 balance should be reduced");
        
        vm.selectFork(forkIds[1]);
        assertEq(token3.balanceOf(user), initialToken3Balance + token3Amount, "Token3 balance should be increased");
        
        console.log("SUCCESS: Cross-chain swap completed!");
        console.log("Cross-chain swap completed successfully");
    }

    /// @notice Test cross-chain swap with failure on second swap and rollback
    /// @dev Tests failure handling when Token2 -> Token3 swap fails on Chain B
    function test_CrossChainSwap_FailureAndRollback() public {
        vm.selectFork(forkIds[0]);
        
        console.log("=== Testing Cross-Chain Swap with Failure and Rollback ===");
        console.log("Will fail the second swap and demonstrate rollback");
        
        vm.startPrank(user);
        
        // Step 1: Successful swap on Chain A (Token1 -> Token2)
        console.log("Step 1: Swapping Token1 for Token2 on Chain A");
        token1.approve(address(exchangeA), swapAmount);
        uint256 token2Amount = exchangeA.swap(address(token1), address(token2), swapAmount);
        console.log("Swapped Token1 for Token2");
        
        // Step 2: Bridge Token2 to Chain B
        console.log("Step 2: Bridging Token2 to Chain B");
        token2.approve(address(bridgeA), token2Amount);
        (uint256 bridgePromiseId, uint256 bridgeCallbackId) = bridgeA.bridgeTokens(
            address(token2),
            token2Amount,
            chainIdByForkId[forkIds[1]],
            user
        );
        
        vm.stopPrank();
        
        // Step 3: Process bridge
        console.log("Step 3: Processing bridge");
        relayAllMessages();
        
        // Step 3b: Execute bridge callback on Chain B
        vm.selectFork(forkIds[1]);
        if (callbackB.exists(bridgeCallbackId) && callbackB.canResolve(bridgeCallbackId)) {
            callbackB.resolve(bridgeCallbackId);
        }
        
        // Verify Token2 is on Chain B
        assertEq(token2.balanceOf(user), token2Amount, "User should have Token2 on Chain B");
        console.log("Bridge completed successfully");
        
        // Step 4: Set up failure for Token2 -> Token3 swap on Chain B
        console.log("Step 4: Setting up failure mode for Token2 -> Token3 swap");
        exchangeB.setFailureMode(address(token2), address(token3), true);
        
        // Step 5: Attempt swap that will fail
        console.log("Step 5: Attempting swap that will fail");
        vm.startPrank(user);
        token2.approve(address(exchangeB), token2Amount);
        
        vm.expectRevert(
            abi.encodeWithSignature("SwapFailedError(string)", "Forced failure for testing")
        );
        exchangeB.swap(address(token2), address(token3), token2Amount);
        vm.stopPrank();
        
        console.log("Swap failed as expected");
        
        // Step 6: Demonstrate rollback - bridge Token2 back to Chain A
        console.log("Step 6: Initiating rollback - bridging Token2 back to Chain A");
        vm.startPrank(user);
        token2.approve(address(bridgeB), token2Amount);
        (uint256 rollbackPromiseId, uint256 rollbackCallbackId) = bridgeB.bridgeTokens(
            address(token2),
            token2Amount,
            chainIdByForkId[forkIds[0]], // Back to Chain A
            user
        );
        vm.stopPrank();
        
        // Step 7: Process rollback bridge
        console.log("Step 7: Processing rollback bridge");
        relayAllMessages();
        
        // Step 7b: Execute rollback callback on Chain A
        vm.selectFork(forkIds[0]);
        if (callbackA.exists(rollbackCallbackId) && callbackA.canResolve(rollbackCallbackId)) {
            callbackA.resolve(rollbackCallbackId);
        }
        
        // Step 8: Verify rollback - swap Token2 back to Token1 on Chain A
        console.log("Step 8: Swapping Token2 back to Token1 on Chain A");
        assertEq(token2.balanceOf(user), token2Amount, "User should have Token2 back on Chain A");
        
        vm.startPrank(user);
        token2.approve(address(exchangeA), token2Amount);
        uint256 recoveredToken1 = exchangeA.swap(address(token2), address(token1), token2Amount);
        vm.stopPrank();
        
        // Step 9: Verify final state after rollback
        console.log("Step 9: Verifying rollback completion");
        assertEq(token1.balanceOf(user), initialToken1Balance, "Token1 balance should be restored");
        
        vm.selectFork(forkIds[1]);
        assertEq(token3.balanceOf(user), initialToken3Balance, "Token3 balance should be unchanged");
        
        console.log("SUCCESS: Rollback completed!");
        console.log("User recovered Token1 after failed cross-chain swap");
    }

    /// @notice Test promise-based automated rollback workflow
    /// @dev Demonstrates using promise callbacks for automatic failure handling
    function test_PromiseBasedAutomaticRollback() public {
        vm.selectFork(forkIds[0]);
        
        console.log("=== Testing Promise-Based Automatic Rollback ===");
        console.log("Using promise callbacks for automated failure handling");
        
        // Create a comprehensive workflow promise
        uint256 workflowPromiseId = promiseA.create();
        
        // Set up failure detection callback that triggers rollback
        uint256 rollbackCallbackId = callbackA.onReject(
            workflowPromiseId,
            address(this),
            this.executeAutomaticRollback.selector
        );
        
        vm.startPrank(user);
        
        // Execute the initial operations
        token1.approve(address(exchangeA), swapAmount);
        uint256 token2Amount = exchangeA.swap(address(token1), address(token2), swapAmount);
        
        token2.approve(address(bridgeA), token2Amount);
        (uint256 bridgePromiseId, uint256 bridgeCallbackId) = bridgeA.bridgeTokens(
            address(token2),
            token2Amount,
            chainIdByForkId[forkIds[1]],
            user
        );
        
        vm.stopPrank();
        
        // Process bridge
        relayAllMessages();
        
        // Set up failure mode on Chain B
        vm.selectFork(forkIds[1]);
        exchangeB.setFailureMode(address(token2), address(token3), true);
        
        // Simulate workflow completion attempt
        vm.selectFork(forkIds[0]);
        
        // In a real implementation, this would be triggered by the second swap failure
        // For this demo, we manually reject the workflow promise to trigger rollback
        promiseA.reject(workflowPromiseId, abi.encode("Second swap failed"));
        
        // Execute the rollback callback
        if (callbackA.canResolve(rollbackCallbackId)) {
            callbackA.resolve(rollbackCallbackId);
        }
        
        console.log("Promise-based rollback mechanism demonstrated");
        console.log("In production, this would automatically trigger when second swap fails");
    }

    /// @notice Callback function for automatic rollback execution
    /// @param errorData Error data from failed workflow
    /// @return success Whether rollback was successful
    function executeAutomaticRollback(bytes memory errorData) external returns (bool success) {
        console.log("Executing automatic rollback due to workflow failure");
        string memory error = abi.decode(errorData, (string));
        console.log("Failure occurred during cross-chain workflow");
        
        // In a real implementation, this would:
        // 1. Detect the failure point
        // 2. Initiate reverse operations
        // 3. Return tokens to original state
        
        return true;
    }
} 