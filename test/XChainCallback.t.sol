// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Relayer} from "../src/test/Relayer.sol";

import {Promise} from "../src/Promise.sol";
import {Callback} from "../src/Callback.sol";
import {PredeployAddresses} from "../src/libraries/PredeployAddresses.sol";

/// @title XChainCallback
/// @notice Tests for cross-chain callback functionality
contract XChainCallbackTest is Test, Relayer {
    // Contracts on each chain
    Promise public promiseA;
    Promise public promiseB;
    Callback public callbackA;
    Callback public callbackB;

    string[] private rpcUrls = [
        vm.envOr("CHAIN_A_RPC_URL", string("https://interop-alpha-0.optimism.io")),
        vm.envOr("CHAIN_B_RPC_URL", string("https://interop-alpha-1.optimism.io"))
    ];

    constructor() Relayer(rpcUrls) {}

    function setUp() public {
        // Deploy Promise contracts using CREATE2 for same addresses
        vm.selectFork(forkIds[0]);
        promiseA = new Promise{salt: bytes32(0)}(
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        callbackA = new Callback{salt: bytes32(0)}(
            address(promiseA),
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        
        vm.selectFork(forkIds[1]);
        promiseB = new Promise{salt: bytes32(0)}(
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        callbackB = new Callback{salt: bytes32(0)}(
            address(promiseB),
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        
        // Verify contracts have same addresses on both chains
        require(address(promiseA) == address(promiseB), "Promise contracts must have same address");
        require(address(callbackA) == address(callbackB), "Callback contracts must have same address");
    }

    /// @notice Test basic cross-chain then callback
    function test_CrossChainThenCallback() public {
        vm.selectFork(forkIds[0]);
        
        // Create parent promise on Chain A
        uint256 parentPromiseId = promiseA.create();
        
        // Create target contract on Chain B
        vm.selectFork(forkIds[1]);
        TestTarget target = new TestTarget();
        
        // Register cross-chain callback from Chain A to Chain B
        vm.selectFork(forkIds[0]);
        uint256 chainBId = chainIdByForkId[forkIds[1]];
        uint256 callbackPromiseId = callbackA.thenOn(
            chainBId,
            parentPromiseId, 
            address(target), 
            target.handleSuccess.selector
        );
        
        // Relay the callback registration message to Chain B
        relayAllMessages();
        
        // Verify callback was registered on Chain B
        vm.selectFork(forkIds[1]);
        assertTrue(callbackB.exists(callbackPromiseId), "Callback should be registered on Chain B");
        
        Callback.CallbackData memory callbackData = callbackB.getCallback(callbackPromiseId);
        assertEq(callbackData.parentPromiseId, parentPromiseId, "Parent promise ID should match");
        assertEq(callbackData.target, address(target), "Target should match");
        assertEq(callbackData.selector, target.handleSuccess.selector, "Selector should match");
        assertEq(uint8(callbackData.callbackType), uint8(Callback.CallbackType.Then), "Should be Then callback");
        
        // Resolve parent promise on Chain A
        vm.selectFork(forkIds[0]);
        promiseA.resolve(parentPromiseId, abi.encode("Test data"));
        
        // Share resolved promise to Chain B
        promiseA.shareResolvedPromise(chainBId, parentPromiseId);
        
        // Relay the share message to Chain B
        relayAllMessages();
        
        // Verify parent promise exists on Chain B
        vm.selectFork(forkIds[1]);
        assertTrue(promiseB.exists(parentPromiseId), "Parent promise should exist on Chain B");
        assertEq(uint8(promiseB.status(parentPromiseId)), uint8(Promise.PromiseStatus.Resolved), "Parent should be resolved");
        
        // Execute callback on Chain B
        assertTrue(callbackB.canResolve(callbackPromiseId), "Callback should be resolvable");
        callbackB.resolve(callbackPromiseId);
        
        // Verify callback executed successfully
        assertTrue(target.successCalled(), "Target should have been called");
        assertEq(target.lastValue(), "Test data", "Target should receive correct data");
        assertEq(uint8(promiseB.status(callbackPromiseId)), uint8(Promise.PromiseStatus.Resolved), "Callback promise should be resolved");
        assertFalse(callbackB.exists(callbackPromiseId), "Callback should be cleaned up");
    }

    /// @notice Test cross-chain onReject callback
    function test_CrossChainOnRejectCallback() public {
        vm.selectFork(forkIds[0]);
        
        // Create parent promise on Chain A
        uint256 parentPromiseId = promiseA.create();
        
        // Create target contract on Chain B
        vm.selectFork(forkIds[1]);
        TestTarget target = new TestTarget();
        
        // Register cross-chain onReject callback from Chain A to Chain B
        vm.selectFork(forkIds[0]);
        uint256 chainBId = chainIdByForkId[forkIds[1]];
        uint256 callbackPromiseId = callbackA.onRejectOn(
            chainBId,
            parentPromiseId,
            address(target),
            target.handleError.selector
        );
        
        // Relay the callback registration message to Chain B
        relayAllMessages();
        
        // Verify callback was registered on Chain B
        vm.selectFork(forkIds[1]);
        assertTrue(callbackB.exists(callbackPromiseId), "Callback should be registered on Chain B");
        
        Callback.CallbackData memory callbackData = callbackB.getCallback(callbackPromiseId);
        assertEq(uint8(callbackData.callbackType), uint8(Callback.CallbackType.Catch), "Should be Catch callback");
        
        // Reject parent promise on Chain A
        vm.selectFork(forkIds[0]);
        promiseA.reject(parentPromiseId, abi.encode("Test error"));
        
        // Share rejected promise to Chain B
        promiseA.shareResolvedPromise(chainBId, parentPromiseId);
        
        // Relay the share message to Chain B
        relayAllMessages();
        
        // Verify parent promise exists on Chain B
        vm.selectFork(forkIds[1]);
        assertTrue(promiseB.exists(parentPromiseId), "Parent promise should exist on Chain B");
        assertEq(uint8(promiseB.status(parentPromiseId)), uint8(Promise.PromiseStatus.Rejected), "Parent should be rejected");
        
        // Execute callback on Chain B
        assertTrue(callbackB.canResolve(callbackPromiseId), "Callback should be resolvable");
        callbackB.resolve(callbackPromiseId);
        
        // Verify callback executed successfully
        assertTrue(target.errorCalled(), "Error handler should have been called");
        assertEq(uint8(promiseB.status(callbackPromiseId)), uint8(Promise.PromiseStatus.Resolved), "Callback promise should be resolved");
    }

    /// @notice Test that then callback doesn't execute when parent is rejected
    function test_CrossChainThenCallbackNotExecutedWhenParentRejected() public {
        vm.selectFork(forkIds[0]);
        
        // Create parent promise on Chain A
        uint256 parentPromiseId = promiseA.create();
        
        // Create target contract on Chain B
        vm.selectFork(forkIds[1]);
        TestTarget target = new TestTarget();
        
        // Register cross-chain then callback from Chain A to Chain B
        vm.selectFork(forkIds[0]);
        uint256 chainBId = chainIdByForkId[forkIds[1]];
        uint256 callbackPromiseId = callbackA.thenOn(
            chainBId,
            parentPromiseId,
            address(target),
            target.handleSuccess.selector
        );
        
        // Relay the callback registration
        relayAllMessages();
        
        // Reject parent promise on Chain A
        promiseA.reject(parentPromiseId, abi.encode("Test error"));
        
        // Share rejected promise to Chain B
        promiseA.shareResolvedPromise(chainBId, parentPromiseId);
        relayAllMessages();
        
        // Execute callback on Chain B (should reject callback since parent was rejected)
        vm.selectFork(forkIds[1]);
        assertTrue(callbackB.canResolve(callbackPromiseId), "Callback should be resolvable to reject it");
        callbackB.resolve(callbackPromiseId);
        
        // Verify callback was rejected and target wasn't called
        assertFalse(target.successCalled(), "Success handler should not have been called");
        assertEq(uint8(promiseB.status(callbackPromiseId)), uint8(Promise.PromiseStatus.Rejected), "Callback promise should be rejected");
    }

    /// @notice Test error handling for cross-chain callbacks
    function test_CrossChainCallbackErrorHandling() public {
        vm.selectFork(forkIds[0]);
        
        // Try to register cross-chain callback to same chain (should revert)
        uint256 parentPromiseId = promiseA.create();
        uint256 chainAId = chainIdByForkId[forkIds[0]];
        
        vm.expectRevert("Callback: cannot register callback on same chain");
        callbackA.thenOn(chainAId, parentPromiseId, address(this), this.dummyHandler.selector);
        
        vm.expectRevert("Callback: cannot register callback on same chain");
        callbackA.onRejectOn(chainAId, parentPromiseId, address(this), this.dummyHandler.selector);
    }

    /// @notice Test multiple cross-chain callbacks on same parent promise
    function test_MultipleCrossChainCallbacks() public {
        vm.selectFork(forkIds[0]);
        
        // Create parent promise on Chain A
        uint256 parentPromiseId = promiseA.create();
        
        // Create target contracts on Chain B
        vm.selectFork(forkIds[1]);
        TestTarget target1 = new TestTarget();
        TestTarget target2 = new TestTarget();
        
        // Register multiple cross-chain callbacks from Chain A to Chain B
        vm.selectFork(forkIds[0]);
        uint256 chainBId = chainIdByForkId[forkIds[1]];
        uint256 callback1 = callbackA.thenOn(chainBId, parentPromiseId, address(target1), target1.handleSuccess.selector);
        uint256 callback2 = callbackA.thenOn(chainBId, parentPromiseId, address(target2), target2.handleSuccess.selector);
        
        // Relay callback registrations
        relayAllMessages();
        
        // Resolve parent promise and share to Chain B
        promiseA.resolve(parentPromiseId, abi.encode("Shared data"));
        promiseA.shareResolvedPromise(chainBId, parentPromiseId);
        relayAllMessages();
        
        // Execute both callbacks on Chain B
        vm.selectFork(forkIds[1]);
        assertTrue(callbackB.canResolve(callback1), "Callback 1 should be resolvable");
        assertTrue(callbackB.canResolve(callback2), "Callback 2 should be resolvable");
        
        callbackB.resolve(callback1);
        callbackB.resolve(callback2);
        
        // Verify both callbacks executed
        assertTrue(target1.successCalled(), "Target 1 should have been called");
        assertTrue(target2.successCalled(), "Target 2 should have been called");
        assertEq(target1.lastValue(), "Shared data", "Target 1 should receive correct data");
        assertEq(target2.lastValue(), "Shared data", "Target 2 should receive correct data");
    }

    /// @notice Test creating callbacks for promises that don't exist locally (remote promises)
    function test_CallbackForRemotePromise() public {
        vm.selectFork(forkIds[0]);
        
        // Create a promise on Chain A
        uint256 remotePromiseId = promiseA.create();
        
        // Create target contract on Chain B
        vm.selectFork(forkIds[1]);
        TestTarget target = new TestTarget();
        
        // Create a callback on Chain B for the promise that only exists on Chain A
        // This should work now that we removed the existence check
        uint256 callbackPromiseId = callbackB.then(
            remotePromiseId,
            address(target),
            target.handleSuccess.selector
        );
        
        // Verify callback was created even though parent promise doesn't exist locally
        assertTrue(callbackB.exists(callbackPromiseId), "Callback should exist even for remote promise");
        assertFalse(promiseB.exists(remotePromiseId), "Parent promise should not exist locally on Chain B");
        
        // Callback should not be resolvable yet (parent promise not shared)
        assertFalse(callbackB.canResolve(callbackPromiseId), "Callback should not be resolvable yet");
        
        // Resolve the promise on Chain A
        vm.selectFork(forkIds[0]);
        promiseA.resolve(remotePromiseId, abi.encode("Remote data"));
        
        // Share the resolved promise to Chain B
        uint256 chainBId = chainIdByForkId[forkIds[1]];
        promiseA.shareResolvedPromise(chainBId, remotePromiseId);
        relayAllMessages();
        
        // Now on Chain B, the promise should exist and callback should be resolvable
        vm.selectFork(forkIds[1]);
        assertTrue(promiseB.exists(remotePromiseId), "Parent promise should now exist on Chain B");
        assertEq(uint8(promiseB.status(remotePromiseId)), uint8(Promise.PromiseStatus.Resolved), "Parent should be resolved");
        assertTrue(callbackB.canResolve(callbackPromiseId), "Callback should be resolvable now");
        
        // Execute the callback
        callbackB.resolve(callbackPromiseId);
        
        // Verify callback executed successfully
        assertTrue(target.successCalled(), "Target should have been called");
        assertEq(target.lastValue(), "Remote data", "Target should receive data from remote promise");
        assertEq(uint8(promiseB.status(callbackPromiseId)), uint8(Promise.PromiseStatus.Resolved), "Callback should be resolved");
        assertFalse(callbackB.exists(callbackPromiseId), "Callback should be cleaned up");
    }

    /// @notice Test creating onReject callbacks for promises that don't exist locally (remote promises)
    function test_OnRejectCallbackForRemotePromise() public {
        vm.selectFork(forkIds[0]);
        
        // Create a promise on Chain A
        uint256 remotePromiseId = promiseA.create();
        
        // Create target contract on Chain B
        vm.selectFork(forkIds[1]);
        TestTarget target = new TestTarget();
        
        // Create an onReject callback on Chain B for the promise that only exists on Chain A
        uint256 callbackPromiseId = callbackB.onReject(
            remotePromiseId,
            address(target),
            target.handleError.selector
        );
        
        // Verify callback was created even though parent promise doesn't exist locally
        assertTrue(callbackB.exists(callbackPromiseId), "Callback should exist even for remote promise");
        assertFalse(promiseB.exists(remotePromiseId), "Parent promise should not exist locally on Chain B");
        
        // Reject the promise on Chain A
        vm.selectFork(forkIds[0]);
        promiseA.reject(remotePromiseId, abi.encode("Remote error"));
        
        // Share the rejected promise to Chain B
        uint256 chainBId = chainIdByForkId[forkIds[1]];
        promiseA.shareResolvedPromise(chainBId, remotePromiseId);
        relayAllMessages();
        
        // Now on Chain B, the callback should be resolvable
        vm.selectFork(forkIds[1]);
        assertTrue(promiseB.exists(remotePromiseId), "Parent promise should now exist on Chain B");
        assertEq(uint8(promiseB.status(remotePromiseId)), uint8(Promise.PromiseStatus.Rejected), "Parent should be rejected");
        assertTrue(callbackB.canResolve(callbackPromiseId), "Callback should be resolvable now");
        
        // Execute the callback
        callbackB.resolve(callbackPromiseId);
        
        // Verify callback executed successfully
        assertTrue(target.errorCalled(), "Error handler should have been called");
        assertEq(uint8(promiseB.status(callbackPromiseId)), uint8(Promise.PromiseStatus.Resolved), "Callback should be resolved");
    }

    /// @notice Test multiple callbacks for same remote promise
    function test_MultipleCallbacksForSameRemotePromise() public {
        vm.selectFork(forkIds[0]);
        
        // Create a promise on Chain A
        uint256 remotePromiseId = promiseA.create();
        
        // Create multiple target contracts on Chain B
        vm.selectFork(forkIds[1]);
        TestTarget target1 = new TestTarget();
        TestTarget target2 = new TestTarget();
        TestTarget errorTarget = new TestTarget();
        
        // Create multiple callbacks on Chain B for the same remote promise
        uint256 callback1 = callbackB.then(remotePromiseId, address(target1), target1.handleSuccess.selector);
        uint256 callback2 = callbackB.then(remotePromiseId, address(target2), target2.handleSuccess.selector);
        uint256 errorCallback = callbackB.onReject(remotePromiseId, address(errorTarget), errorTarget.handleError.selector);
        
        // All callbacks should exist even though parent promise doesn't exist locally
        assertTrue(callbackB.exists(callback1), "Callback 1 should exist");
        assertTrue(callbackB.exists(callback2), "Callback 2 should exist");
        assertTrue(callbackB.exists(errorCallback), "Error callback should exist");
        assertFalse(promiseB.exists(remotePromiseId), "Parent promise should not exist locally");
        
        // Resolve the promise on Chain A
        vm.selectFork(forkIds[0]);
        promiseA.resolve(remotePromiseId, abi.encode("Shared remote data"));
        
        // Share the resolved promise to Chain B
        uint256 chainBId = chainIdByForkId[forkIds[1]];
        promiseA.shareResolvedPromise(chainBId, remotePromiseId);
        relayAllMessages();
        
        // Now all then callbacks should be resolvable, error callback should not
        vm.selectFork(forkIds[1]);
        assertTrue(callbackB.canResolve(callback1), "Callback 1 should be resolvable");
        assertTrue(callbackB.canResolve(callback2), "Callback 2 should be resolvable");
        assertTrue(callbackB.canResolve(errorCallback), "Error callback should be resolvable for rejection");
        
        // Execute all callbacks
        callbackB.resolve(callback1);
        callbackB.resolve(callback2);
        callbackB.resolve(errorCallback); // This will reject since parent was resolved, not rejected
        
        // Verify then callbacks executed successfully
        assertTrue(target1.successCalled(), "Target 1 should have been called");
        assertTrue(target2.successCalled(), "Target 2 should have been called");
        assertEq(target1.lastValue(), "Shared remote data", "Target 1 should receive remote data");
        assertEq(target2.lastValue(), "Shared remote data", "Target 2 should receive remote data");
        
        // Verify error callback was rejected (since parent was resolved, not rejected)
        assertFalse(errorTarget.errorCalled(), "Error target should not have been called");
        assertEq(uint8(promiseB.status(errorCallback)), uint8(Promise.PromiseStatus.Rejected), "Error callback should be rejected");
    }

    /// @notice Test cross-chain callback registration for remote promises
    function test_CrossChainCallbackForRemotePromise() public {
        vm.selectFork(forkIds[0]);
        
        // Create a promise on Chain A
        uint256 remotePromiseId = promiseA.create();
        
        // Create target contract on Chain B
        vm.selectFork(forkIds[1]);
        TestTarget target = new TestTarget();
        
        // Register cross-chain callback from Chain A to Chain B for the promise on Chain A
        vm.selectFork(forkIds[0]);
        uint256 chainBId = chainIdByForkId[forkIds[1]];
        uint256 callbackPromiseId = callbackA.thenOn(
            chainBId,
            remotePromiseId,
            address(target),
            target.handleSuccess.selector
        );
        
        // Relay the callback registration
        relayAllMessages();
        
        // Verify callback was registered on Chain B
        vm.selectFork(forkIds[1]);
        assertTrue(callbackB.exists(callbackPromiseId), "Callback should be registered on Chain B");
        
        // The remote promise still doesn't exist on Chain B
        assertFalse(promiseB.exists(remotePromiseId), "Remote promise should not exist on Chain B yet");
        
        // Resolve the promise on Chain A
        vm.selectFork(forkIds[0]);
        promiseA.resolve(remotePromiseId, abi.encode("Cross-chain data"));
        
        // Share the resolved promise to Chain B
        promiseA.shareResolvedPromise(chainBId, remotePromiseId);
        relayAllMessages();
        
        // Now the callback should be resolvable on Chain B
        vm.selectFork(forkIds[1]);
        assertTrue(promiseB.exists(remotePromiseId), "Remote promise should now exist on Chain B");
        assertTrue(callbackB.canResolve(callbackPromiseId), "Callback should be resolvable");
        
        // Execute the callback
        callbackB.resolve(callbackPromiseId);
        
        // Verify callback executed successfully
        assertTrue(target.successCalled(), "Target should have been called");
        assertEq(target.lastValue(), "Cross-chain data", "Target should receive cross-chain data");
    }

    /// @notice Dummy handler for error testing
    function dummyHandler(bytes memory) external pure returns (string memory) {
        return "dummy";
    }
}

/// @notice Test contract for callback functionality
contract TestTarget {
    string public lastValue;
    bool public successCalled;
    bool public errorCalled;

    function handleSuccess(bytes memory data) external returns (string memory) {
        lastValue = abi.decode(data, (string));
        successCalled = true;
        return "success";
    }

    function handleError(bytes memory data) external returns (string memory) {
        errorCalled = true;
        string memory errorMsg = abi.decode(data, (string));
        return string(abi.encodePacked("Handled: ", errorMsg));
    }

    function reset() external {
        lastValue = "";
        successCalled = false;
        errorCalled = false;
    }
} 