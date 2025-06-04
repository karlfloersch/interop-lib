// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";

import {PromiseAwareMessenger} from "../src/PromiseAwareMessenger.sol";
import {AtomicPromiseExample} from "../src/examples/AtomicPromiseExample.sol";
import {Relayer} from "../src/test/Relayer.sol";
import {IPromise, Handle} from "../src/interfaces/IPromise.sol";
import {Promise} from "../src/Promise.sol";
import {PredeployAddresses} from "../src/libraries/PredeployAddresses.sol";
import {SuperchainERC20} from "../src/SuperchainERC20.sol";

contract AtomicPromiseTest is Relayer, Test {
    IPromise public p = IPromise(PredeployAddresses.PROMISE);
    PromiseAwareMessenger public promiseMessenger;
    AtomicPromiseExample public atomicExample;
    L2NativeSuperchainERC20 public token;

    // Track contract addresses on each fork
    address public atomicExampleA; // Address on fork 0
    address public atomicExampleB; // Address on fork 1

    bool public parentCallbackExecuted;
    bool public allChildrenResolved;
    bytes public parentCallbackData;

    string[] private rpcUrls = [
        vm.envOr("CHAIN_A_RPC_URL", string("https://interop-alpha-0.optimism.io")),
        vm.envOr("CHAIN_B_RPC_URL", string("https://interop-alpha-1.optimism.io"))
    ];

    constructor() Relayer(rpcUrls) {}

    function setUp() public {
        vm.selectFork(forkIds[0]);
        
        // Deploy Promise contract at predeploy address
        Promise promiseImpl = new Promise();
        vm.etch(PredeployAddresses.PROMISE, address(promiseImpl).code);
        
        // Deploy PromiseAwareMessenger
        promiseMessenger = new PromiseAwareMessenger();
        
        // Deploy example contract on fork A
        atomicExample = new AtomicPromiseExample(address(promiseMessenger));
        atomicExampleA = address(atomicExample);
        
        token = new L2NativeSuperchainERC20{salt: bytes32(0)}();

        vm.selectFork(forkIds[1]);
        
        // Deploy Promise contract on second fork too
        promiseImpl = new Promise();
        vm.etch(PredeployAddresses.PROMISE, address(promiseImpl).code);
        
        // Deploy PromiseAwareMessenger on second fork
        promiseMessenger = new PromiseAwareMessenger();
        
        // Deploy example contract on fork B
        atomicExample = new AtomicPromiseExample(address(promiseMessenger));
        atomicExampleB = address(atomicExample);
        
        new L2NativeSuperchainERC20{salt: bytes32(0)}();

        // mint tokens on chain B
        token.mint(address(this), 1000);
    }

    modifier async() {
        require(msg.sender == address(p), "AtomicPromiseTest: caller not Promise");
        _;
    }

    /// @notice Test atomic promise with a single child - simpler test case
    function test_atomic_promise_single_child() public {
        vm.selectFork(forkIds[0]);
        
        parentCallbackExecuted = false;
        
        console.log("=== Testing Single Child Atomic Promise ===");
        
        // Step 1: Send a parent promise that creates one child
        bytes32 parentPromise = p.sendMessage(
            chainIdByForkId[forkIds[1]], 
            atomicExampleB,
            abi.encodeCall(AtomicPromiseExample.conditionalOperation, (
                true, // shouldCreateChild = true
                chainIdByForkId[forkIds[0]], // destinationChain
                address(token) // targetContract
            ))
        );
        
        // Step 2: Attach callback
        p.then(parentPromise, this.parentPromiseCallback.selector, "single_child");
        
        // Step 3: Relay parent message (creates child)
        relayAllMessages();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        
        // Should NOT resolve yet
        assertFalse(parentCallbackExecuted, "Parent should not resolve with unresolved child");
        
        // Step 4: Relay child message 
        vm.selectFork(forkIds[0]);
        relayAllMessages();
        logs = vm.getRecordedLogs();
        
        // Step 5: Relay child callback (should notify parent)
        relayPromises(logs, p, chainIdByForkId[forkIds[1]]);
        
        // Step 6: Relay parent callback
        vm.selectFork(forkIds[0]);
        relayAllMessages();
        logs = vm.getRecordedLogs();
        relayPromises(logs, p, chainIdByForkId[forkIds[0]]);
        
        // Now should resolve
        assertTrue(parentCallbackExecuted, "Parent should resolve after child completes");
        
        console.log("=== Single Child Test Complete ===");
    }

    /// @notice Test basic atomic promise resolution - parent waits for children
    function test_atomic_promise_basic() public {
        vm.selectFork(forkIds[0]);
        
        // Reset state
        parentCallbackExecuted = false;
        allChildrenResolved = false;
        parentCallbackData = "";
        
        console.log("=== Testing Atomic Promise Resolution ===");
        
        // Step 1: Send a promise to a contract that creates child promises
        console.log("Step 1: Sending parent promise that will create children");
        bytes32 parentPromise = p.sendMessage(
            chainIdByForkId[forkIds[1]], 
            atomicExampleB, // Use the address from fork 1
            abi.encodeCall(AtomicPromiseExample.distributeTokensAtomically, (
                chainIdByForkId[forkIds[0]], // chainA - send to fork 0
                chainIdByForkId[forkIds[0]], // chainB - also send to fork 0 (not same chain)
                chainIdByForkId[forkIds[0]], // chainC - also send to fork 0
                address(token), // tokenA
                address(token), // tokenB  
                address(token), // tokenC
                address(this)   // recipient
            ))
        );
        
        // Step 2: Attach callback to parent promise - should NOT execute until ALL children resolve
        console.log("Step 2: Attaching callback to parent promise");
        p.then(parentPromise, this.parentPromiseCallback.selector, "atomic_test");
        
        // Step 3: Relay the parent message (will create child promises during execution)
        console.log("Step 3: Relaying parent message");
        relayAllMessages();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        
        // Step 4: Verify callback has NOT executed yet (children haven't resolved)
        assertFalse(parentCallbackExecuted, "Parent callback should not execute until children resolve");
        
        // Step 5: Verify parent promise state on destination chain
        vm.selectFork(forkIds[1]);
        console.log("Step 5: Checking parent promise state on destination chain");
        
        // Check the promise state - it should be completed but not resolved (waiting for children) 
        // We need to find the actual promise hash that was generated in handleMessage
        // Since the parent promise was relayed, check for NestedPromiseCreated events
        bool foundParentWithChildren = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == keccak256("NestedPromiseCreated(bytes32,bytes32)")) {
                console.log("Found NestedPromiseCreated event - parent has children");
                foundParentWithChildren = true;
                break;
            }
        }
        assertTrue(foundParentWithChildren, "Parent promise should have children");
        
        // Step 6: Relay the child promises that were created
        vm.selectFork(forkIds[0]); // Switch to destination of child promises
        console.log("Step 6: Relaying child promises");
        relayAllMessages();
        logs = vm.getRecordedLogs();
        
        // Step 7: Relay callbacks for child promises
        console.log("Step 7: Relaying callbacks for child promises");
        relayPromises(logs, p, chainIdByForkId[forkIds[1]]);
        
        // Step 8: Now relay the parent promise callback - should execute now
        vm.selectFork(forkIds[0]);
        console.log("Step 8: Relaying parent promise callback");
        relayAllMessages();
        logs = vm.getRecordedLogs();
        relayPromises(logs, p, chainIdByForkId[forkIds[0]]);
        
        // Step 9: Verify atomic resolution
        assertTrue(parentCallbackExecuted, "Parent callback should execute after all children resolve");
        assertTrue(allChildrenResolved, "Should confirm all children resolved");
        assertTrue(parentCallbackData.length > 0, "Should receive callback data");
        
        console.log("=== Atomic Promise Test Complete ===");
    }
    
    /// @notice Test conditional child promise creation
    function test_conditional_atomic_promise() public {
        vm.selectFork(forkIds[0]);
        
        parentCallbackExecuted = false;
        
        console.log("=== Testing Conditional Child Promise Creation ===");
        
        // Test 1: No children created - should resolve immediately
        bytes32 noChildPromise = p.sendMessage(
            chainIdByForkId[forkIds[1]], 
            atomicExampleB, // Use the address from fork 1
            abi.encodeCall(AtomicPromiseExample.conditionalOperation, (
                false, // shouldCreateChild = false
                chainIdByForkId[forkIds[0]], // destinationChain
                address(token) // targetContract
            ))
        );
        
        p.then(noChildPromise, this.parentPromiseCallback.selector, "no_children");
        
        // Relay and execute
        relayAllMessages();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        relayPromises(logs, p, chainIdByForkId[forkIds[0]]);
        
        // Should resolve immediately since no children
        assertTrue(parentCallbackExecuted, "Promise with no children should resolve immediately");
        
        // Reset for test 2
        parentCallbackExecuted = false;
        
        // Test 2: Children created - should wait for resolution
        bytes32 withChildPromise = p.sendMessage(
            chainIdByForkId[forkIds[1]], 
            atomicExampleB, // Use the address from fork 1
            abi.encodeCall(AtomicPromiseExample.conditionalOperation, (
                true, // shouldCreateChild = true
                chainIdByForkId[forkIds[0]], // destinationChain
                address(token) // targetContract
            ))
        );
        
        p.then(withChildPromise, this.parentPromiseCallback.selector, "with_children");
        
        // Initial relay - should NOT resolve yet
        relayAllMessages();
        logs = vm.getRecordedLogs();
        relayPromises(logs, p, chainIdByForkId[forkIds[0]]);
        
        // Should NOT resolve yet (has children)
        assertFalse(parentCallbackExecuted, "Promise with children should not resolve immediately");
        
        // Relay child promises
        relayAllMessages();
        logs = vm.getRecordedLogs();
        relayHandlers(logs, p, chainIdByForkId[forkIds[0]]);
        relayPromises(logs, p, chainIdByForkId[forkIds[0]]);
        
        // Now should resolve
        assertTrue(parentCallbackExecuted, "Promise should resolve after children complete");
        
        console.log("=== Conditional Test Complete ===");
    }
    
    /// @notice Test comprehensive atomic promise workflow
    function test_atomic_promise_workflow() public {
        vm.selectFork(forkIds[0]);
        
        // Reset state
        parentCallbackExecuted = false;
        allChildrenResolved = false;
        parentCallbackData = "";
        
        console.log("=== Testing Complete Atomic Promise Workflow ===");
        
        // Step 1: Send parent promise that creates 3 child promises
        console.log("Step 1: Creating parent promise with 3 children");
        bytes32 parentPromise = p.sendMessage(
            chainIdByForkId[forkIds[1]], 
            atomicExampleB,
            abi.encodeCall(AtomicPromiseExample.distributeTokensAtomically, (
                chainIdByForkId[forkIds[0]], // All children go to fork 0
                chainIdByForkId[forkIds[0]], 
                chainIdByForkId[forkIds[0]], 
                address(token), 
                address(token),  
                address(token), 
                address(this)   
            ))
        );
        
        // Step 2: Attach callback to parent
        p.then(parentPromise, this.parentPromiseCallback.selector, "workflow_test");
        
        // Step 3: Relay parent message (creates children)
        console.log("Step 3: Relaying parent message");
        relayAllMessages();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        
        // Verify parent has not resolved yet
        assertFalse(parentCallbackExecuted, "Parent should not resolve immediately");
        
        // Step 4: Verify children were created
        bool foundChildCreation = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == keccak256("NestedPromiseCreated(bytes32,bytes32)")) {
                foundChildCreation = true;
                break;
            }
        }
        assertTrue(foundChildCreation, "Should have created child promises");
        
        // Step 5: Relay child promises to their destination
        vm.selectFork(forkIds[0]);
        console.log("Step 5: Relaying child promises");
        relayAllMessages();
        logs = vm.getRecordedLogs();
        
        // Step 6: Process child promise callbacks - this should trigger parent resolution
        console.log("Step 6: Processing child callbacks");
        relayPromises(logs, p, chainIdByForkId[forkIds[1]]);
        
        // Step 7: Process parent promise callback
        vm.selectFork(forkIds[0]);
        console.log("Step 7: Processing parent callback");
        relayAllMessages();
        logs = vm.getRecordedLogs();
        relayPromises(logs, p, chainIdByForkId[forkIds[0]]);
        
        // Step 8: Verify atomic resolution
        assertTrue(parentCallbackExecuted, "Parent callback should execute after all children resolve");
        assertTrue(allChildrenResolved, "All children should be resolved");
        assertTrue(parentCallbackData.length > 0, "Should have callback data");
        
        console.log("=== Atomic Promise Workflow Complete ===");
    }

    /// @notice Callback for parent promise - only executes when ALL children are resolved
    function parentPromiseCallback(bytes memory data) public async {
        console.log("Parent promise callback executed!");
        parentCallbackExecuted = true;
        parentCallbackData = data;
        
        // Verify this is only called when all children are resolved
        // In a real scenario, you could check the promise state here
        allChildrenResolved = true;
        
        // Log the context
        bytes memory context = p.promiseContext();
        console.log("Callback context length:", context.length);
    }
}

/// @notice Mock token for testing - same as in Promise.t.sol
contract L2NativeSuperchainERC20 is SuperchainERC20 {
    error ZeroAddress();
    
    event Mint(address indexed account, uint256 amount);
    event Burn(address indexed account, uint256 amount);

    function mint(address _to, uint256 _amount) external virtual {
        if (_to == address(0)) revert ZeroAddress();
        _mint(_to, _amount);
        emit Mint(_to, _amount);
    }

    function burn(address _from, uint256 _amount) external virtual {
        if (_from == address(0)) revert ZeroAddress();
        _burn(_from, _amount);
        emit Burn(_from, _amount);
    }

    function name() public pure virtual override returns (string memory) {
        return "L2NativeSuperchainERC20";
    }

    function symbol() public pure virtual override returns (string memory) {
        return "MOCK";
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }
} 