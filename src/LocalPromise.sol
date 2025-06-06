// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @notice Local promise library for managing async callbacks
/// @dev Minimal implementation focused on local execution patterns
contract LocalPromise {
    enum PromiseStatus { PENDING, RESOLVED, REJECTED }
    
    struct PromiseState {
        PromiseStatus status;
        bytes value;      // resolved value OR rejection reason
        address creator;
    }
    
    struct Callback {
        address target;
        bytes4 selector;
        bytes4 errorSelector;  // optional error handler
    }
    
    /// @notice All promises by ID
    mapping(bytes32 => PromiseState) public promises;
    
    /// @notice Callbacks registered for each promise
    mapping(bytes32 => Callback[]) public callbacks;
    
    /// @notice Nonce for generating unique promise IDs
    uint256 private nonce;
    
    /// @notice Emitted when a promise is created
    event PromiseCreated(bytes32 indexed promiseId, address indexed creator);
    
    /// @notice Emitted when a promise is resolved
    event PromiseResolved(bytes32 indexed promiseId, bytes value);
    
    /// @notice Emitted when a promise is rejected
    event PromiseRejected(bytes32 indexed promiseId, bytes reason);
    
    /// @notice Emitted when a callback is registered
    event CallbackRegistered(bytes32 indexed promiseId, address target, bytes4 selector, bytes4 errorSelector);
    
    /// @notice Create a new pending promise
    /// @return promiseId The unique identifier for this promise
    function create() external returns (bytes32) {
        bytes32 promiseId = keccak256(abi.encodePacked(msg.sender, ++nonce, block.timestamp));
        
        promises[promiseId] = PromiseState({
            status: PromiseStatus.PENDING,
            value: "",
            creator: msg.sender
        });
        
        emit PromiseCreated(promiseId, msg.sender);
        return promiseId;
    }
    
    /// @notice Resolve a promise with a value, executing all callbacks
    /// @param promiseId The promise to resolve
    /// @param value The value to resolve with
    function resolve(bytes32 promiseId, bytes calldata value) external {
        PromiseState storage promiseState = promises[promiseId];
        require(promiseState.creator != address(0), "LocalPromise: promise does not exist");
        require(promiseState.creator == msg.sender, "LocalPromise: only creator can resolve");
        require(promiseState.status == PromiseStatus.PENDING, "LocalPromise: already resolved");
        
        // Update promise state
        promiseState.status = PromiseStatus.RESOLVED;
        promiseState.value = value;
        
        // Execute all success callbacks immediately (JavaScript-like behavior)
        Callback[] storage callbackList = callbacks[promiseId];
        for (uint256 i = 0; i < callbackList.length; i++) {
            Callback memory callback = callbackList[i];
            
            // Call the success callback function with the resolved value
            (bool success,) = callback.target.call(
                abi.encodePacked(callback.selector, value)
            );
            
            // Auto-reject if callback fails (JavaScript-like behavior)
            if (!success) {
                // If callback fails, call error callback if available
                if (callback.errorSelector != bytes4(0)) {
                    callback.target.call(
                        abi.encodeWithSelector(callback.errorSelector, abi.encode("Callback execution failed"))
                    );
                }
            }
        }
        
        emit PromiseResolved(promiseId, value);
    }
    
    /// @notice Reject a promise with an error reason, executing error callbacks
    /// @param promiseId The promise to reject
    /// @param reason The error reason
    function reject(bytes32 promiseId, bytes calldata reason) external {
        PromiseState storage promiseState = promises[promiseId];
        require(promiseState.creator != address(0), "LocalPromise: promise does not exist");
        require(promiseState.creator == msg.sender, "LocalPromise: only creator can reject");
        require(promiseState.status == PromiseStatus.PENDING, "LocalPromise: already resolved or rejected");
        
        // Update promise state
        promiseState.status = PromiseStatus.REJECTED;
        promiseState.value = reason;
        
        // Execute all error callbacks immediately
        Callback[] storage callbackList = callbacks[promiseId];
        for (uint256 i = 0; i < callbackList.length; i++) {
            Callback memory callback = callbackList[i];
            
            // Only call error callback if it's defined
            if (callback.errorSelector != bytes4(0)) {
                (bool success,) = callback.target.call(
                    abi.encodeWithSelector(callback.errorSelector, reason)
                );
                // Ignore failures in error callbacks to prevent cascading failures
            }
        }
        
        emit PromiseRejected(promiseId, reason);
    }
    
    /// @notice Register a callback to be executed when promise resolves or rejects
    /// @param promiseId The promise to listen to
    /// @param selector The function selector to call on success
    /// @param errorSelector The function selector to call on error (optional)
    function then(bytes32 promiseId, bytes4 selector, bytes4 errorSelector) public {
        require(promises[promiseId].creator != address(0), "LocalPromise: promise does not exist");
        
        PromiseState memory promiseState = promises[promiseId];
        
        // If already resolved/rejected, execute appropriate callback immediately
        if (promiseState.status == PromiseStatus.RESOLVED) {
            msg.sender.call(abi.encodePacked(selector, promiseState.value));
        } else if (promiseState.status == PromiseStatus.REJECTED) {
            if (errorSelector != bytes4(0)) {
                msg.sender.call(abi.encodeWithSelector(errorSelector, promiseState.value));
            }
        } else {
            // Register for future execution
            callbacks[promiseId].push(Callback({
                target: msg.sender,
                selector: selector,
                errorSelector: errorSelector
            }));
        }
        
        emit CallbackRegistered(promiseId, msg.sender, selector, errorSelector);
    }
    
    /// @notice Register a callback to be executed when promise resolves (no error handler)
    /// @param promiseId The promise to listen to  
    /// @param selector The function selector to call on success
    function then(bytes32 promiseId, bytes4 selector) external {
        then(promiseId, selector, bytes4(0));
    }
    
    /// @notice Register an error callback to be executed when promise rejects
    /// @param promiseId The promise to listen to
    /// @param errorSelector The function selector to call on error
    function onReject(bytes32 promiseId, bytes4 errorSelector) external {
        then(promiseId, bytes4(0), errorSelector);
    }
} 