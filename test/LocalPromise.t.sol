// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {LocalPromise} from "../src/LocalPromise.sol";

contract LocalPromiseTest is Test {
    LocalPromise public promises;
    
    // Test state (Forge automatically gives fresh state per test)
    uint256 public receivedValue;
    bool public callbackExecuted;
    bool public errorCallbackExecuted;
    bytes public receivedError;
    
    function setUp() public {
        promises = new LocalPromise();
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
        
        // Verify callback was executed
        assertTrue(callbackExecuted);
        assertEq(receivedValue, testValue);
        
        // Verify promise state
        (LocalPromise.PromiseStatus status, bytes memory value,) = promises.promises(promiseId);
        assertEq(uint256(status), uint256(LocalPromise.PromiseStatus.RESOLVED));
        assertEq(abi.decode(value, (uint256)), testValue);
    }
    
    function test_late_callback_registration() public {
        // Create and resolve promise first
        bytes32 promiseId = promises.create();
        uint256 testValue = 123;
        promises.resolve(promiseId, abi.encode(testValue));
        
        // Register callback AFTER resolution - should execute immediately
        promises.then(promiseId, this.handleValue.selector);
        
        // Verify callback was executed immediately
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
        
        // Verify error callback was executed
        assertTrue(errorCallbackExecuted);
        assertEq(abi.decode(receivedError, (string)), errorMsg);
        
        // Verify success callback was NOT executed
        assertFalse(callbackExecuted);
        
        // Verify promise state
        (LocalPromise.PromiseStatus status, bytes memory value,) = promises.promises(promiseId);
        assertEq(uint256(status), uint256(LocalPromise.PromiseStatus.REJECTED));
        assertEq(abi.decode(value, (string)), errorMsg);
    }
    
    function test_catch_method() public {
        // Create promise
        bytes32 promiseId = promises.create();
        
        // Register error callback using .onReject() convenience method
        promises.onReject(promiseId, this.handleError.selector);
        
        // Reject the promise
        string memory errorMsg = "Caught error";
        promises.reject(promiseId, abi.encode(errorMsg));
        
        // Verify error callback was executed
        assertTrue(errorCallbackExecuted);
        assertEq(abi.decode(receivedError, (string)), errorMsg);
    }
    
    function test_late_error_callback_registration() public {
        // Create and reject promise first
        bytes32 promiseId = promises.create();
        string memory errorMsg = "Already rejected";
        promises.reject(promiseId, abi.encode(errorMsg));
        
        // Register error callback AFTER rejection - should execute immediately
        promises.onReject(promiseId, this.handleError.selector);
        
        // Verify error callback was executed immediately
        assertTrue(errorCallbackExecuted);
        assertEq(abi.decode(receivedError, (string)), errorMsg);
    }
} 