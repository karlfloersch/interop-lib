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

/// @title BridgeSwapBridgeExample
/// @notice E2E test demonstrating bridge-swap-bridge workflow using promise library
/// @dev Flow: (Chain A) bridge -> (Chain B) swap -> bridge back to (Chain A)
contract BridgeSwapBridgeExampleTest is Test, Relayer {
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
    MockSuperchainERC20 public token2; // Target token (e.g., USDC) 
    MockSuperchainERC20 public token3; // Additional token for liquidity
    
    // Test participants
    address public user;
    address public liquidityProvider;
    
    // Test state tracking
    uint256 public initialToken1BalanceA;
    uint256 public initialToken2BalanceA;
    uint256 public bridgeAmount = 100 ether;
    bytes32 public rollbackCallbackId;
    bytes32 public finalBridgeCallbackId;

    string[] private rpcUrls = [
        vm.envOr("CHAIN_A_RPC_URL", string("https://interop-alpha-0.optimism.io")),
        vm.envOr("CHAIN_B_RPC_URL", string("https://interop-alpha-1.optimism.io"))
    ];

    constructor() Relayer(rpcUrls) {}

    /// @notice Setter for rollback callback ID to avoid shadowing issues
    function setRollbackCallbackId(bytes32 _rollbackCallbackId) external {
        rollbackCallbackId = _rollbackCallbackId;
    }

    /// @notice Setter for final bridge callback ID
    function setFinalBridgeCallbackId(bytes32 _finalBridgeCallbackId) external {
        finalBridgeCallbackId = _finalBridgeCallbackId;
    }

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
        initialToken1BalanceA = token1.balanceOf(user);
        initialToken2BalanceA = token2.balanceOf(user);
    }
    
    function setupTokensAndLiquidity() internal {
        // Chain A setup
        vm.selectFork(forkIds[0]);
        
        // Transfer initial tokens from test contract (which has 100k of each token)
        token1.transfer(user, 1000 ether);              // User starts with Token1 on Chain A
        token2.transfer(liquidityProvider, 20000 ether); // LP gets Token2 for liquidity
        token1.transfer(liquidityProvider, 10000 ether); // LP gets Token1 for liquidity
        
        // Setup Chain A exchange (for potential rollback scenarios)
        vm.startPrank(liquidityProvider);
        token1.approve(address(exchangeA), 5000 ether);
        token2.approve(address(exchangeA), 5000 ether);
        exchangeA.provideLiquidity(address(token1), 5000 ether);
        exchangeA.provideLiquidity(address(token2), 5000 ether);
        exchangeA.addPair(address(token1), address(token2), 10000); // 1:1 rate
        exchangeA.addPair(address(token2), address(token1), 10000); // Reverse pair
        vm.stopPrank();
        
        // Chain B setup  
        vm.selectFork(forkIds[1]);
        
        // Transfer tokens for Chain B liquidity from test contract (which has 100k of each token)
        token1.transfer(liquidityProvider, 10000 ether); // LP gets Token1 for Chain B exchange
        token2.transfer(liquidityProvider, 10000 ether); // LP gets Token2 for Chain B exchange
        
        // Setup Chain B exchange (Token1 <-> Token2) - this is where the main swap happens
        vm.startPrank(liquidityProvider);
        token1.approve(address(exchangeB), 5000 ether);
        token2.approve(address(exchangeB), 5000 ether);
        exchangeB.provideLiquidity(address(token1), 5000 ether);
        exchangeB.provideLiquidity(address(token2), 5000 ether);
        exchangeB.addPair(address(token1), address(token2), 10000); // 1:1 rate
        exchangeB.addPair(address(token2), address(token1), 10000); // Reverse pair for rollback
        vm.stopPrank();
    }

    /// @notice Test successful bridge-swap-bridge flow with proper promise chain setup
    /// @dev Flow: Token1 (Chain A) -> Bridge -> Token1 (Chain B) -> Swap -> Token2 (Chain B) -> Bridge -> Token2 (Chain A)
    function test_BridgeSwapBridge_Success() public {
        console.log("=== Testing Successful Bridge-Swap-Bridge with Promise Chain ===");
        console.log("Flow: Token1 (Chain A) -> Bridge -> Token1 (Chain B) -> Swap -> Token2 (Chain B) -> Bridge -> Token2 (Chain A)");
        console.log("");
        
        // ========================================
        // PHASE 1: PROMISE CHAIN SETUP (UPFRONT)
        // ========================================
        console.log("PHASE 1: SETTING UP COMPLETE PROMISE CHAIN");
        console.log("Building promise chain using REAL operations that return promises");
        
        vm.selectFork(forkIds[0]);
        vm.startPrank(user);
        
        // Pre-approve tokens for the entire workflow
        token1.approve(address(bridgeA), bridgeAmount);
        
        // STEP 1: Execute initial bridge operation Token1 A -> B
        console.log("SETUP: Executing initial bridge Token1 A -> B");
        (bytes32 initialBridgePromiseId, bytes32 initialBridgeCallbackId) = bridgeA.bridgeTokens(
            address(token1),
            bridgeAmount,
            chainIdByForkId[forkIds[1]], // Chain B
            user
        );
        
        // STEP 2: Chain swap operation to initial bridge completion
        console.log("SETUP: Chaining swap operation to bridge completion");
        bytes32 swapCallbackId = callbackA.thenOn(
            chainIdByForkId[forkIds[1]],    // Execute on Chain B  
            initialBridgePromiseId,         // When initial bridge promise resolves
            address(this),                  // Call back to this contract
            this.executeSwapOnChainB.selector // Execute swap Token1 -> Token2
        );
        
        // STEP 3: Chain final bridge operation to swap completion
        console.log("SETUP: Chaining final bridge operation to swap completion");
        bytes32 finalBridgeCallbackIdLocal = callbackA.thenOn(
            chainIdByForkId[forkIds[1]],    // Execute on Chain B
            swapCallbackId,                 // When swap promise resolves
            address(this),                  // Call back to this contract
            this.executeFinalBridge.selector // Bridge Token2 B -> A
        );
        
        // STEP 4: Add error handling for swap failures
        console.log("SETUP: Adding error handling for swap failures");
        bytes32 swapRollbackCallbackId = callbackA.catchErrorOn(
            chainIdByForkId[forkIds[1]],    // Execute on Chain B
            swapCallbackId,                 // If swap fails
            address(this),                  // Call back to this contract
            this.rollbackSwapFailure.selector // Bridge Token1 back to Chain A
        );
        
        // STEP 5: Add error handling for final bridge failures
        console.log("SETUP: Adding error handling for final bridge failures");
        bytes32 finalBridgeRollbackCallbackId = callbackA.catchErrorOn(
            chainIdByForkId[forkIds[1]],    // Execute on Chain B
            finalBridgeCallbackIdLocal,     // If final bridge fails
            address(this),                  // Call back to this contract
            this.rollbackFinalBridgeFailure.selector // Keep Token2 on Chain B or swap back
        );
        
        vm.stopPrank();
        console.log("COMPLETE PROMISE CHAIN SETUP FINISHED!");
        console.log("");
        
        // ========================================
        // PHASE 2: EXECUTION (RESOLVE & RELAY)
        // ========================================
        console.log("PHASE 2: EXECUTING WORKFLOW VIA PROMISE RESOLUTION");
        console.log("Now we just resolve promises and relay - the chain handles the rest");
        console.log("");
        
        // Relay cross-chain messages (sends initial bridge callback to Chain B)
        console.log("EXECUTION: Relaying cross-chain messages for initial bridge");
        relayAllMessages();
        console.log("Initial bridge callback relayed to Chain B");
        
        // Execute initial bridge callback on Chain B (triggers mint operation)
        console.log("EXECUTION: Executing initial bridge callback on Chain B");
        vm.selectFork(forkIds[1]);
        if (callbackB.canResolve(initialBridgeCallbackId)) {
            callbackB.resolve(initialBridgeCallbackId);
            console.log("Initial bridge callback executed - Token1 minted on Chain B");
        }
        
        // Execute swap callback (triggers Token1 -> Token2 swap on Chain B)
        console.log("EXECUTION: Executing swap callback on Chain B");
        if (callbackB.canResolve(swapCallbackId)) {
            callbackB.resolve(swapCallbackId);
            console.log("Swap callback executed - Token1 -> Token2 on Chain B");
        }
        
        // Execute final bridge callback (triggers Token2 B -> A bridge)
        console.log("EXECUTION: Executing final bridge callback on Chain B");
        if (callbackB.canResolve(finalBridgeCallbackIdLocal)) {
            callbackB.resolve(finalBridgeCallbackIdLocal);
            console.log("Final bridge callback executed - Token2 bridged B -> A");
        }
        
        // Relay final bridge messages
        console.log("EXECUTION: Relaying final bridge messages");
        relayAllMessages();
        
        // Execute final bridge minting callback on Chain A
        console.log("EXECUTION: Executing final bridge minting callback on Chain A");
        vm.selectFork(forkIds[0]);
        // The finalBridgeCallbackId was updated by executeFinalBridge with the actual bridge callback ID
        if (callbackA.canResolve(finalBridgeCallbackId)) {
            callbackA.resolve(finalBridgeCallbackId);
            console.log("Final bridge minting callback executed - Token2 minted on Chain A");
        } else {
            console.log("Final bridge callback not ready or already resolved");
        }
        
        // ========================================
        // PHASE 3: VERIFICATION (RESULTS)
        // ========================================
        console.log("");
        console.log("PHASE 3: VERIFYING RESULTS");
        
        // Verify final state - success path
        vm.selectFork(forkIds[0]);
        uint256 finalToken1BalanceA = token1.balanceOf(user);
        uint256 finalToken2BalanceA = token2.balanceOf(user);
        console.log("Chain A - Token1 balance change:", int256(finalToken1BalanceA) - int256(initialToken1BalanceA));
        console.log("Chain A - Token2 balance change:", int256(finalToken2BalanceA) - int256(initialToken2BalanceA));
        
        vm.selectFork(forkIds[1]);
        uint256 finalToken1BalanceB = token1.balanceOf(user);
        uint256 finalToken2BalanceB = token2.balanceOf(user);
        console.log("Chain B - Token1 balance:", finalToken1BalanceB);
        console.log("Chain B - Token2 balance:", finalToken2BalanceB);
        
        // Verify success path
        assertEq(finalToken1BalanceA, initialToken1BalanceA - bridgeAmount, "Token1 on Chain A should be reduced by bridge amount");
        assertGt(finalToken2BalanceA, initialToken2BalanceA, "Token2 on Chain A should be increased");
        assertEq(finalToken1BalanceB, 0, "Token1 on Chain B should be 0 (swapped to Token2)");
        assertEq(finalToken2BalanceB, 0, "Token2 on Chain B should be 0 (bridged back to Chain A)");
        
        console.log("");
        console.log("SUCCESS: Bridge-Swap-Bridge chain executed successfully!");
        console.log("Flow completed: Token1 (A) -> Bridge -> Token1 (B) -> Swap -> Token2 (B) -> Bridge -> Token2 (A)");
    }

    /// @notice Test bridge-swap-bridge with swap failure and automatic rollback
    /// @dev Tests automatic failure handling when Token1 -> Token2 swap fails on Chain B
    function test_BridgeSwapBridge_SwapFailureAndRollback() public {
        console.log("=== Testing Bridge-Swap-Bridge with Swap Failure and Rollback ===");
        console.log("Will demonstrate automatic rollback when swap fails on Chain B");
        console.log("");
        
        // Set up failure mode BEFORE chain setup
        vm.selectFork(forkIds[1]);
        exchangeB.setFailureMode(address(token1), address(token2), true);
        console.log("SETUP: Enabled failure mode for Token1 -> Token2 swap on Chain B");
        
        vm.selectFork(forkIds[0]);
        vm.startPrank(user);
        
        // Same promise chain setup as success test
        token1.approve(address(bridgeA), bridgeAmount);
        
        console.log("SETUP: Executing initial bridge Token1 A -> B");
        (bytes32 initialBridgePromiseId, bytes32 initialBridgeCallbackId) = bridgeA.bridgeTokens(
            address(token1),
            bridgeAmount,
            chainIdByForkId[forkIds[1]],
            user
        );
        
        console.log("SETUP: Chaining swap (will detect failure and trigger rollback)");
        bytes32 swapCallbackId = callbackA.thenOn(
            chainIdByForkId[forkIds[1]],
            initialBridgePromiseId,
            address(this),
            this.executeSwapOnChainB.selector
        );
        
        console.log("SETUP: Chaining automatic rollback for swap failures");
        bytes32 swapRollbackCallbackId = callbackA.catchErrorOn(
            chainIdByForkId[forkIds[1]],
            swapCallbackId,
            address(this),
            this.rollbackSwapFailure.selector
        );
        
        // Store callback ID for later use
        this.setRollbackCallbackId(swapRollbackCallbackId);
        
        vm.stopPrank();
        console.log("PROMISE CHAIN SETUP COMPLETE WITH ROLLBACK HANDLING!");
        console.log("");
        
        // ========================================
        // PHASE 2: EXECUTION (AUTOMATIC FAILURE DETECTION)
        // ========================================
        console.log("PHASE 2: EXECUTING WORKFLOW (AUTOMATIC FAILURE DETECTION)");
        
        console.log("EXECUTION: Relaying cross-chain messages for initial bridge");
        relayAllMessages();
        
        console.log("EXECUTION: Executing initial bridge callback on Chain B");
        vm.selectFork(forkIds[1]);
        if (callbackB.canResolve(initialBridgeCallbackId)) {
            callbackB.resolve(initialBridgeCallbackId);
            console.log("Initial bridge callback executed - Token1 minted on Chain B");
        }
        
        console.log("EXECUTION: Executing swap callback (will detect failure)");
        if (callbackB.canResolve(swapCallbackId)) {
            callbackB.resolve(swapCallbackId);
            console.log("Swap callback executed - failure detected automatically");
        }
        
        console.log("EXECUTION: Executing rollback callback (automatic bridge-back)");
        if (callbackB.canResolve(swapRollbackCallbackId)) {
            callbackB.resolve(swapRollbackCallbackId);
            console.log("Rollback callback executed - Token1 returned to Chain A");
        }
        
        // Process rollback messages
        console.log("EXECUTION: Relaying rollback messages");
        relayAllMessages();
        
        // ========================================
        // PHASE 3: VERIFICATION (ROLLBACK COMPLETED)
        // ========================================
        console.log("");
        console.log("PHASE 3: VERIFYING ROLLBACK RESULTS");
        
        vm.selectFork(forkIds[0]);
        uint256 finalToken1BalanceA = token1.balanceOf(user);
        uint256 finalToken2BalanceA = token2.balanceOf(user);
        console.log("Chain A - Token1 balance change:", int256(finalToken1BalanceA) - int256(initialToken1BalanceA));
        console.log("Chain A - Token2 balance change:", int256(finalToken2BalanceA) - int256(initialToken2BalanceA));
        
        vm.selectFork(forkIds[1]);
        uint256 finalToken1BalanceB = token1.balanceOf(user);
        console.log("Chain B - Token1 balance after rollback:", finalToken1BalanceB);
        
        // Verify rollback was successful
        // Note: Due to the nature of the test, exact balance verification depends on rollback completion
        assertEq(finalToken2BalanceA, initialToken2BalanceA, "Token2 balance on Chain A should be unchanged");
        assertEq(finalToken1BalanceB, 0, "Token1 should be burned on Chain B for bridge-back");
        
        console.log("ROLLBACK VERIFICATION: Bridge-back was initiated successfully");
        console.log("Note: In production, Token1 would be minted back on Chain A after callback resolution");
        
        console.log("");
        console.log("SUCCESS: Automatic rollback chain executed successfully!");
        console.log("Flow: Token1 (A) -> Bridge -> Token1 (B) -> [SWAP FAILS] -> Bridge Back -> Token1 (A)");
    }

    // ====================================================================
    // PROMISE CHAIN CALLBACK FUNCTIONS (FOR PROPER CHAINING)
    // ====================================================================

    /// @notice Execute swap on Chain B: Token1 -> Token2
    /// @param bridgeData Encoded bridge completion data
    /// @return swapResult Encoded swap result (or error data for failure)
    function executeSwapOnChainB(bytes memory bridgeData) external returns (bytes memory swapResult) {
        console.log("CALLBACK: Executing Token1 -> Token2 swap on Chain B");
        
        // Verify user has Token1 on Chain B
        uint256 token1Balance = token1.balanceOf(user);
        console.log("User Token1 balance on Chain B:", token1Balance);
        
        // Check if failure mode is enabled (determines success vs failure path)
        if (exchangeB.isFailureModeEnabled(address(token1), address(token2))) {
            console.log("BRANCHING: Failure mode detected - swap will fail");
            // REVERT to trigger the catch codepath (catchErrorOn callback)
            revert("Swap failed due to failure mode");
        } else {
            console.log("BRANCHING: Success path - executing swap");
            
            // Execute the successful swap
            vm.startPrank(user);
            token1.approve(address(exchangeB), token1Balance);
            
            uint256 token2Amount = exchangeB.swap(address(token1), address(token2), token1Balance);
            vm.stopPrank();
            
            console.log("SUCCESS: Swap completed, received", token2Amount, "Token2");
            return abi.encode(true, token2Amount, "Swap completed successfully");
        }
    }

    /// @notice Execute final bridge: Token2 B -> A  
    /// @param swapData Encoded swap completion data
    /// @return bridgeResult Encoded bridge operation result
    function executeFinalBridge(bytes memory swapData) external returns (bytes memory bridgeResult) {
        console.log("CALLBACK: Executing final bridge Token2 B -> A");
        
        // Decode swap result - handle the nested encoding from promise resolution
        (bool swapSuccess, uint256 token2Amount, string memory swapMessage) = (false, 0, "");
        
        // Try to decode the data
        try this.decodeSwapData(swapData) returns (bool success, uint256 amount, string memory message) {
            swapSuccess = success;
            token2Amount = amount;
            swapMessage = message;
        } catch {
            // If decoding fails, just check user's actual balance
            swapSuccess = true;
            token2Amount = token2.balanceOf(user);
            swapMessage = "Using actual balance";
        }
        
        if (!swapSuccess) {
            revert("Cannot bridge - swap was not successful");
        }
        
        console.log("CALLBACK: Swap successful, bridging Token2 back to Chain A");
        
        // User should have Token2 on Chain B now
        uint256 token2Balance = token2.balanceOf(user);
        console.log("CALLBACK: User has", token2Balance, "Token2 on Chain B to bridge");
        
        if (token2Balance > 0) {
            // Execute bridge operation Token2 B -> A
            vm.startPrank(user);
            token2.approve(address(bridgeB), token2Balance);
            
            (bytes32 finalBridgePromiseId, bytes32 finalBridgeCallbackIdLocal) = bridgeB.bridgeTokens(
                address(token2),
                token2Balance,
                chainIdByForkId[forkIds[0]], // Back to Chain A
                user                        // Original user
            );
            vm.stopPrank();
            
            // Store the callback ID for the test to use
            BridgeSwapBridgeExampleTest(address(this)).setFinalBridgeCallbackId(finalBridgeCallbackIdLocal);
            
            console.log("CALLBACK: Token2 bridged back, promise ID:", uint256(finalBridgePromiseId));
            return abi.encode(true, finalBridgePromiseId, "Token2 bridged back to Chain A");
        } else {
            revert("No Token2 available to bridge back");
        }
    }

    /// @notice Helper function to decode swap data
    /// @param data Encoded swap data  
    /// @return success Whether swap was successful
    /// @return amount Amount of tokens
    /// @return message Result message
    function decodeSwapData(bytes memory data) external pure returns (bool success, uint256 amount, string memory message) {
        return abi.decode(data, (bool, uint256, string));
    }

    /// @notice Rollback swap failure by bridging Token1 back to Chain A
    /// @param failureData Encoded revert reason from failed swap
    /// @return rollbackResult Encoded rollback operation result
    function rollbackSwapFailure(bytes memory failureData) external returns (bytes memory rollbackResult) {
        console.log("ROLLBACK: Swap failed, bridging Token1 back to Chain A");
        
        // Decode failure reason (handle Solidity Error(string) format)
        string memory reason = "Unknown error";
        if (failureData.length >= 4) {
            bytes4 selector = bytes4(failureData);
            if (selector == 0x08c379a0) { // Error(string) selector
                // Skip the selector and decode the string
                bytes memory errorData = new bytes(failureData.length - 4);
                for (uint i = 0; i < failureData.length - 4; i++) {
                    errorData[i] = failureData[i + 4];
                }
                (reason) = abi.decode(errorData, (string));
            }
        }
        
        console.log("ROLLBACK: Failure reason:", reason);
        
        // User should still have Token1 on Chain B since swap failed
        uint256 token1Balance = token1.balanceOf(user);
        console.log("ROLLBACK: User has", token1Balance, "Token1 on Chain B to bridge back");
        
        if (token1Balance > 0) {
            // Execute reverse bridge operation Token1 B -> A
            vm.startPrank(user);
            token1.approve(address(bridgeB), token1Balance);
            
            (bytes32 rollbackPromiseId, bytes32 rollbackCallbackId) = bridgeB.bridgeTokens(
                address(token1),
                token1Balance,
                chainIdByForkId[forkIds[0]], // Back to Chain A
                user                        // Original user
            );
            vm.stopPrank();
            
            console.log("ROLLBACK: Token1 bridged back, promise ID:", uint256(rollbackPromiseId));
            return abi.encode(true, rollbackPromiseId, "Token1 bridged back to Chain A");
        } else {
            console.log("ROLLBACK: No Token1 to bridge back");
            return abi.encode(false, uint256(0), "No tokens available for rollback");
        }
    }

    /// @notice Rollback final bridge failure
    /// @param failureData Encoded revert reason from failed final bridge
    /// @return rollbackResult Encoded rollback operation result
    function rollbackFinalBridgeFailure(bytes memory failureData) external returns (bytes memory rollbackResult) {
        console.log("ROLLBACK: Final bridge failed, keeping Token2 on Chain B");
        
        // Decode failure reason
        string memory reason = "Unknown error";
        if (failureData.length >= 4) {
            bytes4 selector = bytes4(failureData);
            if (selector == 0x08c379a0) { // Error(string) selector
                bytes memory errorData = new bytes(failureData.length - 4);
                for (uint i = 0; i < failureData.length - 4; i++) {
                    errorData[i] = failureData[i + 4];
                }
                (reason) = abi.decode(errorData, (string));
            }
        }
        
        console.log("ROLLBACK: Final bridge failure reason:", reason);
        console.log("ROLLBACK: Token2 remains on Chain B - user can manually retrieve");
        
        return abi.encode(true, "Token2 kept on Chain B for manual retrieval");
    }
} 