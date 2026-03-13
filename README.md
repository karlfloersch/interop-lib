# Interop Promise Library

A Solidity implementation of JavaScript-style promises for cross-chain and local asynchronous operations.

### **Just 426 lines of code** 
Promise: 130, Callback: 150, PromiseAll: 99, SetTimeout: 47

## Overview

This library provides a comprehensive promise-based system for handling asynchronous operations in smart contracts, with support for both local and cross-chain execution. The system enables JavaScript-familiar promise semantics including creation, resolution, rejection, chaining, and aggregation across multiple blockchain networks.

## Components

### Core Contracts

- **Promise.sol** - Base promise contract managing promise lifecycle, state, and cross-chain sharing
- **SetTimeout.sol** - Time-based promises that resolve after specified timestamps
- **Callback.sol** - Promise chaining with `.then()` and `.catchError()` callbacks, including cross-chain callback registration
- **PromiseAll.sol** - Promise aggregation that resolves when all constituent promises succeed
- **PromiseChain.sol** - Fluent builder for JS-like promise chaining syntax (`.from().then().catchError().build()`)
- **PromiseUtils.sol** - Variadic helpers for `PromiseAll` (avoid manual array construction)

### Twin System — Consistent Identity Across Chains

The Twin system gives users a single deterministic address (`msg.sender`) that is the same on every chain. When a callback fires, the target contract sees `msg.sender == twin` instead of the Callback contract.

- **Twin.sol** - User's cross-chain agent. Wraps Callback to route calls through the twin so targets always see `msg.sender == twin`. Supports `makeCall` (local), `makeCallOn` (cross-chain), `.then()`, `.thenOn()`, `.catchError()`, `.catchErrorOn()`, callback scripts (`.thenScript*` / `.catchErrorScript*`), and direct `execute`.
- **TwinFactory.sol** - CREATE2 factory for deterministic twin deployment. Same factory address on all chains → same twin address everywhere. The router is set once by the factory owner.
- **TwinRouter.sol** - User entry point. Deploys the user's twin (if needed) and delegatecalls a script into it.
- **TwinChain.sol** - Fluent builder routed through a Twin. Supports normal callbacks and delegatecall callback scripts.
- **IScript.sol** - Interface for script contracts that run inside a Twin via delegatecall.

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
uint256 timeoutId = setTimeoutContract.create(100);

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
uint256 catchId = callbackContract.catchError(
    parentPromiseId,
    targetContract,
    targetContract.handleError.selector
);
```

### Fluent Promise Chaining (PromiseChain)

For complex chains, `PromiseChain` provides a fluent builder API that mirrors JavaScript promise syntax — no manual nesting of callback calls required:

```solidity
import {PromiseChain} from "./PromiseChain.sol";

// Instead of manually nesting callback.then(callback.then(...)):
bytes32 finalId = PromiseChain
    .from(callback, initialPromise)
    .then(target1, target1.onSuccess.selector)
    .thenOn(chainB, target2, target2.handleRemote.selector)
    .catchError(errorHandler, errorHandler.onError.selector)
    .build();
```

**API:**

| Method | Description |
|--------|-------------|
| `from(cb, promiseId)` | Start a chain from an existing promise |
| `.then(target, selector)` | Success callback on the same chain |
| `.thenOn(destChain, target, selector)` | Success callback on a different chain |
| `.thenScript(script, selector)` | Success callback script executed via `delegatecall` in the twin |
| `.thenScriptOn(destChain, script, selector)` | Cross-chain success callback script executed in the destination twin |
| `.catchError(target, selector)` | Error callback on the same chain |
| `.catchErrorOn(destChain, target, selector)` | Error callback on a different chain |
| `.catchErrorScript(script, selector)` | Error callback script executed via `delegatecall` in the twin |
| `.catchErrorScriptOn(destChain, script, selector)` | Cross-chain error callback script executed in the destination twin |
| `.fork()` | Branch the chain — both branches start from the same promise |
| `.build()` / `.current()` | Extract the final promise ID |

**Forking** lets you attach parallel handlers to the same promise:

```solidity
PromiseChain.Chain memory chain = PromiseChain.from(callback, promise);

// Fork for error handling on a separate branch
PromiseChain.Chain memory errorBranch = chain.fork();
errorBranch.catchError(fallback, fallback.onError.selector).build();

// Continue the success path
bytes32 resultId = chain
    .then(processor, processor.process.selector)
    .thenOn(chainB, sink, sink.store.selector)
    .build();
```

`PromiseUtils` also provides variadic `all()` helpers so you don't need to manually construct arrays for `PromiseAll`:

```solidity
import {PromiseUtils} from "./PromiseUtils.sol";

// Instead of building a uint256[] array:
bytes32 allId = PromiseUtils.all(promiseAll, p1, p2);
bytes32 allId = PromiseUtils.all(promiseAll, p1, p2, p3);
bytes32 allId = PromiseUtils.all(promiseAll, p1, p2, p3, p4);
```

### Twin — Consistent `msg.sender` Across Chains

The Twin system wraps the promise/callback system so that `msg.sender` at every target is the user's deterministic twin address, not the Callback contract.

Use normal callbacks when the next step is just "call this target with the parent return data". Use callback scripts when the next step needs to keep orchestrating as the twin, for example:

- decoding callback data
- approving tokens
- starting another bridge or swap
- branching into a rollback path

**Quick start — via Router + Script:**

```solidity
// 1. Write a stateless script
contract SwapAndDeposit is IScript {
    using TwinChain for TwinChain.Chain;

    uint256 immutable chainB;
    address immutable dex;
    address immutable lending;

    constructor(uint256 _chainB, address _dex, address _lending) {
        chainB = _chainB; dex = _dex; lending = _lending;
    }

    function run() external {
        Twin twin = Twin(address(this)); // delegatecall context
        twin.makeCallOn(chainB, dex, abi.encodeCall(IDex.swap, (token1, token2, amt)))
            .then(lending, ILending.deposit.selector)
            .build();
    }
}

// 2. Execute it — one transaction does everything
TwinRouter(router).execute(address(myScript));
// → Router deploys twin if needed
// → Twin delegatecalls script.run()
// → Script sets up full promise chain as the twin
```

**Direct usage (without Router/Script):**

```solidity
using TwinChain for TwinChain.Chain;

// Same-chain: execute + create promise + chain callbacks
twin.makeCall(target, data)
    .then(handler, handler.onResult.selector)
    .catchError(fallback, fallback.onError.selector)
    .build();

// Cross-chain: call on chain B, then handle result on chain C
twin.makeCallOn(chainB, dex, abi.encodeCall(dex.swap, (t1, t2, amt)))
    .thenOn(chainC, lending, lending.deposit.selector)
    .build();

// Continue orchestration inside the twin with a callback script
twin.makeCall(exchange, abi.encodeCall(exchange.swap, (tokenA, tokenB, amountIn)))
    .thenScript(afterSwapScript, AfterSwapScript.run.selector)
    .build();
```

**How it works:**

1. `makeCallOn(chainB, dex, data)` → creates promise P1, sends cross-chain message to twin on chain B
2. Twin on chain B: calls `dex.swap(...)` (msg.sender == twin), resolves P1, shares back to chain A
3. `.then(handler, sel)` → registers callback on P1 via Callback contract, but with twin as the target
4. When P1 resolves: Callback calls `twin.executeCallback(data)`
5. Twin dispatches either:
   - `target.call(...)` for normal callbacks, so the target sees `msg.sender == twin`
   - `script.delegatecall(...)` for callback scripts, so the script can keep executing as the twin

### Twin Callback Scripts

Callback scripts solve the main gap in multi-step workflows: a callback often needs to do more than just forward data to a target. It may need to approve tokens, start a bridge, register another callback, or create a rollback branch.

Example:

```solidity
contract AfterSwapScript {
    using TwinChain for TwinChain.Chain;

    address immutable tokenB;
    address immutable bridge;
    address immutable nextScript;
    uint256 immutable destinationChain;

    function run(bytes memory parentReturnData) external {
        Twin twin = Twin(address(this));
        uint256 amountOut = abi.decode(parentReturnData, (uint256));

        twin.execute(tokenB, abi.encodeCall(IERC20.approve, (bridge, amountOut)));

        bytes memory bridgeResult = twin.execute(
            bridge,
            abi.encodeCall(PromiseBridge.bridgeTokens, (tokenB, amountOut, destinationChain, address(this)))
        );

        (, bytes32 bridgeMintCallbackId) = abi.decode(bridgeResult, (bytes32, bytes32));

        TwinChain.from(twin, bridgeMintCallbackId)
            .thenScriptOn(destinationChain, nextScript, DestinationSwapScript.run.selector)
            .build();
    }
}
```

This is the pattern to use when a callback needs to continue the promise chain as the same twin on the same or a remote chain.

### Example: Swap -> Bridge -> Swap With Bridge-Back Rollback

The isolated Twin-based example lives in `test/examples/TwinSwapBridgeSwapExample.t.sol`.

Success path:

1. On chain A, the twin swaps `tokenA -> tokenB`
2. A callback script bridges `tokenB` to chain B
3. A destination callback script swaps `tokenB -> tokenC` on chain B

Rollback path:

1. The destination swap is wrapped in a promise created by the twin
2. A forked `.catchErrorScript(...)` branch is registered against that swap
3. If the second swap reverts, the rollback script bridges `tokenB` back to chain A

Core shape:

```solidity
twin.makeCall(exchange, abi.encodeCall(MockExchange.swap, (tokenA, tokenB, amountIn)))
    .thenScript(afterLocalSwapScript, AfterLocalSwapScript.run.selector)
    .build();
```

Inside the destination script:

```solidity
twin.makeCall(exchange, abi.encodeCall(MockExchange.swap, (tokenB, tokenC, amountIn)))
    .fork()
    .catchErrorScript(rollbackScript, RollbackBridgeBackScript.run.selector)
    .build();
```

Important behavior: callback branches only enter the error path when the callback actually reverts. Returning `false` is still a successful resolution from the promise system's perspective.

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

The `test_PeriodicFeeCollectionAndBurning` test demonstrates a complete cross-chain automated fee collection and burning system that operates like a truly automatic cron job - once started, it runs perpetually without any manual intervention:

#### Architecture Overview
- **CronScheduler** contract orchestrates the recurring workflow
- **SetTimeout** creates periodic triggers (e.g., every hour)
- **Cross-chain callbacks** collect fees from multiple chains
- **PromiseAll** aggregates all fee collection results
- **Burn callback** executes when all fees are collected
- **Automatic scheduling** creates the next cycle timeout

#### Flow Summary
1. **Initialize cycle**: `startPeriodicFeeCollection()` sets up recurring 1-hour intervals with automatic execution
2. **Automatic triggering**: After 1 hour passes, timeout callback automatically calls `executeCycle()`
3. **Fee collection setup**: Creates callbacks to collect fees from Chain A and Chain B
4. **Aggregation setup**: Uses PromiseAll to wait for both fee collections
5. **Burn setup**: Registers callback to burn fees when aggregation completes
6. **Schedule next cycle**: Automatically creates timeout and callback for next hour
7. **Resolution cascade**: 
   - Timeout resolves → Execution callback triggers → `executeCycle()` runs automatically
   - Fee collection callbacks execute → PromiseAll resolves  
   - PromiseAll resolves → Burn callback executes
   - System perpetually schedules and executes next cycle

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
        uint256 nextTimeoutId = setTimeoutContract.create(cycle.interval);
        
        // **AUTOMATIC TRIGGERING**: Create callback to automatically execute next cycle
        uint256 nextExecutionCallbackId = callbackContract.then(
            nextTimeoutId,
            address(this),
            CronScheduler.executeCycleCallback.selector
        );
        executionCallbackIds[cycleId] = nextExecutionCallbackId;
        
        nextTimeoutIds[cycleId] = nextTimeoutId;
}

/// @notice Callback wrapper for automatic cycle execution  
/// @dev This function is called automatically when timeout resolves
function executeCycleCallback(bytes memory /* data */) external returns (string memory) {
    // Find which cycle needs to be executed by checking which timeout is resolved
    for (uint256 cycleId = 1; cycleId < nextCycleId; cycleId++) {
        if (!cycles[cycleId].active) continue;
        
        uint256 timeoutId = nextTimeoutIds[cycleId];
        if (timeoutId > 0 && 
            promiseContract.status(timeoutId) == Promise.PromiseStatus.Resolved &&
            (cycles[cycleId].lastExecution == 0 || 
             block.timestamp >= cycles[cycleId].lastExecution + cycles[cycleId].interval)) {
            // This timeout resolved and cycle is ready
            this.executeCycle(cycleId);
            return "Cycle executed automatically";
        }
    }
    return "No cycles ready for execution";
}
```

#### 3. Execution Flow

```solidity
// Time passes and cycle triggers automatically
vm.warp(block.timestamp + 3700);

// Resolve the trigger timeout (this will automatically execute the cycle)
uint256 triggerTimeoutId = cronScheduler.getNextTimeoutId(cycleId);
setTimeoutA.resolve(triggerTimeoutId);

// Resolve the automatic cycle execution callback
uint256 executionCallbackId = cronScheduler.getExecutionCallbackId(cycleId);
callbackA.resolve(executionCallbackId);

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

- **Fully Automatic Execution**: Each cycle creates a callback that automatically triggers the next execution when the timeout resolves
- **Self-Perpetuating**: Once started, cycles continue indefinitely without manual intervention
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

Cross-chain tests require [supersim](https://github.com/ethereum-optimism/supersim) running locally:

```bash
# Build and run supersim (provides two L2 chains on ports 9545 and 9546)
cd /path/to/supersim && go build -o supersim cmd/main.go
./supersim
```

Then run tests:

```bash
forge test                                        # All tests
forge test --match-path "test/Twin.t.sol"         # Twin single-chain tests
forge test --match-path "test/XChainTwin.t.sol"   # Twin cross-chain tests
forge test --match-path "test/examples/TwinSwapBridgeSwapExample.t.sol" # Twin rollback example
forge test --match-path "test/XChain*.sol"        # All cross-chain tests
```

## Architecture

The system centers around a Promise contract managing promise state and cross-chain operations. Specialized contracts handle different promise types while maintaining composability. The architecture supports:

- **Decentralized promise management** through ID-based referencing
- **Cross-chain state synchronization** via message passing
- **Extensible promise types** through the IResolvable interface
- **Automated resolution** via PromiseHarness for complex testing scenarios

All contracts are designed for CREATE2 deployment to ensure consistent addresses across chains, enabling seamless cross-chain coordination.
