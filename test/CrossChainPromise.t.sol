// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {CrossChainPromise} from "../src/CrossChainPromise.sol";
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
    }
    
    function test_create_promise() public {
        vm.selectFork(forkIds[0]); // Use chain A
        
        bytes32 promiseId = promisesA.create();
        
        // Verify promise exists and is pending
        (CrossChainPromise.PromiseStatus status, bytes memory value, address creator) = promisesA.promises(promiseId);
        
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
        (CrossChainPromise.PromiseStatus status,,) = promisesA.promises(chainedPromiseId);
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
        (CrossChainPromise.PromiseStatus status,,) = promisesA.promises(chainedPromiseId);
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
        (CrossChainPromise.PromiseStatus proxyStatus,bytes memory proxyValue,) = promisesA.promises(remotePromiseId);
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
        (CrossChainPromise.PromiseStatus remoteStatus,bytes memory remoteValue,) = promisesB.promises(remotePromiseId);
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
        (CrossChainPromise.PromiseStatus finalStatus,bytes memory finalValue,) = promisesA.promises(remotePromiseId);
        assertEq(uint256(finalStatus), 1); // RESOLVED
        assertTrue(finalValue.length > 0);
        
        // Verify return value (doubled by remoteHandler)
        uint256 returnValue = abi.decode(finalValue, (uint256));
        assertEq(returnValue, testValue * 2);
        console.log("Local proxy updated with return value:", returnValue);
        
        console.log("SUCCESS: Complete cross-chain promise end-to-end flow verified!");
        console.log("Flow: Chain A ->", testValue, "-> Chain B -> Chain A ->", returnValue);
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
} 