// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {Promise} from "../src/Promise.sol";
import {PromiseAll} from "../src/PromiseAll.sol";
import {SetTimeout} from "../src/SetTimeout.sol";

contract PromiseAllTest is Test {
    Promise public promiseContract;
    PromiseAll public promiseAllContract;
    SetTimeout public setTimeoutContract;
    
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public charlie = address(0x3);

    event PromiseAllCreated(uint256 indexed promiseAllId, uint256[] inputPromises);
    event PromiseAllResolved(uint256 indexed promiseAllId, bytes[] values);
    event PromiseAllRejected(uint256 indexed promiseAllId, uint256 failedPromiseId, bytes errorData);

    function setUp() public {
        promiseContract = new Promise(address(0));
        promiseAllContract = new PromiseAll(address(promiseContract));
        setTimeoutContract = new SetTimeout(address(promiseContract));
    }

    function test_createPromiseAll() public {
        // Create some input promises
        vm.prank(alice);
        uint256 promise1 = promiseContract.create();
        
        vm.prank(bob);
        uint256 promise2 = promiseContract.create();
        
        uint256[] memory inputPromises = new uint256[](2);
        inputPromises[0] = promise1;
        inputPromises[1] = promise2;
        
        // Create PromiseAll
        vm.expectEmit(false, false, false, true);
        emit PromiseAllCreated(0, inputPromises); // promiseAllId will be 3
        
        vm.prank(charlie);
        uint256 promiseAllId = promiseAllContract.create(inputPromises);
        
        // Verify the PromiseAll was created
        assertTrue(promiseAllContract.exists(promiseAllId), "PromiseAll should exist");
        assertTrue(promiseContract.exists(promiseAllId), "PromiseAll promise should exist in Promise contract");
        assertEq(uint256(promiseContract.status(promiseAllId)), uint256(Promise.PromiseStatus.Pending), "PromiseAll should be pending");
        
        // Check input promises
        uint256[] memory retrievedInputs = promiseAllContract.getInputPromises(promiseAllId);
        assertEq(retrievedInputs.length, 2, "Should have 2 input promises");
        assertEq(retrievedInputs[0], promise1, "First input should match");
        assertEq(retrievedInputs[1], promise2, "Second input should match");
        
        // Check status
        (uint256 resolvedCount, uint256 totalCount, bool settled) = promiseAllContract.getStatus(promiseAllId);
        assertEq(resolvedCount, 0, "No promises resolved yet");
        assertEq(totalCount, 2, "Should have 2 total promises");
        assertFalse(settled, "Should not be settled yet");
    }

    function test_cannotCreateWithEmptyArray() public {
        uint256[] memory emptyArray = new uint256[](0);
        
        vm.expectRevert("PromiseAll: empty input array");
        promiseAllContract.create(emptyArray);
    }

    function test_cannotCreateWithNonExistentPromise() public {
        uint256[] memory inputPromises = new uint256[](1);
        inputPromises[0] = 999; // Non-existent promise
        
        vm.expectRevert("PromiseAll: input promise does not exist");
        promiseAllContract.create(inputPromises);
    }

    function test_resolveWhenAllPromisesResolve() public {
        // Create input promises
        vm.prank(alice);
        uint256 promise1 = promiseContract.create();
        
        vm.prank(alice);
        uint256 promise2 = promiseContract.create();
        
        uint256[] memory inputPromises = new uint256[](2);
        inputPromises[0] = promise1;
        inputPromises[1] = promise2;
        
        // Create PromiseAll
        vm.prank(charlie);
        uint256 promiseAllId = promiseAllContract.create(inputPromises);
        
        // Initially cannot resolve
        assertFalse(promiseAllContract.canResolve(promiseAllId), "Should not be resolvable initially");
        
        // Resolve first promise
        vm.prank(alice);
        promiseContract.resolve(promise1, abi.encode("result1"));
        
        // Still cannot resolve (only 1 of 2 resolved)
        assertFalse(promiseAllContract.canResolve(promiseAllId), "Should not be resolvable with only 1 resolved");
        
        // Check status
        (uint256 resolvedCount, uint256 totalCount, bool settled) = promiseAllContract.getStatus(promiseAllId);
        assertEq(resolvedCount, 1, "Should have 1 resolved");
        assertEq(totalCount, 2, "Should have 2 total");
        assertFalse(settled, "Should not be settled yet");
        
        // Resolve second promise
        vm.prank(alice);
        promiseContract.resolve(promise2, abi.encode("result2"));
        
        // Now can resolve
        assertTrue(promiseAllContract.canResolve(promiseAllId), "Should be resolvable with all resolved");
        
        // Resolve the PromiseAll
        bytes[] memory expectedValues = new bytes[](2);
        expectedValues[0] = abi.encode("result1");
        expectedValues[1] = abi.encode("result2");
        
        vm.expectEmit(false, false, false, true);
        emit PromiseAllResolved(promiseAllId, expectedValues);
        
        promiseAllContract.resolve(promiseAllId);
        
        // Verify final state
        assertEq(uint256(promiseContract.status(promiseAllId)), uint256(Promise.PromiseStatus.Resolved), "PromiseAll should be resolved");
        
        // Check that values are encoded correctly
        Promise.PromiseData memory promiseData = promiseContract.getPromise(promiseAllId);
        bytes[] memory decodedValues = abi.decode(promiseData.returnData, (bytes[]));
        assertEq(decodedValues.length, 2, "Should have 2 values");
        assertEq(decodedValues[0], abi.encode("result1"), "First value should match");
        assertEq(decodedValues[1], abi.encode("result2"), "Second value should match");
        
        // PromiseAll should be cleaned up
        assertFalse(promiseAllContract.exists(promiseAllId), "PromiseAll should be cleaned up");
    }

    function test_rejectWhenAnyPromiseRejects() public {
        // Create input promises
        vm.prank(alice);
        uint256 promise1 = promiseContract.create();
        
        vm.prank(alice);
        uint256 promise2 = promiseContract.create();
        
        vm.prank(alice);
        uint256 promise3 = promiseContract.create();
        
        uint256[] memory inputPromises = new uint256[](3);
        inputPromises[0] = promise1;
        inputPromises[1] = promise2;
        inputPromises[2] = promise3;
        
        // Create PromiseAll
        vm.prank(charlie);
        uint256 promiseAllId = promiseAllContract.create(inputPromises);
        
        // Resolve first promise
        vm.prank(alice);
        promiseContract.resolve(promise1, abi.encode("result1"));
        
        // Reject second promise
        vm.prank(alice);
        promiseContract.reject(promise2, abi.encode("error occurred"));
        
        // Now can resolve (actually reject) due to fail-fast behavior
        assertTrue(promiseAllContract.canResolve(promiseAllId), "Should be resolvable due to rejection");
        
        // Resolve the PromiseAll (it will reject)
        vm.expectEmit(false, false, false, true);
        emit PromiseAllRejected(promiseAllId, promise2, abi.encode("error occurred"));
        
        promiseAllContract.resolve(promiseAllId);
        
        // Verify final state
        assertEq(uint256(promiseContract.status(promiseAllId)), uint256(Promise.PromiseStatus.Rejected), "PromiseAll should be rejected");
        
        // Check that error data is preserved
        Promise.PromiseData memory promiseData = promiseContract.getPromise(promiseAllId);
        assertEq(promiseData.returnData, abi.encode("error occurred"), "Error data should match");
        
        // Promise3 can still be pending - doesn't matter in fail-fast
        assertEq(uint256(promiseContract.status(promise3)), uint256(Promise.PromiseStatus.Pending), "Promise3 should still be pending");
        
        // PromiseAll should be cleaned up
        assertFalse(promiseAllContract.exists(promiseAllId), "PromiseAll should be cleaned up");
    }

    function test_integrationWithSetTimeout() public {
        // Create some timeout promises
        vm.prank(alice);
        uint256 timeout1 = setTimeoutContract.create(block.timestamp + 100);
        
        vm.prank(alice);
        uint256 timeout2 = setTimeoutContract.create(block.timestamp + 200);
        
        uint256[] memory inputPromises = new uint256[](2);
        inputPromises[0] = timeout1;
        inputPromises[1] = timeout2;
        
        // Create PromiseAll
        vm.prank(charlie);
        uint256 promiseAllId = promiseAllContract.create(inputPromises);
        
        // Initially cannot resolve
        assertFalse(promiseAllContract.canResolve(promiseAllId), "Should not be resolvable initially");
        
        // Fast forward past first timeout
        vm.warp(block.timestamp + 150);
        setTimeoutContract.resolve(timeout1);
        
        // Still cannot resolve
        assertFalse(promiseAllContract.canResolve(promiseAllId), "Should not be resolvable with only 1 timeout resolved");
        
        // Fast forward past second timeout
        vm.warp(block.timestamp + 100);
        setTimeoutContract.resolve(timeout2);
        
        // Now can resolve
        assertTrue(promiseAllContract.canResolve(promiseAllId), "Should be resolvable with all timeouts resolved");
        
        // Resolve the PromiseAll
        promiseAllContract.resolve(promiseAllId);
        
        // Verify final state
        assertEq(uint256(promiseContract.status(promiseAllId)), uint256(Promise.PromiseStatus.Resolved), "PromiseAll should be resolved");
        
        // Check values (timeouts resolve with empty bytes)
        Promise.PromiseData memory promiseData = promiseContract.getPromise(promiseAllId);
        bytes[] memory decodedValues = abi.decode(promiseData.returnData, (bytes[]));
        assertEq(decodedValues.length, 2, "Should have 2 values");
        assertEq(decodedValues[0].length, 0, "First value should be empty (timeout)");
        assertEq(decodedValues[1].length, 0, "Second value should be empty (timeout)");
    }

    function test_mixedPromiseTypes() public {
        // Create a manual promise
        vm.prank(alice);
        uint256 manualPromise = promiseContract.create();
        
        // Create a timeout promise
        vm.prank(alice);
        uint256 timeoutPromise = setTimeoutContract.create(block.timestamp + 100);
        
        uint256[] memory inputPromises = new uint256[](2);
        inputPromises[0] = manualPromise;
        inputPromises[1] = timeoutPromise;
        
        // Create PromiseAll
        vm.prank(charlie);
        uint256 promiseAllId = promiseAllContract.create(inputPromises);
        
        // Resolve manual promise
        vm.prank(alice);
        promiseContract.resolve(manualPromise, abi.encode("manual result"));
        
        // Cannot resolve yet (timeout not ready)
        assertFalse(promiseAllContract.canResolve(promiseAllId), "Should not be resolvable yet");
        
        // Fast forward and resolve timeout
        vm.warp(block.timestamp + 150);
        setTimeoutContract.resolve(timeoutPromise);
        
        // Now can resolve
        assertTrue(promiseAllContract.canResolve(promiseAllId), "Should be resolvable now");
        
        promiseAllContract.resolve(promiseAllId);
        
        // Verify values
        Promise.PromiseData memory promiseData = promiseContract.getPromise(promiseAllId);
        bytes[] memory decodedValues = abi.decode(promiseData.returnData, (bytes[]));
        assertEq(decodedValues.length, 2, "Should have 2 values");
        assertEq(decodedValues[0], abi.encode("manual result"), "Manual result should be preserved");
        assertEq(decodedValues[1].length, 0, "Timeout result should be empty");
    }

    function test_cannotResolveNonExistentPromiseAll() public {
        vm.expectRevert("PromiseAll: promise does not exist");
        promiseAllContract.resolve(999);
    }

    function test_cannotResolveAlreadySettled() public {
        // Create and resolve a PromiseAll
        vm.prank(alice);
        uint256 promise1 = promiseContract.create();
        
        uint256[] memory inputPromises = new uint256[](1);
        inputPromises[0] = promise1;
        
        vm.prank(charlie);
        uint256 promiseAllId = promiseAllContract.create(inputPromises);
        
        // Resolve input promise
        vm.prank(alice);
        promiseContract.resolve(promise1, abi.encode("result"));
        
        // Resolve PromiseAll
        promiseAllContract.resolve(promiseAllId);
        
        // Try to resolve again
        vm.expectRevert("PromiseAll: promise does not exist"); // Storage was cleaned up
        promiseAllContract.resolve(promiseAllId);
    }

    function test_cannotResolveBeforeAllResolved() public {
        vm.prank(alice);
        uint256 promise1 = promiseContract.create();
        
        vm.prank(alice);
        uint256 promise2 = promiseContract.create();
        
        uint256[] memory inputPromises = new uint256[](2);
        inputPromises[0] = promise1;
        inputPromises[1] = promise2;
        
        vm.prank(charlie);
        uint256 promiseAllId = promiseAllContract.create(inputPromises);
        
        // Resolve only first promise
        vm.prank(alice);
        promiseContract.resolve(promise1, abi.encode("result1"));
        
        // Try to resolve PromiseAll
        vm.expectRevert("PromiseAll: not all promises resolved yet");
        promiseAllContract.resolve(promiseAllId);
    }

    function test_singlePromiseAll() public {
        // Test with just one input promise
        vm.prank(alice);
        uint256 promise1 = promiseContract.create();
        
        uint256[] memory inputPromises = new uint256[](1);
        inputPromises[0] = promise1;
        
        vm.prank(charlie);
        uint256 promiseAllId = promiseAllContract.create(inputPromises);
        
        // Resolve the single input promise
        vm.prank(alice);
        promiseContract.resolve(promise1, abi.encode("single result"));
        
        // Should be resolvable immediately
        assertTrue(promiseAllContract.canResolve(promiseAllId), "Should be resolvable with single promise resolved");
        
        promiseAllContract.resolve(promiseAllId);
        
        // Verify result
        assertEq(uint256(promiseContract.status(promiseAllId)), uint256(Promise.PromiseStatus.Resolved), "PromiseAll should be resolved");
        
        Promise.PromiseData memory promiseData = promiseContract.getPromise(promiseAllId);
        bytes[] memory decodedValues = abi.decode(promiseData.returnData, (bytes[]));
        assertEq(decodedValues.length, 1, "Should have 1 value");
        assertEq(decodedValues[0], abi.encode("single result"), "Single result should match");
    }

    function test_promiseOrderPreserved() public {
        // Create promises and resolve them out of order to test order preservation
        vm.prank(alice);
        uint256 promise1 = promiseContract.create();
        
        vm.prank(alice);
        uint256 promise2 = promiseContract.create();
        
        vm.prank(alice);
        uint256 promise3 = promiseContract.create();
        
        uint256[] memory inputPromises = new uint256[](3);
        inputPromises[0] = promise1;
        inputPromises[1] = promise2;
        inputPromises[2] = promise3;
        
        vm.prank(charlie);
        uint256 promiseAllId = promiseAllContract.create(inputPromises);
        
        // Resolve promises out of order: 3, 1, 2
        vm.prank(alice);
        promiseContract.resolve(promise3, abi.encode("result3"));
        
        vm.prank(alice);
        promiseContract.resolve(promise1, abi.encode("result1"));
        
        vm.prank(alice);
        promiseContract.resolve(promise2, abi.encode("result2"));
        
        // Resolve PromiseAll
        promiseAllContract.resolve(promiseAllId);
        
        // Verify order is preserved (should be result1, result2, result3)
        Promise.PromiseData memory promiseData = promiseContract.getPromise(promiseAllId);
        bytes[] memory decodedValues = abi.decode(promiseData.returnData, (bytes[]));
        assertEq(decodedValues.length, 3, "Should have 3 values");
        assertEq(decodedValues[0], abi.encode("result1"), "First result should be result1");
        assertEq(decodedValues[1], abi.encode("result2"), "Second result should be result2");
        assertEq(decodedValues[2], abi.encode("result3"), "Third result should be result3");
    }

    function test_canResolveAfterRejection() public {
        vm.prank(alice);
        uint256 promise1 = promiseContract.create();
        
        uint256[] memory inputPromises = new uint256[](1);
        inputPromises[0] = promise1;
        
        vm.prank(charlie);
        uint256 promiseAllId = promiseAllContract.create(inputPromises);
        
        // Reject the input promise
        vm.prank(alice);
        promiseContract.reject(promise1, abi.encode("error"));
        
        // Should be resolvable (will actually reject)
        assertTrue(promiseAllContract.canResolve(promiseAllId), "Should be resolvable after rejection");
    }
} 