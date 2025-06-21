# Cross-Chain Swap Examples

**EXPERIMENTAL CODE**

This directory contains experimental examples that demonstrate cross-chain swap workflows using the promise library. These examples are not as thoroughly vetted as the core tests in the repository and should be considered proof-of-concept implementations. Use for educational and development purposes only.

## Overview

This example suite demonstrates a complete cross-chain swap workflow using the interop promise library with proper promise chain setup. The implementation showcases:

- Upfront promise chain construction before any execution
- Real promise chaining from operations like `bridgeTokens()`
- Automatic success/failure branching using revert-based callbacks
- Cross-chain token bridging using promise-based callbacks
- Exchange interactions with configurable failure modes
- Real SuperchainERC20 token implementations
- End-to-end cross-chain swap orchestration with automatic rollback

## Promise Chain Architecture

The examples demonstrate the correct way to structure promise-based workflows:

### Phase 1: Setup (Promise Chain Construction)
- Build complete promise chain upfront using real operations
- Chain promises returned from actual functions like `bridgeTokens()`
- Register all callbacks (success, failure, cross-chain) before execution
- Single setup creates entire workflow coordination with rollback handling

### Phase 2: Execution (Resolution & Relays)
- Simply resolve promises and relay cross-chain messages
- Promise chain automatically handles branching logic via reverts
- Same infrastructure gracefully handles both success and failure paths

### Phase 3: Verification (Results)
- Verify final state based on execution path taken
- Success path: tokens swapped cross-chain as expected
- Failure path: automatic rollback initiated successfully

## Architecture

The example consists of three main components:

### Core Contracts

1. **MockSuperchainERC20** - Implementation of ISuperchainERC20 interface with cross-chain mint/burn capabilities
2. **MockExchange** - Simple 1:1 token exchange with configurable failure modes
3. **PromiseBridge** - Cross-chain token bridge using promise library for coordination

### Test Scenarios (3 Tests - All Passing)

1. `test_CrossChainSwap_Success` - Shows promise chain with successful execution path
2. `test_CrossChainSwap_FailureAndRollback` - Same promise chain but with failure detection and automatic rollback
3. `test_PromiseBasedAutomaticRollback` - Shows promise-based error handling with `catchError()` callbacks

**Key Design**: All tests use the same promise chain infrastructure but test different execution branches (success vs failure vs automatic recovery).

## Test Results Summary

**All Example Tests Passing: 23/23**

| Test Suite | Tests | Status |
|------------|--------|---------|
| CrossChainSwapExampleTest | 3/3 | All Passing |
| MockExchangeTest | 11/11 | All Passing |  
| MockSuperchainERC20Test | 9/9 | All Passing |
| **Total** | **23/23** | **All Passing** |

```bash
# Run all examples  
forge test --match-path "test/examples/*" -v
```

## Detailed Tutorial: End-to-End Cross-Chain Swap

This tutorial walks through the `test_CrossChainSwap_Success()` test, explaining each step of the cross-chain swap process and the promise chain methodology.

### Setup Phase

The test begins with a multi-chain setup deploying contracts on two chains (Chain A and Chain B):

```solidity
// Promise system contracts deployed with identical addresses on both chains
promiseA = new Promise{salt: bytes32(0)}(PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER);
callbackA = new Callback{salt: bytes32(0)}(address(promiseA), PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER);

// Application contracts
exchangeA = new MockExchange{salt: bytes32(0)}();
bridgeA = new PromiseBridge{salt: bytes32(0)}(address(promiseA), address(callbackA));

// Tokens with initial supply and bridge as authorized minter
token1 = new MockSuperchainERC20{salt: bytes32(0)}("Token1", "TK1", 100000 ether, address(bridgeA));
```

**Key Setup Details:**
- All contracts use CREATE2 with salt `bytes32(0)` to ensure identical addresses across chains
- Tokens are created with large initial supply allocated to the test contract
- Bridge contracts are set as authorized minters for cross-chain operations
- Exchange pairs are configured with 1:1 swap rates and sufficient liquidity

### Phase 1: Promise Chain Setup

```solidity
// PHASE 1: SETTING UP COMPLETE PROMISE CHAIN
// Building promise chain using REAL operations that return promises

vm.selectFork(forkIds[0]);
vm.startPrank(user);

// Pre-approve tokens for the entire workflow
token1.approve(address(exchangeA), swapAmount);
token2.approve(address(bridgeA), swapAmount);

// CHAIN CONSTRUCTION: Each operation returns a promise, chain the next operation to it
console.log("SETUP: Executing initial swap Token1 -> Token2");
uint256 token2Amount = exchangeA.swap(address(token1), address(token2), swapAmount);

console.log("SETUP: Executing bridge operation");  
(uint256 bridgePromiseId, uint256 bridgeCallbackId) = bridgeA.bridgeTokens(
    address(token2),
    token2Amount,
    chainIdByForkId[forkIds[1]], // Chain B
    user
);

// CHAINING: Register callback that chains to bridge completion
console.log("SETUP: Chaining final swap with failure handling");
uint256 finalSwapCallbackId = callbackA.thenOn(
    chainIdByForkId[forkIds[1]], // Execute on Chain B  
    bridgePromiseId,            // When bridge promise resolves
    address(this),              // Call back to this contract
    this.executeFinalSwapWithBranching.selector // Smart callback with branching
);

// CATCH: Register rollback for final swap failures (bridge tokens back)
console.log("SETUP: Chaining bridge-back for final swap failures");
        uint256 bridgeBackCallbackId = callbackA.catchErrorOn(
            chainIdByForkId[forkIds[1]], // Execute on Chain B
            finalSwapCallbackId,        // If final swap fails
            address(this),              // Call back to this contract
            this.bridgeTokensBack.selector // Bridge tokens back to Chain A
        );

vm.stopPrank();
console.log("PROMISE CHAIN SETUP COMPLETE WITH ROLLBACK HANDLING!");
```

**What Happens in Setup:**
- Step 1: Perform initial swap (Token1 → Token2) 
- Step 2: Execute bridge operation, get back promise ID
- Step 3: Chain final swap callback to bridge promise completion
- Step 4: Register bridge-back callback using `catchErrorOn()` for final swap failures
- **Result**: Complete workflow with automatic rollback defined before any cross-chain execution

**Rollback Chain Architecture:**
```
Success Path:   Token1 → Token2 → Bridge → Token2 (Chain B) → Token3
Failure Path:   Token1 → Token2 → Bridge → Token2 (Chain B) → [SWAP FAILS]
                                                                    ↓
Recovery Chain: Token2 (Chain B) → Bridge Back → Token2 (Chain A)
```

### Phase 2: Execution (Resolve & Relay)

```solidity
// PHASE 2: EXECUTING WORKFLOW VIA PROMISE RESOLUTION
// Now we just resolve promises and relay - the chain handles the rest

console.log("EXECUTION: Relaying cross-chain messages");
relayAllMessages();

console.log("EXECUTION: Executing bridge callback on Chain B");
vm.selectFork(forkIds[1]);
if (callbackB.canResolve(bridgeCallbackId)) {
    callbackB.resolve(bridgeCallbackId);
    console.log("Bridge callback executed - tokens minted on Chain B");
}

console.log("EXECUTION: Executing final swap callback");
if (callbackB.canResolve(finalSwapCallbackId)) {
    callbackB.resolve(finalSwapCallbackId);
    console.log("Final swap callback executed");
}
```

**What Happens:**
- Cross-chain messages are relayed automatically
- Bridge callback executes, minting tokens on Chain B  
- Final swap callback executes with automatic success/failure branching
- Promise chain gracefully handles both success and failure scenarios

### Phase 3: Verification (Results)

```solidity
// PHASE 3: VERIFYING RESULTS

vm.selectFork(forkIds[0]);
uint256 finalToken1Balance = token1.balanceOf(user);
console.log("Chain A - Token1 balance change:", int256(finalToken1Balance) - int256(initialToken1Balance));

vm.selectFork(forkIds[1]);
uint256 finalToken3Balance = token3.balanceOf(user);
console.log("Chain B - Token3 balance change:", int256(finalToken3Balance) - int256(initialToken3Balance));

// Verify success path
assertEq(finalToken1Balance, initialToken1Balance - swapAmount, "Token1 should be reduced");
assertGt(finalToken3Balance, initialToken3Balance, "Token3 should be increased");
```

**What Happens:**
- Test verifies the complete workflow succeeded
- User's Token1 balance decreased on Chain A (initial swap)
- User's Token3 balance increased on Chain B (final swap)
- Complete cross-chain workflow executed successfully

## Technical Implementation Details

### Promise Chain Callback Pattern

The key innovation is using **revert-based callbacks** to trigger automatic rollback:

```solidity
/// @notice Execute final swap with automatic success/failure branching
function executeFinalSwapWithBranching(bytes memory bridgeData) external returns (bytes memory swapResult) {
    console.log("CALLBACK: Executing final swap with automatic branching");
    
    uint256 token2Amount = swapAmount;
    uint256 actualBalance = token2.balanceOf(user);
    console.log("User Token2 balance on Chain B:", actualBalance);
    
    // Check if failure mode is enabled (determines success vs failure path)
    if (exchangeB.isFailureModeEnabled(address(token2), address(token3))) {
        console.log("BRANCHING: Failure mode detected - swap will fail");
        // REVERT to trigger the catch codepath (catchErrorOn callback)
        revert("Swap failed due to failure mode");
    } else {
        console.log("BRANCHING: Success path - executing swap");
        
        // Execute the successful swap
        vm.startPrank(user);
        token2.approve(address(exchangeB), token2Amount);
        
        uint256 token3Amount = exchangeB.swap(address(token2), address(token3), token2Amount);
        vm.stopPrank();
        
        console.log("SUCCESS: Final swap completed, received", token3Amount, "Token3");
        return abi.encode(true, token3Amount, "Swap completed successfully");
    }
}
```

**Critical Pattern**: Callbacks that should trigger `catchErrorOn()` must **revert**, not return error data.

### Automatic Rollback Implementation

When the final swap fails, the automatic rollback is triggered:

```solidity
/// @notice Bridge tokens back to Chain A (automatic rollback)
function bridgeTokensBack(bytes memory failureData) external returns (bytes memory rollbackResult) {
    console.log("ROLLBACK: Final swap failed, bridging tokens back to Chain A");
    
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
    
    // User should still have Token2 on Chain B since swap failed
    uint256 token2Balance = token2.balanceOf(user);
    console.log("ROLLBACK: User has", token2Balance, "Token2 on Chain B to bridge back");
    
    if (token2Balance > 0) {
        // Execute reverse bridge operation
        vm.startPrank(user);
        token2.approve(address(bridgeB), token2Balance);
        
        (uint256 rollbackPromiseId, uint256 rollbackCallbackId) = bridgeB.bridgeTokens(
            address(token2),
            token2Balance,
            chainIdByForkId[forkIds[0]], // Back to Chain A
            user                        // Original user
        );
        vm.stopPrank();
        
        console.log("ROLLBACK: Tokens bridged back, promise ID:", rollbackPromiseId);
        return abi.encode(true, rollbackPromiseId, "Tokens bridged back to Chain A");
    } else {
        console.log("ROLLBACK: No tokens to bridge back");
        return abi.encode(false, uint256(0), "No tokens available for rollback");
    }
}
```

**Key Technical Details:**
- Solidity `revert(string)` encoding uses selector `0x08c379a0` + ABI-encoded string
- Rollback function properly decodes the Error(string) format
- Bridge-back creates new async promises requiring separate resolution
- Test verifies tokens are burned on Chain B (rollback initiated) vs full completion

### Failure Test: Automatic Rollback Chain

The `test_CrossChainSwap_FailureAndRollback()` test demonstrates the same promise chain but with automatic failure handling:

```solidity
// Same promise chain setup as success test
vm.selectFork(forkIds[1]);
exchangeB.setFailureMode(address(token2), address(token3), true); // Enable failure mode

// IDENTICAL promise chain construction...
uint256 finalSwapCallbackId = callbackA.thenOn(chainB, bridgePromiseId, address(this), this.executeFinalSwapWithBranching.selector);
uint256 bridgeBackCallbackId = callbackA.catchErrorOn(chainB, finalSwapCallbackId, address(this), this.bridgeTokensBack.selector);

// EXECUTION: Same process, different outcome
relayAllMessages();
callbackB.resolve(bridgeCallbackId);    // Bridge succeeds
callbackB.resolve(finalSwapCallbackId); // Swap FAILS (reverts)
callbackB.resolve(bridgeBackCallbackId); // Rollback executes automatically
relayAllMessages(); // Process rollback messages

// VERIFICATION: Rollback initiated successfully
assertEq(finalToken3Balance, initialToken3Balance, "Token3 balance unchanged (no successful swap)");
assertEq(token2BalanceChainB, 0, "Token2 burned on Chain B for bridge-back");
console.log("ROLLBACK VERIFICATION: Bridge-back was initiated successfully");
```

**What This Demonstrates:**
- Same promise chain infrastructure handles both success and failure
- Failure mode is determined by execution context, not chain structure  
- Automatic rollback triggers when callbacks revert
- Test verifies rollback initiation (tokens burned) vs full completion

## Complete Flow Summary

```
SUCCESS PATH:
Chain A                          Chain B
┌─────────────┐                 ┌─────────────┐
│ Token1      │                 │             │
│     ↓       │                 │             │
│ Token2      │  Bridge Promise │             │
│     ↓       │ ──────────────→ │ Token2      │
│ (burned)    │                 │     ↓       │
│             │                 │ Token3      │
└─────────────┘                 └─────────────┘

FAILURE PATH:
Chain A                          Chain B
┌─────────────┐                 ┌─────────────┐
│ Token1      │                 │             │
│     ↓       │                 │             │
│ Token2      │  Bridge Promise │             │
│     ↓       │ ──────────────→ │ Token2      │
│ (burned)    │                 │     ↓       │
│             │ ←────────────── │ [SWAP FAILS]│
│             │  Rollback Promise│     ↓       │
│             │                 │ (bridged    │
│             │                 │  back)      │
└─────────────┘                 └─────────────┘
```

## Promise Library Integration Details

### Bridge Implementation

```solidity
function bridgeTokens(address token, uint256 amount, uint256 destinationChain, address recipient) 
    external returns (uint256 promiseId, uint256 callbackPromiseId) {
    
    // Create promise for this bridge operation
    promiseId = promiseContract.create();
    
    // Burn tokens on source chain
    IERC20(token).transferFrom(msg.sender, address(this), amount);
    IERC7802(token).crosschainBurn(address(this), amount);
    
    // Register cross-chain callback for destination minting
    callbackPromiseId = callbackContract.thenOn(
        destinationChain,
        promiseId,
        address(this),
        this.mintTokensCallback.selector
    );
    
    // Resolve promise and share to destination
    bytes memory bridgeData = abi.encode(token, recipient, amount, block.chainid);
    promiseContract.resolve(promiseId, bridgeData);
    promiseContract.shareResolvedPromise(destinationChain, promiseId);
}
```

### Cross-Chain Callback Registration

```solidity
// Register success callback (thenOn)
uint256 successCallbackId = callbackA.thenOn(
    chainB,                    // Execute on destination chain
    bridgePromiseId,          // When bridge promise resolves
    address(this),            // Target contract
    this.finalSwap.selector   // Function to call
);

// Register failure callback (catchErrorOn)
uint256 failureCallbackId = callbackA.catchErrorOn(
    chainB,                   // Execute on same chain as failed callback
    successCallbackId,        // If success callback fails
    address(this),            // Target contract  
    this.bridgeBack.selector  // Rollback function to call
);
```

### Authorization Model

The system maintains proper authorization throughout:

- **Bridge Authorization**: Bridge contracts are authorized minters for tokens
- **Callback Authorization**: Only the callback contract can execute bridge callbacks
- **Token Authorization**: Tokens verify the caller is an authorized minter before minting

## Running the Tests

Execute the complete test suite:

```bash
# Run all example tests
forge test --match-path "test/examples/*" -v

# Run specific test scenarios
forge test --match-test "test_CrossChainSwap_Success" -vv
forge test --match-test "test_CrossChainSwap_FailureAndRollback" -vv  
forge test --match-test "test_PromiseBasedAutomaticRollback" -vv

# Run unit tests for utility contracts
forge test --match-path "test/examples/utils/tests/*.sol" -v
```

## Implementation Notes

### Test Environment

- Uses two fork environments to simulate separate blockchains
- Leverages CREATE2 for deterministic contract addresses across chains
- Employs test harness (`Relayer`) for cross-chain message simulation

### Revert-Based Failure Handling

- Callbacks that should trigger `catchErrorOn()` must **revert**, not return error data
- Solidity `revert(string)` uses Error(string) encoding: `0x08c379a0` + ABI-encoded string
- Rollback functions receive and decode the revert data for debugging/logging

### Promise Chain Methodology

- **Phase 1**: Build complete promise chain upfront using real operations
- **Phase 2**: Execute via promise resolution and message relay  
- **Phase 3**: Verify results based on execution path (success vs rollback)
- Same promise infrastructure gracefully handles both success and failure scenarios

## Limitations and Considerations

1. **Experimental Status**: These examples are proof-of-concept implementations
2. **Simplified Economics**: Uses 1:1 swap rates and simplified fee models
3. **Test Environment**: Relies on test harness for cross-chain message simulation
4. **Manual Callback Execution**: Requires explicit callback execution in current implementation
5. **Authorization Model**: Uses simplified authorization scheme suitable for testing
6. **Rollback Verification**: Tests verify rollback initiation, not full completion (requires additional async steps)

## Future Enhancements

Potential improvements for production use:

- Automated callback execution with economic incentives
- More sophisticated fee and slippage models  
- Enhanced error handling and recovery mechanisms
- Gas optimization and batching
- Integration with real cross-chain messaging infrastructure
- Complete rollback verification (including callback resolution on origin chain) 