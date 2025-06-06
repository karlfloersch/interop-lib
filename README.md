# Cross-Chain Promise Library 🌉

**⚠️ EXPERIMENTAL PROJECT ⚠️**

This is a test project for experimentation, focused specifically on building a **cross-chain promise library** that enables JavaScript-like promise chaining across multiple blockchains. Think `async/await` but for cross-chain smart contract development.

## 🎯 Vision

Imagine writing cross-chain smart contracts like this:

```solidity
// Chain A: Create a promise and chain across multiple networks
bytes32 promise = promiseLib.create();
bytes32 remoteResult = promiseLib.then(promise, chainB, processOnChainB);
bytes32 finalResult = promiseLib.then(remoteResult, chainC, finalizeOnChainC);

// Resolve on Chain A, automatically executes across Chain B → Chain C → back to Chain A
promiseLib.resolve(promise, abi.encode(initialData));
```

No complex message passing, no manual cross-chain coordination - just **promise chaining that works across chains as naturally as it works locally**.

## 🏗️ What We Built

### Core Architecture

1. **`LocalPromise`** - Manual execution promise library with gas safety
2. **`CrossChainPromise`** - Extends LocalPromise with cross-chain capabilities  
3. **`PromiseAwareMessenger`** - Cross-chain message routing with promise context
4. **Local Proxy Pattern** - Immediate chaining without waiting for cross-chain messages

### Key Innovation: Local Proxy Promises

The breakthrough insight is creating **local representations** of remote promises:

```solidity
// This returns immediately - no waiting for cross-chain messages!
bytes32 remotePromiseId = promiseA.then(localPromise, chainB, callback);

// You can chain on it right away, even though the remote promise doesn't exist yet
bytes32 nextPromise = promiseA.then(remotePromiseId, chainC, nextCallback);
```

Behind the scenes:
- **Deterministic IDs** ensure the same promise ID exists on all chains
- **State synchronization** keeps local proxies in sync with remote execution
- **Unified API** makes cross-chain feel like local development

## 🧪 Working End-to-End Test

Our `test_cross_chain_promise_end_to_end()` demonstrates the full round-trip flow:

### Setup: Deterministic Deployment
```solidity
// Deploy identical contracts on both chains using salt
messengerA = new PromiseAwareMessenger{salt: bytes32(0)}();
promisesA = new CrossChainPromise{salt: bytes32(0)}(address(messengerA));

messengerB = new PromiseAwareMessenger{salt: bytes32(0)}();  
promisesB = new CrossChainPromise{salt: bytes32(0)}(address(messengerB));

// Verify same addresses across chains (critical for auth)
require(address(promisesA) == address(promisesB));
```

### Step 1: Promise Creation & Cross-Chain Setup
```solidity
// Create promise on Chain A
bytes32 promiseId = promisesA.create();

// Register cross-chain callback → creates local proxy immediately!
uint256 destinationChain = chainIdByForkId[forkIds[1]];
bytes32 remotePromiseId = promisesA.then(promiseId, destinationChain, this.remoteHandler.selector);

// Verify local proxy exists and is pending
(PromiseStatus status, bytes memory value,) = promisesA.promises(remotePromiseId);
assertEq(uint256(status), 0); // PENDING
```

### Step 2: Resolution & Cross-Chain Forwarding
```solidity
// Resolve original promise
uint256 testValue = 100;
promisesA.resolve(promiseId, abi.encode(testValue));

// Execute callbacks - sends 2 cross-chain messages:
// 1. setupRemotePromise(remotePromiseId, target, selector, ...)  
// 2. executeRemoteCallback(remotePromiseId, value)
promisesA.executeAllCallbacks(promiseId);
```

### Step 3: Remote Execution on Chain B
```solidity
// Messages arrive on Chain B via relayAllMessages()
relayAllMessages();

// Verify remote promise was created and resolved
vm.selectFork(forkIds[1]); // Switch to Chain B
(PromiseStatus remoteStatus, bytes memory remoteValue,) = promisesB.promises(remotePromiseId);
assertEq(uint256(remoteStatus), 1); // RESOLVED
assertEq(abi.decode(remoteValue, (uint256)), 100);

// Verify callback executed successfully  
assertTrue(remoteCallbackExecuted);
assertEq(remoteReceivedValue, 100);
```

### Step 4: Return Path & Local Proxy Sync
```solidity
// Remote callback transforms value and sends back
function remoteHandler(uint256 value) external returns (uint256) {
    remoteCallbackExecuted = true;
    remoteReceivedValue = value;
    return value * 2; // Transform: 100 → 200
}

// Return message automatically sent, relay it back
relayAllMessages();

// Verify local proxy updated with return value
vm.selectFork(forkIds[0]); // Back to Chain A
(PromiseStatus finalStatus, bytes memory finalValue,) = promisesA.promises(remotePromiseId);
assertEq(uint256(finalStatus), 1); // RESOLVED
assertEq(abi.decode(finalValue, (uint256)), 200); // Transformed value!
```

### Complete Flow Verification ✅
```
Chain A (100) → Chain B (remoteHandler) → Chain A (200)
SUCCESS: Complete cross-chain promise end-to-end flow verified!
```

## 📊 Test Results

**29/29 tests passing** across the full promise ecosystem:
- LocalPromise: 17/17 tests ✅ (manual execution, gas safety, chaining)
- PromiseAwareMessenger: 3/3 tests ✅ (cross-chain messaging)  
- CrossChainPromise: 6/6 tests ✅ (including full e2e flow)
- Promise: 3/3 tests ✅ (baseline functionality)

## ⚠️ Missing Parts (This Might Not Work)

### 1. Deployment & Hardening
- **No production deployment** - only tested in Forge simulation
- **Deterministic deployment** requirements may not work on all chains
- **Gas limit analysis** - cross-chain messages could exceed block gas limits
- **Economic security** - no fee mechanisms or spam protection

### 2. Authentication Vulnerabilities  
- **Wildly vulnerable to auth bugs** - the cross-domain message sender validation is basic
- **Same-address requirement** - relies on deterministic deployment for security
- **Message replay attacks** - no nonce or unique message verification
- **Cross-chain message forgery** - minimal validation of message authenticity

### 3. Test Coverage Gaps
- **Error handling edge cases** - callback failures, gas exhaustion, invalid selectors
- **Multi-chain scenarios** - promises spanning 3+ chains
- **Concurrent execution** - multiple promises resolving simultaneously  
- **State corruption** - malicious actors manipulating promise state
- **Gas optimization** - actual gas costs vs theoretical limits

## 🚀 Future Improvements

### 1. Storage & Gas Efficiency
Once the API stabilizes, optimize storage layout by **emitting events instead of using storage variables**:

```solidity
// Instead of: promises[id] = PromiseState(...)
// Emit: PromiseResolved(id, value, timestamp)
// Read: scan events to reconstruct state
```

**Benefits:**
- **No SSTORE costs** - events are much cheaper than storage
- **Easy state expiry** - log events can be pruned, don't keep promise state forever
- **Better indexing** - external systems can easily track promise lifecycle

### 2. Syntactic Sugar

#### Option A: Proxy Contracts
```solidity
// Create promise-specific proxy contracts
PromiseProxy memory promise = promiseLib.createProxy();
promise.then(chainB, callback).then(chainC, finalizer);
```

#### Option B: Solidity Language Extension (The Dream 🌟)
```solidity
async function crossChainWorkflow() {
    uint256 result = await processOnChainB(initialData);
    uint256 final = await processOnChainC(result);
    return final;
}
```

**This would be so sick** - native `async/await` in Solidity for cross-chain development!

## 🧪 Running Tests

```bash
# Run all tests
forge test

# Run just the cross-chain end-to-end test
forge test --match-test test_cross_chain_promise_end_to_end -vv

# Run with maximum verbosity to see the full flow
forge test --match-test test_cross_chain_promise_end_to_end -vvv
```

## 🤝 Contributing

This is an experimental research project. If you're interested in:
- Security analysis (please find the bugs!)
- Gas optimization strategies  
- Alternative architectural approaches
- Production deployment considerations

Feel free to open issues or PRs. The goal is to explore what's possible in cross-chain developer experience.

---

**Remember: This is experimental code. Do not use in production. Assume there are critical bugs we haven't found yet.** 🐛
