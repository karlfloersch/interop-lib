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
    
    struct AllPromiseData {
        bytes32[] promiseIds;      // The promises we're waiting for
        bytes[] results;           // Collected results (parallel to promiseIds)
        uint256 resolvedCount;     // How many have resolved so far
        bool hasRejected;          // If any rejected
        bytes rejectionReason;     // First rejection reason
        address creator;           // Who created this all-promise
    }
    
    /// @notice All promises by ID
    mapping(bytes32 => PromiseState) public promises;
    
    /// @notice Callbacks registered for each promise
    mapping(bytes32 => Callback[]) public callbacks;
    
    /// @notice Promise.all data by all-promise ID
    mapping(bytes32 => AllPromiseData) public allPromises;
    
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
    
    /// @notice Emitted when Promise.all is created
    event AllPromiseCreated(bytes32 indexed allPromiseId, bytes32[] promiseIds, address indexed creator);
    
    /// @notice Emitted when Promise.all is resolved
    event AllPromiseResolved(bytes32 indexed allPromiseId, bytes[] results);
    
    /// @notice Emitted when Promise.all is rejected
    event AllPromiseRejected(bytes32 indexed allPromiseId, bytes reason);
    
    /// @notice Create a new pending promise
    /// @return promiseId The unique identifier for this promise
    function create() external returns (bytes32) {
        return _createPromise(msg.sender);
    }
    
    /// @notice Internal helper to create a promise with specified creator
    function _createPromise(address creator) internal returns (bytes32) {
        bytes32 promiseId = keccak256(abi.encode(creator, ++nonce, block.timestamp));
        
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
    function executeCallback(bytes32 promiseId, uint256 callbackIndex) external virtual returns (bytes32 nextPromiseId) {
        return _executeCallbackCore(promiseId, callbackIndex);
    }
    
    /// @notice Internal core callback execution logic - can be reused by child classes
    /// @param promiseId The promise whose callback to execute
    /// @param callbackIndex The index of the callback to execute  
    /// @return nextPromiseId The next promise ID if chaining (bytes32(0) if none)
    function _executeCallbackCore(bytes32 promiseId, uint256 callbackIndex) internal returns (bytes32 nextPromiseId) {
        PromiseState memory promiseState = promises[promiseId];
        require(promiseState.status != PromiseStatus.PENDING, "LocalPromise: promise not yet resolved");
        
        Callback[] storage callbackList = callbacks[promiseId];
        require(callbackIndex < callbackList.length, "LocalPromise: callback index out of bounds");
        
        Callback memory callback = callbackList[callbackIndex];
        bool isError = promiseState.status == PromiseStatus.REJECTED;
        
        if (isError) {
            // Execute error callback if available
            if (callback.errorSelector != bytes4(0)) {
                callback.target.call(abi.encodePacked(callback.errorSelector, promiseState.value));
            }
        } else {
            // Execute success callback and handle chaining
            if (callback.selector != bytes4(0)) {
                (bool success, bytes memory returnData) = _callCallbackWithProperEncoding(
                    callback.target, callback.selector, promiseState.value
                );
                
                if (success && callback.nextPromiseId != bytes32(0)) {
                    // Resolve next promise with callback return value (no recursion)
                    _setPromiseState(callback.nextPromiseId, PromiseStatus.RESOLVED, returnData);
                    nextPromiseId = callback.nextPromiseId;
                } else if (!success) {
                    // Handle callback failure
                    if (callback.errorSelector != bytes4(0)) {
                        callback.target.call(
                            abi.encodePacked(callback.errorSelector, abi.encode("Callback execution failed"))
                        );
                    }
                }
            }
        }
    }
    
    /// @notice Execute all callbacks for a resolved/rejected promise
    /// @param promiseId The promise whose callbacks to execute
    /// @return nextPromiseIds Array of next promise IDs from chaining
    function executeAllCallbacks(bytes32 promiseId) external virtual returns (bytes32[] memory nextPromiseIds) {
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
    
    /// @notice Internal helper to call callbacks with proper encoding
    /// @dev Tries uint256 decoding first, falls back to raw bytes
    function _callCallbackWithProperEncoding(
        address target, 
        bytes4 selector, 
        bytes memory value
    ) internal returns (bool success, bytes memory returnData) {
        // First try decoding as uint256 (most common case)
        if (value.length == 32) {
            try this.decodeAndCall(target, selector, value) returns (bool success1, bytes memory returnData1) {
                return (success1, returnData1);
            } catch {
                // If uint256 decoding fails, try raw bytes
                return target.call(abi.encodeWithSelector(selector, value));
            }
        } else {
            // For non-32-byte values, use raw bytes
            return target.call(abi.encodeWithSelector(selector, value));
        }
    }
    
    /// @notice Helper function to try decoding bytes as uint256 and calling the target
    function decodeAndCall(address target, bytes4 selector, bytes memory value) external returns (bool success, bytes memory returnData) {
        uint256 decodedValue = abi.decode(value, (uint256));
        return target.call(abi.encodeWithSelector(selector, decodedValue));
    }
    
    /// @notice Create a Promise.all that resolves when all provided promises resolve
    /// @param promiseIds Array of promise IDs to wait for
    /// @return allPromiseId The ID of the all-promise
    function all(bytes32[] calldata promiseIds) external returns (bytes32 allPromiseId) {
        require(promiseIds.length > 0, "LocalPromise: empty promise array");
        
        // Create the all-promise
        allPromiseId = _createPromise(msg.sender);
        
        // Initialize all-promise data
        AllPromiseData storage allData = allPromises[allPromiseId];
        allData.promiseIds = promiseIds;
        allData.results = new bytes[](promiseIds.length);
        allData.resolvedCount = 0;
        allData.hasRejected = false;
        allData.creator = msg.sender;
        
        // Verify all promises exist
        for (uint256 i = 0; i < promiseIds.length; i++) {
            require(promises[promiseIds[i]].creator != address(0), "LocalPromise: promise does not exist");
        }
        
        emit AllPromiseCreated(allPromiseId, promiseIds, msg.sender);
    }
    
    /// @notice Check and potentially resolve/reject a Promise.all
    /// @param allPromiseId The all-promise ID to check
    /// @return shouldResolve True if all-promise should resolve
    /// @return shouldReject True if all-promise should reject
    function checkAllPromise(bytes32 allPromiseId) external view returns (bool shouldResolve, bool shouldReject) {
        AllPromiseData storage allData = allPromises[allPromiseId];
        require(allData.creator != address(0), "LocalPromise: all-promise does not exist");
        
        // Check if already resolved/rejected
        PromiseState memory allPromiseState = promises[allPromiseId];
        if (allPromiseState.status != PromiseStatus.PENDING) {
            return (false, false);
        }
        
        // Check if already marked as rejected
        if (allData.hasRejected) {
            return (false, true);
        }
        
        uint256 resolvedCount = 0;
        
        // Check status of all sub-promises
        for (uint256 i = 0; i < allData.promiseIds.length; i++) {
            PromiseState memory promiseState = promises[allData.promiseIds[i]];
            
            if (promiseState.status == PromiseStatus.REJECTED) {
                return (false, true);
            } else if (promiseState.status == PromiseStatus.RESOLVED) {
                resolvedCount++;
            }
        }
        
        // All resolved?
        if (resolvedCount == allData.promiseIds.length) {
            return (true, false);
        }
        
        return (false, false);
    }
    
    /// @notice Execute Promise.all resolution logic
    /// @param allPromiseId The all-promise ID to execute
    /// @return wasExecuted True if the all-promise was resolved/rejected
    function executeAll(bytes32 allPromiseId) external returns (bool wasExecuted) {
        AllPromiseData storage allData = allPromises[allPromiseId];
        require(allData.creator != address(0), "LocalPromise: all-promise does not exist");
        
        // Check if already resolved/rejected
        PromiseState memory allPromiseState = promises[allPromiseId];
        if (allPromiseState.status != PromiseStatus.PENDING) {
            return false;
        }
        
        // If already marked as rejected, reject now
        if (allData.hasRejected) {
            _setPromiseState(allPromiseId, PromiseStatus.REJECTED, allData.rejectionReason);
            emit AllPromiseRejected(allPromiseId, allData.rejectionReason);
            return true;
        }
        
        uint256 resolvedCount = 0;
        
        // Check status and collect results
        for (uint256 i = 0; i < allData.promiseIds.length; i++) {
            PromiseState memory promiseState = promises[allData.promiseIds[i]];
            
            if (promiseState.status == PromiseStatus.REJECTED) {
                // First rejection - mark as rejected
                allData.hasRejected = true;
                allData.rejectionReason = promiseState.value;
                _setPromiseState(allPromiseId, PromiseStatus.REJECTED, promiseState.value);
                emit AllPromiseRejected(allPromiseId, promiseState.value);
                return true;
            } else if (promiseState.status == PromiseStatus.RESOLVED) {
                allData.results[i] = promiseState.value;
                resolvedCount++;
            }
        }
        
        // Update resolved count
        allData.resolvedCount = resolvedCount;
        
        // All resolved?
        if (resolvedCount == allData.promiseIds.length) {
            // Encode results as bytes array
            bytes memory encodedResults = abi.encode(allData.results);
            _setPromiseState(allPromiseId, PromiseStatus.RESOLVED, encodedResults);
            emit AllPromiseResolved(allPromiseId, allData.results);
            return true;
        }
        
        return false;
    }
    
    /// @notice Get Promise.all status and results
    /// @param allPromiseId The all-promise ID to query
    /// @return promiseIds The promise IDs being waited for
    /// @return results Current results (empty for unresolved)
    /// @return resolvedCount Number of resolved promises
    /// @return hasRejected Whether any promise has rejected
    function getAllPromiseData(bytes32 allPromiseId) external view returns (
        bytes32[] memory promiseIds,
        bytes[] memory results,
        uint256 resolvedCount,
        bool hasRejected
    ) {
        AllPromiseData storage allData = allPromises[allPromiseId];
        require(allData.creator != address(0), "LocalPromise: all-promise does not exist");
        
        return (allData.promiseIds, allData.results, allData.resolvedCount, allData.hasRejected);
    }
} 