// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {Promise} from "../src/Promise.sol";
import {SetTimeout} from "../src/SetTimeout.sol";
import {Callback} from "../src/Callback.sol";
import {PromiseHarness} from "./PromiseHarness.sol";

contract PromiseHarnessTest is Test {
    Promise public promiseContract;
    SetTimeout public setTimeoutContract;
    Callback public callbackContract;
    PromiseHarness public harness;
    
    address public alice = address(0x1);
    address public bob = address(0x2);

    event PromisesResolved(uint256 promisesResolved);

    function setUp() public {
        promiseContract = new Promise(address(0));
        setTimeoutContract = new SetTimeout(address(promiseContract));
        callbackContract = new Callback(address(promiseContract));
        
        address[] memory resolvableContracts = new address[](2);
        resolvableContracts[0] = address(setTimeoutContract);
        resolvableContracts[1] = address(callbackContract);
        
        harness = new PromiseHarness(
            address(promiseContract),
            resolvableContracts
        );
    }

    function test_resolveTimeouts() public {
        // Create some timeout promises
        vm.prank(alice);
        uint256 timeout1 = setTimeoutContract.create(block.timestamp + 100);
        
        vm.prank(bob);
        uint256 timeout2 = setTimeoutContract.create(block.timestamp + 200);
        
        // Check pending count
        uint256 pendingPromises = harness.countPendingAuto();
        assertEq(pendingPromises, 0, "Should be 0 pending promises before time passes");
        
        // Fast forward past first timeout
        vm.warp(block.timestamp + 150);
        
        pendingPromises = harness.countPendingAuto();
        assertEq(pendingPromises, 1, "Should be 1 pending promise");
        
        // Resolve pending promises (first layer - timeouts only)
        vm.expectEmit(false, false, false, true);
        emit PromisesResolved(1);
        
        uint256 promisesResolved = harness.resolveAllPendingAuto();
        assertEq(promisesResolved, 1, "Should resolve 1 promise");
        
        // Check timeout1 is resolved, timeout2 is still pending
        assertEq(uint256(promiseContract.status(timeout1)), uint256(Promise.PromiseStatus.Resolved), "Timeout1 should be resolved");
        assertEq(uint256(promiseContract.status(timeout2)), uint256(Promise.PromiseStatus.Pending), "Timeout2 should still be pending");
        
        // Fast forward past second timeout and resolve
        vm.warp(block.timestamp + 100);
        promisesResolved = harness.resolveAllPendingAuto();
        assertEq(promisesResolved, 1, "Should resolve 1 more promise");
        
        assertEq(uint256(promiseContract.status(timeout2)), uint256(Promise.PromiseStatus.Resolved), "Timeout2 should be resolved");
    }

    function test_resolveCallbacks() public {
        // Create a manual promise that we'll resolve
        vm.prank(alice);
        uint256 parentPromise = promiseContract.create();
        
        // Create callbacks on that promise
        TestTarget target = new TestTarget();
        vm.prank(bob);
        uint256 callback1 = callbackContract.then(parentPromise, address(target), target.handleSuccess.selector);
        
        vm.prank(bob);
        uint256 callback2 = callbackContract.onReject(parentPromise, address(target), target.handleError.selector);
        
        // Check pending count
        uint256 pendingPromises = harness.countPendingAuto();
        assertEq(pendingPromises, 0, "Should be 0 pending promises (parent not settled)");
        
        // Resolve parent promise
        vm.prank(alice);
        promiseContract.resolve(parentPromise, abi.encode(uint256(42)));
        
        // Now callbacks should be resolvable
        pendingPromises = harness.countPendingAuto();
        assertEq(pendingPromises, 2, "Should be 2 resolvable callbacks"); // Both can be resolved (then executes, catch rejects)
        
        // Resolve callbacks
        uint256 promisesResolved = harness.resolveAllPendingAuto();
        assertEq(promisesResolved, 2, "Should resolve 2 callbacks");
        
        // Check results
        assertEq(uint256(promiseContract.status(callback1)), uint256(Promise.PromiseStatus.Resolved), "Then callback should be resolved");
        assertEq(uint256(promiseContract.status(callback2)), uint256(Promise.PromiseStatus.Rejected), "Catch callback should be rejected");
        
        assertTrue(target.successCalled(), "Success handler should have been called");
        assertFalse(target.errorCalled(), "Error handler should not have been called");
    }

    function test_countPending() public {
        // Initially no pending promises
        uint256 pendingPromises = harness.countPendingAuto();
        assertEq(pendingPromises, 0, "Should start with 0 pending promises");
        
        // Create a timeout
        vm.prank(alice);
        setTimeoutContract.create(block.timestamp + 100);
        
        // Create a manual promise and callback
        vm.prank(alice);
        uint256 parentPromise = promiseContract.create();
        
        TestTarget target = new TestTarget();
        vm.prank(bob);
        callbackContract.then(parentPromise, address(target), target.handleSuccess.selector);
        
        // Should still be 0 pending (timeout not ready, parent not settled)
        pendingPromises = harness.countPendingAuto();
        assertEq(pendingPromises, 0, "Timeout not ready yet, parent not settled yet");
        
        // Fast forward time
        vm.warp(block.timestamp + 150);
        
        pendingPromises = harness.countPendingAuto();
        assertEq(pendingPromises, 1, "Should have 1 pending timeout");
        
        // Resolve parent promise
        vm.prank(alice);
        promiseContract.resolve(parentPromise, abi.encode(uint256(42)));
        
        pendingPromises = harness.countPendingAuto();
        assertEq(pendingPromises, 2, "Should now have 2 pending promises (1 timeout + 1 callback)");
    }

    function test_getAllPromiseStatuses() public {
        // Create some promises in different states
        vm.prank(alice);
        uint256 promise1 = promiseContract.create(); // Will stay pending
        
        vm.prank(alice);
        uint256 promise2 = promiseContract.create(); // Will be resolved
        
        vm.prank(alice);
        uint256 promise3 = promiseContract.create(); // Will be rejected
        
        // Resolve and reject some promises
        vm.prank(alice);
        promiseContract.resolve(promise2, abi.encode("resolved"));
        
        vm.prank(alice);
        promiseContract.reject(promise3, abi.encode("rejected"));
        
        // Get all statuses
        uint8[] memory statuses = harness.getAllPromiseStatuses(3);
        
        assertEq(statuses.length, 3, "Should return 3 statuses");
        assertEq(statuses[0], uint8(Promise.PromiseStatus.Pending), "Promise 1 should be pending");
        assertEq(statuses[1], uint8(Promise.PromiseStatus.Resolved), "Promise 2 should be resolved");
        assertEq(statuses[2], uint8(Promise.PromiseStatus.Rejected), "Promise 3 should be rejected");
    }

    function test_resolveAllPendingWithRange() public {
        // Create promises 1-5
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(alice);
            setTimeoutContract.create(block.timestamp + 100);
        }
        
        // Fast forward time
        vm.warp(block.timestamp + 150);
        
        // Resolve only first 3 promises
        uint256 promisesResolved = harness.resolveAllPending(3);
        assertEq(promisesResolved, 3, "Should resolve exactly 3 promises");
        
        // Check that promises 4 and 5 are still pending
        assertEq(uint256(promiseContract.status(4)), uint256(Promise.PromiseStatus.Pending), "Promise 4 should still be pending");
        assertEq(uint256(promiseContract.status(5)), uint256(Promise.PromiseStatus.Pending), "Promise 5 should still be pending");
        
        // Resolve the rest
        promisesResolved = harness.resolveAllPending(5);
        assertEq(promisesResolved, 2, "Should resolve remaining 2 promises");
    }

    function test_handleResolveErrors() public {
        // Create a timeout
        vm.prank(alice);
        uint256 timeoutPromise = setTimeoutContract.create(block.timestamp + 100);
        
        // Fast forward time
        vm.warp(block.timestamp + 150);
        
        // Manually resolve the timeout first
        setTimeoutContract.resolve(timeoutPromise);
        
        // Now harness should handle the error gracefully when trying to resolve again
        uint256 promisesResolved = harness.resolveAllPendingAuto();
        assertEq(promisesResolved, 0, "Should resolve 0 promises (already resolved)");
        
        // Should not revert
    }

    function test_emptyResolve() public {
        // With no promises, should handle gracefully
        uint256 promisesResolved = harness.resolveAllPendingAuto();
        assertEq(promisesResolved, 0, "Should resolve 0 promises");
    }

    function test_layeredResolution() public {
        // Create a timeout
        vm.prank(alice);
        uint256 timeoutPromise = setTimeoutContract.create(block.timestamp + 100);
        
        // Create callback on the timeout
        TestTarget target = new TestTarget();
        vm.prank(bob);
        uint256 callbackPromise = callbackContract.then(timeoutPromise, address(target), target.handleSuccess.selector);
        
        // Fast forward time
        vm.warp(block.timestamp + 150);
        
        // First call should only resolve the timeout (layer 1)
        uint256 promisesResolved1 = harness.resolveAllPendingAuto();
        assertEq(promisesResolved1, 1, "First call should resolve 1 promise");
        
        // Timeout should be resolved, callback should still be pending
        assertEq(uint256(promiseContract.status(timeoutPromise)), uint256(Promise.PromiseStatus.Resolved), "Timeout should be resolved");
        assertEq(uint256(promiseContract.status(callbackPromise)), uint256(Promise.PromiseStatus.Pending), "Callback should still be pending");
        
        // Second call should resolve the callback (layer 2)
        uint256 promisesResolved2 = harness.resolveAllPendingAuto();
        assertEq(promisesResolved2, 1, "Second call should resolve 1 callback");
        
        // Now both should be resolved
        assertEq(uint256(promiseContract.status(timeoutPromise)), uint256(Promise.PromiseStatus.Resolved), "Timeout should be resolved");
        assertEq(uint256(promiseContract.status(callbackPromise)), uint256(Promise.PromiseStatus.Resolved), "Callback should be resolved");
        
        // Third call should resolve nothing
        uint256 promisesResolved3 = harness.resolveAllPendingAuto();
        assertEq(promisesResolved3, 0, "Third call should resolve 0 promises");
    }

    function test_resolveAllLayers() public {
        // Create a timeout
        vm.prank(alice);
        uint256 timeoutPromise = setTimeoutContract.create(block.timestamp + 100);
        
        // Create callback on the timeout
        TestTarget target = new TestTarget();
        vm.prank(bob);
        callbackContract.then(timeoutPromise, address(target), target.handleSuccess.selector);
        
        // Fast forward time
        vm.warp(block.timestamp + 150);
        
        // Use resolveAllLayers to resolve everything at once
        (uint256 totalPromises, uint256 layers) = harness.resolveAllLayers();
        assertEq(totalPromises, 2, "Should resolve 2 promises total");
        assertEq(layers, 2, "Should process 2 layers");
        
        // All promises should be resolved
        assertEq(uint256(promiseContract.status(timeoutPromise)), uint256(Promise.PromiseStatus.Resolved), "Timeout should be resolved");
    }
}

/// @notice Test contract for callback functionality
contract TestTarget {
    uint256 public lastValue;
    bool public successCalled;
    bool public errorCalled;

    function handleSuccess(bytes memory data) external returns (uint256) {
        successCalled = true;
        
        if (data.length == 0) {
            // Handle empty data (e.g., from SetTimeout)
            lastValue = 0;
            return 1; // Return a default value
        } else {
            uint256 value = abi.decode(data, (uint256));
            lastValue = value;
            return value * 2;
        }
    }

    function handleError(bytes memory data) external returns (string memory) {
        errorCalled = true;
        string memory errorMsg = abi.decode(data, (string));
        return string(abi.encodePacked("Handled: ", errorMsg));
    }
} 