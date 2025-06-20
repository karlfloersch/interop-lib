# Interop Promise Library

A Solidity implementation of JavaScript-style promises for cross-chain and local asynchronous operations.

## Overview

This library provides a comprehensive promise-based system for handling asynchronous operations in smart contracts, with support for both local and cross-chain execution. The system enables JavaScript-familiar promise semantics including creation, resolution, rejection, chaining, and aggregation across multiple blockchain networks.

## Components

### Core Contracts

- **Promise.sol** - Base promise contract managing promise lifecycle, state, and cross-chain sharing
- **SetTimeout.sol** - Time-based promises that resolve after specified timestamps  
- **Callback.sol** - Promise chaining with `.then()` and `.catch()` callbacks, including cross-chain callback registration
- **PromiseAll.sol** - Promise aggregation that resolves when all constituent promises succeed

### Cross-Chain Capabilities

All core contracts support cross-chain operations through integration with L2ToL2CrossDomainMessenger:

- **Promise sharing** - Resolved promises can be shared across chains with full state preservation
- **Resolution transfer** - Promise resolution rights can be transferred to other chains
- **Cross-chain callbacks** - Callbacks can be registered to execute on different chains
- **Remote promise callbacks** - Callbacks can be created for promises that exist on other chains
- **Global promise IDs** - Hash-based unique identifiers ensure promise uniqueness across chains

### Supporting Infrastructure

- **IResolvable.sol** - Interface for contracts that can resolve promises
- **PromiseHarness.sol** - Test automation for automatically resolving pending promises
- **Relayer.sol** - Cross-chain message relay simulation for testing

## Usage

### Basic Promise Operations

```solidity
// Create a promise
uint256 promiseId = promiseContract.create();

// Resolve with data
promiseContract.resolve(promiseId, abi.encode("result"));

// Or reject with error
promiseContract.reject(promiseId, abi.encode("error"));

// Check promise status
Promise.PromiseStatus status = promiseContract.status(promiseId);
```

### Cross-Chain Promise Sharing

```solidity
// Share resolved promise to another chain
promiseContract.shareResolvedPromise(destinationChainId, promiseId);

// Transfer resolution rights to another chain
promiseContract.transferResolve(promiseId, destinationChainId, newResolverAddress);
```

### Timeout Promises

```solidity
// Create a promise that resolves after 100 seconds
uint256 timeoutId = setTimeoutContract.create(block.timestamp + 100);

// Later, anyone can resolve it once the time has passed
if (setTimeoutContract.canResolve(timeoutId)) {
    setTimeoutContract.resolve(timeoutId);
}
```

### Promise Chaining

```solidity
// Local callback registration
uint256 thenId = callbackContract.then(
    parentPromiseId, 
    targetContract, 
    targetContract.handleSuccess.selector
);

// Cross-chain callback registration
uint256 crossChainThenId = callbackContract.thenOn(
    destinationChainId,
    parentPromiseId,
    targetContract,
    targetContract.handleSuccess.selector
);

// Error handling callbacks
uint256 catchId = callbackContract.onReject(
    parentPromiseId,
    targetContract, 
    targetContract.handleError.selector
);
```

### Remote Promise Callbacks

```solidity
// Create callbacks for promises that exist on other chains
uint256 remoteCallbackId = callbackContract.then(
    remotePromiseId, // Promise ID from another chain
    targetContract,
    targetContract.handleSuccess.selector
);
// Callback will become resolvable when remote promise is shared to this chain
```

### Promise Aggregation

```solidity
// Aggregate promises from multiple chains
uint256[] memory promises = new uint256[](3);
promises[0] = localPromise;
promises[1] = chainAPromise;  // From Chain A
promises[2] = chainBPromise;  // From Chain B

uint256 promiseAllId = promiseAllContract.create(promises);
// Resolves when all promises resolve, rejects on first failure
```

## E2E Test Walkthroughs

### Periodic Fee Collection and Burning (Cron Job Pattern)

The `test_PeriodicFeeCollectionAndBurning` test demonstrates a complete cross-chain automated fee collection and burning system that operates like a cron job:

#### 1. Initial Setup

```solidity
// Simulate accumulated fees on both chains
feeCollectorA.simulateAccumulatedFees(1000 ether);
feeCollectorB.simulateAccumulatedFees(500 ether);

// Start the periodic cycle
uint256 cycleId = cronScheduler.startPeriodicFeeCollection(
    3600, // Run every hour (interval in seconds)
    address(feeCollectorA),  // Chain A fee collector
    address(feeCollectorB),  // Chain B fee collector  
    address(feeBurner)       // Fee burner
);
```

#### 2. CronScheduler.executeCycle() - The Heart of Automation

```solidity
function executeCycle(uint256 cycleId) external {
    // Create cross-chain fee collection callbacks
    uint256 chainAFeePromise = callbackContract.then(
        nextTimeoutIds[cycleId],
        cycle.chainAFeeCollector,
        FeeCollector.collectFees.selector
    );
    
    uint256 chainBFeePromise = callbackContract.thenOn(
        cycle.chainBId,
        nextTimeoutIds[cycleId],
        cycle.chainBFeeCollector,
        FeeCollector.collectFees.selector
    );
    
    // Create PromiseAll to wait for both fee collections
    uint256[] memory feePromises = new uint256[](2);
    feePromises[0] = chainAFeePromise;
    feePromises[1] = chainBFeePromise;
    uint256 promiseAllId = promiseAllContract.create(feePromises);
    
    // Create burn callback that executes when both fees are collected
    uint256 burnCallbackId = callbackContract.then(
        promiseAllId,
        cycle.feeBurner,
        FeeBurner.burnFees.selector
    );
    
    // **CRON MAGIC**: Schedule next execution automatically
    uint256 nextTimeoutId = setTimeoutContract.create(block.timestamp + cycle.interval);
    nextTimeoutIds[cycleId] = nextTimeoutId;
}
```

#### 3. Execution Flow

```solidity
// Time passes and timeout becomes resolvable
vm.warp(block.timestamp + 3700);

// Resolve the trigger timeout
uint256 triggerTimeoutId = cronScheduler.getNextTimeoutId(cycleId);
setTimeoutA.resolve(triggerTimeoutId);

// Execute the cycle (sets up all callbacks and next timeout)
cronScheduler.executeCycle(cycleId);

// Share timeout to Chain B so cross-chain callbacks can execute
promiseA.shareResolvedPromise(chainBId, triggerTimeoutId);
relayAllMessages();
```

#### 4. Resolution Cascade

```solidity
// Fee collection callbacks become resolvable
uint256 chainAFeePromise = cronScheduler.getLastChainAFeePromise(cycleId);
uint256 chainBFeePromise = cronScheduler.getLastChainBFeePromise(cycleId);

// Execute fee collections
callbackA.resolve(chainAFeePromise);  // Collects Chain A fees
callbackB.resolve(chainBFeePromise);  // Collects Chain B fees

// Share Chain B results back to Chain A for aggregation
promiseB.shareResolvedPromise(chainAId, chainBFeePromise);
relayAllMessages();

// PromiseAll becomes resolvable when both fee collections complete
uint256 promiseAllId = cronScheduler.getLastPromiseAllId(cycleId);
promiseAllA.resolve(promiseAllId);  // Aggregates [1000 ETH, 500 ETH]

// Burn callback becomes resolvable when PromiseAll completes
uint256 burnCallbackId = cronScheduler.getLastBurnCallbackId(cycleId);
callbackA.resolve(burnCallbackId);  // Burns total 1500 ETH
```

#### 5. Verification

```solidity
// Verify the complete workflow succeeded
assertTrue(feeCollectorA.wasCollected(), "Chain A fees collected");
assertTrue(feeCollectorB.wasCollected(), "Chain B fees collected");
assertTrue(feeBurner.wasBurned(), "Fees burned");
assertEq(feeBurner.totalBurned(), 1500 ether, "Total burned: 1500 ETH");

// Verify next cycle is automatically scheduled
uint256 nextTimeoutId = cronScheduler.getNextTimeoutId(cycleId);
assertTrue(nextTimeoutId > 0, "Next timeout scheduled");
```

#### Key Architecture Features

- **Automatic Self-Scheduling**: Each cycle schedules the next execution
- **Cross-Chain Coordination**: Seamlessly orchestrates operations across multiple chains
- **Fail-Safe Aggregation**: Uses PromiseAll to ensure all collections complete before burning
- **State Management**: Tracks cycle state, execution count, and promise relationships
- **Error Handling**: Failed fee collections cause PromiseAll to reject, preventing burning

This pattern enables fully automated recurring operations across multiple chains with sophisticated error handling and state coordination.

### Remote Promise Orchestration

The `test_RemotePromiseTimeoutOrchestration` test demonstrates advanced cross-chain coordination where one chain controls timing while another orchestrates complex business logic:

#### Scenario
- **Chain B** controls timing by creating timeout promises
- **Chain A** orchestrates fee collection workflows triggered by Chain B's timeouts
- Demonstrates callback creation for promises that don't exist locally

#### Key Capabilities
- **Proactive orchestration**: Chain A sets up complete workflows before triggers occur
- **Remote promise callbacks**: Callbacks created for promises existing only on other chains  
- **Separation of concerns**: Timing control and business logic can be on different chains
- **Cross-chain coordination**: Complex multi-chain workflows triggered by remote events

This pattern enables sophisticated architectures where specialized chains handle what they do best - one chain manages scheduling, another handles complex orchestration logic.

## Promise States

- **Pending** - Initial state, not yet resolved or rejected
- **Resolved** - Completed successfully with return data  
- **Rejected** - Failed with error data

## Global Promise IDs

The system uses hash-based global promise IDs generated from `keccak256(abi.encode(chainId, localPromiseId))` to ensure uniqueness across chains while maintaining deterministic identification.

## Testing

The library includes comprehensive test coverage:

- **Local tests** covering core promise functionality
- **Cross-chain tests** demonstrating multi-chain coordination
- **End-to-end tests** showing complete realistic workflows
- Error handling, edge cases, and complex orchestration scenarios

Run tests with:
```bash
forge test                    # All tests
forge test --match-path "test/XChain*.sol"  # Cross-chain tests only
```

## Architecture

The system centers around a Promise contract managing promise state and cross-chain operations. Specialized contracts handle different promise types while maintaining composability. The architecture supports:

- **Decentralized promise management** through ID-based referencing
- **Cross-chain state synchronization** via message passing
- **Extensible promise types** through the IResolvable interface
- **Automated resolution** via PromiseHarness for complex testing scenarios

All contracts are designed for CREATE2 deployment to ensure consistent addresses across chains, enabling seamless cross-chain coordination.
