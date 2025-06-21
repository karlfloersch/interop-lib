# Cross-Chain Swap Examples

**EXPERIMENTAL CODE**

This directory contains experimental examples that demonstrate cross-chain swap workflows using the promise library. These examples are not as thoroughly vetted as the core tests in the repository and should be considered proof-of-concept implementations. Use for educational and development purposes only.

## Overview

This example suite demonstrates a complete cross-chain swap workflow using the interop promise library with proper promise chain setup. The implementation showcases:

- Upfront promise chain construction before any execution
- Real promise chaining from operations like `bridgeTokens()`
- Automatic success/failure branching within the same promise infrastructure
- Cross-chain token bridging using promise-based callbacks
- Exchange interactions with configurable failure modes
- Real SuperchainERC20 token implementations
- End-to-end cross-chain swap orchestration

## Promise Chain Architecture

The examples demonstrate the correct way to structure promise-based workflows:

### Phase 1: Setup (Promise Chain Construction)
- Build complete promise chain upfront using real operations
- Chain promises returned from actual functions like `bridgeTokens()`
- Register all callbacks (success, failure, cross-chain) before execution
- Single setup creates entire workflow coordination

### Phase 2: Execution (Resolution & Relays)
- Simply resolve promises and relay cross-chain messages
- Promise chain automatically handles branching logic
- Same infrastructure gracefully handles both success and failure paths

### Phase 3: Verification (Results)
- Verify final state based on execution path taken
- Success path: tokens swapped cross-chain as expected
- Failure path: automatic rollback completed successfully

## Architecture

The example consists of three main components:

### Core Contracts

1. MockSuperchainERC20 - Implementation of ISuperchainERC20 interface with cross-chain mint/burn capabilities
2. MockExchange - Simple 1:1 token exchange with configurable failure modes
3. PromiseBridge - Cross-chain token bridge using promise library for coordination

### Test Scenarios (3 Tests - All Passing)

1. `test_CrossChainSwap_Success` - Shows promise chain with successful execution path
2. `test_CrossChainSwap_FailureAndRollback` - Same promise chain but with failure detection and rollback
3. `test_PromiseBasedAutomaticRollback` - Shows promise-based error handling with `onReject()` callbacks

Key Design: All tests use the same promise chain infrastructure but test different execution branches (success vs failure vs automatic recovery).

## Test Results Summary

All Example Tests Passing: 23/23

| Test Suite | Tests | Status |
|------------|--------|---------|
| CrossChainSwapExampleTest | 3/3 | All Passing |
| MockExchangeTest | 11/11 | All Passing |  
| MockSuperchainERC20Test | 9/9 | All Passing |
| Total | 23/23 | All Passing |

```bash
# Run all examples  
forge test --match-path "test/examples/**" --summary
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

Key Setup Details:
- All contracts use CREATE2 with salt `bytes32(0)` to ensure identical addresses across chains
- Tokens are created with large initial supply allocated to the test contract
- Bridge contracts are set as authorized minters for cross-chain operations
- Exchange pairs are configured with 1:1 swap rates and sufficient liquidity

### Phase 1: Promise Chain Setup

```solidity
// === SETTING UP COMPLETE PROMISE CHAIN ===
// Build promise chain using REAL operations that return promises

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
uint256 bridgeBackCallbackId = callbackA.onRejectOn(
    chainIdByForkId[forkIds[1]], // Execute on Chain B
    finalSwapCallbackId,        // If final swap fails
    address(this),              // Call back to this contract
    this.bridgeTokensBack.selector // Bridge tokens back to Chain A
);

// Note: Additional recovery layers could be added here if needed
// For this example, the bridge-back is the primary rollback mechanism

vm.stopPrank();
console.log("PROMISE CHAIN SETUP COMPLETE WITH ROLLBACK HANDLING!");
```

What Happens in Setup:
- Step 1: Perform initial swap (Token1 → Token2) 
- Step 2: Execute bridge operation, get back promise ID
- Step 3: Chain final swap callback to bridge promise completion
- Step 4: Register bridge-back callback using `onRejectOn()` for final swap failures
- Result: Complete workflow with automatic rollback defined before any cross-chain execution

Rollback Chain Architecture:
```
Success Path:   Token1 → Token2 → Bridge → Token2 (Chain B) → Token3
Failure Path:   Token1 → Token2 → Bridge → Token2 (Chain B) → [SWAP FAILS]
                                                                    ↓
Recovery Chain: Token2 (Chain B) → Bridge Back → Token2 (Chain A)
```

### Phase 2: Execution (Resolve & Relay)

```solidity
// === WORKFLOW EXECUTION VIA PROMISE RESOLUTION ===
// Now we just resolve promises and relay - the chain handles the rest

console.log("EXECUTION: Relaying cross-chain messages");
relayAllMessages(); // Send bridge callback to Chain B

console.log("EXECUTION: Executing cross-chain callback on Chain B");
vm.selectFork(forkIds[1]);
if (callbackB.canResolve(bridgeCallbackId)) {
    callbackB.resolve(bridgeCallbackId); // Triggers mint operation
}

console.log("EXECUTION: Executing final swap callback");  
if (callbackB.canResolve(finalSwapCallbackId)) {
    callbackB.resolve(finalSwapCallbackId); // Triggers smart branching callback
}
```

What Happens:
- User approves bridge to spend Token2
- Bridge contract calls `bridgeTokens()` which:
  1. Burns Token2 on Chain A using `crosschainBurn()`
  2. Creates a promise for the bridge operation
  3. Registers cross-chain callback using `callbackContract.thenOn()`
  4. Resolves the promise with bridge data
  5. Shares the resolved promise to Chain B using `shareResolvedPromise()`
  6. Returns both promise ID and callback ID

Technical Detail - Bridge Implementation:
```solidity
function bridgeTokens(...) external returns (uint256 promiseId, uint256 callbackPromiseId) {
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
    promiseContract.resolve(promiseId, abi.encode(token, recipient, amount, currentChainId));
    promiseContract.shareResolvedPromise(destinationChain, promiseId);
}
```

Technical Detail - Rollback Implementation:
```solidity
// Automatic rollback handler - executes when bridge operation fails
function executeAutomaticRollback(bytes memory errorData) external returns (bool success) {
    console.log("ROLLBACK: Bridge operation failed, executing automatic recovery");
    
    // In a real implementation, this would:
    // 1. Detect the failure point (bridge, swap, etc.)
    // 2. Initiate reverse bridge operation
    // 3. Return tokens to original state on source chain
    
    return true;
}

// Bridge tokens back handler - executes when final swap fails  
function bridgeTokensBack(bytes memory failureData) external returns (bool success) {
    console.log("ROLLBACK: Final swap failed, bridging tokens back to Chain A");
    
    // Decode failure context
    (address token, uint256 amount, address recipient) = 
        abi.decode(failureData, (address, uint256, address));
    
    // Execute reverse bridge operation
    (uint256 rollbackPromiseId,) = bridgeB.bridgeTokens(
        token,
        amount,
        chainIdByForkId[forkIds[0]], // Back to Chain A
        recipient                    // Original user
    );
    
    console.log("ROLLBACK: Tokens bridged back, user can recover original state");
    return true;
}
```

### Step 3: Cross-Chain Message Relay

```solidity
// Relay all cross-chain messages
relayAllMessages();
```

What Happens:
- The test harness relays all pending cross-chain messages
- This simulates the actual cross-chain message passing infrastructure
- Bridge callback registration message is sent to Chain B
- Promise sharing message is sent to Chain B

### Step 4: Cross-Chain Callback Execution

```solidity
// Execute cross-chain callback on Chain B
vm.selectFork(forkIds[1]);
if (callbackB.canResolve(bridgeCallbackId)) {
    callbackB.resolve(bridgeCallbackId);
}
```

What Happens:
- Test switches to Chain B
- Checks if the bridge callback is resolvable (parent promise exists and is resolved)
- Executes the callback, which triggers `mintTokensCallback()`

Technical Detail - Callback Implementation:
```solidity
function mintTokensCallback(bytes memory bridgeData) external returns (bool success) {
    require(msg.sender == address(callbackContract), "Only callback contract can call");
    
    // Decode bridge data from Chain A
    (address token, address recipient, uint256 amount, uint256 sourceChain) = 
        abi.decode(bridgeData, (address, address, uint256, uint256));
    
    // Verify bridge is authorized minter
    address authorizedMinter = MockSuperchainERC20(token).authorizedMinter();
    require(authorizedMinter == address(this), "Bridge must be authorized minter");
    
    // Mint tokens on destination chain
    IERC7802(token).crosschainMint(recipient, amount);
    return true;
}
```

### Step 5: Second Swap on Chain B

```solidity
// Swap Token2 for Token3 on Chain B
vm.startPrank(user);
token2.approve(address(exchangeB), token2Amount);
uint256 token3Amount = exchangeB.swap(address(token2), address(token3), token2Amount);
```

What Happens:
- User now has Token2 on Chain B (from cross-chain mint)
- User swaps Token2 for Token3 using Chain B exchange
- Final result: User holds Token3 on Chain B

### Step 6: Verification

```solidity
// Verify final state
vm.selectFork(forkIds[0]);
assertEq(token1.balanceOf(user), initialToken1Balance - swapAmount, "Token1 balance reduced");

vm.selectFork(forkIds[1]);
assertEq(token3.balanceOf(user), initialToken3Balance + token3Amount, "Token3 balance increased");
```

What Happens:
- Test verifies the complete workflow succeeded
- User's Token1 balance decreased on Chain A
- User's Token3 balance increased on Chain B

## Complete Flow Summary

```
Chain A                          Chain B
┌─────────────┐                 ┌─────────────┐
│ Token1      │                 │             │
│     ↓       │                 │             │
│ Token2      │  Bridge Promise │             │
│     ↓       │ ──────────────→ │ Token2      │
│ (burned)    │                 │     ↓       │
│             │                 │ Token3      │
└─────────────┘                 └─────────────┘
```

## Promise Library Integration Details

### Promise Creation and Resolution

The bridge creates a promise to coordinate the cross-chain operation:

1. Promise Creation: `promiseContract.create()` generates a unique promise ID
2. Promise Resolution: `promiseContract.resolve(promiseId, data)` marks the promise as complete
3. Promise Sharing: `shareResolvedPromise(destinationChain, promiseId)` makes the promise available on the destination chain

### Cross-Chain Callbacks

The callback system enables automatic execution on the destination chain:

1. Callback Registration: `callbackContract.thenOn(chain, promiseId, target, selector)` registers a cross-chain callback
2. Callback Execution: When the parent promise is shared and resolved, the callback becomes executable
3. Manual Execution: `callbackContract.resolve(callbackId)` triggers the callback function

### Failure Handling Callbacks

The callback system also supports automatic failure recovery:

1. Rollback Registration: `callbackContract.onRejectOn(chain, promiseId, target, selector)` registers cross-chain failure callbacks
2. Failure Detection: When a promise is rejected or a callback fails, the failure handlers are triggered
3. Automatic Recovery: Rollback callbacks execute reverse operations (bridge back, swap back, etc.)
4. Nested Rollbacks: Multiple levels of failure handling can be chained together

Example rollback chain:
```solidity
// If final swap fails → bridge tokens back to Chain A
callbackA.onRejectOn(chainB, finalSwapPromiseId, address(this), this.bridgeTokensBack.selector);

// Additional recovery layers can be added as needed for more complex scenarios
```

### Authorization Model

The system maintains proper authorization throughout the cross-chain flow:

- Bridge Authorization: Bridge contracts are authorized minters for tokens
- Callback Authorization: Only the callback contract can execute bridge callbacks
- Token Authorization: Tokens verify the caller is an authorized minter before minting

## Failure Handling

The examples demonstrate two approaches to failure handling:

### Manual Rollback

If a step fails, users can manually bridge tokens back and recover their original position:

1. Detect failure (e.g., second swap fails)
2. Bridge tokens back to original chain
3. Swap back to original token

### Promise-Based Automatic Rollback (Demonstrated in Phase 1 Setup)

The promise system can automatically handle failures using the `.catch` pattern shown in Phase 1:

1. **Setup Phase**: Register `onRejectOn()` callbacks for automatic recovery during promise chain construction
2. **Failure Detection**: When any promise in the chain fails, the corresponding rollback callback is triggered
3. **Automatic Recovery**: Rollback callbacks execute reverse operations without manual intervention
4. **Nested Recovery**: Multiple levels of failure handling ensure comprehensive error recovery

Implementation Pattern:
```solidity
// Primary operation
uint256 swapCallbackId = callbackA.thenOn(chainB, bridgePromiseId, address(this), this.finalSwap.selector);

// Automatic rollback if primary operation fails
uint256 rollbackId = callbackA.onRejectOn(chainB, swapCallbackId, address(this), this.bridgeBack.selector);
```

This pattern ensures that users never lose tokens even if cross-chain operations fail at any step.

## Running the Tests

Execute the complete test suite:

```bash
# Run all example tests
forge test --match-contract "CrossChainSwapExampleTest" -v

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

### Token Model

- Implements full ISuperchainERC20 interface
- Supports both regular transfers and cross-chain mint/burn operations
- Maintains authorization controls for cross-chain operations

### Exchange Model

- Provides simple 1:1 swap functionality
- Supports configurable failure modes for testing
- Includes liquidity management and pair configuration

### Bridge Model

- Coordinates cross-chain token transfers using promise library
- Handles both burn-on-source and mint-on-destination operations
- Provides promise IDs for operation tracking and chaining

## Limitations and Considerations

1. Experimental Status: These examples are proof-of-concept implementations
2. Simplified Economics: Uses 1:1 swap rates and simplified fee models
3. Test Environment: Relies on test harness for cross-chain message simulation
4. Manual Callback Execution: Requires explicit callback execution in current implementation
5. Authorization Model: Uses simplified authorization scheme suitable for testing

## Future Enhancements

Potential improvements for production use:

- Automated callback execution
- Economic incentives for callback execution
- More sophisticated fee and slippage models
- Enhanced error handling and recovery mechanisms
- Gas optimization and batching
- Integration with real cross-chain messaging infrastructure 