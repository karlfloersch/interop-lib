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
        return keccak256(abi.encodePacked(
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
        
        for (uint256 i = 0; i < callbackList.length; i++) {
            Callback memory callback = callbackList[i];
            
            if (callback.selector != bytes4(0)) {
                (bool success, bytes memory returnData) = callback.target.call(
                    abi.encodePacked(callback.selector, value)
                );
                
                emit CrossChainCallbackExecuted(remotePromiseId, success, returnData);
                
                if (success && returnData.length > 0) {
                    finalReturnValue = returnData; // Use callback's return value
                } else if (!success) {
                    callbackSucceeded = false;
                    if (callback.errorSelector != bytes4(0)) {
                        callback.target.call(
                            abi.encodeWithSelector(callback.errorSelector, abi.encode("Remote callback failed"))
                        );
                    }
                }
            }
        }
        
        // Handle return forwarding if configured
        CrossChainForwardData storage forwardData = crossChainForwarding[remotePromiseId];
        if (forwardData.isActive) {
            if (callbackSucceeded) {
                // Send successful result back to source chain
                bytes memory resolveMessage = abi.encodeCall(
                    this._resolveChainedPromise,
                    (forwardData.remotePromiseId, finalReturnValue)
                );
                messenger.sendMessage(forwardData.destinationChain, address(this), resolveMessage);
            } else {
                // Send error back to source chain
                bytes memory rejectMessage = abi.encodeCall(
                    this._rejectChainedPromise,
                    (forwardData.remotePromiseId, abi.encode("Remote callback failed"))
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
        // First execute the regular callback using LocalPromise logic
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
        
        // Check if this promise has cross-chain forwarding
        CrossChainForwardData storage forwardData = crossChainForwarding[promiseId];
        if (forwardData.isActive && promiseState.status == PromiseStatus.RESOLVED) {
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
    
    /// @notice Override executeAllCallbacks to handle cross-chain forwarding
    function executeAllCallbacks(bytes32 promiseId) external override returns (bytes32[] memory nextPromiseIds) {
        // Execute all regular callbacks using LocalPromise logic
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
        
        // Handle cross-chain forwarding even if there are no regular callbacks
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
} 