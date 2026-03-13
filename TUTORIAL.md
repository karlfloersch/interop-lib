# Twin Swap -> Bridge -> Swap Tutorial

This tutorial walks through the isolated Twin example in `test/examples/TwinSwapBridgeSwapExample.t.sol`.

It covers two paths:

1. Success: `tokenA -> tokenB` on chain A, bridge `tokenB`, then `tokenB -> tokenC` on chain B
2. Rollback: if the second swap fails on chain B, bridge `tokenB` back to chain A

The example is built around the Twin system, so every externally visible action happens with `msg.sender == twin`.

If you call `TwinRouter.execute{value: ...}(script)`, that native value is also deposited into the executing twin's callback gas tank. That lets later callback scripts pay the relayer from inside the script flow instead of pre-wiring a separate payment transaction.

## Why This Example Exists

The simple Twin flow is easy:

```solidity
twin.makeCallOn(chainB, dex, data).then(handler, selector).build();
```

That only works when the callback step is "call this target with the previous return data".

The `swap -> bridge -> swap` workflow is more demanding. Each step has to do more orchestration:

- decode the previous result
- approve a token
- call the bridge
- capture a callback ID returned by the bridge
- register the next step
- create an error branch for rollback

That is exactly why the Twin callback-script API exists:

- `thenScript`
- `thenScriptOn`
- `catchErrorScript`
- `catchErrorScriptOn`

These run by `delegatecall` inside the twin, so the callback script can keep acting as the twin.

## Files To Read

- Main test: `test/examples/TwinSwapBridgeSwapExample.t.sol`
- Twin callback-script support: `src/Twin.sol`
- Fluent helpers: `src/TwinChain.sol`
- Example bridge: `test/examples/utils/PromiseBridge.sol`
- Example exchange: `test/examples/utils/MockExchange.sol`

## Actors

- `aliceTwinA`: Alice's twin on chain A
- `aliceTwinB`: Alice's twin on chain B
- `exchangeA`: local swap venue for `tokenA -> tokenB`
- `exchangeB`: destination swap venue for `tokenB -> tokenC`
- `bridgeA` / `bridgeB`: example bridge contracts
- `recorderA` / `recorderB`: helper contracts that store callback IDs during the flow

## Token Flow

Success path:

1. Twin on chain A swaps `tokenA -> tokenB`
2. Twin on chain A bridges `tokenB` to chain B
3. Bridge mints `tokenB` to the twin on chain B
4. Twin on chain B swaps `tokenB -> tokenC`

Rollback path:

1. Steps 1-3 are the same
2. The `tokenB -> tokenC` swap reverts
3. A rollback callback script fires on chain B
4. The rollback script bridges `tokenB` back to chain A
5. Bridge mints `tokenB` back to the twin on chain A

## High-Level Shape

The workflow is intentionally broken into small scripts.

### 1. Init script

`SwapBridgeSwapInitScript.run()`

This is the entry point executed through `TwinRouter.execute(script)`.

It does two things:

1. approves `tokenA` to `exchangeA`
2. starts the first promise:

```solidity
twin.makeCall(exchange, abi.encodeCall(MockExchange.swap, (tokenA, tokenB, amountIn)))
    .thenScript(afterLocalSwapScript, AfterLocalSwapScript.run.selector)
    .build();
```

That means:

- do the first swap now
- when it resolves, continue inside `AfterLocalSwapScript`

### 2. After-local-swap script

`AfterLocalSwapScript.run(bytes parentReturnData)`

This script runs after the first swap resolves.

It:

1. decodes the amount of `tokenB` received
2. approves `bridgeA`
3. calls `PromiseBridge.bridgeTokens(...)`
4. extracts the bridge mint callback ID returned by the bridge
5. registers the remote destination swap using:

```solidity
TwinChain.from(twin, bridgeMintCallbackId)
    .thenScriptOn(destinationChainId, destinationSwapScript, DestinationSwapScript.run.selector)
    .build();
```

The important detail is that the next step is registered against the bridge mint callback, not against the bridge initiation call itself.

The bridge returns two IDs:

- the bridge operation promise
- the destination mint callback promise

The destination swap should only happen after the mint callback succeeds on chain B, so the example chains from that callback ID.

### 3. Destination swap script

`DestinationSwapScript.run(bytes)`

This script runs on chain B after the bridge mint callback resolves.

It:

1. reads the twin's `tokenB` balance on chain B
2. approves `exchangeB`
3. starts the destination swap:

```solidity
twin.makeCall(exchange, abi.encodeCall(MockExchange.swap, (tokenB, tokenC, amountIn)))
```

4. forks the chain and attaches an error branch:

```solidity
.fork()
.catchErrorScript(rollbackScript, RollbackBridgeBackScript.run.selector)
.build();
```

This gives the second swap a rollback path without disturbing the success path.

## Why `fork()` Is Used

`fork()` makes a second builder branch that starts from the same promise ID.

In this example:

- the main branch is the destination swap promise
- the forked branch watches the same promise for rejection

If the destination swap succeeds:

- the swap promise resolves
- the rollback callback promise is rejected as non-matching

If the destination swap fails:

- the swap promise rejects
- the rollback callback becomes resolvable

## 4. Rollback bridge-back script

`RollbackBridgeBackScript.run(bytes)`

This script runs on chain B if the second swap rejects.

It:

1. reads the twin's `tokenB` balance on chain B
2. approves `bridgeB`
3. bridges `tokenB` back to chain A
4. records the bridge-back mint callback ID

That bridge-back mint callback is then resolved on chain A to complete the rollback.

## Success Walkthrough

This matches `test_swapBridgeSwap_success()`.

### Phase 1: start the workflow on chain A

Alice calls:

```solidity
routerA.execute{value: gasBudget}(address(initScriptA));
```

The router:

1. finds or deploys Alice's twin
2. credits the twin's callback gas tank with `gasBudget`
3. delegatecalls the init script into the twin

The init script:

1. approves `exchangeA`
2. swaps `tokenA -> tokenB`
3. registers `AfterLocalSwapScript`
4. stores that callback ID in `recorderA`

### Phase 2: resolve the first callback on chain A

The test reads the callback ID from `recorderA` and resolves it through `callbackA`.

That runs `AfterLocalSwapScript`, which:

1. bridges `tokenB` to chain B
2. records the bridge mint callback ID
3. registers the destination swap script on chain B
4. records the second swap callback ID

### Phase 3: relay cross-chain messages

`relayAllMessages()` moves the bridge and callback registration messages to chain B.

At this point chain B has:

- the bridge mint callback
- the destination swap callback registration

### Phase 4: resolve the bridge mint callback

The test resolves the bridge mint callback on chain B.

That mints `tokenB` to `aliceTwinB`.

### Phase 5: resolve the destination swap callback

The test resolves the second swap callback on chain B.

That runs `DestinationSwapScript`, which:

1. approves `exchangeB`
2. swaps `tokenB -> tokenC`
3. registers the rollback catch branch

Since the swap succeeds in the happy path:

- `aliceTwinB` ends with `tokenC`
- no rollback action is taken

### Final balances

The assertions check:

- chain A twin no longer has `tokenA`
- chain A twin does not keep bridged `tokenB`
- chain B twin no longer has `tokenB`
- chain B twin now has `tokenC`

## Rollback Walkthrough

This matches `test_swapBridgeSwap_secondSwapFailureBridgesBack()`.

The setup is the same except:

```solidity
exchangeB.setFailureMode(address(tokenB), address(tokenC), true);
```

That forces the second swap to revert.

### Phase 1: same setup as success

The test:

1. runs the init script
2. resolves the local after-swap callback
3. relays messages to chain B
4. resolves the bridge mint callback on chain B

At that point `aliceTwinB` holds bridged `tokenB`.

### Phase 2: second swap fails

The test resolves the second swap callback on chain B.

Inside `DestinationSwapScript`:

1. the twin tries `tokenB -> tokenC`
2. `MockExchange` reverts because failure mode is enabled
3. the destination swap promise is rejected

Because the rollback branch was attached with `catchErrorScript`, the rollback callback becomes resolvable.

### Phase 3: rollback script runs

The test reads the rollback callback ID from `recorderB` and resolves it.

That runs `RollbackBridgeBackScript`, which:

1. approves `bridgeB`
2. bridges `tokenB` back to chain A
3. records the bridge-back mint callback ID

### Phase 4: complete bridge-back on chain A

After another `relayAllMessages()`, the test resolves the bridge-back mint callback on chain A.

That mints `tokenB` back to `aliceTwinA`.

### Final balances

The assertions check:

- chain A twin still does not get `tokenA` back
- chain A twin does get `tokenB` back
- chain B twin no longer has `tokenB`
- chain B twin never receives `tokenC`

This is a partial economic rollback, not a full undo of the original local swap.

The workflow recovers the bridged asset after the remote failure. It does not restore the pre-swap state on chain A.

## Why The Callback IDs Are Recorded

The tutorial test uses `WorkflowRecorder` because multiple callback promises are created inside scripts.

Those IDs are needed later by the test harness to manually resolve:

- the after-local-swap callback
- the bridge mint callback
- the second swap callback
- the rollback callback
- the bridge-back mint callback

This keeps the example deterministic and easy to inspect during review.

## Important Gotchas

### 1. Revert to trigger rollback

`catchErrorScript(...)` only fires when the watched promise rejects.

That means the failing step must revert.

Returning `false` is not enough. A returned value still counts as a successful resolution unless the callee reverts.

### 2. Callback scripts are for orchestration

Use `then(...)` / `catchError(...)` when you just want to forward data to another target.

Use `thenScript(...)` / `catchErrorScript(...)` when the next step needs to:

- decode
- approve
- branch
- bridge
- register more callbacks

### 3. Cross-chain chaining often wants the callback promise, not the original operation promise

In this example, the destination swap waits on the bridge mint callback ID.

That is the correct dependency because the destination swap needs the bridged tokens to exist on chain B first.

### 4. The bridge helper must reject on mint failure

The example bridge is set up so destination mint failures revert in `mintTokensCallback`.

If it only returned `false`, the promise system would treat that as a successful callback return value and error branches would not fire.

## Suggested Reading Order In Code

If you want to review the example with other people, this order works well:

1. `test_swapBridgeSwap_success()`
2. `SwapBridgeSwapInitScript.run()`
3. `AfterLocalSwapScript.run()`
4. `DestinationSwapScript.run()`
5. `RollbackBridgeBackScript.run()`
6. `test_swapBridgeSwap_secondSwapFailureBridgesBack()`

## Running The Example

```bash
forge test --match-path "test/examples/TwinSwapBridgeSwapExample.t.sol" -vv
```

Cross-chain tests require the local supersim setup described in `README.md`.
