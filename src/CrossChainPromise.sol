// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {LocalPromise} from "./LocalPromise.sol";
import {PromiseAwareMessenger} from "./PromiseAwareMessenger.sol";

/// @notice Cross-chain promise library extending LocalPromise with remote execution
/// @dev Enables promise chaining across different chains using PromiseAwareMessenger
contract CrossChainPromise is LocalPromise {
    PromiseAwareMessenger public immutable messenger;
    uint256 private crossChainNonce;
    
    /// @notice Track cross-chain promise metadata
    mapping(bytes32 => CrossChainPromiseData) public crossChainPromises;
    
    /// @notice Track cross-chain forwarding for promises
    mapping(bytes32 => CrossChainForwardData) public crossChainForwarding;
    
    // Mapping to track nested promise to remote promise relationships for forwarding
    mapping(bytes32 => bytes32) public nestedToRemotePromise;
    // Track which nested promise is currently being processed
    bytes32 private currentNestedPromise;
    
    struct CrossChainPromiseData {
        uint256 sourceChain;
        bytes32 sourcePromiseId;
        address returnTarget;     // Where to send results back
        bytes4 returnSelector;    // Function to call with results
        bool isRemoteOrigin;      // True if this promise was created by remote chain
    }
    
    struct CrossChainForwardData {
        uint256 destinationChain;
        bytes32 remotePromiseId;
        bytes32 chainedPromiseId;
        bool isActive;
    }
    
    /// @notice Structure for remote promise state query results
    struct RemotePromiseState {
        bytes32 promiseId;      // The remote promise ID
        PromiseStatus status;   // Status of the remote promise
        bytes value;           // Value/reason from the remote promise
        address creator;       // Creator of the remote promise
        bool exists;          // Whether the promise exists (creator != address(0))
    }
    
    /// @notice Event emitted when a cross-chain promise is created
    event CrossChainPromiseCreated(
        bytes32 indexed promiseId,
        uint256 indexed sourceChain,
        uint256 indexed destinationChain,
        address target,
        bytes4 selector
    );
    
    /// @notice Event emitted when a cross-chain callback is executed
    event CrossChainCallbackExecuted(
        bytes32 indexed promiseId,
        bool success,
        bytes returnData
    );
    
    /// @notice Event emitted when a cross-chain promise state query is sent
    event CrossChainQuerySent(bytes32 indexed queryPromiseId, uint256 remoteChain, bytes32 remotePromiseId);
    
    /// @notice Event emitted when a cross-chain promise state query response is sent
    event CrossChainQueryResponse(bytes32 indexed queriedPromiseId, uint256 responseChain, bytes32 responsePromiseId);
    
    /// @notice Event emitted when a cross-chain promise state query is resolved
    event CrossChainQueryResolved(bytes32 indexed queryPromiseId, bytes32 remotePromiseId, PromiseStatus remoteStatus);
    
    modifier onlyPromiseLibrary() {
        require(msg.sender == address(messenger), "CrossChainPromise: not from messenger");
        
        // Try to get the cross-domain message sender - this will revert if not in cross-domain context
        try messenger.xDomainMessageSender() returns (address xDomainSender) {
            // If we get here, we're in a cross-domain call with a valid sender
            require(xDomainSender != address(0), "CrossChainPromise: invalid cross-domain sender");
        } catch {
            // If xDomainMessageSender() reverts, we're not in a cross-domain context
            revert("CrossChainPromise: not from cross-chain call");
        }
        _;
    }
    
    constructor(address _messenger) {
        messenger = PromiseAwareMessenger(_messenger);
    }
    
    /// @notice Test function to verify cross-chain calls work (no auth required)
    bool public testCallReceived = false;
    function testCrossChainCall() external {
        testCallReceived = true;
    }
    
    /// @notice Register a callback to be executed when promise resolves (cross-chain version)
    /// @param promiseId The promise to listen to
    /// @param destinationChain The chain where callback should execute (0 = local)
    /// @param selector The function selector to call on success
    /// @param errorSelector The function selector to call on error (optional)
    /// @return nextPromiseId New promise ID for chaining
    function then(
        bytes32 promiseId, 
        uint256 destinationChain,
        bytes4 selector, 
        bytes4 errorSelector
    ) external returns (bytes32 nextPromiseId) {
        require(promises[promiseId].creator != address(0), "CrossChainPromise: promise does not exist");
        
        if (destinationChain == 0 || destinationChain == block.chainid) {
            // Local execution - delegate to parent
            return then(promiseId, selector, errorSelector);
        }
        
        // Cross-chain execution
        return _setupCrossChainThen(promiseId, destinationChain, selector, errorSelector);
    }
    
    /// @notice Register a callback to be executed when promise resolves (local or cross-chain)
    /// @param promiseId The promise to listen to  
    /// @param destinationChain The chain where callback should execute (0 = local)
    /// @param selector The function selector to call on success
    /// @return nextPromiseId New promise ID for chaining
    function then(bytes32 promiseId, uint256 destinationChain, bytes4 selector) external returns (bytes32) {
        require(promises[promiseId].creator != address(0), "CrossChainPromise: promise does not exist");
        
        if (destinationChain == 0 || destinationChain == block.chainid) {
            // Local execution - delegate to parent
            return then(promiseId, selector, bytes4(0));
        }
        
        // Cross-chain execution
        return _setupCrossChainThen(promiseId, destinationChain, selector, bytes4(0));
    }
    
    /// @notice Internal function to setup cross-chain promise chaining
    function _setupCrossChainThen(
        bytes32 localPromiseId,
        uint256 destinationChain,
        bytes4 selector,
        bytes4 errorSelector
    ) internal returns (bytes32 remotePromiseId) {
        // 1. Calculate predictable remote promise ID
        remotePromiseId = _calculateRemotePromiseId(
            block.chainid,
            ++crossChainNonce,
            destinationChain,
            msg.sender,
            selector
        );
        
        // 2. Create LOCAL REPRESENTATION of the remote promise (this is the key insight!)
        // This allows immediate chaining without waiting for cross-chain messages
        promises[remotePromiseId] = PromiseState({
            status: PromiseStatus.PENDING,
            value: "",
            creator: msg.sender
        });
        
        // 3. Track metadata for the local representation
        crossChainPromises[remotePromiseId] = CrossChainPromiseData({
            sourceChain: block.chainid,
            sourcePromiseId: localPromiseId,
            returnTarget: address(0),
            returnSelector: bytes4(0),
            isRemoteOrigin: false  // This is a local representation
        });
        
        // 4. Register cross-chain forwarding from local promise to remote execution
        crossChainForwarding[localPromiseId] = CrossChainForwardData({
            destinationChain: destinationChain,
            remotePromiseId: remotePromiseId,  // The actual remote promise (same ID)
            chainedPromiseId: remotePromiseId, // The local representation (same ID)
            isActive: true
        });
        
        // 5. Send cross-chain message to setup actual remote promise with same ID
        bytes memory setupMessage = abi.encodeCall(
            this.setupRemotePromise,
            (
                remotePromiseId,  // Same ID on both chains!
                msg.sender,       // This should be the test contract address
                selector,
                errorSelector,
                block.chainid,
                remotePromiseId   // Return updates to the local representation
            )
        );
        
        messenger.sendMessage(destinationChain, address(this), setupMessage);
        
        emit CrossChainPromiseCreated(
            remotePromiseId,
            block.chainid,
            destinationChain,
            msg.sender,
            selector
        );
        
        // Return the local representation ID - users can chain on this immediately!
        return remotePromiseId;
    }
    
    /// @notice Calculate predictable remote promise ID
    function _calculateRemotePromiseId(
        uint256 sourceChain,
        uint256 sourceNonce,
        uint256 destinationChain,
        address target,
        bytes4 selector
    ) internal view returns (bytes32) {
        return keccak256(abi.encode(
            sourceChain,
            sourceNonce,
            destinationChain,
            target,
            selector,
            block.timestamp
        ));
    }
    
    /// @notice Setup a remote promise (called via cross-chain message)
    function setupRemotePromise(
        bytes32 remotePromiseId,
        address target,
        bytes4 selector,
        bytes4 errorSelector,
        uint256 returnChain,
        bytes32 returnPromiseId
    ) external onlyPromiseLibrary {
        // Create the remote promise with predictable ID
        promises[remotePromiseId] = PromiseState({
            status: PromiseStatus.PENDING,
            value: "",
            creator: address(this) // Promise library creates it
        });
        
        // Track cross-chain metadata
        crossChainPromises[remotePromiseId] = CrossChainPromiseData({
            sourceChain: messenger.crossDomainMessageSource(),
            sourcePromiseId: bytes32(0), // Not needed for remote promises
            returnTarget: address(0),    // Not used
            returnSelector: bytes4(0),   // Not used
            isRemoteOrigin: true
        });
        
        // Register the user's callback
        callbacks[remotePromiseId].push(Callback({
            target: target,
            selector: selector,
            errorSelector: errorSelector,
            nextPromiseId: bytes32(0) // Remote promises don't chain locally
        }));
        
        // Set up return forwarding for this remote promise
        crossChainForwarding[remotePromiseId] = CrossChainForwardData({
            destinationChain: returnChain,
            remotePromiseId: returnPromiseId, // This is the promise to resolve on return chain
            chainedPromiseId: bytes32(0),     // Not used for return forwarding
            isActive: true
        });
    }
    
    /// @notice Execute remote callback and resolve promise (called via cross-chain message)
    function executeRemoteCallback(
        bytes32 remotePromiseId,
        bytes memory value
    ) external onlyPromiseLibrary {
        // Resolve the remote promise first
        _setPromiseState(remotePromiseId, PromiseStatus.RESOLVED, value);
        
        // Execute the user callback and capture return value
        Callback[] storage callbackList = callbacks[remotePromiseId];
        bytes memory finalReturnValue = value; // Default to input value
        bool callbackSucceeded = true;
        bytes32 nestedPromiseId = bytes32(0); // Track if callback returned nested promise
        
        for (uint256 i = 0; i < callbackList.length; i++) {
            Callback memory callback = callbackList[i];
            
            if (callback.selector != bytes4(0)) {
                // Use the same unified encoding approach as LocalPromise
                (bool success, bytes memory returnData) = _callCallbackWithProperEncoding(
                    callback.target, callback.selector, value
                );
                
                emit CrossChainCallbackExecuted(remotePromiseId, success, returnData);
                
                if (success && returnData.length > 0) {
                    // Try to decode as explicit nested promise format: (bytes32 promiseId, bytes memory result)
                    (bytes32 explicitPromiseId, bytes memory explicitResult) = _tryDecodeAsExplicitReturn(returnData);
                    
                    if (explicitPromiseId != bytes32(0)) {
                        // EXPLICIT NESTED PROMISE: Callback wants us to wait for this promise
                        if (_isValidPendingPromise(explicitPromiseId)) {
                            nestedPromiseId = explicitPromiseId;
                            // We'll wait for this promise to resolve before forwarding result
                        } else {
                            // Invalid promise ID - use error message as result
                            finalReturnValue = abi.encode("Invalid nested promise ID");
                            callbackSucceeded = false;
                        }
                    } else if (explicitResult.length > 0) {
                        // EXPLICIT RESULT: Use the provided result value
                        finalReturnValue = explicitResult;
                    } else {
                        // LEGACY: Use raw return data
                        finalReturnValue = returnData;
                    }
                } else if (!success) {
                    callbackSucceeded = false;
                    if (callback.errorSelector != bytes4(0)) {
                        callback.target.call(
                            abi.encodePacked(callback.errorSelector, abi.encode("Remote callback failed"))
                        );
                    }
                }
            }
        }
        
        // If callback returned a nested promise, wait for it to resolve
        if (nestedPromiseId != bytes32(0)) {
            // Track the relationship between nested and remote promise
            nestedToRemotePromise[nestedPromiseId] = remotePromiseId;
            currentNestedPromise = nestedPromiseId;
            
            // Setup nested promise chain: when nested resolves, forward result
            callbacks[nestedPromiseId].push(Callback({
                target: address(this),
                selector: this._forwardNestedResult.selector,
                errorSelector: this._forwardNestedError.selector,
                nextPromiseId: remotePromiseId // Store the remote promise ID for forwarding lookup
            }));
            
            emit NestedPromiseDetected(remotePromiseId, nestedPromiseId);
            
            // Don't forward result yet - wait for nested promise
            return;
        }
        
        // No nested promise - forward result immediately
        _forwardCrossChainResult(remotePromiseId, finalReturnValue, callbackSucceeded);
    }
    
    /// @notice Forward nested promise result (called when nested promise resolves)
    function _forwardNestedResult(bytes memory nestedValue) external returns (bytes memory) {
        require(msg.sender == address(this), "CrossChainPromise: only self can call");
        
        // Find the active nested-to-remote mapping
        bytes32 originalRemotePromiseId = bytes32(0);
        bytes32 nestedPromiseId = bytes32(0);
        
        if (currentNestedPromise != bytes32(0)) {
            nestedPromiseId = currentNestedPromise;
            originalRemotePromiseId = nestedToRemotePromise[currentNestedPromise];
        }
        
        // If we found a valid mapping, forward the result
        if (originalRemotePromiseId != bytes32(0)) {
            // Clean up the mappings
            delete nestedToRemotePromise[nestedPromiseId];
            currentNestedPromise = bytes32(0);
            
            // Forward the nested result back to the source chain
            _forwardCrossChainResult(originalRemotePromiseId, nestedValue, true);
        }
        
        return nestedValue;
    }
    
    /// @notice Forward nested promise error (called when nested promise rejects)  
    function _forwardNestedError(bytes memory nestedError) external {
        require(msg.sender == address(this), "CrossChainPromise: only self can call");
        
        // Use similar logic to find the active mapping
        bytes32 originalRemotePromiseId = bytes32(0);
        
        if (currentNestedPromise != bytes32(0) && nestedToRemotePromise[currentNestedPromise] != bytes32(0)) {
            originalRemotePromiseId = nestedToRemotePromise[currentNestedPromise];
            delete nestedToRemotePromise[currentNestedPromise];
            currentNestedPromise = bytes32(0);
        }
        
        if (originalRemotePromiseId != bytes32(0)) {
            // Forward the error back to the source chain
            _forwardCrossChainResult(originalRemotePromiseId, nestedError, false);
        }
    }
    
    /// @notice Forward results for all active cross-chain forwarding
    function _forwardAllActiveResults(bytes memory resultValue, bool success) internal {
        // This is a temporary solution - iterate through all forwarding data
        // In a production system, we'd want a more efficient mapping
        // For now, we'll rely on the fact that there's typically only one active forwarding per test
        
        // Since we can't efficiently iterate mappings, we'll use a different approach
        // The real fix would be to store the remotePromiseId explicitly
        
        // For debugging, let's just log that we got here
        emit CrossChainCallbackExecuted(bytes32(0), success, resultValue);
    }
    
    /// @notice Internal helper to forward cross-chain results
    function _forwardCrossChainResult(bytes32 remotePromiseId, bytes memory resultValue, bool success) internal {
        // Handle return forwarding if configured
        CrossChainForwardData storage forwardData = crossChainForwarding[remotePromiseId];
        if (forwardData.isActive) {
            if (success) {
                // Send successful result back to source chain
                bytes memory resolveMessage = abi.encodeCall(
                    this._resolveChainedPromise,
                    (forwardData.remotePromiseId, resultValue)
                );
                messenger.sendMessage(forwardData.destinationChain, address(this), resolveMessage);
            } else {
                // Send error back to source chain
                bytes memory rejectMessage = abi.encodeCall(
                    this._rejectChainedPromise,
                    (forwardData.remotePromiseId, resultValue)
                );
                messenger.sendMessage(forwardData.destinationChain, address(this), rejectMessage);
            }
            
            forwardData.isActive = false;
        }
    }
    
    /// @notice Sync local proxy with remote result (called via cross-chain message)
    function _resolveChainedPromise(bytes32 proxyPromiseId, bytes memory resultData) external onlyPromiseLibrary {
        // Update the local proxy with the result from remote chain
        _setPromiseState(proxyPromiseId, PromiseStatus.RESOLVED, resultData);
    }
    
    /// @notice Sync local proxy with remote error (called via cross-chain message)
    function _rejectChainedPromise(bytes32 proxyPromiseId, bytes memory errorData) external onlyPromiseLibrary {
        // Update the local proxy with the error from remote chain
        _setPromiseState(proxyPromiseId, PromiseStatus.REJECTED, errorData);
    }
    
    /// @notice Override executeCallback to handle cross-chain forwarding
    function executeCallback(bytes32 promiseId, uint256 callbackIndex) external override returns (bytes32 nextPromiseId) {
        // REUSE parent core logic - maximum code reuse!
        nextPromiseId = _executeCallbackCore(promiseId, callbackIndex);
        
        // ONLY add our cross-chain specific logic
        _handleCrossChainForwarding(promiseId);
    }
    
    /// @notice Override executeAllCallbacks to handle cross-chain forwarding
    function executeAllCallbacks(bytes32 promiseId) external override returns (bytes32[] memory nextPromiseIds) {
        // REUSE parent implementation logic
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
        
        // ONLY add our cross-chain specific logic
        _handleCrossChainForwarding(promiseId);
    }
    
    /// @notice Internal helper to handle cross-chain forwarding after callbacks execute
    /// @param promiseId The promise that was executed
    function _handleCrossChainForwarding(bytes32 promiseId) internal {
        CrossChainForwardData storage forwardData = crossChainForwarding[promiseId];
        if (forwardData.isActive) {
            PromiseState memory promiseState = promises[promiseId];
            if (promiseState.status == PromiseStatus.RESOLVED) {
                // Send the value to the remote chain
                bytes memory executeMessage = abi.encodeCall(
                    this.executeRemoteCallback,
                    (forwardData.remotePromiseId, promiseState.value)
                );
                
                messenger.sendMessage(forwardData.destinationChain, address(this), executeMessage);
                
                // Mark forwarding as completed
                forwardData.isActive = false;
            }
        }
    }
    
    /// @notice Query the state of a promise on a remote chain
    /// @param remoteChain The chain ID where the promise exists
    /// @param promiseId The promise ID to query
    /// @return queryPromiseId Promise ID that will resolve with the remote promise state
    function queryRemotePromiseState(uint256 remoteChain, bytes32 promiseId) 
        external returns (bytes32 queryPromiseId) {
        
        // Create a local promise for the query result
        queryPromiseId = _createPromise(msg.sender);
        
        // Send query message to remote chain
        bytes memory queryMessage = abi.encodeCall(
            this.getPromiseState, 
            (promiseId, block.chainid, queryPromiseId)
        );
        
        messenger.sendMessage(remoteChain, address(this), queryMessage);
        
        emit CrossChainQuerySent(queryPromiseId, remoteChain, promiseId);
    }
    
    /// @notice Get the state of a local promise (called from remote chain)
    /// @param promiseId The promise ID to query
    /// @param responseChain The chain to send the response to
    /// @param responsePromiseId The promise ID on the response chain to resolve
    function getPromiseState(bytes32 promiseId, uint256 responseChain, bytes32 responsePromiseId) 
        external onlyPromiseLibrary {
        
        PromiseState memory promiseState = promises[promiseId];
        
        // Encode the complete promise state
        bytes memory stateData = abi.encode(
            promiseState.status,
            promiseState.value,
            promiseState.creator
        );
        
        // Send response back to the requesting chain
        bytes memory responseMessage = abi.encodeCall(
            this.handleRemotePromiseStateResponse,
            (responsePromiseId, promiseId, stateData)
        );
        
        messenger.sendMessage(responseChain, address(this), responseMessage);
        
        emit CrossChainQueryResponse(promiseId, responseChain, responsePromiseId);
    }
    
    /// @notice Handle the response from a remote promise state query
    /// @param queryPromiseId The local query promise to resolve
    /// @param remotePromiseId The remote promise that was queried
    /// @param stateData The encoded state data from the remote promise
    function handleRemotePromiseStateResponse(
        bytes32 queryPromiseId, 
        bytes32 remotePromiseId, 
        bytes memory stateData
    ) external onlyPromiseLibrary {
        
        // Decode the remote promise state
        (PromiseStatus remoteStatus, bytes memory remoteValue, address remoteCreator) = 
            abi.decode(stateData, (PromiseStatus, bytes, address));
        
        // Create response data structure
        RemotePromiseState memory remoteState = RemotePromiseState({
            promiseId: remotePromiseId,
            status: remoteStatus,
            value: remoteValue,
            creator: remoteCreator,
            exists: remoteCreator != address(0)
        });
        
        // Resolve the query promise with the remote state
        _setPromiseState(queryPromiseId, PromiseStatus.RESOLVED, abi.encode(remoteState));
        
        emit CrossChainQueryResolved(queryPromiseId, remotePromiseId, remoteStatus);
    }
} 