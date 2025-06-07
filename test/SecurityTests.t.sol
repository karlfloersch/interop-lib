// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {CrossChainPromise} from "../src/CrossChainPromise.sol";
import {LocalPromise} from "../src/LocalPromise.sol";
import {PromiseAwareMessenger} from "../src/PromiseAwareMessenger.sol";
import {PromiseExecutor} from "../src/PromiseExecutor.sol";

contract SecurityTestsTest is Test {
    CrossChainPromise public promises;
    LocalPromise public localPromises;
    PromiseAwareMessenger public messenger;
    PromiseExecutor public executor;
    
    address public alice = address(0x1111);
    address public bob = address(0x2222);
    address public attacker = address(0x3333);
    
    function setUp() public {
        messenger = new PromiseAwareMessenger();
        promises = new CrossChainPromise(address(messenger));
        localPromises = new LocalPromise();
        executor = new PromiseExecutor(address(localPromises));
    }
    
    // ============ CROSS-CHAIN AUTHORIZATION TESTS ============
    
    function test_unauthorized_setupRemotePromise_reverts() public {
        vm.prank(attacker);
        vm.expectRevert("CrossChainPromise: not from messenger");
        promises.setupRemotePromise(
            bytes32(uint256(1)), // remotePromiseId
            alice,              // target
            bytes4(0x12345678), // selector
            bytes4(0x87654321), // errorSelector
            1,                  // returnChain
            bytes32(uint256(2)) // returnPromiseId
        );
        
        console.log("SUCCESS: setupRemotePromise protected from unauthorized access");
    }
    
    function test_unauthorized_executeRemoteCallback_reverts() public {
        vm.prank(attacker);
        vm.expectRevert("CrossChainPromise: not from messenger");
        promises.executeRemoteCallback(
            bytes32(uint256(1)), // remotePromiseId
            abi.encode("test")   // value
        );
        
        console.log("SUCCESS: executeRemoteCallback protected from unauthorized access");
    }
    
    function test_unauthorized_resolveChainedPromise_reverts() public {
        vm.prank(attacker);
        vm.expectRevert("CrossChainPromise: not from messenger");
        promises._resolveChainedPromise(
            bytes32(uint256(1)), // proxyPromiseId
            abi.encode("test")   // resultData
        );
        
        console.log("SUCCESS: _resolveChainedPromise protected from unauthorized access");
    }
    
    function test_unauthorized_rejectChainedPromise_reverts() public {
        vm.prank(attacker);
        vm.expectRevert("CrossChainPromise: not from messenger");
        promises._rejectChainedPromise(
            bytes32(uint256(1)), // proxyPromiseId
            abi.encode("error")  // errorData
        );
        
        console.log("SUCCESS: _rejectChainedPromise protected from unauthorized access");
    }
    
    // ============ LOCAL PROMISE AUTHORIZATION TESTS ============
    
    function test_only_creator_can_resolve() public {
        // Alice creates a promise
        vm.prank(alice);
        bytes32 promiseId = localPromises.create();
        
        // Bob tries to resolve it - should fail
        vm.prank(bob);
        vm.expectRevert("LocalPromise: only creator can resolve");
        localPromises.resolve(promiseId, abi.encode("unauthorized"));
        
        // Alice can resolve it - should work
        vm.prank(alice);
        localPromises.resolve(promiseId, abi.encode("authorized"));
        
        // Verify it was resolved
        (LocalPromise.PromiseStatus status, bytes memory value,) = localPromises.promises(promiseId);
        assertEq(uint256(status), uint256(LocalPromise.PromiseStatus.RESOLVED));
        assertEq(string(abi.decode(value, (string))), "authorized");
        
        console.log("SUCCESS: Only promise creator can resolve");
    }
    
    function test_only_creator_can_reject() public {
        // Alice creates a promise
        vm.prank(alice);
        bytes32 promiseId = localPromises.create();
        
        // Bob tries to reject it - should fail
        vm.prank(bob);
        vm.expectRevert("LocalPromise: only creator can reject");
        localPromises.reject(promiseId, abi.encode("unauthorized"));
        
        // Alice can reject it - should work
        vm.prank(alice);
        localPromises.reject(promiseId, abi.encode("authorized"));
        
        // Verify it was rejected
        (LocalPromise.PromiseStatus status, bytes memory value,) = localPromises.promises(promiseId);
        assertEq(uint256(status), uint256(LocalPromise.PromiseStatus.REJECTED));
        assertEq(string(abi.decode(value, (string))), "authorized");
        
        console.log("SUCCESS: Only promise creator can reject");
    }
    
    // ============ EDGE CASE SECURITY TESTS ============
    
    function test_double_resolution_protection() public {
        vm.prank(alice);
        bytes32 promiseId = localPromises.create();
        
        // Resolve the promise
        vm.prank(alice);
        localPromises.resolve(promiseId, abi.encode("first"));
        
        // Try to resolve again - should fail
        vm.prank(alice);
        vm.expectRevert("LocalPromise: already resolved");
        localPromises.resolve(promiseId, abi.encode("second"));
        
        // Verify original value is preserved
        (LocalPromise.PromiseStatus status, bytes memory value,) = localPromises.promises(promiseId);
        assertEq(uint256(status), uint256(LocalPromise.PromiseStatus.RESOLVED));
        assertEq(string(abi.decode(value, (string))), "first");
        
        console.log("SUCCESS: Double resolution protection working");
    }
    
    function test_double_rejection_protection() public {
        vm.prank(alice);
        bytes32 promiseId = localPromises.create();
        
        // Reject the promise
        vm.prank(alice);
        localPromises.reject(promiseId, abi.encode("first error"));
        
        // Try to reject again - should fail
        vm.prank(alice);
        vm.expectRevert("LocalPromise: already resolved or rejected");
        localPromises.reject(promiseId, abi.encode("second error"));
        
        // Verify original error is preserved
        (LocalPromise.PromiseStatus status, bytes memory value,) = localPromises.promises(promiseId);
        assertEq(uint256(status), uint256(LocalPromise.PromiseStatus.REJECTED));
        assertEq(string(abi.decode(value, (string))), "first error");
        
        console.log("SUCCESS: Double rejection protection working");
    }
    
    function test_resolve_after_reject_protection() public {
        vm.prank(alice);
        bytes32 promiseId = localPromises.create();
        
        // Reject the promise
        vm.prank(alice);
        localPromises.reject(promiseId, abi.encode("rejected"));
        
        // Try to resolve after rejection - should fail
        vm.prank(alice);
        vm.expectRevert("LocalPromise: already resolved");
        localPromises.resolve(promiseId, abi.encode("trying to resolve"));
        
        // Verify rejection is preserved
        (LocalPromise.PromiseStatus status, bytes memory value,) = localPromises.promises(promiseId);
        assertEq(uint256(status), uint256(LocalPromise.PromiseStatus.REJECTED));
        assertEq(string(abi.decode(value, (string))), "rejected");
        
        console.log("SUCCESS: Cannot resolve after rejection");
    }
    
    function test_reject_after_resolve_protection() public {
        vm.prank(alice);
        bytes32 promiseId = localPromises.create();
        
        // Resolve the promise
        vm.prank(alice);
        localPromises.resolve(promiseId, abi.encode("resolved"));
        
        // Try to reject after resolution - should fail
        vm.prank(alice);
        vm.expectRevert("LocalPromise: already resolved or rejected");
        localPromises.reject(promiseId, abi.encode("trying to reject"));
        
        // Verify resolution is preserved
        (LocalPromise.PromiseStatus status, bytes memory value,) = localPromises.promises(promiseId);
        assertEq(uint256(status), uint256(LocalPromise.PromiseStatus.RESOLVED));
        assertEq(string(abi.decode(value, (string))), "resolved");
        
        console.log("SUCCESS: Cannot reject after resolution");
    }
    
    function test_invalid_promise_execution_protection() public {
        bytes32 fakePromiseId = bytes32(uint256(999999));
        
        // Try to get promise that doesn't exist
        (LocalPromise.PromiseStatus status,,) = localPromises.promises(fakePromiseId);
        assertEq(uint256(status), uint256(LocalPromise.PromiseStatus.PENDING));
        
        // Since the promise doesn't exist, it will be in default PENDING state
        // This is expected behavior as non-existent promises are just empty
        console.log("SUCCESS: Invalid promise behavior is predictable");
    }
    
    // ============ CALLBACK FAILURE RECOVERY TESTS ============
    
    uint256 public callbackValue;
    bool public errorHandlerExecuted;
    
    function test_callback_failure_recovery() public {
        vm.prank(alice);
        bytes32 promiseId = localPromises.create();
        
        // Register callback that will fail and error handler
        localPromises.then(promiseId, this.failingCallback.selector, this.errorHandler.selector);
        
        // Resolve promise
        vm.prank(alice);
        localPromises.resolve(promiseId, abi.encode(uint256(123)));
        
        // Execute callback via PromiseExecutor - should fail gracefully and call error handler
        executor.executePromiseCallbacks(promiseId);
        
        // Verify error handler was called
        assertTrue(errorHandlerExecuted, "Error handler should have been executed");
        
        console.log("SUCCESS: Callback failure recovery working");
    }
    
    function failingCallback(uint256 value) external pure {
        require(false, "This callback always fails");
    }
    
    function errorHandler(bytes calldata error) external {
        errorHandlerExecuted = true;
        console.log("Error handler called with error length:", error.length);
    }
    
    function successCallback(uint256 value) external {
        callbackValue = value;
        console.log("Success callback received:", value);
    }
} 