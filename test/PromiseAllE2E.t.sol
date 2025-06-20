// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {Promise} from "../src/Promise.sol";
import {PromiseAll} from "../src/PromiseAll.sol";
import {SetTimeout} from "../src/SetTimeout.sol";
import {Callback} from "../src/Callback.sol";
import {PromiseHarness} from "./PromiseHarness.sol";

/// @title PromiseAll E2E Integration Test
/// @notice Demonstrates PromiseAll working with PromiseHarness and other promise types
contract PromiseAllE2ETest is Test {
    Promise public promiseContract;
    PromiseAll public promiseAllContract;
    SetTimeout public setTimeoutContract;
    Callback public callbackContract;
    PromiseHarness public harness;
    
    address public alice = address(0x1);
    address public bob = address(0x2);

    function setUp() public {
        promiseContract = new Promise();
        promiseAllContract = new PromiseAll(address(promiseContract));
        setTimeoutContract = new SetTimeout(address(promiseContract));
        callbackContract = new Callback(address(promiseContract));
        
        // Create harness with all resolvable contracts including PromiseAll
        address[] memory resolvableContracts = new address[](3);
        resolvableContracts[0] = address(setTimeoutContract);
        resolvableContracts[1] = address(callbackContract);
        resolvableContracts[2] = address(promiseAllContract);
        
        harness = new PromiseHarness(
            address(promiseContract),
            resolvableContracts
        );
    }

    /// @notice Test PromiseAll integration with harness automation
    function test_promiseAllWithHarnessAutomation() public {
        // Create some timeout promises that will be combined with PromiseAll
        vm.prank(alice);
        uint256 timeout1 = setTimeoutContract.create(block.timestamp + 100);
        
        vm.prank(alice);  
        uint256 timeout2 = setTimeoutContract.create(block.timestamp + 150);
        
        // Create a PromiseAll that waits for both timeouts
        uint256[] memory inputPromises = new uint256[](2);
        inputPromises[0] = timeout1;
        inputPromises[1] = timeout2;
        
        vm.prank(bob);
        uint256 promiseAllId = promiseAllContract.create(inputPromises);
        
        // Create a callback on the PromiseAll result
        TestTarget target = new TestTarget();
        vm.prank(alice);
        uint256 finalCallback = callbackContract.then(promiseAllId, address(target), target.handlePromiseAllResult.selector);
        
        // Initially nothing is resolvable
        uint256 pending = harness.countPendingAuto();
        assertEq(pending, 0, "No promises should be resolvable initially");
        
        // Fast forward to make first timeout resolvable
        vm.warp(block.timestamp + 120);
        
        // Should be able to resolve one timeout
        pending = harness.countPendingAuto();
        assertEq(pending, 1, "Should have 1 resolvable timeout");
        
        // Resolve first timeout
        uint256 resolved = harness.resolveAllPendingAuto();
        assertEq(resolved, 1, "Should resolve 1 timeout");
        
        // PromiseAll still can't resolve (waiting for timeout2)
        assertFalse(promiseAllContract.canResolve(promiseAllId), "PromiseAll should not be resolvable yet");
        
        // Fast forward to make second timeout resolvable  
        vm.warp(block.timestamp + 50);
        
        // Now should be able to resolve timeout2
        resolved = harness.resolveAllPendingAuto();
        assertEq(resolved, 1, "Should resolve second timeout");
        
        // Now PromiseAll should be resolvable
        assertTrue(promiseAllContract.canResolve(promiseAllId), "PromiseAll should be resolvable now");
        
        // Resolve PromiseAll
        resolved = harness.resolveAllPendingAuto();
        assertEq(resolved, 1, "Should resolve PromiseAll");
        
        // Finally resolve the callback on PromiseAll
        resolved = harness.resolveAllPendingAuto();
        assertEq(resolved, 1, "Should resolve final callback");
        
        // Verify everything is resolved
        assertEq(uint256(promiseContract.status(timeout1)), uint256(Promise.PromiseStatus.Resolved), "Timeout1 should be resolved");
        assertEq(uint256(promiseContract.status(timeout2)), uint256(Promise.PromiseStatus.Resolved), "Timeout2 should be resolved");  
        assertEq(uint256(promiseContract.status(promiseAllId)), uint256(Promise.PromiseStatus.Resolved), "PromiseAll should be resolved");
        assertEq(uint256(promiseContract.status(finalCallback)), uint256(Promise.PromiseStatus.Resolved), "Final callback should be resolved");
        
        // Verify the callback was executed with PromiseAll result
        assertTrue(target.called(), "Target should have been called");
        assertEq(target.receivedArrayLength(), 2, "Should have received array of 2 values");
        
        // No more pending promises
        pending = harness.countPendingAuto();
        assertEq(pending, 0, "No more pending promises");
    }

    /// @notice Test PromiseAll with mixed promise types and failure scenarios  
    function test_promiseAllWithFailureAndHarness() public {
        // Create a manual promise (will be rejected)
        vm.prank(alice);
        uint256 manualPromise = promiseContract.create();
        
        // Create a timeout promise (will be resolved)
        vm.prank(alice);
        uint256 timeoutPromise = setTimeoutContract.create(block.timestamp + 100);
        
        // Create PromiseAll 
        uint256[] memory inputPromises = new uint256[](2);
        inputPromises[0] = manualPromise;
        inputPromises[1] = timeoutPromise;
        
        vm.prank(bob);
        uint256 promiseAllId = promiseAllContract.create(inputPromises);
        
        // Create an error handler callback
        ErrorTarget errorTarget = new ErrorTarget();
        vm.prank(alice);
        uint256 errorCallback = callbackContract.onReject(promiseAllId, address(errorTarget), errorTarget.handleError.selector);
        
        // Reject the manual promise first (should make PromiseAll resolvable immediately)
        vm.prank(alice);
        promiseContract.reject(manualPromise, abi.encode("manual error"));
        
        // PromiseAll should be resolvable due to fail-fast behavior
        assertTrue(promiseAllContract.canResolve(promiseAllId), "PromiseAll should be resolvable after rejection");
        
        // Use harness to resolve (will reject PromiseAll)
        uint256 resolved = harness.resolveAllPendingAuto();
        assertEq(resolved, 1, "Should resolve (reject) PromiseAll");
        
        // Verify PromiseAll was rejected
        assertEq(uint256(promiseContract.status(promiseAllId)), uint256(Promise.PromiseStatus.Rejected), "PromiseAll should be rejected");
        
        // Now error callback should be resolvable
        assertTrue(callbackContract.canResolve(errorCallback), "Error callback should be resolvable");
        
        // Resolve error callback
        resolved = harness.resolveAllPendingAuto();
        assertEq(resolved, 1, "Should resolve error callback");
        
        // Verify error handler was called
        assertTrue(errorTarget.called(), "Error target should have been called");
        assertEq(uint256(promiseContract.status(errorCallback)), uint256(Promise.PromiseStatus.Resolved), "Error callback should be resolved");
        
        // Note: timeoutPromise can still be pending - PromiseAll failed fast
        assertEq(uint256(promiseContract.status(timeoutPromise)), uint256(Promise.PromiseStatus.Pending), "Timeout should still be pending");
    }

    /// @notice Complex orchestration: SetTimeout → Two Callbacks → PromiseAll → Final Callback
    function test_complexPromiseOrchestration() public {
        // Create test targets
        DataProcessor processor1 = new DataProcessor();
        DataProcessor processor2 = new DataProcessor();
        FinalAggregator aggregator = new FinalAggregator();
        
        // 1. Create initial timeout promise
        vm.prank(alice);
        uint256 timeoutPromise = setTimeoutContract.create(block.timestamp + 100);
        
        // 2. Create two parallel callbacks on the timeout
        vm.prank(alice);
        uint256 callback1 = callbackContract.then(timeoutPromise, address(processor1), processor1.processData.selector);
        
        vm.prank(alice);
        uint256 callback2 = callbackContract.then(timeoutPromise, address(processor2), processor2.processData.selector);
        
        // 3. Create PromiseAll that waits for both callbacks to complete
        uint256[] memory callbackPromises = new uint256[](2);
        callbackPromises[0] = callback1;
        callbackPromises[1] = callback2;
        
        vm.prank(bob);
        uint256 promiseAllId = promiseAllContract.create(callbackPromises);
        
        // 4. Create final callback that triggers only after PromiseAll resolves
        vm.prank(alice);
        uint256 finalCallback = callbackContract.then(promiseAllId, address(aggregator), aggregator.aggregateResults.selector);
        
        // 5. Initially nothing is resolvable
        uint256 pending = harness.countPendingAuto();
        assertEq(pending, 0, "No promises should be resolvable initially");
        
        // 6. Verify the complex dependency chain
        assertEq(uint256(promiseContract.status(timeoutPromise)), uint256(Promise.PromiseStatus.Pending), "Timeout should be pending");
        assertEq(uint256(promiseContract.status(callback1)), uint256(Promise.PromiseStatus.Pending), "Callback1 should be pending");
        assertEq(uint256(promiseContract.status(callback2)), uint256(Promise.PromiseStatus.Pending), "Callback2 should be pending");
        assertEq(uint256(promiseContract.status(promiseAllId)), uint256(Promise.PromiseStatus.Pending), "PromiseAll should be pending");
        assertEq(uint256(promiseContract.status(finalCallback)), uint256(Promise.PromiseStatus.Pending), "Final callback should be pending");
        
        // 7. Fast forward to trigger timeout
        vm.warp(block.timestamp + 150);
        
        // 8. Step-by-step resolution demonstrating the cascade
        
        // Layer 1: Resolve timeout
        uint256 resolved = harness.resolveAllPendingAuto();
        assertEq(resolved, 1, "Should resolve timeout");
        assertEq(uint256(promiseContract.status(timeoutPromise)), uint256(Promise.PromiseStatus.Resolved), "Timeout should be resolved");
        
        // Layer 2: Resolve both callbacks in parallel
        resolved = harness.resolveAllPendingAuto();
        assertEq(resolved, 2, "Should resolve both callbacks");
        assertEq(uint256(promiseContract.status(callback1)), uint256(Promise.PromiseStatus.Resolved), "Callback1 should be resolved");
        assertEq(uint256(promiseContract.status(callback2)), uint256(Promise.PromiseStatus.Resolved), "Callback2 should be resolved");
        
        // Verify processors were called
        assertTrue(processor1.called(), "Processor1 should have been called");
        assertTrue(processor2.called(), "Processor2 should have been called");
        assertEq(processor1.result(), "processed-timeout", "Processor1 should have correct result");
        assertEq(processor2.result(), "processed-timeout", "Processor2 should have correct result");
        
        // Layer 3: Resolve PromiseAll (now that both callbacks are done)
        resolved = harness.resolveAllPendingAuto();
        assertEq(resolved, 1, "Should resolve PromiseAll");
        assertEq(uint256(promiseContract.status(promiseAllId)), uint256(Promise.PromiseStatus.Resolved), "PromiseAll should be resolved");
        
        // Layer 4: Resolve final callback (triggered by PromiseAll completion)
        resolved = harness.resolveAllPendingAuto();
        assertEq(resolved, 1, "Should resolve final callback");
        assertEq(uint256(promiseContract.status(finalCallback)), uint256(Promise.PromiseStatus.Resolved), "Final callback should be resolved");
        
        // 9. Verify final aggregator was called with both results
        assertTrue(aggregator.called(), "Aggregator should have been called");
        assertEq(aggregator.receivedCount(), 2, "Aggregator should have received 2 results");
        assertEq(aggregator.finalResult(), "aggregated-processed-timeout-processed-timeout", "Final result should be aggregated");
        
        // 10. Verify complete resolution
        pending = harness.countPendingAuto();
        assertEq(pending, 0, "All promises should be resolved");
        
        // This demonstrates:
        // 1. Sequential dependency: timeout → callbacks
        // 2. Parallel execution: both callbacks run independently  
        // 3. Synchronization point: PromiseAll waits for both
        // 4. Final aggregation: only after all work is complete
        // 5. Complex orchestration with proper ordering
    }
}

/// @notice Test target that handles PromiseAll results
contract TestTarget {
    bool public called;
    uint256 public receivedArrayLength;
    
    function handlePromiseAllResult(bytes memory data) external returns (string memory) {
        called = true;
        
        // Decode the array of results from PromiseAll
        bytes[] memory results = abi.decode(data, (bytes[]));
        receivedArrayLength = results.length;
        
        return "PromiseAll handled";
    }
}

/// @notice Test target for error handling
contract ErrorTarget {
    bool public called;
    
    function handleError(bytes memory) external returns (string memory) {
        called = true;
        return "error handled";
    }
}

/// @notice Data processor that handles timeout results and processes them
contract DataProcessor {
    bool public called;
    string public result;
    
    function processData(bytes memory data) external returns (string memory) {
        called = true;
        
        // For timeout promises, data is empty - we'll process it into something meaningful
        if (data.length == 0) {
            result = "processed-timeout";
        } else {
            // For other data, decode and process
            string memory input = abi.decode(data, (string));
            result = string(abi.encodePacked("processed-", input));
        }
        
        return result;
    }
}

/// @notice Final aggregator that takes PromiseAll results and combines them
contract FinalAggregator {
    bool public called;
    uint256 public receivedCount;
    string public finalResult;
    
    function aggregateResults(bytes memory data) external returns (string memory) {
        called = true;
        
        // Decode the array of results from PromiseAll
        bytes[] memory results = abi.decode(data, (bytes[]));
        receivedCount = results.length;
        
        // Aggregate all the string results
        string memory aggregated = "aggregated";
        for (uint256 i = 0; i < results.length; i++) {
            string memory result = abi.decode(results[i], (string));
            aggregated = string(abi.encodePacked(aggregated, "-", result));
        }
        
        finalResult = aggregated;
        return finalResult;
    }
} 