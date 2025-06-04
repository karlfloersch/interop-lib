// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IL2ToL2CrossDomainMessenger} from "./interfaces/IL2ToL2CrossDomainMessenger.sol";
import {ICrossL2Inbox, Identifier} from "./interfaces/ICrossL2Inbox.sol";
import {Handle} from "./interfaces/IPromise.sol";
import {Hashing} from "./libraries/Hashing.sol";
import {PredeployAddresses} from "./libraries/PredeployAddresses.sol";
import {TransientReentrancyAware} from "./libraries/TransientContext.sol";
import {console} from "forge-std/console.sol";

contract Promise is TransientReentrancyAware {
    /// @notice a struct to represent a callback to be executed when the return value of
    ///         a sent message is captured.
    struct Callback {
        address target;
        bytes4 selector;
        bytes context;
    }

    /// @dev The L2 to L2 cross domain messenger predeploy to handle message passing
    IL2ToL2CrossDomainMessenger internal messenger =
        IL2ToL2CrossDomainMessenger(PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER);

    /// @notice a mapping of message hashes to their registered callbacks
    mapping(bytes32 => Callback[]) public callbacks;

    /// @notice a mapping to track destination-side promise handles
    mapping(bytes32 => Handle) public handles;

    /// @notice a mapping from message hash to handle hashes for handle execution
    mapping(bytes32 => bytes32[]) public messageToHandles;

    /// @notice a mapping to store handle registration intents for cross-chain execution
    mapping(bytes32 => Handle[]) public pendingHandles;

    /// @notice a mapping to track nested promise relationships
    mapping(bytes32 => bytes32) public nestedPromises;

    /// @notice a mapping to track promise chains (parent -> child relationships)
    mapping(bytes32 => bytes32[]) public promiseChains;

    /// @notice the relay identifier that is satisfying the promise
    Identifier internal currentRelayIdentifier;

    /// @notice the context that is being propagated with the promise
    bytes internal currentContext;

    /// @notice the currently executing promise context for tracking child promises
    bytes32 internal currentPromiseContext;

    /// @notice whether we're currently executing within a promise context
    bool internal inPromiseExecution;

    /// @notice a mapping of message sent by this library. To prevent callbacks being registered to messages
    ///         sent directly to the L2ToL2CrossDomainMessenger which does not emit the return value (yet)
    mapping(bytes32 => bool) private sentMessages;

    /// @notice a mapping to track destination chains for sent messages
    mapping(bytes32 => uint256) private messageDestinations;

    /// @notice a mapping to store original message parameters for hash reconstruction
    mapping(bytes32 => MessageParams) private messageParams;

    /// @notice struct to store message parameters for hash reconstruction
    struct MessageParams {
        uint256 nonce;
        address target;
        bytes message;
        uint256 sourceChain;
    }

    /// @notice struct to track promise resolution state
    struct PromiseState {
        bool isResolved;        // Whether this promise is fully resolved (no more nesting)
        bytes finalReturnData; // The final resolved data (only set when isResolved = true)
        bytes32 nestedPromise; // If not resolved, points to the nested promise
        bool hasCallbacks;     // Whether this promise has pending callbacks
        bool isCompleted;      // Whether the immediate call completed (vs fully resolved)
        bytes32[] childPromises; // All direct child promises created by this promise
        bytes32 parentPromise;   // The parent promise that created this one
        uint256 unresolvedChildCount; // Number of children that haven't resolved yet
        bool resolutionBlocked;  // Whether this promise is waiting for children to resolve
    }

    /// @notice a mapping to track promise resolution states for automatic flattening
    mapping(bytes32 => PromiseState) public promiseStates;

    /// @notice mapping to track which chain each promise lives on (renamed to avoid conflict)
    mapping(bytes32 => uint256) public promiseOriginChains;

    /// @notice mapping to track promise resolution dependencies
    mapping(bytes32 => bytes32[]) public promiseDependencies;

    /// @notice mapping to track promises waiting for resolution notifications
    mapping(bytes32 => bytes32[]) public resolutionWaiters;

    /// @notice an event emitted when a callback is registered
    event CallbackRegistered(bytes32 messageHash);

    /// @notice an event emitted when all callbacks for a message are dispatched
    event CallbacksCompleted(bytes32 messageHash);

    /// @notice an event emitted when a message is relayed
    event RelayedMessage(bytes32 messageHash, bytes returnData);

    /// @notice an event emitted when a handle is created for destination-side execution
    event HandleCreated(bytes32 messageHash, uint256 destinationChain);

    /// @notice an event emitted when a handle is completed with return data
    event HandleCompleted(bytes32 handleHash, bytes returnData);

    /// @notice an event emitted when a nested promise is created
    event NestedPromiseCreated(bytes32 parentPromiseHash, bytes32 nestedPromiseHash);

    /// @notice an event emitted when a nested promise chain is resolved
    event NestedPromiseResolved(bytes32 rootPromiseHash, bytes32 finalValue);

    /// @dev Modifier to restrict a function to only be a cross domain callback into this contract
    modifier onlyCrossDomainCallback() {
        require(msg.sender == address(messenger), "Promise: caller not L2ToL2CrossDomainMessenger");
        require(messenger.crossDomainMessageSender() == address(this), "Promise: invalid cross-domain sender");
        _;
    }

    /// @notice send a message to the destination contract capturing the return value. this cannot call
    ///         contracts that rely on the L2ToL2CrossDomainMessenger, such as the SuperchainTokenBridge.
    function sendMessage(uint256 _destination, address _target, bytes calldata _message) external returns (bytes32) {
        uint256 nonce = messenger.messageNonce();
        bytes32 msgHash = messenger.sendMessage(
            _destination, address(this), abi.encodeCall(this.handleMessage, (nonce, _target, _message))
        );
        sentMessages[msgHash] = true;
        messageDestinations[msgHash] = _destination;
        
        // Store message parameters for hash reconstruction
        messageParams[msgHash] = MessageParams({
            nonce: nonce,
            target: _target,
            message: _message,
            sourceChain: block.chainid
        });
        
        // 🆕 AUTOMATIC CHILD TRACKING: If we're currently executing within a promise context, 
        // automatically track this as a child promise
        if (inPromiseExecution && currentPromiseContext != bytes32(0)) {
            _addChildPromise(currentPromiseContext, msgHash);
        }
        
        return msgHash;
    }

    /// @notice Promise-aware sendMessage that tracks parent-child relationships for atomic resolution
    /// @dev This function should be used by contracts that want their sendMessage calls to be tracked as child promises
    /// @param _destination The destination chain ID
    /// @param _target The target contract address
    /// @param _message The message to send
    /// @return msgHash The hash of the sent message
    function sendChildMessage(uint256 _destination, address _target, bytes calldata _message) external returns (bytes32) {
        bytes32 msgHash = this.sendMessage(_destination, _target, _message);
        
        // If we're currently executing within a promise context, track this as a child promise
        if (inPromiseExecution && currentPromiseContext != bytes32(0)) {
            _addChildPromise(currentPromiseContext, msgHash);
        }
        
        return msgHash;
    }

    /// @dev handler to dispatch and emit the return value of a message
    function handleMessage(uint256 _nonce, address _target, bytes calldata _message) external onlyCrossDomainCallback {
        // Set promise execution context
        bytes32 messageHash = Hashing.hashL2toL2CrossDomainMessage({
            _destination: block.chainid,
            _source: messenger.crossDomainMessageSource(),
            _nonce: _nonce,
            _sender: address(this),
            _target: address(this),
            _message: abi.encodeCall(this.handleMessage, (_nonce, _target, _message))
        });
        
        // Set the execution context for tracking child promises
        currentPromiseContext = messageHash;
        inPromiseExecution = true;
        
        (bool success, bytes memory returnData_) = _target.call(_message);
        require(success, "Promise: target call failed");

        // Check current child count BEFORE clearing context
        PromiseState storage tempState = promiseStates[messageHash];

        // Clear execution context
        inPromiseExecution = false;
        currentPromiseContext = bytes32(0);

        // 🆕 Enhanced: Check if return data represents a nested promise
        bool isNestedPromise = false;
        bytes32 nestedPromiseHash = bytes32(0);
        
        if (returnData_.length == 32) {
            bytes32 potentialPromiseHash = abi.decode(returnData_, (bytes32));
            if (sentMessages[potentialPromiseHash]) {
                isNestedPromise = true;
                nestedPromiseHash = potentialPromiseHash;
            }
        }

        if (isNestedPromise) {
            // 🆕 Deferred resolution: Don't emit RelayedMessage yet
            // Store the promise state as unresolved with nested promise
            promiseStates[messageHash] = PromiseState({
                isResolved: false,
                finalReturnData: "",
                nestedPromise: nestedPromiseHash,
                hasCallbacks: callbacks[messageHash].length > 0,
                isCompleted: true, // The immediate call completed, but waiting for children
                childPromises: new bytes32[](0),
                parentPromise: bytes32(0),
                unresolvedChildCount: 0,
                resolutionBlocked: true // Blocked until nested promise resolves
            });
            
            // Track the nested promise as a child
            _addChildPromise(messageHash, nestedPromiseHash);
        } else {
            // Check if this promise has any children that were created during execution
            PromiseState storage state = promiseStates[messageHash];
            
            // Initialize state if it doesn't exist, BUT preserve child tracking
            if (!state.isCompleted) {
                // Don't overwrite existing child tracking!
                uint256 currentChildCount = state.unresolvedChildCount;
                
                state.isResolved = false;
                state.finalReturnData = returnData_;
                state.nestedPromise = bytes32(0);
                state.hasCallbacks = callbacks[messageHash].length > 0;
                state.isCompleted = true;
                // Keep existing child tracking
                state.unresolvedChildCount = currentChildCount;
                // childPromises array is already set
                state.resolutionBlocked = (currentChildCount > 0);
            } else {
                // Mark as completed and store return data
                state.isCompleted = true;
                state.finalReturnData = returnData_;
            }
            
            // If no unresolved children, resolve atomically
            if (state.unresolvedChildCount == 0) {
                _resolvePromiseAtomically(messageHash);
            }
            // Otherwise, wait for children to resolve
        }

        // Execute any pending handles on the destination chain
        Handle[] storage pendingHandleList = pendingHandles[messageHash];
        
        for (uint256 i = 0; i < pendingHandleList.length; i++) {
            Handle storage pendingHandle = pendingHandleList[i];
            
            // Update destination chain to current chain
            pendingHandle.destinationChain = block.chainid;
            
            // Execute the destination-side continuation
            (bool handleSuccess, bytes memory handleReturnData) = pendingHandle.target.call(pendingHandle.message);
            
            if (handleSuccess) {
                pendingHandle.completed = true;
                pendingHandle.returnData = handleReturnData;
                
                // Check if the return data represents a nested promise (32 bytes that could be a message hash)
                if (handleReturnData.length == 32) {
                    bytes32 potentialPromiseHash = abi.decode(handleReturnData, (bytes32));
                    
                    // If this looks like a valid promise hash and we sent it, treat it as nested
                    if (sentMessages[potentialPromiseHash]) {
                        pendingHandle.nestedPromiseHash = potentialPromiseHash;
                        nestedPromises[pendingHandle.messageHash] = potentialPromiseHash;
                        promiseChains[pendingHandle.messageHash].push(potentialPromiseHash);
                        
                        emit NestedPromiseCreated(pendingHandle.messageHash, potentialPromiseHash);
                    }
                }
                
                // Store the completed handle
                handles[pendingHandle.messageHash] = pendingHandle;
                emit HandleCompleted(pendingHandle.messageHash, handleReturnData);
            }
            // Note: we don't revert on handle failure to avoid breaking the main message flow
        }
    }

    /// @notice attach a continuation dependent only on the return value of the remote message
    function then(bytes32 _msgHash, bytes4 _selector) external {
        require(sentMessages[_msgHash], "Promise: message not sent");
        callbacks[_msgHash].push(Callback({target: msg.sender, selector: _selector, context: ""}));
        emit CallbackRegistered(_msgHash);
    }

    /// @notice attach a continuation dependent on the return value and some additional saved context
    function then(bytes32 _msgHash, bytes4 _selector, bytes calldata _context) external {
        require(sentMessages[_msgHash], "Promise: message not sent");
        callbacks[_msgHash].push(Callback({target: msg.sender, selector: _selector, context: _context}));
        emit CallbackRegistered(_msgHash);
    }

    /// @notice Enhanced callback dispatch that supports automatic promise resolution
    /// @dev This function now checks if promises are fully resolved before executing callbacks
    function dispatchCallbacks(Identifier calldata _id, bytes calldata _payload) external payable nonReentrant {
        require(_id.origin == address(this), "Promise: invalid origin");
        ICrossL2Inbox(PredeployAddresses.CROSS_L2_INBOX).validateMessage(_id, keccak256(_payload));

        bytes32 eventSel = abi.decode(_payload[:32], (bytes32));
        require(eventSel == RelayedMessage.selector, "Promise: invalid event");

        currentRelayIdentifier = _id;

        (bytes32 msgHash, bytes memory returnData) = abi.decode(_payload[32:], (bytes32, bytes));
        
        // 🆕 Enhanced: Check if this resolves a parent promise that was waiting for nested resolution
        _resolveParentPromises(msgHash, returnData);
        
        // 🆕 Enhanced: Check promise resolution state
        PromiseState storage state = promiseStates[msgHash];
        
        // 🔧 BACKWARD COMPATIBILITY: If no state exists, treat as resolved (old behavior)
        bool isResolved = state.nestedPromise == bytes32(0) || state.isResolved;
        bytes memory finalData = state.isResolved ? state.finalReturnData : returnData;
        
        if (isResolved && callbacks[msgHash].length > 0) {
            // Execute callbacks with the final resolved data
            for (uint256 i = 0; i < callbacks[msgHash].length; i++) {
                Callback memory callback = callbacks[msgHash][i];
                if (callback.context.length > 0) {
                    currentContext = callback.context;
                }

                (bool completed,) = callback.target.call(abi.encodePacked(callback.selector, finalData));
                require(completed, "Promise: callback call failed");

                if (callback.context.length > 0) {
                    delete currentContext;
                }
            }

            emit CallbacksCompleted(msgHash);

            // storage cleanup
            delete callbacks[msgHash];
            if (state.nestedPromise != bytes32(0)) {
                delete promiseStates[msgHash];
            }
        } else if (!isResolved) {
            // Promise is still waiting for nested resolution - callbacks will execute later
            // Update the return data for when it does resolve
            _updateNestedPromiseResolution(msgHash, returnData);
        } else {
            // Promise is resolved but has no callbacks - just emit completion
            emit CallbacksCompleted(msgHash);
        }

        // 🆕 ATOMIC RESOLUTION: Notify parent if this promise has one
        // This is crucial for atomic promise resolution
        _notifyParentOfResolution(msgHash);

        delete sentMessages[msgHash];
        delete currentRelayIdentifier;
    }

    /// @notice get the context that is being propagated with the promise
    function promiseContext() public view returns (bytes memory) {
        return currentContext;
    }

    /// @notice get the relay identifier that is satisfying the promise
    function promiseRelayIdentifier() public view returns (Identifier memory) {
        return currentRelayIdentifier;
    }

    /// @notice attach a destination-side continuation that executes on the destination chain
    /// @param _msgHash The message hash to attach the destination callback to
    /// @param _target The contract to call on the destination chain
    /// @param _message The message to send to the destination contract
    /// @return handle A handle representing the destination-side promise
    function andThen(bytes32 _msgHash, address _target, bytes calldata _message) external returns (Handle memory) {
        require(sentMessages[_msgHash], "Promise: message not sent");
        
        // Generate a unique handle hash for this destination callback
        bytes32 handleHash = keccak256(abi.encodePacked(_msgHash, _target, _message, block.timestamp));
        
        // Create handle intent
        Handle memory handle = Handle({
            messageHash: handleHash,
            destinationChain: block.chainid,
            target: _target,
            message: _message,
            completed: false,
            returnData: "",
            nestedPromiseHash: bytes32(0) // Initially no nested promise
        });
        
        // Calculate the reconstructed message hash that handleMessage will use
        MessageParams memory params = messageParams[_msgHash];
        bytes32 reconstructedHash = Hashing.hashL2toL2CrossDomainMessage({
            _destination: messageDestinations[_msgHash],
            _source: params.sourceChain,
            _nonce: params.nonce,
            _sender: address(this),
            _target: address(this),
            _message: abi.encodeCall(this.handleMessage, (params.nonce, params.target, params.message))
        });
        
        // Send cross-chain message to register handle on destination chain
        // Pass the reconstructed hash so handles are stored under the correct key
        messenger.sendMessage(
            messageDestinations[_msgHash], // Send to the same destination as the original message
            address(this),
            abi.encodeCall(this.registerHandle, (reconstructedHash, handle))
        );
        
        emit HandleCreated(handleHash, block.chainid);
        
        return handle;
    }

    /// @notice get a handle by its message hash
    /// @param _handleHash The hash of the handle to retrieve
    /// @return handle The handle struct
    function getHandle(bytes32 _handleHash) external view returns (Handle memory) {
        return handles[_handleHash];
    }

    /// @notice check if a handle is completed
    /// @param _handleHash The hash of the handle to check
    /// @return completed Whether the handle is completed
    function isHandleCompleted(bytes32 _handleHash) external view returns (bool) {
        return handles[_handleHash].completed;
    }

    /// @notice get pending handles for a message hash
    /// @param _msgHash The message hash to get pending handles for
    /// @return handles Array of pending handles
    function getPendingHandles(bytes32 _msgHash) external view returns (Handle[] memory) {
        return pendingHandles[_msgHash];
    }

    /// @notice register a handle on the destination chain (called via cross-chain message)
    /// @param _msgHash The original message hash this handle is associated with
    /// @param _handle The handle to register
    function registerHandle(bytes32 _msgHash, Handle calldata _handle) external onlyCrossDomainCallback {
        // Store handle under the reconstructed message hash
        pendingHandles[_msgHash].push(_handle);
    }

    /// @notice Manually execute all pending handles for a specific message hash
    /// @dev This is a helper function for testing to execute handles after they've been registered
    /// @param _messageHash The message hash to execute handles for
    function executePendingHandles(bytes32 _messageHash) external {
        Handle[] storage pendingHandleList = pendingHandles[_messageHash];
        
        for (uint256 i = 0; i < pendingHandleList.length; i++) {
            Handle storage pendingHandle = pendingHandleList[i];
            
            if (pendingHandle.completed) {
                continue; // Skip already completed handles
            }
            
            // Update destination chain to current chain
            pendingHandle.destinationChain = block.chainid;
            
            // Execute the destination-side continuation
            (bool handleSuccess, bytes memory handleReturnData) = pendingHandle.target.call(pendingHandle.message);
            
            if (handleSuccess) {
                pendingHandle.completed = true;
                pendingHandle.returnData = handleReturnData;
                
                // Check if the return data represents a nested promise (32 bytes that could be a message hash)
                if (handleReturnData.length == 32) {
                    bytes32 potentialPromiseHash = abi.decode(handleReturnData, (bytes32));
                    
                    // If this looks like a valid promise hash and we sent it, treat it as nested
                    if (sentMessages[potentialPromiseHash]) {
                        pendingHandle.nestedPromiseHash = potentialPromiseHash;
                        nestedPromises[pendingHandle.messageHash] = potentialPromiseHash;
                        promiseChains[pendingHandle.messageHash].push(potentialPromiseHash);
                        
                        emit NestedPromiseCreated(pendingHandle.messageHash, potentialPromiseHash);
                    }
                }
                
                // Store the completed handle
                handles[pendingHandle.messageHash] = pendingHandle;
                emit HandleCompleted(pendingHandle.messageHash, handleReturnData);
            }
        }
    }

    /// @notice Check if a handle's return data represents a nested promise
    /// @param _handleHash The hash of the handle to check
    /// @return isNested Whether the handle contains a nested promise
    /// @return nestedPromiseHash The hash of the nested promise if it exists
    function getNestedPromise(bytes32 _handleHash) external view returns (bool isNested, bytes32 nestedPromiseHash) {
        Handle memory handle = handles[_handleHash];
        isNested = handle.nestedPromiseHash != bytes32(0);
        nestedPromiseHash = handle.nestedPromiseHash;
    }

    /// @notice Resolve a nested promise chain by following promise links
    /// @param _rootPromiseHash The starting promise hash
    /// @return resolved Whether the chain is fully resolved  
    /// @return finalReturnData The final return data from the resolved chain
    function resolveNestedPromise(bytes32 _rootPromiseHash) external view returns (bool resolved, bytes memory finalReturnData) {
        Handle memory handle = handles[_rootPromiseHash];
        
        // If no handle exists or it's not completed, chain is not resolved
        if (!handle.completed) {
            return (false, "");
        }
        
        // If no nested promise, this is the end of the chain
        if (handle.nestedPromiseHash == bytes32(0)) {
            return (true, handle.returnData);
        }
        
        // Follow the chain recursively (with depth limit to prevent infinite loops)
        return _resolveNestedPromiseRecursive(handle.nestedPromiseHash, 0);
    }

    /// @notice Internal recursive function to resolve nested promises with depth limiting
    /// @param _promiseHash The current promise hash to resolve
    /// @param _depth Current recursion depth
    /// @return resolved Whether the chain is fully resolved
    /// @return finalReturnData The final return data from the resolved chain
    function _resolveNestedPromiseRecursive(bytes32 _promiseHash, uint256 _depth) internal view returns (bool resolved, bytes memory finalReturnData) {
        // Prevent infinite recursion
        if (_depth > 10) {
            return (false, "Max chain depth exceeded");
        }
        
        Handle memory handle = handles[_promiseHash];
        
        // If handle doesn't exist or isn't completed, chain is not resolved
        if (!handle.completed) {
            return (false, "");
        }
        
        // If no nested promise, this is the end of the chain
        if (handle.nestedPromiseHash == bytes32(0)) {
            return (true, handle.returnData);
        }
        
        // Continue following the chain
        return _resolveNestedPromiseRecursive(handle.nestedPromiseHash, _depth + 1);
    }

    /// @notice Chain another promise to execute after this handle completes
    /// @dev This creates a nested promise relationship where the new promise depends on this handle's completion
    /// @param _handleHash The handle to chain from
    /// @param _destination The destination chain for the new promise
    /// @param _target The target contract for the new promise  
    /// @param _message The message for the new promise
    /// @return nestedPromiseHash The hash of the newly created nested promise
    function chainPromise(bytes32 _handleHash, uint256 _destination, address _target, bytes calldata _message) external returns (bytes32 nestedPromiseHash) {
        Handle memory handle = handles[_handleHash];
        require(handle.completed, "Promise: parent handle not completed");
        require(handle.nestedPromiseHash == bytes32(0), "Promise: handle already has nested promise");
        
        // Create a new promise that depends on this handle's completion
        nestedPromiseHash = this.sendMessage(_destination, _target, _message);
        
        // Update the handle to point to the new nested promise
        handles[_handleHash].nestedPromiseHash = nestedPromiseHash;
        nestedPromises[_handleHash] = nestedPromiseHash;
        promiseChains[_handleHash].push(nestedPromiseHash);
        
        emit NestedPromiseCreated(_handleHash, nestedPromiseHash);
        
        return nestedPromiseHash;
    }

    /// @notice Internal function to start the nested promise resolution process
    /// @param parentPromise The parent promise that returned a nested promise
    /// @param nestedPromise The nested promise to resolve
    function _startNestedResolution(bytes32 parentPromise, bytes32 nestedPromise) internal {
        // Register a callback on the nested promise to resolve the parent when it completes
        // This creates a chain: nested promise resolves -> parent promise resolves -> parent callbacks execute
        
        // We store the parent-child relationship for resolution tracking
        // When the nested promise resolves, we'll check if it needs further resolution
        
        emit NestedPromiseCreated(parentPromise, nestedPromise);
    }

    /// @notice Internal function to check if this promise resolution resolves any parent promises
    /// @param resolvedPromise The promise that just resolved
    /// @param returnData The return data from the resolved promise
    function _resolveParentPromises(bytes32 resolvedPromise, bytes memory returnData) internal {
        // Look for parent promises that were waiting for this nested promise to resolve
        // This is a simplified version - a full implementation would need efficient parent->child tracking
        
        // For now, we iterate through promise states to find parents
        // In production, you'd want a more efficient data structure
        // This is conceptual - would need optimization
    }

    /// @notice Internal function to update nested promise resolution
    /// @param parentPromise The parent promise 
    /// @param nestedReturnData The return data from nested promise
    function _updateNestedPromiseResolution(bytes32 parentPromise, bytes memory nestedReturnData) internal {
        PromiseState storage parentState = promiseStates[parentPromise];
        
        // Check if the nested return data is itself another promise
        if (nestedReturnData.length == 32) {
            bytes32 potentialNestedPromise = abi.decode(nestedReturnData, (bytes32));
            if (sentMessages[potentialNestedPromise]) {
                // Still nested - update the nested promise pointer
                parentState.nestedPromise = potentialNestedPromise;
                emit NestedPromiseCreated(parentPromise, potentialNestedPromise);
                return;
            }
        }
        
        // No further nesting - mark as resolved
        parentState.isResolved = true;
        parentState.finalReturnData = nestedReturnData;
        parentState.nestedPromise = bytes32(0);
        
        // Emit the delayed RelayedMessage for this promise
        emit RelayedMessage(parentPromise, nestedReturnData);
        
        // If this promise had callbacks waiting, they will execute in the next dispatchCallbacks call
    }

    /// @notice Get the current resolution state of a promise
    /// @param _promiseHash The promise hash to check
    /// @return state The current promise state
    function getPromiseState(bytes32 _promiseHash) external view returns (PromiseState memory) {
        return promiseStates[_promiseHash];
    }

    /// @notice Check if a promise is fully resolved (no more nested promises)
    /// @param _promiseHash The promise hash to check
    /// @return resolved Whether the promise is fully resolved
    function isPromiseResolved(bytes32 _promiseHash) external view returns (bool) {
        return promiseStates[_promiseHash].isResolved;
    }

    /// @notice Internal function to add a child promise to a parent's tracking
    /// @param parentPromise The parent promise hash
    /// @param childPromise The child promise hash that was just created
    function _addChildPromise(bytes32 parentPromise, bytes32 childPromise) internal {
        // Add to parent's children list
        promiseStates[parentPromise].childPromises.push(childPromise);
        promiseStates[parentPromise].unresolvedChildCount++;
        promiseStates[parentPromise].resolutionBlocked = true;
        
        // Set child's parent
        promiseStates[childPromise].parentPromise = parentPromise;
        
        // Track chain location
        promiseOriginChains[childPromise] = block.chainid;
        
        // Add to legacy tracking for backward compatibility
        promiseChains[parentPromise].push(childPromise);
        
        emit NestedPromiseCreated(parentPromise, childPromise);
    }

    /// @notice Internal function to notify parent promises when a child resolves
    /// @param resolvedPromise The promise that just resolved
    function _notifyParentOfResolution(bytes32 resolvedPromise) internal {
        PromiseState storage resolvedState = promiseStates[resolvedPromise];
        bytes32 parentPromise = resolvedState.parentPromise;
        
        if (parentPromise != bytes32(0)) {
            PromiseState storage parentState = promiseStates[parentPromise];
            
            // Decrease parent's unresolved child count
            if (parentState.unresolvedChildCount > 0) {
                parentState.unresolvedChildCount--;
                
                // If parent has no more unresolved children and is itself completed, it can now resolve
                if (parentState.unresolvedChildCount == 0 && parentState.isCompleted) {
                    _resolvePromiseAtomically(parentPromise);
                }
            }
        }
    }

    /// @notice Internal function to atomically resolve a promise once all children are resolved
    /// @param promiseHash The promise to resolve
    function _resolvePromiseAtomically(bytes32 promiseHash) internal {
        PromiseState storage state = promiseStates[promiseHash];
        
        // Mark as fully resolved
        state.isResolved = true;
        state.resolutionBlocked = false;
        
        // Emit the delayed RelayedMessage
        emit RelayedMessage(promiseHash, state.finalReturnData);
        
        // Emit resolution event
        emit NestedPromiseResolved(promiseHash, keccak256(state.finalReturnData));
        
        // Notify parent if this promise has one
        _notifyParentOfResolution(promiseHash);
        
        // If on a different chain, send cross-chain notification to parent
        if (state.parentPromise != bytes32(0)) {
            uint256 parentChain = promiseOriginChains[state.parentPromise];
            if (parentChain != 0 && parentChain != block.chainid) {
                // Send cross-chain notification to parent chain
                messenger.sendMessage(
                    parentChain,
                    address(this),
                    abi.encodeCall(this.notifyParentPromiseResolution, (state.parentPromise, promiseHash))
                );
            }
        }
    }

    /// @notice Cross-chain function to notify a parent promise that its child has resolved
    /// @param parentPromise The parent promise hash
    /// @param childPromise The child promise that resolved
    function notifyParentPromiseResolution(bytes32 parentPromise, bytes32 childPromise) external onlyCrossDomainCallback {
        _notifyParentOfResolution(childPromise);
    }

    /// @notice Automatically track a child promise if called during promise execution
    /// @dev Called by PromiseAwareMessenger to automatically track child promises
    /// @param childPromiseHash The hash of the child promise to track
    function autoTrackChildPromise(bytes32 childPromiseHash) external {
        // If we're currently executing within a promise context, track this as a child promise
        if (inPromiseExecution && currentPromiseContext != bytes32(0)) {
            _addChildPromise(currentPromiseContext, childPromiseHash);
        }
        
        // If not in promise context, this is a no-op (normal cross-domain message)
    }

    /// @notice Check if we're currently in promise execution context
    /// @dev Used by PromiseAwareMessenger to determine if tracking is needed
    /// @return inContext Whether we're currently executing within a promise
    function inPromiseExecutionContext() external view returns (bool) {
        return inPromiseExecution;
    }

    /// @notice Get the current promise context
    /// @dev Used for debugging and testing
    /// @return contextHash The current promise being executed
    function getCurrentPromiseContext() external view returns (bytes32) {
        return currentPromiseContext;
    }
}
