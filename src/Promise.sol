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
        
        return msgHash;
    }

    /// @dev handler to dispatch and emit the return value of a message
    function handleMessage(uint256 _nonce, address _target, bytes calldata _message) external onlyCrossDomainCallback {
        (bool success, bytes memory returnData_) = _target.call(_message);
        require(success, "Promise: target call failed");

        // reconstruct the L2ToL2CrossDomainMessenger message hash
        bytes32 messageHash = Hashing.hashL2toL2CrossDomainMessage({
            _destination: block.chainid,
            _source: messenger.crossDomainMessageSource(),
            _nonce: _nonce,
            _sender: address(this),
            _target: address(this),
            _message: abi.encodeCall(this.handleMessage, (_nonce, _target, _message))
        });

        emit RelayedMessage(messageHash, returnData_);

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

    /// @notice invoke continuations present on the completion of a remote message. for now this requires all
    ///         callbacks to be dispatched in a single call. A failing callback will halt the entire process.
    function dispatchCallbacks(Identifier calldata _id, bytes calldata _payload) external payable nonReentrant {
        require(_id.origin == address(this), "Promise: invalid origin");
        ICrossL2Inbox(PredeployAddresses.CROSS_L2_INBOX).validateMessage(_id, keccak256(_payload));

        bytes32 eventSel = abi.decode(_payload[:32], (bytes32));
        require(eventSel == RelayedMessage.selector, "Promise: invalid event");

        currentRelayIdentifier = _id;

        (bytes32 msgHash, bytes memory returnData) = abi.decode(_payload[32:], (bytes32, bytes));
        for (uint256 i = 0; i < callbacks[msgHash].length; i++) {
            Callback memory callback = callbacks[msgHash][i];
            if (callback.context.length > 0) {
                currentContext = callback.context;
            }

            (bool completed,) = callback.target.call(abi.encodePacked(callback.selector, returnData));
            require(completed, "Promise: callback call failed");

            if (callback.context.length > 0) {
                delete currentContext;
            }
        }

        emit CallbacksCompleted(msgHash);

        // storage cleanup
        delete callbacks[msgHash];
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
}
