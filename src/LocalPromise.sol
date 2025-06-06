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
        bytes32 nextPromiseId; // promise to auto-resolve with callback return value
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
        return _createPromise(msg.sender);
    }
    
    /// @notice Internal helper to create a promise with specified creator
    function _createPromise(address creator) internal returns (bytes32) {
        bytes32 promiseId = keccak256(abi.encodePacked(creator, ++nonce, block.timestamp));
        
        promises[promiseId] = PromiseState({
            status: PromiseStatus.PENDING,
            value: "",
            creator: creator
        });
        
        emit PromiseCreated(promiseId, creator);
        return promiseId;
    }
    
    /// @notice Internal helper to set promise state (no automatic execution)
    function _setPromiseState(bytes32 promiseId, PromiseStatus status, bytes memory value) internal {
        PromiseState storage promiseState = promises[promiseId];
        require(promiseState.status == PromiseStatus.PENDING, "LocalPromise: already resolved or rejected");
        
        promiseState.status = status;
        promiseState.value = value;
        
        if (status == PromiseStatus.RESOLVED) {
            emit PromiseResolved(promiseId, value);
        } else if (status == PromiseStatus.REJECTED) {
            emit PromiseRejected(promiseId, value);
        }
    }
    
    /// @notice Resolve a promise with a value (callbacks must be executed separately)
    /// @param promiseId The promise to resolve
    /// @param value The value to resolve with
    function resolve(bytes32 promiseId, bytes calldata value) external {
        PromiseState storage promiseState = promises[promiseId];
        require(promiseState.creator != address(0), "LocalPromise: promise does not exist");
        require(promiseState.creator == msg.sender, "LocalPromise: only creator can resolve");
        require(promiseState.status == PromiseStatus.PENDING, "LocalPromise: already resolved");
        
        _setPromiseState(promiseId, PromiseStatus.RESOLVED, value);
    }
    
    /// @notice Execute a specific callback for a resolved/rejected promise
    /// @param promiseId The promise whose callback to execute
    /// @param callbackIndex The index of the callback to execute  
    /// @return nextPromiseId The next promise ID if chaining (bytes32(0) if none)
    function executeCallback(bytes32 promiseId, uint256 callbackIndex) external returns (bytes32 nextPromiseId) {
        PromiseState memory promiseState = promises[promiseId];
        require(promiseState.status != PromiseStatus.PENDING, "LocalPromise: promise not yet resolved");
        
        Callback[] storage callbackList = callbacks[promiseId];
        require(callbackIndex < callbackList.length, "LocalPromise: callback index out of bounds");
        
        Callback memory callback = callbackList[callbackIndex];
        bool isError = promiseState.status == PromiseStatus.REJECTED;
        
        if (isError) {
            // Execute error callback if available
            if (callback.errorSelector != bytes4(0)) {
                callback.target.call(abi.encodeWithSelector(callback.errorSelector, promiseState.value));
            }
        } else {
            // Execute success callback and handle chaining
            if (callback.selector != bytes4(0)) {
                (bool success, bytes memory returnData) = callback.target.call(
                    abi.encodePacked(callback.selector, promiseState.value)
                );
                
                if (success && callback.nextPromiseId != bytes32(0)) {
                    // Resolve next promise with callback return value (no recursion)
                    _setPromiseState(callback.nextPromiseId, PromiseStatus.RESOLVED, returnData);
                    nextPromiseId = callback.nextPromiseId;
                } else if (!success) {
                    // Handle callback failure
                    if (callback.errorSelector != bytes4(0)) {
                        callback.target.call(
                            abi.encodeWithSelector(callback.errorSelector, abi.encode("Callback execution failed"))
                        );
                    }
                }
            }
        }
    }
    
    /// @notice Execute all callbacks for a resolved/rejected promise
    /// @param promiseId The promise whose callbacks to execute
    /// @return nextPromiseIds Array of next promise IDs from chaining
    function executeAllCallbacks(bytes32 promiseId) external returns (bytes32[] memory nextPromiseIds) {
        Callback[] storage callbackList = callbacks[promiseId];
        nextPromiseIds = new bytes32[](callbackList.length);
        uint256 nextCount = 0;
        
        for (uint256 i = 0; i < callbackList.length; i++) {
            bytes32 nextPromiseId = this.executeCallback(promiseId, i);
            if (nextPromiseId != bytes32(0)) {
                nextPromiseIds[nextCount] = nextPromiseId;
                nextCount++;
            }
        }
        
        // Resize array to actual count
        assembly {
            mstore(nextPromiseIds, nextCount)
        }
    }
    
    /// @notice Reject a promise with an error reason (callbacks must be executed separately)
    /// @param promiseId The promise to reject
    /// @param reason The error reason
    function reject(bytes32 promiseId, bytes calldata reason) external {
        PromiseState storage promiseState = promises[promiseId];
        require(promiseState.creator != address(0), "LocalPromise: promise does not exist");
        require(promiseState.creator == msg.sender, "LocalPromise: only creator can reject");
        require(promiseState.status == PromiseStatus.PENDING, "LocalPromise: already resolved or rejected");
        
        _setPromiseState(promiseId, PromiseStatus.REJECTED, reason);
    }
    
    /// @notice Register a callback to be executed when promise resolves or rejects
    /// @param promiseId The promise to listen to
    /// @param selector The function selector to call on success
    /// @param errorSelector The function selector to call on error (optional)
    /// @return nextPromiseId New promise ID for chaining (if success callback provided)
    function then(bytes32 promiseId, bytes4 selector, bytes4 errorSelector) public returns (bytes32 nextPromiseId) {
        require(promises[promiseId].creator != address(0), "LocalPromise: promise does not exist");
        
        // Create new promise for chaining (if success callback provided)
        if (selector != bytes4(0)) {
            nextPromiseId = _createPromise(msg.sender);
        }
        
        PromiseState memory promiseState = promises[promiseId];
        
        // Always register callback (no automatic execution even for resolved promises)
        callbacks[promiseId].push(Callback({
            target: msg.sender,
            selector: selector,
            errorSelector: errorSelector,
            nextPromiseId: nextPromiseId
        }));
        
        emit CallbackRegistered(promiseId, msg.sender, selector, errorSelector);
    }
    
    /// @notice Register a callback to be executed when promise resolves (no error handler)
    /// @param promiseId The promise to listen to  
    /// @param selector The function selector to call on success
    /// @return nextPromiseId New promise ID for chaining
    function then(bytes32 promiseId, bytes4 selector) external returns (bytes32) {
        return then(promiseId, selector, bytes4(0));
    }
    
    /// @notice Register an error callback to be executed when promise rejects
    /// @param promiseId The promise to listen to
    /// @param errorSelector The function selector to call on error
    function onReject(bytes32 promiseId, bytes4 errorSelector) external {
        then(promiseId, bytes4(0), errorSelector);
    }
    
    /// @notice Get the number of callbacks registered for a promise
    /// @param promiseId The promise to query
    /// @return Number of callbacks
    function getCallbackCount(bytes32 promiseId) external view returns (uint256) {
        return callbacks[promiseId].length;
    }
    
    /// @notice Get a specific callback for a promise
    /// @param promiseId The promise to query
    /// @param index The callback index
    /// @return callback The callback data
    function getCallback(bytes32 promiseId, uint256 index) external view returns (Callback memory callback) {
        require(index < callbacks[promiseId].length, "LocalPromise: callback index out of bounds");
        return callbacks[promiseId][index];
    }
    
    /// @notice Check if a promise is ready for callback execution
    /// @param promiseId The promise to check
    /// @return ready True if promise is resolved or rejected
    function isReadyForExecution(bytes32 promiseId) external view returns (bool ready) {
        return promises[promiseId].status != PromiseStatus.PENDING;
    }
    
    /// @notice Get all callbacks for a promise
    /// @param promiseId The promise to query
    /// @return callbackList Array of all callbacks
    function getAllCallbacks(bytes32 promiseId) external view returns (Callback[] memory callbackList) {
        return callbacks[promiseId];
    }
} 