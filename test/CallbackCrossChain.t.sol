// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Relayer} from "../src/test/Relayer.sol";

import {Promise} from "../src/Promise.sol";
import {Callback} from "../src/Callback.sol";
import {PredeployAddresses} from "../src/libraries/PredeployAddresses.sol";

/// @title CallbackCrossChain
/// @notice Tests for cross-chain callback functionality
contract CallbackCrossChainTest is Test, Relayer {
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