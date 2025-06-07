// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {LocalPromise} from "../src/LocalPromise.sol";
import {PromiseExecutor} from "../src/PromiseExecutor.sol";

contract LocalPromiseTest is Test {
    LocalPromise public promises;
    PromiseExecutor public executor;
    
    // Test state (Forge automatically gives fresh state per test)
    uint256 public receivedValue;
    bool public callbackExecuted;
    bool public errorCallbackExecuted;
    bytes public receivedError;
    
    function setUp() public {
        promises = new LocalPromise();
        executor = new PromiseExecutor(address(promises));
        
        // Reset test state
        receivedValue = 0;
        callbackExecuted = false;
        errorCallbackExecuted = false;
        receivedError = "";
    }
    
    function test_create_promise() public {
        bytes32 promiseId = promises.create();
        
        // Verify promise exists and is pending
        (LocalPromise.PromiseStatus status, bytes memory value, address creator) = promises.promises(promiseId);
        
        assertEq(uint256(status), uint256(LocalPromise.PromiseStatus.PENDING));
        assertEq(value.length, 0);
        assertEq(creator, address(this));
    }
    
    function test_resolve_and_callback() public {
        // Create promise
        bytes32 promiseId = promises.create();
        
        // Register callback
        promises.then(promiseId, this.handleValue.selector);
        
        // Resolve with value
        uint256 testValue = 42;
        promises.resolve(promiseId, abi.encode(testValue));
        
        // Verify promise state
        (LocalPromise.PromiseStatus status, bytes memory value,) = promises.promises(promiseId);
        assertEq(uint256(status), uint256(LocalPromise.PromiseStatus.RESOLVED));
        assertEq(abi.decode(value, (uint256)), testValue);
        
        // Callbacks are NOT executed automatically - need manual execution
        assertFalse(callbackExecuted);
        
        // Execute callbacks manually
        executor.executePromiseCallbacks(promiseId);
        
        // Verify callback was executed
        assertTrue(callbackExecuted);
        assertEq(receivedValue, testValue);
    }
    
    function test_late_callback_registration() public {
        // Create and resolve promise first
        bytes32 promiseId = promises.create();
        uint256 testValue = 123;
        promises.resolve(promiseId, abi.encode(testValue));
        
        // Register callback AFTER resolution - no automatic execution
        promises.then(promiseId, this.handleValue.selector);
        
        // Verify callback was NOT executed automatically
        assertFalse(callbackExecuted);
        
        // Execute callbacks manually
        executor.executePromiseCallbacks(promiseId);
        
        // Verify callback was executed after manual execution
        assertTrue(callbackExecuted);
        assertEq(receivedValue, testValue);
    }
    
    /// @notice Callback function that receives the resolved value
    function handleValue(uint256 value) external {
        callbackExecuted = true;
        receivedValue = value;
        console.log("Callback executed with value:", value);
    }
    
    /// @notice Error callback function that receives rejection reasons
    function handleError(bytes calldata reason) external {
        errorCallbackExecuted = true;
        receivedError = reason;
        console.log("Error callback executed with reason length:", reason.length);
    }
    
    /// @notice Callback that always fails (for testing auto-rejection)
    function failingCallback(uint256 value) external pure {
        require(false, "This callback always fails");
    }
    
    function test_manual_rejection() public {
        // Create promise
        bytes32 promiseId = promises.create();
        
        // Register both success and error callbacks
        promises.then(promiseId, this.handleValue.selector, this.handleError.selector);
        
        // Manually reject the promise
        string memory errorMsg = "Something went wrong";
        promises.reject(promiseId, abi.encode(errorMsg));
        
        // Verify promise state
        (LocalPromise.PromiseStatus status, bytes memory value,) = promises.promises(promiseId);
        assertEq(uint256(status), uint256(LocalPromise.PromiseStatus.REJECTED));
        assertEq(abi.decode(value, (string)), errorMsg);
        
        // Callbacks are NOT executed automatically
        assertFalse(errorCallbackExecuted);
        assertFalse(callbackExecuted);
        
        // Execute callbacks manually
        executor.executePromiseCallbacks(promiseId);
        
        // Verify error callback was executed
        assertTrue(errorCallbackExecuted);
        assertEq(string(receivedError), errorMsg);
        
        // Verify success callback was NOT executed
        assertFalse(callbackExecuted);
    }
    
    function test_catch_method() public {
        // Create promise
        bytes32 promiseId = promises.create();
        
        // Register error callback using .onReject() convenience method
        promises.onReject(promiseId, this.handleError.selector);
        
        // Reject the promise
        string memory errorMsg = "Caught error";
        promises.reject(promiseId, abi.encode(errorMsg));
        
        // Callback not executed automatically
        assertFalse(errorCallbackExecuted);
        
        // Execute callbacks manually
        executor.executePromiseCallbacks(promiseId);
        
        // Verify error callback was executed
        assertTrue(errorCallbackExecuted);
        assertEq(string(receivedError), errorMsg);
    }
    
    function test_late_error_callback_registration() public {
        // Create and reject promise first
        bytes32 promiseId = promises.create();
        string memory errorMsg = "Already rejected";
        promises.reject(promiseId, abi.encode(errorMsg));
        
        // Register error callback AFTER rejection - no automatic execution
        promises.onReject(promiseId, this.handleError.selector);
        
        // Verify callback was NOT executed automatically
        assertFalse(errorCallbackExecuted);
        
        // Execute callbacks manually
        executor.executePromiseCallbacks(promiseId);
        
        // Verify error callback was executed after manual execution
        assertTrue(errorCallbackExecuted);
        assertEq(string(receivedError), errorMsg);
    }
    
    function test_promise_chaining() public {
        // Create initial promise
        bytes32 promise1 = promises.create();
        
        // Chain promises: promise1 -> promise2 -> promise3
        bytes32 promise2 = promises.then(promise1, this.doubleValue.selector);
        bytes32 promise3 = promises.then(promise2, this.addTen.selector);
        
        // Verify promises are different
        assertTrue(promise1 != promise2);
        assertTrue(promise2 != promise3);
        assertTrue(promise1 != promise3);
        
        // Resolve the first promise with value 5
        uint256 initialValue = 5;
        promises.resolve(promise1, abi.encode(initialValue));
        
        // Check promise1 state
        (LocalPromise.PromiseStatus status1, bytes memory value1,) = promises.promises(promise1);
        assertEq(uint256(status1), uint256(LocalPromise.PromiseStatus.RESOLVED));
        assertEq(abi.decode(value1, (uint256)), initialValue);
        
        // Promises are NOT auto-resolved - need manual chain execution
        (LocalPromise.PromiseStatus status2, bytes memory value2,) = promises.promises(promise2);
        assertEq(uint256(status2), uint256(LocalPromise.PromiseStatus.PENDING));
        
        (LocalPromise.PromiseStatus status3, bytes memory value3,) = promises.promises(promise3);
        assertEq(uint256(status3), uint256(LocalPromise.PromiseStatus.PENDING));
        
        // Execute the entire chain using the executor
        uint256 stepsExecuted = executor.flushChain(promise1, 10);
        assertEq(stepsExecuted, 2); // Should take 2 steps: promise1->promise2, promise2->promise3
        
        // Check promise2 state (should now be resolved with doubled value: 5 * 2 = 10)
        (status2, value2,) = promises.promises(promise2);
        assertEq(uint256(status2), uint256(LocalPromise.PromiseStatus.RESOLVED));
        assertEq(abi.decode(value2, (uint256)), 10);
        
        // Check promise3 state (should now be resolved with: 10 + 10 = 20)
        (status3, value3,) = promises.promises(promise3);
        assertEq(uint256(status3), uint256(LocalPromise.PromiseStatus.RESOLVED));
        assertEq(abi.decode(value3, (uint256)), 20);
        
        console.log("Chain: 5 -> double -> 10 -> add10 -> 20");
        console.log("SUCCESS: Promise chaining with controlled execution!");
    }
    
    /// @notice Callback that doubles the input value
    function doubleValue(uint256 value) external returns (uint256) {
        console.log("doubleValue called with:", value);
        return value * 2;
    }
    
    /// @notice Callback that adds ten to the input value  
    function addTen(uint256 value) external returns (uint256) {
        console.log("addTen called with:", value);
        return value + 10;
    }
    
    function test_error_breaks_chain() public {
        // Create chain: promise1 -> promise2 -> promise3
        bytes32 promise1 = promises.create();
        bytes32 promise2 = promises.then(promise1, this.doubleValue.selector);
        bytes32 promise3 = promises.then(promise2, this.addTen.selector);
        
        // Reject promise1 (should break the entire chain)
        promises.reject(promise1, abi.encode("Chain broken at start"));
        
        // Verify promise1 was rejected
        (LocalPromise.PromiseStatus status1,,) = promises.promises(promise1);
        assertEq(uint256(status1), uint256(LocalPromise.PromiseStatus.REJECTED));
        
        // Verify promise2 stays pending (chain broken, no auto-resolution)
        (LocalPromise.PromiseStatus status2,,) = promises.promises(promise2);
        assertEq(uint256(status2), uint256(LocalPromise.PromiseStatus.PENDING));
        
        // Verify promise3 stays pending (chain broken upstream)
        (LocalPromise.PromiseStatus status3,,) = promises.promises(promise3);
        assertEq(uint256(status3), uint256(LocalPromise.PromiseStatus.PENDING));
        
        // Try to execute chain - should not progress past the error
        uint256 stepsExecuted = executor.flushChain(promise1, 10);
        assertEq(stepsExecuted, 1); // Only executes the error callback, no chain progression
        
        // Verify promises still in expected states
        (status2,,) = promises.promises(promise2);
        assertEq(uint256(status2), uint256(LocalPromise.PromiseStatus.PENDING));
        
        (status3,,) = promises.promises(promise3);
        assertEq(uint256(status3), uint256(LocalPromise.PromiseStatus.PENDING));
        
        console.log("SUCCESS: Error correctly breaks promise chain");
    }
    
    function test_callback_failure_in_chain() public {
        // Create chain with failing callback
        bytes32 promise1 = promises.create();
        bytes32 promise2 = promises.then(promise1, this.failingCallback.selector, this.handleError.selector);
        bytes32 promise3 = promises.then(promise2, this.addTen.selector);
        
        // Resolve promise1 (should trigger failing callback)
        promises.resolve(promise1, abi.encode(uint256(5)));
        
        // Verify promise1 resolved
        (LocalPromise.PromiseStatus status1,,) = promises.promises(promise1);
        assertEq(uint256(status1), uint256(LocalPromise.PromiseStatus.RESOLVED));
        
        // Verify promise2 stays pending (failing callback doesn't auto-resolve it)
        (LocalPromise.PromiseStatus status2,,) = promises.promises(promise2);
        assertEq(uint256(status2), uint256(LocalPromise.PromiseStatus.PENDING));
        
        // Verify promise3 stays pending (chain broken by callback failure)
        (LocalPromise.PromiseStatus status3,,) = promises.promises(promise3);
        assertEq(uint256(status3), uint256(LocalPromise.PromiseStatus.PENDING));
        
        // Execute the chain - failing callback should trigger error handling
        uint256 stepsExecuted = executor.flushChain(promise1, 10);
        assertEq(stepsExecuted, 1); // Only executes promise1 callback (which fails)
        
        // Verify error callback was executed
        assertTrue(errorCallbackExecuted);
        
        // Verify promises remain in expected states (chain broken)
        (status2,,) = promises.promises(promise2);
        assertEq(uint256(status2), uint256(LocalPromise.PromiseStatus.PENDING));
        
        (status3,,) = promises.promises(promise3);
        assertEq(uint256(status3), uint256(LocalPromise.PromiseStatus.PENDING));
        
        console.log("SUCCESS: Callback failure correctly breaks chain");
    }
    
    function test_error_handling_with_chaining() public {
        // Create promise with dual callback for error handling
        bytes32 promise1 = promises.create();
        bytes32 promise2 = promises.then(promise1, this.doubleValue.selector, this.handleError.selector);
        bytes32 promise3 = promises.then(promise2, this.addTen.selector);
        
        // Reject promise1 (should trigger error callback, NOT continue chain)
        promises.reject(promise1, abi.encode("Error in chain"));
        
        // Verify promise1 was rejected
        (LocalPromise.PromiseStatus status1,,) = promises.promises(promise1);
        assertEq(uint256(status1), uint256(LocalPromise.PromiseStatus.REJECTED));
        
        // Verify promise2 stays pending (error doesn't auto-resolve it)
        (LocalPromise.PromiseStatus status2,,) = promises.promises(promise2);
        assertEq(uint256(status2), uint256(LocalPromise.PromiseStatus.PENDING));
        
        // Verify promise3 stays pending (chain broken by error)
        (LocalPromise.PromiseStatus status3,,) = promises.promises(promise3);
        assertEq(uint256(status3), uint256(LocalPromise.PromiseStatus.PENDING));
        
        // Execute the chain - should handle error and not continue
        uint256 stepsExecuted = executor.flushChain(promise1, 10);
        assertEq(stepsExecuted, 1); // Only executes the error callback
        
        // Verify error callback was executed
        assertTrue(errorCallbackExecuted);
        
        // Verify promises remain in expected states (chain broken)
        (status2,,) = promises.promises(promise2);
        assertEq(uint256(status2), uint256(LocalPromise.PromiseStatus.PENDING));
        
        (status3,,) = promises.promises(promise3);
        assertEq(uint256(status3), uint256(LocalPromise.PromiseStatus.PENDING));
        
        console.log("SUCCESS: Error handling works correctly in chains");
    }
    
    function test_late_registration_on_chained_promise() public {
        // Create and immediately resolve chain
        bytes32 promise1 = promises.create();
        bytes32 promise2 = promises.then(promise1, this.doubleValue.selector);
        
        // Resolve promise1 (does NOT auto-resolve promise2)
        promises.resolve(promise1, abi.encode(uint256(7)));
        
        // Execute the chain to resolve promise2
        executor.flushChain(promise1, 10);
        
        // Verify promise2 was resolved by chain execution
        (LocalPromise.PromiseStatus status2, bytes memory value2,) = promises.promises(promise2);
        assertEq(uint256(status2), uint256(LocalPromise.PromiseStatus.RESOLVED));
        assertEq(abi.decode(value2, (uint256)), 14); // 7 * 2
        
        // Now register late callback on already-resolved promise2
        promises.then(promise2, this.handleValue.selector);
        
        // Verify late callback was NOT executed automatically
        assertFalse(callbackExecuted);
        
        // Execute callbacks manually
        executor.executePromiseCallbacks(promise2);
        
        // Verify late callback was executed after manual execution
        assertTrue(callbackExecuted);
        assertEq(receivedValue, 14);
        
        console.log("SUCCESS: Late registration works on chained promises");
    }
    
    function test_multiple_callbacks_on_chained_promise() public {
        // Create chain
        bytes32 promise1 = promises.create();
        bytes32 promise2 = promises.then(promise1, this.doubleValue.selector);
        
        // Register additional callback on promise2 (before resolution)
        promises.then(promise2, this.handleValue.selector);
        
        // Resolve promise1 (does NOT auto-resolve promise2)
        promises.resolve(promise1, abi.encode(uint256(6)));
        
        // Execute the chain to resolve promise2
        executor.flushChain(promise1, 10);
        
        // Verify promise2 was resolved with transformed value
        (LocalPromise.PromiseStatus status2, bytes memory value2,) = promises.promises(promise2);
        assertEq(uint256(status2), uint256(LocalPromise.PromiseStatus.RESOLVED));
        assertEq(abi.decode(value2, (uint256)), 12); // 6 * 2
        
        // Additional callback WAS executed during chain execution
        // (flushChain executes ALL callbacks, including our additional one)
        assertTrue(callbackExecuted);
        assertEq(receivedValue, 12);
        
        console.log("SUCCESS: Multiple callbacks work with chaining");
    }
    
    // ============ EXECUTION ORDER TESTS ============
    
    function test_cannot_execute_pending_promise_callbacks() public {
        // Create promise but don't resolve it
        bytes32 promiseId = promises.create();
        
        // Register callback on pending promise
        promises.then(promiseId, this.handleValue.selector);
        
        // Try to execute callbacks on pending promise - should revert
        vm.expectRevert("PromiseExecutor: promise not ready");
        executor.executePromiseCallbacks(promiseId);
        
        // Callback should not have been executed
        assertFalse(callbackExecuted);
        
        console.log("SUCCESS: Cannot execute callbacks on pending promises");
    }
    
    function test_cannot_execute_chain_out_of_order() public {
        // Create chain: promise1 -> promise2 -> promise3
        bytes32 promise1 = promises.create();
        bytes32 promise2 = promises.then(promise1, this.doubleValue.selector);
        bytes32 promise3 = promises.then(promise2, this.addTen.selector);
        
        // DON'T resolve promise1 yet
        
        // Try to execute promise2 callbacks (should revert since promise2 is pending)
        vm.expectRevert("PromiseExecutor: promise not ready");
        executor.executePromiseCallbacks(promise2);
        
        // Try to execute promise3 callbacks (should revert since promise3 is pending)  
        vm.expectRevert("PromiseExecutor: promise not ready");
        executor.executePromiseCallbacks(promise3);
        
        // Verify all promises are still pending
        (LocalPromise.PromiseStatus status1,,) = promises.promises(promise1);
        (LocalPromise.PromiseStatus status2,,) = promises.promises(promise2);
        (LocalPromise.PromiseStatus status3,,) = promises.promises(promise3);
        
        assertEq(uint256(status1), uint256(LocalPromise.PromiseStatus.PENDING));
        assertEq(uint256(status2), uint256(LocalPromise.PromiseStatus.PENDING));
        assertEq(uint256(status3), uint256(LocalPromise.PromiseStatus.PENDING));
        
        console.log("SUCCESS: Cannot execute chain out of order");
    }
    
    function test_cannot_skip_chain_dependencies() public {
        // Create chain: promise1 -> promise2 -> promise3
        bytes32 promise1 = promises.create();
        bytes32 promise2 = promises.then(promise1, this.doubleValue.selector);
        bytes32 promise3 = promises.then(promise2, this.addTen.selector);
        
        // Resolve only promise1
        promises.resolve(promise1, abi.encode(uint256(5)));
        
        // Try to start chain execution from promise2 (should revert since promise2 is still pending)
        vm.expectRevert("PromiseExecutor: promise not ready");
        executor.executePromiseCallbacks(promise2);
        
        // Try to flush chain starting from promise2 (should revert since promise2 is pending)
        vm.expectRevert("PromiseExecutor: start promise not ready");
        executor.flushChain(promise2, 10);
        
        // Verify promise2 and promise3 are still pending
        (LocalPromise.PromiseStatus status2,,) = promises.promises(promise2);
        (LocalPromise.PromiseStatus status3,,) = promises.promises(promise3);
        
        assertEq(uint256(status2), uint256(LocalPromise.PromiseStatus.PENDING));
        assertEq(uint256(status3), uint256(LocalPromise.PromiseStatus.PENDING));
        
        console.log("SUCCESS: Cannot skip chain dependencies");
    }
    
    function test_partial_chain_execution_enforces_order() public {
        // Create chain: promise1 -> promise2 -> promise3
        bytes32 promise1 = promises.create();
        bytes32 promise2 = promises.then(promise1, this.doubleValue.selector);
        bytes32 promise3 = promises.then(promise2, this.addTen.selector);
        
        // Resolve promise1 and execute one step
        promises.resolve(promise1, abi.encode(uint256(5)));
        uint256 stepsExecuted = executor.flushChain(promise1, 1); // Limit to 1 step
        
        assertEq(stepsExecuted, 1); // Should execute exactly 1 step
        
        // Verify promise1 -> promise2 step was executed
        (LocalPromise.PromiseStatus status2, bytes memory value2,) = promises.promises(promise2);
        assertEq(uint256(status2), uint256(LocalPromise.PromiseStatus.RESOLVED));
        assertEq(abi.decode(value2, (uint256)), 10); // 5 * 2
        
        // But promise3 should still be pending (step limit prevented further execution)
        (LocalPromise.PromiseStatus status3,,) = promises.promises(promise3);
        assertEq(uint256(status3), uint256(LocalPromise.PromiseStatus.PENDING));
        
        // Now try to execute from promise3 directly (should revert since promise3 is still pending)
        vm.expectRevert("PromiseExecutor: promise not ready");
        executor.executePromiseCallbacks(promise3);
        
        // Continue chain execution from promise2 (now that it's resolved)
        uint256 moreSteps = executor.flushChain(promise2, 10);
        assertEq(moreSteps, 1); // Should execute promise2 -> promise3
        
        // Now promise3 should be resolved
        bytes memory value3;
        (status3, value3,) = promises.promises(promise3);
        assertEq(uint256(status3), uint256(LocalPromise.PromiseStatus.RESOLVED));
        assertEq(abi.decode(value3, (uint256)), 20); // 10 + 10
        
        console.log("SUCCESS: Partial chain execution enforces proper order");
    }
    
    function test_cannot_execute_callbacks_on_nonexistent_promise() public {
        // Try to execute callbacks on a promise that doesn't exist
        bytes32 fakePromiseId = bytes32(uint256(999999));
        
        // This should revert since the promise doesn't exist (creator will be address(0))
        vm.expectRevert("PromiseExecutor: promise not ready");
        executor.executePromiseCallbacks(fakePromiseId);
        
        console.log("SUCCESS: Cannot execute callbacks on non-existent promise");
    }
}  