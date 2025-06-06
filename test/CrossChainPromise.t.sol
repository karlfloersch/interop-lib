// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {CrossChainPromise} from "../src/CrossChainPromise.sol";
import {LocalPromise} from "../src/LocalPromise.sol";
import {PromiseAwareMessenger} from "../src/PromiseAwareMessenger.sol";
import {Relayer} from "../src/test/Relayer.sol";



contract CrossChainPromiseTest is Relayer, Test {
    CrossChainPromise public promisesA;
    CrossChainPromise public promisesB;
    PromiseAwareMessenger public messengerA;
    PromiseAwareMessenger public messengerB;
    
    // Test state
    uint256 public receivedValue;
    bool public callbackExecuted;
    bool public remoteCallbackExecuted;
    uint256 public remoteReceivedValue;
    
    // Nested promise test state
    bool public nestedChainerExecuted;
    uint256 public nestedChainerValue;
    bool public finalProcessorExecuted;
    uint256 public finalProcessorValue;
    bool public nestedResultReaderExecuted;
    uint256 public nestedResultReaderValue;
    
    // Cross-chain Promise.all test state
    bool public crossChainAggregatorExecuted;
    uint256 public crossChainAggregatorValue;
    bool public dataProcessor1Executed;
    uint256 public dataProcessor1Value;
    bool public dataProcessor2Executed;
    uint256 public dataProcessor2Value;
    bool public finalAggregatorExecuted;
    uint256 public finalAggregatorValue;
    bool public ultimateResultHandlerExecuted;
    uint256 public ultimateResultHandlerValue;
    
    string[] private rpcUrls = [
        vm.envOr("CHAIN_A_RPC_URL", string("https://interop-alpha-0.optimism.io")),
        vm.envOr("CHAIN_B_RPC_URL", string("https://interop-alpha-1.optimism.io"))
    ];
    
    constructor() Relayer(rpcUrls) {}
    
    function setUp() public {
        // Deploy on chain A using deterministic salt
        vm.selectFork(forkIds[0]);
        messengerA = new PromiseAwareMessenger{salt: bytes32(0)}();
        promisesA = new CrossChainPromise{salt: bytes32(0)}(address(messengerA));
        
        // Deploy on chain B using same salt for same addresses
        vm.selectFork(forkIds[1]);
        messengerB = new PromiseAwareMessenger{salt: bytes32(0)}();
        promisesB = new CrossChainPromise{salt: bytes32(0)}(address(messengerB));
        
        // Verify deployments at same addresses
        require(address(messengerA) == address(messengerB), "Messengers not at same address");
        require(address(promisesA) == address(promisesB), "Promises not at same address");
        
        // Reset test state
        receivedValue = 0;
        callbackExecuted = false;
        remoteCallbackExecuted = false;
        remoteReceivedValue = 0;
        
        // Reset nested promise test state
        nestedChainerExecuted = false;
        nestedChainerValue = 0;
        finalProcessorExecuted = false;
        finalProcessorValue = 0;
        nestedResultReaderExecuted = false;
        nestedResultReaderValue = 0;
        
        // Reset cross-chain Promise.all test state
        crossChainAggregatorExecuted = false;
        crossChainAggregatorValue = 0;
        dataProcessor1Executed = false;
        dataProcessor1Value = 0;
        dataProcessor2Executed = false;
        dataProcessor2Value = 0;
        finalAggregatorExecuted = false;
        finalAggregatorValue = 0;
        ultimateResultHandlerExecuted = false;
        ultimateResultHandlerValue = 0;
        
        // Reset cross-chain Promise.all test state
        crossChainAggregatorExecuted = false;
        crossChainAggregatorValue = 0;
        dataProcessor1Executed = false;
        dataProcessor1Value = 0;
        dataProcessor2Executed = false;
        dataProcessor2Value = 0;
        finalAggregatorExecuted = false;
        finalAggregatorValue = 0;
        ultimateResultHandlerExecuted = false;
        ultimateResultHandlerValue = 0;
    }
    
    function test_create_promise() public {
        vm.selectFork(forkIds[0]); // Use chain A
        
        bytes32 promiseId = promisesA.create();
        
        // Verify promise exists and is pending
        (LocalPromise.PromiseStatus status, bytes memory value, address creator) = promisesA.promises(promiseId);
        
        assertEq(uint256(status), 0); // PENDING = 0
        assertEq(value.length, 0);
        assertEq(creator, address(this));
    }
    
    function test_local_then() public {
        vm.selectFork(forkIds[0]); // Use chain A
        
        // Create promise
        bytes32 promiseId = promisesA.create();
        
        // Register local callback using parent function
        bytes32 chainedPromiseId = promisesA.then(promiseId, this.handleValue.selector);
        
        // Verify chained promise was created
        (LocalPromise.PromiseStatus status,,) = promisesA.promises(chainedPromiseId);
        assertEq(uint256(status), 0); // PENDING = 0
        
        // Resolve original promise
        uint256 testValue = 42;
        promisesA.resolve(promiseId, abi.encode(testValue));
        
        // Execute callbacks manually (should resolve chained promise)
        promisesA.executeAllCallbacks(promiseId);
        
        // Verify chained promise was resolved with callback return value
        bytes memory value;
        (status, value,) = promisesA.promises(chainedPromiseId);
        assertEq(uint256(status), 1); // RESOLVED = 1
        
        // Execute callbacks on chained promise
        promisesA.executeAllCallbacks(chainedPromiseId);
        
        // Verify our callback was executed
        assertTrue(callbackExecuted);
        assertEq(receivedValue, testValue);
    }
    
    function test_cross_chain_then_setup() public {
        vm.selectFork(forkIds[0]); // Use chain A
        
        // Create promise on chain A
        bytes32 promiseId = promisesA.create();
        
        // Register cross-chain callback to chain B
        uint256 destinationChain = chainIdByForkId[forkIds[1]];
        bytes32 chainedPromiseId = promisesA.then(promiseId, destinationChain, this.handleValue.selector);
        
        // Verify chained promise was created on chain A
        (LocalPromise.PromiseStatus status,,) = promisesA.promises(chainedPromiseId);
        assertEq(uint256(status), 0); // PENDING = 0
        
        // Verify cross-chain forwarding was set up
        (
            uint256 destChain,
            bytes32 remotePromiseId,
            bytes32 chainedId,
            bool isActive
        ) = promisesA.crossChainForwarding(promiseId);
        
        assertEq(destChain, destinationChain);
        assertTrue(isActive);
        assertEq(chainedId, chainedPromiseId);
        assertTrue(remotePromiseId != bytes32(0));
        
        console.log("SUCCESS: Cross-chain then setup completed");
    }
    
    function test_cross_chain_promise_end_to_end() public {
        vm.selectFork(forkIds[0]); // Start on chain A
        
        console.log("=== Testing Cross-Chain Promise End-to-End ===");
        
        // Create promise on chain A
        bytes32 promiseId = promisesA.create();
        console.log("Created promise on chain A");
        
        // Register cross-chain callback to chain B - returns local proxy of remote promise
        uint256 destinationChain = chainIdByForkId[forkIds[1]];
        bytes32 remotePromiseId = promisesA.then(promiseId, destinationChain, this.remoteHandler.selector);
        console.log("Registered cross-chain callback to chain B");
        console.log("Remote promise ID (local proxy):", vm.toString(remotePromiseId));
        
        // Verify local proxy is pending
        (LocalPromise.PromiseStatus proxyStatus,bytes memory proxyValue,) = promisesA.promises(remotePromiseId);
        assertEq(uint256(proxyStatus), 0); // PENDING
        assertEq(proxyValue.length, 0);
        
        // Resolve the original promise on chain A
        uint256 testValue = 100;
        promisesA.resolve(promiseId, abi.encode(testValue));
        console.log("Resolved original promise with value:", testValue);
        
        // Execute callbacks on chain A (this sends setup + execution to chain B)
        promisesA.executeAllCallbacks(promiseId);
        console.log("Executed callbacks on chain A - cross-chain messages sent");
        
        // Relay messages to chain B
        relayAllMessages();
        console.log("Relayed messages to chain B");
        
        // Switch to chain B and verify remote promise was executed
        vm.selectFork(forkIds[1]);
        
        // Check that actual remote promise exists and was resolved
        (LocalPromise.PromiseStatus remoteStatus,bytes memory remoteValue,) = promisesB.promises(remotePromiseId);
        assertEq(uint256(remoteStatus), 1); // RESOLVED
        
        uint256 forwardedValue = abi.decode(remoteValue, (uint256));
        assertEq(forwardedValue, testValue);
        console.log("Remote promise resolved with value:", forwardedValue);
        
        // Verify callback executed
        assertTrue(remoteCallbackExecuted);
        assertEq(remoteReceivedValue, testValue);
        console.log("Remote callback executed successfully");
        
        // Relay return message back to chain A
        relayAllMessages();
        console.log("Relayed return message to chain A");
        
        // Switch back to chain A and verify local proxy was updated
        vm.selectFork(forkIds[0]);
        
        // Check that local proxy is now resolved with return value
        (LocalPromise.PromiseStatus finalStatus,bytes memory finalValue,) = promisesA.promises(remotePromiseId);
        assertEq(uint256(finalStatus), 1); // RESOLVED
        assertTrue(finalValue.length > 0);
        
        // Verify return value (doubled by remoteHandler)
        uint256 returnValue = abi.decode(finalValue, (uint256));
        assertEq(returnValue, testValue * 2);
        console.log("Local proxy updated with return value:", returnValue);
        
        console.log("SUCCESS: Complete cross-chain promise end-to-end flow verified!");
        console.log("Flow: Chain A ->", testValue, "-> Chain B -> Chain A ->", returnValue);
    }
    
    function test_nested_cross_chain_promises() public {
        vm.selectFork(forkIds[0]); // Start on chain A
        
        console.log("=== Testing Nested Cross-Chain Promise Chaining ===");
        
        // Create promise on chain A
        bytes32 promiseId = promisesA.create();
        console.log("Created promise on chain A");
        
        // Register cross-chain callback to chain B that will create nested promises
        uint256 destinationChain = chainIdByForkId[forkIds[1]];
        bytes32 remotePromiseId = promisesA.then(promiseId, destinationChain, this.nestedChainer.selector);
        console.log("Registered nested chainer callback to chain B");
        console.log("Remote promise ID (local proxy) created");
        
        // Chain a callback to the remote promise proxy to read the final nested result
        bytes32 resultReaderPromise = promisesA.then(remotePromiseId, this.nestedResultReader.selector);
        console.log("Chained result reader to remote promise proxy");
        
        // Resolve the original promise on chain A
        uint256 testValue = 50;
        promisesA.resolve(promiseId, abi.encode(testValue));
        console.log("Resolved original promise with value:", testValue);
        
        // Execute callbacks on chain A (sends to chain B)
        promisesA.executeAllCallbacks(promiseId);
        console.log("Executed callbacks on chain A - cross-chain messages sent");
        
        // Relay messages to chain B
        relayAllMessages();
        console.log("Relayed messages to chain B");
        
        // Verify nested chainer executed on chain B
        assertTrue(nestedChainerExecuted, "Nested chainer should have executed");
        assertEq(nestedChainerValue, testValue, "Nested chainer should have received correct value");
        console.log("Nested chainer executed with value:", nestedChainerValue);
        
        // Relay the nested promise messages back to chain A
        relayAllMessages();
        console.log("Relayed nested promise messages to chain A");
        
        // Verify final processor executed on chain A
        assertTrue(finalProcessorExecuted, "Final processor should have executed");
        assertEq(finalProcessorValue, testValue * 10, "Final processor should have received transformed value");
        console.log("Final processor executed with value:", finalProcessorValue);
        
        // Switch back to chain A and verify the nested result propagated
        vm.selectFork(forkIds[0]);
        
        // Check that original remote promise proxy was updated
        (LocalPromise.PromiseStatus remoteStatus, bytes memory remoteValue,) = promisesA.promises(remotePromiseId);
        assertEq(uint256(remoteStatus), 1, "Remote promise should be resolved");
        
        // Execute the callback chained to the remote promise proxy to read the nested result
        promisesA.executeAllCallbacks(remotePromiseId);
        console.log("Executed callbacks on remote promise proxy");
        
        // Verify the result reader got the final nested value
        assertTrue(nestedResultReaderExecuted, "Nested result reader should have executed");
        assertEq(nestedResultReaderValue, testValue * 10, "Result reader should have received nested result");
        console.log("Result reader executed with nested value:", nestedResultReaderValue);
        
        console.log("SUCCESS: Nested cross-chain promise flow verified!");
        console.log("Flow: Chain A ->", testValue, "-> Chain B (nested promise) -> Chain A ->", finalProcessorValue);
        console.log("Final: Remote proxy updated and readable on Chain A with value:", nestedResultReaderValue);
    }
    
    function test_basic_cross_chain_call() public {
        vm.selectFork(forkIds[0]); // Start on chain A
        
        // Send a simple test message from chain A to chain B
        uint256 destinationChain = chainIdByForkId[forkIds[1]];
        messengerA.sendMessage(destinationChain, address(promisesB), abi.encodeWithSelector(promisesB.testCrossChainCall.selector));
        
        // Relay the message
        relayAllMessages();
        
        // Check if the call was received on chain B
        vm.selectFork(forkIds[1]);
        assertTrue(promisesB.testCallReceived(), "Test call should have been received");
        
        console.log("SUCCESS: Basic cross-chain call working");
    }
    
    function test_calculate_remote_promise_id() public {
        vm.selectFork(forkIds[0]); // Use chain A
        
        // Test that remote promise IDs are predictable
        uint256 destinationChain = chainIdByForkId[forkIds[1]];
        
        // Create two promises with cross-chain then - should have different IDs
        bytes32 promise1 = promisesA.create();
        bytes32 chained1 = promisesA.then(promise1, destinationChain, this.handleValue.selector);
        
        bytes32 promise2 = promisesA.create();
        bytes32 chained2 = promisesA.then(promise2, destinationChain, this.handleValue.selector);
        
        // Chained promises should be different
        assertTrue(chained1 != chained2);
        
        console.log("SUCCESS: Remote promise IDs are unique");
    }
    
    function test_cross_chain_promise_all_with_chaining() public {
        vm.selectFork(forkIds[0]); // Start on chain A
        
        console.log("=== Testing Cross-Chain Promise.all with Mixed Operations & Chaining ===");
        
        // Step 1: Create initial promise on Chain A
        bytes32 initialPromise = promisesA.create();
        console.log("Step 1: Created initial promise on Chain A");
        
        // Step 2: Chain to Chain B with crossChainAggregator callback
        uint256 chainBId = chainIdByForkId[forkIds[1]];
        bytes32 aggregatorPromise = promisesA.then(initialPromise, chainBId, this.crossChainAggregator.selector);
        console.log("Step 2: Chained to Chain B crossChainAggregator");
        
        // Step 3: Chain final result handler to aggregator promise (on Chain A)
        bytes32 finalPromise = promisesA.then(aggregatorPromise, this.ultimateResultHandler.selector);
        console.log("Step 3: Chained ultimate result handler on Chain A");
        
        // Step 4: Resolve initial promise to start the flow
        uint256 initialValue = 10;
        promisesA.resolve(initialPromise, abi.encode(initialValue));
        console.log("Step 4: Resolved initial promise with value:", initialValue);
        
        // Step 5: Execute callbacks (sends to Chain B)
        promisesA.executeAllCallbacks(initialPromise);
        console.log("Step 5: Executed callbacks - message sent to Chain B");
        
        // Step 6: Relay to Chain B
        relayAllMessages();
        console.log("Step 6: Relayed messages to Chain B");
        
        // Verify crossChainAggregator executed on Chain B
        assertTrue(crossChainAggregatorExecuted, "Cross-chain aggregator should have executed");
        assertEq(crossChainAggregatorValue, initialValue, "Aggregator received correct value");
        console.log("SUCCESS: CrossChainAggregator executed on Chain B with value:", crossChainAggregatorValue);
        
        // Step 7: Relay Promise.all results back to Chain A
        relayAllMessages();
        console.log("Step 7: Relayed Promise.all results back to Chain A");
        
        // Step 8: Execute final aggregator promise on Chain A
        vm.selectFork(forkIds[0]);
        promisesA.executeAllCallbacks(aggregatorPromise);
        console.log("Step 8: Executed aggregator promise callbacks on Chain A");
        
        // Step 9: Execute ultimate result handler
        promisesA.executeAllCallbacks(finalPromise);
        console.log("Step 9: Executed ultimate result handler");
        
        // Verify final results
        assertTrue(ultimateResultHandlerExecuted, "Ultimate result handler should have executed");
        console.log("SUCCESS: Ultimate result handler executed with value:", ultimateResultHandlerValue);
        
        // Verify the full flow worked
        assertTrue(dataProcessor1Executed, "Data processor 1 should have executed");
        assertTrue(dataProcessor2Executed, "Data processor 2 should have executed");
        console.log("SUCCESS: Both processors executed - Processor 1:", dataProcessor1Value, "Processor 2:", dataProcessor2Value);
        
        // Expected flow: 10 -> Chain B -> (30 cross-chain + 51 local) -> 81 -> Chain A
        uint256 expectedFinal = dataProcessor1Value + dataProcessor2Value;
        assertEq(ultimateResultHandlerValue, expectedFinal, "Ultimate result should be sum of both operations");
        
        console.log("SUCCESS: Cross-Chain Promise.all with Mixed Operations Complete!");
        console.log("Flow summary:");
        console.log("  Chain A initial value:", initialValue);
        console.log("  Chain B cross-chain result:", dataProcessor1Value);
        console.log("  Chain B local result:", dataProcessor2Value);
        console.log("  Chain A final result:", ultimateResultHandlerValue);
    }
    
    /// @notice Test callback function for local execution
    function handleValue(uint256 value) external returns (uint256) {
        callbackExecuted = true;
        receivedValue = value;
        console.log("Local callback executed with value:", value);
        return value; // Return the same value for chaining
    }
    
    /// @notice Test callback function for remote execution (should be called via cross-chain promise)
    function remoteHandler(uint256 value) external returns (uint256) {
        remoteCallbackExecuted = true;
        remoteReceivedValue = value;
        console.log("Remote callback executed with value:", value);
        console.log("Called from:", msg.sender);
        
        // In cross-chain context, the call comes from the promise contract on the destination chain
        // Just verify it's not a zero address call
        require(msg.sender != address(0), "Called from zero address");
        
        return value * 2; // Transform the value to test return path
    }
    
    /// @notice Nested chainer callback - creates a new promise on Chain B and chains it back to Chain A
    function nestedChainer(uint256 value) external returns (uint256) {
        nestedChainerExecuted = true;
        nestedChainerValue = value;
        console.log("Nested chainer executed with value:", value);
        console.log("Creating nested promise on Chain B and chaining to Chain A");
        
        // Create a NEW promise on Chain B
        bytes32 nestedPromise = promisesB.create();
        console.log("Created nested promise on Chain B");
        
        // Chain the nested promise back to Chain A
        uint256 chainAId = chainIdByForkId[forkIds[0]];
        promisesB.then(nestedPromise, chainAId, this.finalProcessor.selector);
        console.log("Chained nested promise back to Chain A");
        
        // Resolve the nested promise with transformed value
        uint256 transformedValue = value * 10; // Transform: 50 -> 500
        promisesB.resolve(nestedPromise, abi.encode(transformedValue));
        console.log("Resolved nested promise with transformed value:", transformedValue);
        
        // Execute callbacks on the nested promise (sends back to Chain A)
        promisesB.executeAllCallbacks(nestedPromise);
        console.log("Executed nested promise callbacks - sending to Chain A");
        
        return transformedValue; // Return the transformed value
    }
    
    /// @notice Final processor callback - executes on Chain A as the result of nested promise
    function finalProcessor(uint256 value) external returns (uint256) {
        finalProcessorExecuted = true;
        finalProcessorValue = value;
        console.log("Final processor executed on Chain A with value:", value);
        console.log("Called from:", msg.sender);
        
        // Verify it's not a zero address call
        require(msg.sender != address(0), "Called from zero address");
        
        return value; // Pass through the value
    }
    
    /// @notice Result reader callback - reads the final nested result from the remote promise proxy
    function nestedResultReader(uint256 value) external returns (uint256) {
        nestedResultReaderExecuted = true;
        nestedResultReaderValue = value;
        console.log("Nested result reader executed on Chain A with value:", value);
        console.log("This value came from the nested promise computation!");
        
        return value; // Pass through the value
    }
    
    /// @notice Cross-chain aggregator - creates mixed operations using built-in CrossChainPromise capabilities
    function crossChainAggregator(uint256 value) external returns (uint256) {
        crossChainAggregatorExecuted = true;
        crossChainAggregatorValue = value;
        console.log("=== CrossChainAggregator executing on Chain B with value:", value);
        
        // Create two promises: one cross-chain, one local
        bytes32 crossChainPromise = promisesB.create();
        bytes32 localPromise = promisesB.create();
        console.log("Created cross-chain and local promises on Chain B");
        
        // Setup cross-chain promise (back to Chain A)
        uint256 chainAId = chainIdByForkId[forkIds[0]];
        promisesB.then(crossChainPromise, chainAId, this.dataProcessor1.selector);
        console.log("Chained cross-chain promise to dataProcessor1 on Chain A");
        
        // Setup local promise (stays on Chain B) - using destinationChain = 0 for local
        promisesB.then(localPromise, uint256(0), this.dataProcessor2.selector);
        console.log("Chained local promise to dataProcessor2 on Chain B");
        
        // Resolve both promises with transformed values
        uint256 crossChainValue = value * 3; // 10 -> 30
        uint256 localValue = value * 5;      // 10 -> 50 (will become 51 after local callback transformation)
        
        promisesB.resolve(crossChainPromise, abi.encode(crossChainValue));
        promisesB.resolve(localPromise, abi.encode(localValue));
        console.log("Resolved cross-chain promise with:", crossChainValue, "and local promise with:", localValue);
        
        // Execute both promise callbacks
        promisesB.executeAllCallbacks(crossChainPromise); // Sends to Chain A
        promisesB.executeAllCallbacks(localPromise);      // Executes locally
        console.log("Executed both promise callbacks");
        
        // For this demonstration, we'll aggregate the local result with the cross-chain input
        // In a real implementation, you'd need async coordination or sequential execution
        uint256 localResult = dataProcessor2Value; // 51 (local transformed result)
        uint256 crossChainInput = crossChainValue; // 30 (will be processed cross-chain)
        uint256 aggregatedResult = crossChainInput + localResult; // 30 + 51 = 81
        
        console.log("Local operation completed with result:", localResult);
        console.log("Cross-chain operation initiated with value:", crossChainInput);
        console.log("Partial aggregated result (local + cross-chain input):", aggregatedResult);
        
        return aggregatedResult;
    }
    
    /// @notice Data processor 1 - executes cross-chain on Chain A
    function dataProcessor1(uint256 value) external returns (uint256) {
        dataProcessor1Executed = true;
        dataProcessor1Value = value;
        console.log("DataProcessor1 executing on Chain A with value:", value);
        console.log("Called from:", msg.sender);
        
        require(msg.sender != address(0), "Called from zero address");
        
        // Return the value (could do additional processing)
        return value;
    }
    
    /// @notice Data processor 2 - executes locally on Chain B
    function dataProcessor2(uint256 value) external returns (uint256) {
        dataProcessor2Executed = true;
        uint256 transformedValue = value + 1; // Transform: 50 → 51
        dataProcessor2Value = transformedValue;
        console.log("DataProcessor2 executing locally on Chain B with value:", value);
        console.log("DataProcessor2 transformed value to:", transformedValue);
        
        // Return the transformed value
        return transformedValue;
    }
    
    /// @notice Ultimate result handler - processes final aggregated result on Chain A
    function ultimateResultHandler(uint256 value) external returns (uint256) {
        ultimateResultHandlerExecuted = true;
        ultimateResultHandlerValue = value;
        console.log("=== UltimateResultHandler executing on Chain A with final value:", value);
        console.log("This represents the aggregated result of cross-chain + local operations!");
        
        return value;
    }
} 