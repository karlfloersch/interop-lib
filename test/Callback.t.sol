// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {Promise} from "../src/Promise.sol";
import {Callback} from "../src/Callback.sol";

contract CallbackTest is Test {
    Promise public promiseContract;
    Callback public callbackContract;
    
    address public alice = address(0x1);
    address public bob = address(0x2);

    event CallbackRegistered(uint256 indexed callbackPromiseId, uint256 indexed parentPromiseId, Callback.CallbackType callbackType);
    event CallbackExecuted(uint256 indexed callbackPromiseId, bool success, bytes returnData);

    function setUp() public {
        promiseContract = new Promise(address(0));
        callbackContract = new Callback(address(promiseContract), address(0));
    }

    // Test contract that implements callback functions
    TestTarget testTarget;

    function test_setUp() public {
        testTarget = new TestTarget();
    }

    function test_createThenCallback() public {
        test_setUp();
        
        vm.prank(alice);
        uint256 parentPromiseId = promiseContract.create();
        uint256 expectedCallbackId = promiseContract.generatePromiseId(2);
        
        vm.prank(bob);
        vm.expectEmit(true, true, false, true);
        emit CallbackRegistered(expectedCallbackId, parentPromiseId, Callback.CallbackType.Then);
        
        uint256 callbackPromiseId = callbackContract.then(
            parentPromiseId, 
            address(testTarget), 
            testTarget.handleSuccess.selector
        );
        
        assertEq(callbackPromiseId, expectedCallbackId, "Callback promise ID should match expected global ID");
        
        Callback.CallbackData memory callbackData = callbackContract.getCallback(callbackPromiseId);
        assertEq(callbackData.parentPromiseId, parentPromiseId, "Parent promise ID should match");
        assertEq(callbackData.target, address(testTarget), "Target should match");
        assertEq(callbackData.selector, testTarget.handleSuccess.selector, "Selector should match");
        assertEq(uint256(callbackData.callbackType), uint256(Callback.CallbackType.Then), "Callback type should be Then");
        
        assertTrue(callbackContract.exists(callbackPromiseId), "Callback should exist");
        assertFalse(callbackContract.canResolve(callbackPromiseId), "Callback should not be resolvable yet");
    }

    function test_createOnRejectCallback() public {
        test_setUp();
        
        vm.prank(alice);
        uint256 parentPromiseId = promiseContract.create();
        uint256 expectedCallbackId = promiseContract.generatePromiseId(2);
        
        vm.prank(bob);
        vm.expectEmit(true, true, false, true);
        emit CallbackRegistered(expectedCallbackId, parentPromiseId, Callback.CallbackType.Catch);
        
        uint256 callbackPromiseId = callbackContract.onReject(
            parentPromiseId, 
            address(testTarget), 
            testTarget.handleError.selector
        );
        
        assertEq(callbackPromiseId, expectedCallbackId, "Callback promise ID should match expected global ID");
        
        Callback.CallbackData memory callbackData = callbackContract.getCallback(callbackPromiseId);
        assertEq(uint256(callbackData.callbackType), uint256(Callback.CallbackType.Catch), "Callback type should be Catch");
        
        assertTrue(callbackContract.exists(callbackPromiseId), "Callback should exist");
        assertFalse(callbackContract.canResolve(callbackPromiseId), "Callback should not be resolvable yet");
    }

    function test_canCreateCallbackForNonExistentPromise() public {
        test_setUp();
        
        // Should now be able to create callbacks for non-existent promises (for cross-chain compatibility)
        uint256 callback1 = callbackContract.then(999, address(testTarget), testTarget.handleSuccess.selector);
        uint256 callback2 = callbackContract.onReject(999, address(testTarget), testTarget.handleError.selector);
        
        // Callbacks should exist even though parent promise doesn't exist locally
        assertTrue(callbackContract.exists(callback1), "Then callback should exist for non-existent promise");
        assertTrue(callbackContract.exists(callback2), "OnReject callback should exist for non-existent promise");
        
        // Callbacks should not be resolvable since parent promise doesn't exist
        assertFalse(callbackContract.canResolve(callback1), "Then callback should not be resolvable for non-existent promise");
        assertFalse(callbackContract.canResolve(callback2), "OnReject callback should not be resolvable for non-existent promise");
        
        // Verify callback data is stored correctly
        Callback.CallbackData memory data1 = callbackContract.getCallback(callback1);
        assertEq(data1.parentPromiseId, 999, "Parent promise ID should match");
        assertEq(data1.target, address(testTarget), "Target should match");
        assertEq(uint256(data1.callbackType), uint256(Callback.CallbackType.Then), "Should be Then callback");
        
        Callback.CallbackData memory data2 = callbackContract.getCallback(callback2);
        assertEq(data2.parentPromiseId, 999, "Parent promise ID should match");
        assertEq(uint256(data2.callbackType), uint256(Callback.CallbackType.Catch), "Should be Catch callback");
    }

    function test_resolveThenCallback() public {
        test_setUp();
        
        // Create parent promise
        vm.prank(alice);
        uint256 parentPromiseId = promiseContract.create();
        
        // Create then callback
        vm.prank(bob);
        uint256 callbackPromiseId = callbackContract.then(
            parentPromiseId, 
            address(testTarget), 
            testTarget.handleSuccess.selector
        );
        
        // Resolve parent promise
        bytes memory parentData = abi.encode(uint256(42));
        vm.prank(alice);
        promiseContract.resolve(parentPromiseId, parentData);
        
        // Now callback should be resolvable
        assertTrue(callbackContract.canResolve(callbackPromiseId), "Callback should be resolvable");
        
        // Resolve callback
        vm.expectEmit(true, false, false, false);
        emit CallbackExecuted(callbackPromiseId, true, abi.encode(uint256(84))); // 42 * 2
        
        callbackContract.resolve(callbackPromiseId);
        
        // Check callback promise is resolved with correct data
        assertEq(uint256(promiseContract.status(callbackPromiseId)), uint256(Promise.PromiseStatus.Resolved), "Callback promise should be resolved");
        
        Promise.PromiseData memory callbackPromiseData = promiseContract.getPromise(callbackPromiseId);
        uint256 result = abi.decode(callbackPromiseData.returnData, (uint256));
        assertEq(result, 84, "Callback should have doubled the input (42 * 2 = 84)");
        
        // Check callback is cleaned up
        assertFalse(callbackContract.exists(callbackPromiseId), "Callback should be cleaned up");
        
        // Check target was called correctly
        assertEq(testTarget.lastValue(), 42, "Target should have received correct value");
        assertTrue(testTarget.successCalled(), "Success handler should have been called");
    }

    function test_resolveOnRejectCallback() public {
        test_setUp();
        
        // Create parent promise
        vm.prank(alice);
        uint256 parentPromiseId = promiseContract.create();
        
        // Create onReject callback
        vm.prank(bob);
        uint256 callbackPromiseId = callbackContract.onReject(
            parentPromiseId, 
            address(testTarget), 
            testTarget.handleError.selector
        );
        
        // Reject parent promise
        bytes memory errorData = abi.encode("Something went wrong");
        vm.prank(alice);
        promiseContract.reject(parentPromiseId, errorData);
        
        // Now callback should be resolvable
        assertTrue(callbackContract.canResolve(callbackPromiseId), "Callback should be resolvable");
        
        // Resolve callback
        callbackContract.resolve(callbackPromiseId);
        
        // Check callback promise is resolved
        assertEq(uint256(promiseContract.status(callbackPromiseId)), uint256(Promise.PromiseStatus.Resolved), "Callback promise should be resolved");
        
        // Check target was called correctly
        assertTrue(testTarget.errorCalled(), "Error handler should have been called");
    }

    function test_thenCallbackNotExecutedWhenParentRejects() public {
        test_setUp();
        
        // Create parent promise and then callback
        vm.prank(alice);
        uint256 parentPromiseId = promiseContract.create();
        
        vm.prank(bob);
        uint256 callbackPromiseId = callbackContract.then(
            parentPromiseId, 
            address(testTarget), 
            testTarget.handleSuccess.selector
        );
        
        // Reject parent promise
        vm.prank(alice);
        promiseContract.reject(parentPromiseId, abi.encode("Error"));
        
        // Callback should be resolvable (to reject it)
        assertTrue(callbackContract.canResolve(callbackPromiseId), "Callback should be resolvable");
        
        // Resolve callback (should reject since parent was rejected)
        callbackContract.resolve(callbackPromiseId);
        
        // Check callback promise is rejected
        assertEq(uint256(promiseContract.status(callbackPromiseId)), uint256(Promise.PromiseStatus.Rejected), "Callback promise should be rejected");
        
        // Check target was not called
        assertFalse(testTarget.successCalled(), "Success handler should not have been called");
    }

    function test_onRejectCallbackNotExecutedWhenParentResolves() public {
        test_setUp();
        
        // Create parent promise and onReject callback
        vm.prank(alice);
        uint256 parentPromiseId = promiseContract.create();
        
        vm.prank(bob);
        uint256 callbackPromiseId = callbackContract.onReject(
            parentPromiseId, 
            address(testTarget), 
            testTarget.handleError.selector
        );
        
        // Resolve parent promise
        vm.prank(alice);
        promiseContract.resolve(parentPromiseId, abi.encode(uint256(42)));
        
        // Callback should be resolvable (to reject it)
        assertTrue(callbackContract.canResolve(callbackPromiseId), "Callback should be resolvable");
        
        // Resolve callback (should reject since parent was resolved)
        callbackContract.resolve(callbackPromiseId);
        
        // Check callback promise is rejected
        assertEq(uint256(promiseContract.status(callbackPromiseId)), uint256(Promise.PromiseStatus.Rejected), "Callback promise should be rejected");
        
        // Check target was not called
        assertFalse(testTarget.errorCalled(), "Error handler should not have been called");
    }

    function test_cannotResolveCallbackWhenParentPending() public {
        test_setUp();
        
        // Create parent promise and callback
        vm.prank(alice);
        uint256 parentPromiseId = promiseContract.create();
        
        vm.prank(bob);
        uint256 callbackPromiseId = callbackContract.then(
            parentPromiseId, 
            address(testTarget), 
            testTarget.handleSuccess.selector
        );
        
        // Try to resolve callback while parent is still pending
        vm.expectRevert("Callback: parent promise not settled");
        callbackContract.resolve(callbackPromiseId);
    }

    function test_cannotResolveNonExistentCallback() public {
        vm.expectRevert("Callback: callback does not exist");
        callbackContract.resolve(999);
    }

    function test_cannotResolveAlreadySettledCallback() public {
        test_setUp();
        
        // Create and resolve a callback
        vm.prank(alice);
        uint256 parentPromiseId = promiseContract.create();
        
        vm.prank(bob);
        uint256 callbackPromiseId = callbackContract.then(
            parentPromiseId, 
            address(testTarget), 
            testTarget.handleSuccess.selector
        );
        
        vm.prank(alice);
        promiseContract.resolve(parentPromiseId, abi.encode(uint256(42)));
        
        callbackContract.resolve(callbackPromiseId);
        
        // Try to resolve again (should fail because callback is cleaned up)
        vm.expectRevert("Callback: callback does not exist");
        callbackContract.resolve(callbackPromiseId);
    }

    function test_callbackHandlesTargetFailure() public {
        test_setUp();
        
        // Create parent promise and callback to failing function
        vm.prank(alice);
        uint256 parentPromiseId = promiseContract.create();
        
        vm.prank(bob);
        uint256 callbackPromiseId = callbackContract.then(
            parentPromiseId, 
            address(testTarget), 
            testTarget.alwaysFails.selector
        );
        
        // Resolve parent promise
        vm.prank(alice);
        promiseContract.resolve(parentPromiseId, abi.encode(uint256(42)));
        
        // Resolve callback (should fail and reject the callback promise)
        callbackContract.resolve(callbackPromiseId);
        
        // Check callback promise is rejected
        assertEq(uint256(promiseContract.status(callbackPromiseId)), uint256(Promise.PromiseStatus.Rejected), "Callback promise should be rejected when target fails");
    }

    function test_multipleCallbacksOnSamePromise() public {
        test_setUp();
        
        // Create parent promise
        vm.prank(alice);
        uint256 parentPromiseId = promiseContract.create();
        
        // Create multiple callbacks
        vm.prank(bob);
        uint256 callback1 = callbackContract.then(parentPromiseId, address(testTarget), testTarget.handleSuccess.selector);
        
        TestTarget testTarget2 = new TestTarget();
        vm.prank(bob);
        uint256 callback2 = callbackContract.then(parentPromiseId, address(testTarget2), testTarget2.handleSuccess.selector);
        
        // Resolve parent promise
        vm.prank(alice);
        promiseContract.resolve(parentPromiseId, abi.encode(uint256(10)));
        
        // Both callbacks should be resolvable
        assertTrue(callbackContract.canResolve(callback1), "First callback should be resolvable");
        assertTrue(callbackContract.canResolve(callback2), "Second callback should be resolvable");
        
        // Resolve both callbacks
        callbackContract.resolve(callback1);
        callbackContract.resolve(callback2);
        
        // Both should be resolved
        assertEq(uint256(promiseContract.status(callback1)), uint256(Promise.PromiseStatus.Resolved), "First callback should be resolved");
        assertEq(uint256(promiseContract.status(callback2)), uint256(Promise.PromiseStatus.Resolved), "Second callback should be resolved");
        
        // Both targets should have been called
        assertTrue(testTarget.successCalled(), "First target should have been called");
        assertTrue(testTarget2.successCalled(), "Second target should have been called");
        assertEq(testTarget.lastValue(), 10, "First target should have correct value");
        assertEq(testTarget2.lastValue(), 10, "Second target should have correct value");
    }

    function test_getCallbackForNonExistentCallback() public {
        Callback.CallbackData memory data = callbackContract.getCallback(999);
        assertEq(data.target, address(0), "Non-existent callback should return empty data");
    }

    function test_existsForNonExistentCallback() public {
        assertFalse(callbackContract.exists(999), "Non-existent callback should not exist");
    }
}

/// @notice Test contract for callback functionality
contract TestTarget {
    uint256 public lastValue;
    bool public successCalled;
    bool public errorCalled;

    function handleSuccess(bytes memory data) external returns (uint256) {
        uint256 value = abi.decode(data, (uint256));
        lastValue = value;
        successCalled = true;
        return value * 2; // Double the input
    }

    function handleError(bytes memory data) external returns (string memory) {
        errorCalled = true;
        string memory errorMsg = abi.decode(data, (string));
        return string(abi.encodePacked("Handled: ", errorMsg));
    }

    function alwaysFails(bytes memory) external pure returns (uint256) {
        revert("This function always fails");
    }

    function reset() external {
        lastValue = 0;
        successCalled = false;
        errorCalled = false;
    }
} 