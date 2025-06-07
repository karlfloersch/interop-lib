// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {LocalPromise} from "../src/LocalPromise.sol";
import {PromiseExecutor} from "../src/PromiseExecutor.sol";

/// @notice Promise.all functionality for LocalPromise
/// @dev Combines multiple promises into a single promise that resolves when all complete
contract PromiseAll {
    LocalPromise public immutable promises;
    
    struct AllPromiseState {
        bytes32[] promiseIds;
        uint256 resolvedCount;
        uint256 totalCount;
        bool completed;
        bool failed;
        bytes[] results;
    }
    
    mapping(bytes32 => AllPromiseState) public allPromises;
    
    constructor(address _promises) {
        promises = LocalPromise(_promises);
    }
    
    /// @notice Create a Promise.all that waits for all promises to resolve
    function createAll(bytes32[] calldata promiseIds) external returns (bytes32 allPromiseId) {
        allPromiseId = keccak256(abi.encode(promiseIds, block.timestamp, msg.sender));
        
        allPromises[allPromiseId] = AllPromiseState({
            promiseIds: promiseIds,
            resolvedCount: 0,
            totalCount: promiseIds.length,
            completed: false,
            failed: false,
            results: new bytes[](promiseIds.length)
        });
        
        return allPromiseId;
    }
    
    /// @notice Check if Promise.all is ready and return results
    function checkAll(bytes32 allPromiseId) external view returns (bool ready, bool failed, bytes[] memory results) {
        AllPromiseState storage state = allPromises[allPromiseId];
        
        uint256 resolvedCount = 0;
        bool anyFailed = false;
        bytes[] memory currentResults = new bytes[](state.totalCount);
        
        for (uint256 i = 0; i < state.totalCount; i++) {
            (LocalPromise.PromiseStatus status, bytes memory value,) = promises.promises(state.promiseIds[i]);
            
            if (status == LocalPromise.PromiseStatus.RESOLVED) {
                resolvedCount++;
                currentResults[i] = value;
            } else if (status == LocalPromise.PromiseStatus.REJECTED) {
                anyFailed = true;
                currentResults[i] = value;
            }
        }
        
        ready = (resolvedCount == state.totalCount) || anyFailed;
        failed = anyFailed;
        results = currentResults;
    }
}

contract PromiseAllTestsTest is Test {
    LocalPromise public promises;
    PromiseAll public promiseAll;
    PromiseExecutor public executor;
    
    uint256[] public receivedValues;
    bool public allCallbackExecuted;
    
    function setUp() public {
        promises = new LocalPromise();
        promiseAll = new PromiseAll(address(promises));
        executor = new PromiseExecutor(address(promises));
        
        // Reset state
        delete receivedValues;
        allCallbackExecuted = false;
    }
    
    function test_promise_all_success() public {
        console.log("=== Testing Promise.all Success Case ===");
        
        // Create multiple promises
        bytes32 promise1 = promises.create();
        bytes32 promise2 = promises.create();
        bytes32 promise3 = promises.create();
        
        bytes32[] memory promiseIds = new bytes32[](3);
        promiseIds[0] = promise1;
        promiseIds[1] = promise2;
        promiseIds[2] = promise3;
        
        // Create Promise.all
        bytes32 allPromiseId = promiseAll.createAll(promiseIds);
        
        // Initially not ready
        (bool ready, bool failed,) = promiseAll.checkAll(allPromiseId);
        assertFalse(ready, "Promise.all should not be ready initially");
        assertFalse(failed, "Promise.all should not be failed initially");
        
        // Resolve first two promises
        promises.resolve(promise1, abi.encode(uint256(10)));
        promises.resolve(promise2, abi.encode(uint256(20)));
        
        // Still not ready (missing promise3)
        (ready, failed,) = promiseAll.checkAll(allPromiseId);
        assertFalse(ready, "Promise.all should not be ready with partial completion");
        
        // Resolve final promise
        promises.resolve(promise3, abi.encode(uint256(30)));
        
        // Now should be ready
        (bool ready2, bool failed2, bytes[] memory results) = promiseAll.checkAll(allPromiseId);
        assertTrue(ready2, "Promise.all should be ready when all promises resolve");
        assertFalse(failed2, "Promise.all should not be failed when all succeed");
        assertEq(results.length, 3, "Should have 3 results");
        
        // Verify results
        assertEq(abi.decode(results[0], (uint256)), 10);
        assertEq(abi.decode(results[1], (uint256)), 20);
        assertEq(abi.decode(results[2], (uint256)), 30);
        
        console.log("SUCCESS: Promise.all resolves when all promises complete");
    }
    
    function test_promise_all_early_failure() public {
        console.log("=== Testing Promise.all Early Failure ===");
        
        // Create multiple promises
        bytes32 promise1 = promises.create();
        bytes32 promise2 = promises.create();
        bytes32 promise3 = promises.create();
        
        bytes32[] memory promiseIds = new bytes32[](3);
        promiseIds[0] = promise1;
        promiseIds[1] = promise2;
        promiseIds[2] = promise3;
        
        // Create Promise.all
        bytes32 allPromiseId = promiseAll.createAll(promiseIds);
        
        // Resolve first promise
        promises.resolve(promise1, abi.encode(uint256(10)));
        
        // Reject second promise (should fail the whole Promise.all)
        promises.reject(promise2, abi.encode("Error occurred"));
        
        // Should be ready and failed immediately
        (bool ready3, bool failed3, bytes[] memory results) = promiseAll.checkAll(allPromiseId);
        assertTrue(ready3, "Promise.all should be ready when any promise fails");
        assertTrue(failed3, "Promise.all should be marked as failed");
        
        // Results should include resolved and rejected values
        assertEq(abi.decode(results[0], (uint256)), 10);
        assertEq(string(abi.decode(results[1], (string))), "Error occurred");
        
        console.log("SUCCESS: Promise.all fails fast when any promise rejects");
    }
    
    function test_promise_all_mixed_results() public {
        console.log("=== Testing Promise.all Mixed Results ===");
        
        // Create promises with different data types
        bytes32 promise1 = promises.create();
        bytes32 promise2 = promises.create();
        
        bytes32[] memory promiseIds = new bytes32[](2);
        promiseIds[0] = promise1;
        promiseIds[1] = promise2;
        
        bytes32 allPromiseId = promiseAll.createAll(promiseIds);
        
        // Resolve with different types
        promises.resolve(promise1, abi.encode(uint256(42)));
        promises.resolve(promise2, abi.encode("Hello World"));
        
        (bool ready4, bool failed4, bytes[] memory results) = promiseAll.checkAll(allPromiseId);
        assertTrue(ready4, "Promise.all should be ready");
        assertFalse(failed4, "Promise.all should not be failed");
        
        // Verify mixed type results
        assertEq(abi.decode(results[0], (uint256)), 42);
        assertEq(string(abi.decode(results[1], (string))), "Hello World");
        
        console.log("SUCCESS: Promise.all handles mixed data types");
    }
    
    function test_promise_all_empty_array() public {
        console.log("=== Testing Promise.all Empty Array ===");
        
        bytes32[] memory emptyPromiseIds = new bytes32[](0);
        bytes32 allPromiseId = promiseAll.createAll(emptyPromiseIds);
        
        // Empty Promise.all should be immediately ready
        (bool ready5, bool failed5, bytes[] memory results) = promiseAll.checkAll(allPromiseId);
        assertTrue(ready5, "Empty Promise.all should be immediately ready");
        assertFalse(failed5, "Empty Promise.all should not be failed");
        assertEq(results.length, 0, "Empty Promise.all should have no results");
        
        console.log("SUCCESS: Empty Promise.all resolves immediately");
    }
    
    function test_promise_all_single_promise() public {
        console.log("=== Testing Promise.all Single Promise ===");
        
        bytes32 promise1 = promises.create();
        
        bytes32[] memory promiseIds = new bytes32[](1);
        promiseIds[0] = promise1;
        
        bytes32 allPromiseId = promiseAll.createAll(promiseIds);
        
        // Not ready initially
        (bool ready,,) = promiseAll.checkAll(allPromiseId);
        assertFalse(ready, "Single promise Promise.all should not be ready initially");
        
        // Resolve the promise
        promises.resolve(promise1, abi.encode("single result"));
        
        // Should be ready now
        (bool ready6, bool failed6, bytes[] memory results) = promiseAll.checkAll(allPromiseId);
        assertTrue(ready6, "Single promise Promise.all should be ready after resolution");
        assertFalse(failed6, "Single promise Promise.all should not be failed");
        assertEq(results.length, 1, "Should have one result");
        assertEq(string(abi.decode(results[0], (string))), "single result");
        
        console.log("SUCCESS: Single promise Promise.all works correctly");
    }
    
    function test_promise_all_with_callback_integration() public {
        console.log("=== Testing Promise.all with Callback Integration ===");
        
        // Create promises
        bytes32 promise1 = promises.create();
        bytes32 promise2 = promises.create();
        
        bytes32[] memory promiseIds = new bytes32[](2);
        promiseIds[0] = promise1;
        promiseIds[1] = promise2;
        
        bytes32 allPromiseId = promiseAll.createAll(promiseIds);
        
        // Setup a checker promise that monitors Promise.all
        bytes32 checkerPromise = promises.create();
        promises.then(checkerPromise, this.handleAllResults.selector);
        
        // Resolve the individual promises
        promises.resolve(promise1, abi.encode(uint256(100)));
        promises.resolve(promise2, abi.encode(uint256(200)));
        
        // Check if Promise.all is ready and create result for checker
        (bool ready7, bool failed7, bytes[] memory results) = promiseAll.checkAll(allPromiseId);
        
        if (ready7 && !failed7) {
            // Calculate sum and resolve checker promise
            uint256 sum = abi.decode(results[0], (uint256)) + abi.decode(results[1], (uint256));
            promises.resolve(checkerPromise, abi.encode(sum));
            executor.executePromiseCallbacks(checkerPromise);
        }
        
        // Verify callback was executed with combined result
        assertTrue(allCallbackExecuted, "Callback should have been executed");
        assertEq(receivedValues.length, 1, "Should have received one combined value");
        assertEq(receivedValues[0], 300, "Should have received sum of both values");
        
        console.log("SUCCESS: Promise.all integrates with callback system");
    }
    
    function handleAllResults(uint256 combinedValue) external {
        allCallbackExecuted = true;
        receivedValues.push(combinedValue);
        console.log("Combined result received:", combinedValue);
    }
} 