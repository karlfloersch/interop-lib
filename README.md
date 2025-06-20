# Interop Promise Library

A Solidity implementation of JavaScript-style promises for cross-chain and local async operations.

## Overview

This library provides a promise-based system for handling asynchronous operations in smart contracts. It includes core promise functionality, timeout-based promises, callback chaining, and promise aggregation.

## Components

### Core Contracts

- **Promise.sol** - Base promise contract that manages promise creation, resolution, and rejection
- **SetTimeout.sol** - Time-based promises that resolve after a specified timestamp
- **Callback.sol** - Promise chaining with `.then()` and `.catch()` style callbacks
- **PromiseAll.sol** - Aggregates multiple promises, resolving when all succeed or rejecting on first failure

### Supporting Infrastructure

- **IResolvable.sol** - Interface for contracts that can resolve promises
- **PromiseHarness.sol** - Test automation that automatically resolves pending promises

## Usage

### Basic Promise Operations

```solidity
// Create a promise
uint256 promiseId = promiseContract.create();

// Resolve with data
promiseContract.resolve(promiseId, abi.encode("result"));

// Or reject with error
promiseContract.reject(promiseId, abi.encode("error"));
```

### Timeout Promises

```solidity
// Create a promise that resolves after 100 seconds
uint256 timeoutId = setTimeoutContract.create(block.timestamp + 100);

// Later, anyone can resolve it once the time has passed
setTimeoutContract.resolve(timeoutId);
```

### Promise Chaining

```solidity
// Register success callback
uint256 thenId = callbackContract.then(
    parentPromiseId, 
    targetContract, 
    targetContract.handleSuccess.selector
);

// Register error callback  
uint256 catchId = callbackContract.onReject(
    parentPromiseId,
    targetContract, 
    targetContract.handleError.selector
);
```

### Promise Aggregation

```solidity
// Wait for multiple promises to complete
uint256[] memory promises = new uint256[](2);
promises[0] = promise1;
promises[1] = promise2;

uint256 promiseAllId = promiseAllContract.create(promises);
// Resolves when all input promises resolve
// Rejects immediately if any input promise rejects
```

## Promise States

- **Pending** - Initial state, not yet resolved or rejected
- **Resolved** - Completed successfully with return data  
- **Rejected** - Failed with error data

## Key Features

- **JavaScript compatibility** - Familiar promise semantics and behavior
- **Composable** - Promises can be chained and aggregated arbitrarily
- **Type-agnostic** - Uses `bytes` for flexible data handling
- **Gas efficient** - Minimal storage overhead, cleans up after resolution
- **Extensible** - New promise types can implement `IResolvable` interface

## Testing

The library includes comprehensive tests covering:

- Basic promise operations
- Timeout functionality  
- Callback chaining and error handling
- Promise aggregation scenarios
- Complex orchestration patterns
- Edge cases and error conditions

Run tests with:
```bash
forge test
```

## Architecture

The system is designed around a central Promise contract that manages promise state, with specialized contracts handling different promise types. The IResolvable interface allows for extensibility, and the PromiseHarness provides automation for testing complex scenarios.

All contracts follow a pattern where promises are referenced by ID, allowing for decentralized promise management and cross-contract coordination.
