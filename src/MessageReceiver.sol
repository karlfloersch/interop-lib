// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {BaseMessenger} from "./BaseMessenger.sol";

/// @notice Base contract for receiving cross-domain messages
/// @dev Handles incoming message logic and authentication
contract MessageReceiver is BaseMessenger {
    /// @notice Address of the sender contract (for authentication)
    address public immutable sender;
    
    /// @notice Default value for when no cross-domain message is being executed
    address private constant DEFAULT_SENDER = address(0x000000000000000000000000000000000000dEaD);
    
    /// @notice Address of the sender of the currently executing cross-domain message
    /// @dev This is set during relayWrappedMessage execution to track the original sender
    address private xDomainMsgSender;
    
    /// @notice Event emitted when a wrapped message is relayed
    event WrapperMessageRelayed(address target, address sender, bytes message, bool success);
    
    constructor(address _sender) {
        sender = _sender;
        xDomainMsgSender = DEFAULT_SENDER;
    }
    
    /// @notice Relay a wrapped message - called by CDM from another sender instance
    /// @param _originalSender The original sender from the source chain
    /// @param _target The target contract address
    /// @param _message The message to send to the target
    function relayWrappedMessage(bytes32 /* _parentMessageHash */, address _originalSender, address _target, bytes calldata _message) external virtual {
        // Authenticate that this is being called by the CDM
        require(msg.sender == address(messenger), "MessageReceiver: not called by CDM");
        
        // Authenticate that the CDM was called by a sender at the same address
        require(
            messenger.crossDomainMessageSender() == sender,
            "MessageReceiver: not called by authorized sender"
        );
        
        // Set the cross-domain message sender for the duration of the call
        xDomainMsgSender = _originalSender;
        
        // Make the actual call to the target
        (bool success, bytes memory returnData) = _target.call(_message);
        
        // Reset execution context
        xDomainMsgSender = DEFAULT_SENDER;
        
        emit WrapperMessageRelayed(_target, _originalSender, _message, success);
        
        // Revert on failure to see what went wrong during testing
        if (!success) {
            // Decode the revert reason if possible
            if (returnData.length > 0) {
                assembly {
                    let returnDataSize := mload(returnData)
                    revert(add(32, returnData), returnDataSize)
                }
            } else {
                revert("MessageReceiver: target call failed");
            }
        }
    }
    
    /// @notice Get the original sender of the currently executing cross-domain message
    /// @return The address of the original sender
    function xDomainMessageSender() external view returns (address) {
        require(
            xDomainMsgSender != DEFAULT_SENDER,
            "MessageReceiver: xDomainMessageSender is not set"
        );
        return xDomainMsgSender;
    }
    

} 