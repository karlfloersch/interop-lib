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

#### Architecture
- **CronScheduler** contract orchestrates the recurring workflow
- **SetTimeout** creates periodic triggers (e.g., every hour)
- **Cross-chain callbacks** collect fees from multiple chains
- **PromiseAll** aggregates all fee collection results
- **Burn callback** executes when all fees are collected
- **Automatic scheduling** creates the next cycle timeout

#### Flow
1. **Initialize cycle**: `startPeriodicFeeCollection()` sets up recurring 1-hour intervals
2. **Trigger execution**: After 1 hour passes, `executeCycle()` is called
3. **Fee collection setup**: Creates callbacks to collect fees from Chain A and Chain B
4. **Aggregation setup**: Uses PromiseAll to wait for both fee collections
5. **Burn setup**: Registers callback to burn fees when aggregation completes
6. **Schedule next cycle**: Automatically creates timeout for next hour
7. **Resolution cascade**: 
   - Timeout resolves → Fee collection callbacks execute
   - Fee collections complete → PromiseAll resolves  
   - PromiseAll resolves → Burn callback executes
   - System automatically schedules next cycle

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

- **77 local tests** covering core promise functionality
- **37 cross-chain tests** demonstrating multi-chain coordination
- **5 end-to-end tests** showing complete realistic workflows
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
