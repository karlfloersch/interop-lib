// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {Promise} from "../src/Promise.sol";
import {SetTimeout} from "../src/SetTimeout.sol";
import {Callback} from "../src/Callback.sol";
import {PromiseHarness} from "./PromiseHarness.sol";

/// @title E2E Test - SetTimeout → Callback Chain
/// @notice End-to-end test demonstrating the complete promise system working together
contract E2ETest is Test {
    Promise public promiseContract;
    SetTimeout public setTimeoutContract;
    Callback public callbackContract;
    PromiseHarness public harness;
    
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public charlie = address(0x3);

    function setUp() public {
        promiseContract = new Promise(address(0));
        setTimeoutContract = new SetTimeout(address(promiseContract));
        callbackContract = new Callback(address(promiseContract), address(0));
        
        address[] memory resolvableContracts = new address[](2);
        resolvableContracts[0] = address(setTimeoutContract);
        resolvableContracts[1] = address(callbackContract);
        
        harness = new PromiseHarness(
            address(promiseContract),
            resolvableContracts
        );
    }

    /// @notice Test the basic SetTimeout → Callback flow
    function test_setTimeoutThenCallback() public {
        // Create test targets
        SimpleTarget target1 = new SimpleTarget();
        SimpleTarget target2 = new SimpleTarget();
        
        // 1. Create a SetTimeout promise that resolves in 100 seconds
        vm.prank(alice);
        uint256 timeoutPromise = setTimeoutContract.create(block.timestamp + 100);
        
        // 2. Register callbacks on the timeout promise
        vm.prank(bob);
        uint256 callback1 = callbackContract.then(timeoutPromise, address(target1), target1.onTimeout.selector);
        
        vm.prank(charlie);
        uint256 callback2 = callbackContract.then(timeoutPromise, address(target2), target2.onTimeout.selector);
        
        // 3. Initially, nothing should be resolvable
        uint256 pendingPromises = harness.countPendingAuto();
        assertEq(pendingPromises, 0, "No promises ready yet");
        
        // All promises should be pending
        assertEq(uint256(promiseContract.status(timeoutPromise)), uint256(Promise.PromiseStatus.Pending), "Timeout promise should be pending");
        assertEq(uint256(promiseContract.status(callback1)), uint256(Promise.PromiseStatus.Pending), "Callback 1 should be pending");
        assertEq(uint256(promiseContract.status(callback2)), uint256(Promise.PromiseStatus.Pending), "Callback 2 should be pending");
        
        // 4. Fast forward time to make timeout resolvable
        vm.warp(block.timestamp + 150);
        
        pendingPromises = harness.countPendingAuto();
        assertEq(pendingPromises, 1, "Should have 1 resolvable promise");
        
        // 5. Use harness to auto-resolve everything (first layer)
        uint256 promisesResolved = harness.resolveAllPendingAuto();
        assertEq(promisesResolved, 1, "Should resolve 1 promise (timeout)");
        
        // 6. Resolve second layer (callbacks)
        promisesResolved = harness.resolveAllPendingAuto();
        assertEq(promisesResolved, 2, "Should resolve 2 callbacks");
        
        // 6. Verify final state
        assertEq(uint256(promiseContract.status(timeoutPromise)), uint256(Promise.PromiseStatus.Resolved), "Timeout promise should be resolved");
        assertEq(uint256(promiseContract.status(callback1)), uint256(Promise.PromiseStatus.Resolved), "Callback 1 should be resolved");
        assertEq(uint256(promiseContract.status(callback2)), uint256(Promise.PromiseStatus.Resolved), "Callback 2 should be resolved");
        
        // 7. Verify callback targets were called
        assertTrue(target1.called(), "Target 1 should have been called");
        assertTrue(target2.called(), "Target 2 should have been called");
        assertEq(target1.receivedData(), "", "Target 1 should receive empty data from timeout");
        assertEq(target2.receivedData(), "", "Target 2 should receive empty data from timeout");
        
        // 8. No more pending promises
        pendingPromises = harness.countPendingAuto();
        assertEq(pendingPromises, 0, "No pending promises");
    }

    /// @notice Test chaining callbacks - callback returns another promise
    function test_callbackChaining() public {
        ChainTarget chainTarget = new ChainTarget(address(promiseContract));
        SimpleTarget finalTarget = new SimpleTarget();
        
        // 1. Create initial timeout
        vm.prank(alice);
        uint256 timeoutPromise = setTimeoutContract.create(block.timestamp + 100);
        
        // 2. Chain target will create a new promise when called
        vm.prank(bob);
        uint256 chainCallback = callbackContract.then(timeoutPromise, address(chainTarget), chainTarget.createNewPromise.selector);
        
        // 3. Fast forward and resolve initial timeout
        vm.warp(block.timestamp + 150);
        harness.resolveAllPendingAuto(); // Resolve timeout
        harness.resolveAllPendingAuto(); // Resolve callback (chainTarget)
        
        // 4. ChainTarget should have been called and created a new promise
        assertTrue(chainTarget.called(), "Chain target should have been called");
        uint256 newPromiseId = chainTarget.createdPromiseId();
        assertTrue(newPromiseId > 0, "Should have created a new promise");
        
        // 5. Register callback on the new promise
        vm.prank(charlie);
        uint256 finalCallback = callbackContract.then(newPromiseId, address(finalTarget), finalTarget.onTimeout.selector);
        
        // 6. Manually resolve the new promise
        vm.prank(address(chainTarget));
        promiseContract.resolve(newPromiseId, abi.encode("chained result"));
        
        // 7. Resolve final callback
        harness.resolveAllPendingAuto();
        
        // 8. Verify final callback was executed
        assertTrue(finalTarget.called(), "Final target should have been called");
        assertEq(finalTarget.receivedData(), "chained result", "Final target should receive chained data");
    }

    /// @notice Test multiple timeouts with different delays
    function test_multipleTimeoutsWithCallbacks() public {
        SimpleTarget target1 = new SimpleTarget();
        SimpleTarget target2 = new SimpleTarget();
        SimpleTarget target3 = new SimpleTarget();
        
        // Create timeouts with staggered delays
        vm.prank(alice);
        uint256 timeout1 = setTimeoutContract.create(block.timestamp + 50);  // Resolves first
        
        vm.prank(alice);
        uint256 timeout2 = setTimeoutContract.create(block.timestamp + 100); // Resolves second
        
        vm.prank(alice);
        uint256 timeout3 = setTimeoutContract.create(block.timestamp + 150); // Resolves third
        
        // Register callbacks
        vm.prank(bob);
        callbackContract.then(timeout1, address(target1), target1.onTimeout.selector);
        
        vm.prank(bob);
        callbackContract.then(timeout2, address(target2), target2.onTimeout.selector);
        
        vm.prank(bob);
        callbackContract.then(timeout3, address(target3), target3.onTimeout.selector);
        
        // Test resolution at different time points
        
        // After 60 seconds - only timeout1 should resolve
        vm.warp(block.timestamp + 60);
        harness.resolveAllPendingAuto(); // Resolve timeout1
        harness.resolveAllPendingAuto(); // Resolve callback on timeout1
        
        assertTrue(target1.called(), "Target 1 should be called after 60s");
        assertFalse(target2.called(), "Target 2 should not be called yet");
        assertFalse(target3.called(), "Target 3 should not be called yet");
        
        // After 110 seconds - timeout2 should also resolve
        vm.warp(block.timestamp + 50);
        harness.resolveAllPendingAuto(); // Resolve timeout2
        harness.resolveAllPendingAuto(); // Resolve callback on timeout2
        
        assertTrue(target1.called(), "Target 1 should still be called");
        assertTrue(target2.called(), "Target 2 should now be called");
        assertFalse(target3.called(), "Target 3 should not be called yet");
        
        // After 160 seconds - timeout3 should resolve
        vm.warp(block.timestamp + 50);
        harness.resolveAllPendingAuto(); // Resolve timeout3
        harness.resolveAllPendingAuto(); // Resolve callback on timeout3
        
        assertTrue(target1.called(), "Target 1 should still be called");
        assertTrue(target2.called(), "Target 2 should still be called");
        assertTrue(target3.called(), "Target 3 should now be called");
        
        // All promises should be resolved
        assertEq(uint256(promiseContract.status(timeout1)), uint256(Promise.PromiseStatus.Resolved), "Timeout 1 should be resolved");
        assertEq(uint256(promiseContract.status(timeout2)), uint256(Promise.PromiseStatus.Resolved), "Timeout 2 should be resolved");
        assertEq(uint256(promiseContract.status(timeout3)), uint256(Promise.PromiseStatus.Resolved), "Timeout 3 should be resolved");
    }

    /// @notice Test error handling - callbacks that fail
    function test_errorHandling() public {
        FailingTarget failingTarget = new FailingTarget();
        SimpleTarget normalTarget = new SimpleTarget();
        ErrorTarget errorTarget = new ErrorTarget();
        
        // Create timeout
        vm.prank(alice);
        uint256 timeoutPromise = setTimeoutContract.create(block.timestamp + 100);
        
        // Register callbacks - one that fails, one that succeeds
        vm.prank(bob);
        uint256 failingCallback = callbackContract.then(timeoutPromise, address(failingTarget), failingTarget.alwaysFails.selector);
        
        vm.prank(bob);
        uint256 normalCallback = callbackContract.then(timeoutPromise, address(normalTarget), normalTarget.onTimeout.selector);
        
        // Resolve timeout first
        vm.warp(block.timestamp + 150);
        harness.resolveAllPendingAuto(); // Resolve timeout
        harness.resolveAllPendingAuto(); // Resolve callbacks (failing and normal)
        
        // Check states
        assertEq(uint256(promiseContract.status(timeoutPromise)), uint256(Promise.PromiseStatus.Resolved), "Timeout should be resolved");
        assertEq(uint256(promiseContract.status(failingCallback)), uint256(Promise.PromiseStatus.Rejected), "Failing callback should be rejected");
        assertEq(uint256(promiseContract.status(normalCallback)), uint256(Promise.PromiseStatus.Resolved), "Normal callback should be resolved");
        
        // Normal target should have been called
        assertTrue(normalTarget.called(), "Normal target should have been called");
        
        // Now register an onReject callback on the failing callback (which is now rejected)
        vm.prank(charlie);
        uint256 errorCallback = callbackContract.onReject(failingCallback, address(errorTarget), errorTarget.handleError.selector);
        
        // Error callback should be resolvable now since failingCallback is rejected
        assertTrue(callbackContract.canResolve(errorCallback), "Error callback should be resolvable");
        harness.resolveAllPendingAuto();
        
        // Error target should have been called
        assertTrue(errorTarget.called(), "Error target should have been called");
        assertEq(uint256(promiseContract.status(errorCallback)), uint256(Promise.PromiseStatus.Resolved), "Error callback should be resolved");
    }

    /// @notice Comprehensive test showing the full promise system in action
    function test_comprehensiveE2E() public {
        // This test demonstrates a complex scenario with multiple promise types and chains
        
        SimpleTarget target1 = new SimpleTarget();
        ChainTarget chainTarget = new ChainTarget(address(promiseContract));
        SimpleTarget finalTarget = new SimpleTarget();
        
        // 1. Create multiple timeouts
        vm.prank(alice);
        uint256 shortTimeout = setTimeoutContract.create(block.timestamp + 50);
        
        vm.prank(alice);
        uint256 longTimeout = setTimeoutContract.create(block.timestamp + 200);
        
        // 2. Register callbacks on short timeout
        vm.prank(bob);
        uint256 simpleCallback = callbackContract.then(shortTimeout, address(target1), target1.onTimeout.selector);
        
        vm.prank(bob);
        uint256 chainingCallback = callbackContract.then(shortTimeout, address(chainTarget), chainTarget.createNewPromise.selector);
        
        // 3. Also register callback on long timeout
        vm.prank(charlie);
        uint256 laterCallback = callbackContract.then(longTimeout, address(finalTarget), finalTarget.onTimeout.selector);
        
        // 4. Start with everything pending
        uint8[] memory initialStatuses = harness.getAllPromiseStatuses(5);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(initialStatuses[i], uint8(Promise.PromiseStatus.Pending), "All promises should start pending");
        }
        
        // 5. Fast forward to resolve short timeout
        vm.warp(block.timestamp + 60);
        uint256 promisesResolved = harness.resolveAllPendingAuto();
        assertEq(promisesResolved, 1, "Should resolve short timeout");
        
        // Resolve callbacks in second layer
        promisesResolved = harness.resolveAllPendingAuto();
        assertEq(promisesResolved, 2, "Should resolve callbacks on short timeout");
        
        // 6. Check intermediate state
        assertTrue(target1.called(), "Simple target should be called");
        assertTrue(chainTarget.called(), "Chain target should be called");
        assertFalse(finalTarget.called(), "Final target should not be called yet");
        
        // 7. Chain target created a new promise - register callback on it
        uint256 newPromise = chainTarget.createdPromiseId();
        vm.prank(alice);
        callbackContract.then(newPromise, address(finalTarget), finalTarget.onTimeout.selector);
        
        // 8. Resolve the new promise manually
        vm.prank(address(chainTarget));
        promiseContract.resolve(newPromise, abi.encode("manual resolution"));
        
        harness.resolveAllPendingAuto(); // Resolve the new callback
        
        // 9. Now final target should be called from the chained promise
        assertTrue(finalTarget.called(), "Final target should now be called from chain");
        assertEq(finalTarget.receivedData(), "manual resolution", "Should receive manual data");
        
        // 10. Fast forward to resolve long timeout
        vm.warp(block.timestamp + 160);
        harness.resolveAllPendingAuto(); // Resolve long timeout
        harness.resolveAllPendingAuto(); // Resolve callback on long timeout
        
        // 11. Verify everything is resolved
        uint256 pendingPromises = harness.countPendingAuto();
        assertEq(pendingPromises, 0, "No pending promises at end");
        
        // This test demonstrates:
        // - Multiple timeouts with different delays
        // - Callbacks that execute in sequence
        // - Callback chaining (callback creates new promise)
        // - Manual promise resolution
        // - Auto-resolution via harness
        // - Complex promise orchestration
    }
}

/// @notice Simple test target that records when it's called
contract SimpleTarget {
    bool public called;
    string public receivedData;
    
    function onTimeout(bytes memory data) external returns (string memory) {
        called = true;
        if (data.length > 0) {
            receivedData = abi.decode(data, (string));
        } else {
            receivedData = ""; // Handle empty data from SetTimeout
        }
        return "timeout handled";
    }
}

/// @notice Target that creates a new promise when called
contract ChainTarget {
    bool public called;
    uint256 public createdPromiseId;
    Promise public promiseContract;
    
    constructor(address _promiseContract) {
        promiseContract = Promise(_promiseContract);
    }
    
    function createNewPromise(bytes memory) external returns (uint256) {
        called = true;
        createdPromiseId = promiseContract.create();
        return createdPromiseId;
    }
}

/// @notice Target that always fails
contract FailingTarget {
    function alwaysFails(bytes memory) external pure returns (uint256) {
        revert("This always fails");
    }
}

/// @notice Target for handling errors
contract ErrorTarget {
    bool public called;
    
    function handleError(bytes memory errorData) external returns (string memory) {
        called = true;
        return "error handled";
    }
} 