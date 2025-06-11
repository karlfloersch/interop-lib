// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IL2ToL2CrossDomainMessenger} from "./interfaces/IL2ToL2CrossDomainMessenger.sol";
import {ICrossL2Inbox, Identifier} from "./interfaces/ICrossL2Inbox.sol";
import {Hashing} from "./libraries/Hashing.sol";
import {PredeployAddresses} from "./libraries/PredeployAddresses.sol";
import {TransientReentrancyAware} from "./libraries/TransientContext.sol";

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

    /// @notice the relay identifier that is satisfying the promise
    Identifier internal currentRelayIdentifier;

    /// @notice the context that is being propagated with the promise
    bytes internal currentContext;

    /// @notice a mapping of message sent by this library. To prevent callbacks being registered to messages
    ///         sent directly to the L2ToL2CrossDomainMessenger which does not emit the return value (yet)
    mapping(bytes32 => bool) private sentMessages;

    /// @notice Tracks nested promise relationships - parent hash -> nested hash
    mapping(bytes32 => bytes32) public nestedPromises;
    
    /// @notice Tracks callbacks waiting for nested promises - nested hash -> parent hash
    mapping(bytes32 => bytes32) public pendingNestedCallbacks;
    
    /// @notice Tracks the remaining callbacks for a parent after nested promise is detected
    mapping(bytes32 => Callback[]) public deferredCallbacks;

    /// @notice an event emitted when a callback is registered
    event CallbackRegistered(bytes32 messageHash);

    /// @notice an event emitted when all callbacks for a message are dispatched
    event CallbacksCompleted(bytes32 messageHash);

    /// @notice an event emitted when a message is relayed
    event RelayedMessage(bytes32 messageHash, bytes returnData);
    
    /// @notice an event emitted when a nested promise is detected
    event NestedPromiseDetected(bytes32 indexed parentHash, bytes32 indexed nestedHash);

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
        
        // Check if this is resolving a nested promise
        if (pendingNestedCallbacks[msgHash] != bytes32(0)) {
            _handleNestedPromiseResolution(msgHash, returnData);
            return;
        }
        
        _executeCallbacksWithNesting(msgHash, returnData);

        emit CallbacksCompleted(msgHash);

        // storage cleanup
        delete callbacks[msgHash];
        delete sentMessages[msgHash];
        delete currentRelayIdentifier;
    }
    
    /// @notice Execute callbacks with nested promise detection
    /// @param msgHash The message hash being resolved
    /// @param returnData The return data from the message
    function _executeCallbacksWithNesting(bytes32 msgHash, bytes memory returnData) internal {
        Callback[] memory callbackList = callbacks[msgHash];
        
        for (uint256 i = 0; i < callbackList.length; i++) {
            Callback memory callback = callbackList[i];
            if (callback.context.length > 0) {
                currentContext = callback.context;
            }

            (bool completed, bytes memory callbackReturnData) = callback.target.call(abi.encodePacked(callback.selector, returnData));
            require(completed, "Promise: callback call failed");

            // Check if callback returned a nested promise (message hash)
            if (callbackReturnData.length > 0) {
                bytes32 nestedHash = _tryDecodeAsMessageHash(callbackReturnData);
                
                if (nestedHash != bytes32(0) && _isValidPendingMessage(nestedHash)) {
                    // NESTED PROMISE DETECTED!
                    emit NestedPromiseDetected(msgHash, nestedHash);
                    
                    // Store the nested relationship
                    nestedPromises[msgHash] = nestedHash;
                    pendingNestedCallbacks[nestedHash] = msgHash;
                    
                    // Store remaining callbacks to execute after nested promise resolves
                    _storeDeferredCallbacks(msgHash, callbackList, i + 1);
                    
                    // Stop processing callbacks - wait for nested promise
                    if (callback.context.length > 0) {
                        delete currentContext;
                    }
                    return;
                }
            }

            if (callback.context.length > 0) {
                delete currentContext;
            }
        }
    }
    
    /// @notice Handle resolution of a nested promise
    /// @param nestedHash The nested promise that just resolved
    /// @param nestedReturnData The return data from the nested promise
    function _handleNestedPromiseResolution(bytes32 nestedHash, bytes memory nestedReturnData) internal {
        bytes32 parentHash = pendingNestedCallbacks[nestedHash];
        require(parentHash != bytes32(0), "Promise: no parent for nested promise");
        
        // Execute the deferred callbacks with the nested promise result
        Callback[] memory deferredCallbackList = deferredCallbacks[parentHash];
        
        for (uint256 i = 0; i < deferredCallbackList.length; i++) {
            Callback memory callback = deferredCallbackList[i];
            if (callback.context.length > 0) {
                currentContext = callback.context;
            }

            (bool completed,) = callback.target.call(abi.encodePacked(callback.selector, nestedReturnData));
            require(completed, "Promise: deferred callback call failed");

            if (callback.context.length > 0) {
                delete currentContext;
            }
        }
        
        // Cleanup nested promise tracking
        delete nestedPromises[parentHash];
        delete pendingNestedCallbacks[nestedHash];
        delete deferredCallbacks[parentHash];
        
        emit CallbacksCompleted(parentHash);
        
        // Cleanup parent message state
        delete callbacks[parentHash];
        delete sentMessages[parentHash];
    }
    
    /// @notice Try to decode return data as a message hash (32 bytes)
    /// @param returnData The data returned from callback
    /// @return messageHash The message hash if valid, bytes32(0) otherwise
    function _tryDecodeAsMessageHash(bytes memory returnData) internal pure returns (bytes32 messageHash) {
        // Message hashes are exactly 32 bytes
        if (returnData.length == 32) {
            messageHash = abi.decode(returnData, (bytes32));
        }
        // Return bytes32(0) if not 32 bytes or decode fails
    }
    
    /// @notice Check if a message hash is valid and still pending
    /// @param messageHash The message hash to check  
    /// @return valid True if message was sent by this contract and still pending
    function _isValidPendingMessage(bytes32 messageHash) internal view returns (bool valid) {
        // Check if this message was sent by this contract and hasn't been resolved yet
        return sentMessages[messageHash] && callbacks[messageHash].length > 0;
    }
    
    /// @notice Store callbacks that should execute after nested promise resolves
    /// @param parentHash The parent message hash
    /// @param allCallbacks All callbacks for the parent
    /// @param startIndex Index to start storing from (callbacks after the nested one)
    function _storeDeferredCallbacks(bytes32 parentHash, Callback[] memory allCallbacks, uint256 startIndex) internal {
        uint256 deferredCount = allCallbacks.length - startIndex;
        if (deferredCount == 0) return;
        
        // Clear existing deferred callbacks
        delete deferredCallbacks[parentHash];
        
        // Store the callbacks that should execute after nested promise resolves
        for (uint256 i = 0; i < deferredCount; i++) {
            deferredCallbacks[parentHash].push(allCallbacks[startIndex + i]);
        }
    }

    /// @notice get the context that is being propagated with the promise
    function promiseContext() public view returns (bytes memory) {
        return currentContext;
    }

    /// @notice get the relay identifier that is satisfying the promise
    function promiseRelayIdentifier() public view returns (Identifier memory) {
        return currentRelayIdentifier;
    }
}
