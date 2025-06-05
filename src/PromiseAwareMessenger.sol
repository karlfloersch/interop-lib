// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IL2ToL2CrossDomainMessenger} from "./interfaces/IL2ToL2CrossDomainMessenger.sol";
import {Identifier} from "./interfaces/IIdentifier.sol";
import {PredeployAddresses} from "./libraries/PredeployAddresses.sol";

/// @notice A wrapper around IL2ToL2CrossDomainMessenger that adds proper authentication and sender tracking
/// @dev This wrapper uses the CDM to call itself on the destination chain, then makes the actual call
contract PromiseAwareMessenger {
    /// @notice The underlying cross domain messenger
    IL2ToL2CrossDomainMessenger public immutable messenger;
    
    /// @notice Default value for when no cross-domain message is being executed
    address private constant DEFAULT_SENDER = address(0x000000000000000000000000000000000000dEaD);
    
    /// @notice Address of the sender of the currently executing cross-domain message
    /// @dev This is set during relayWrappedMessage execution to track the original sender
    address private xDomainMsgSender;
    
    /// @notice Event emitted when a message is sent through the wrapper
    event WrapperMessageSent(uint256 destination, address target, bytes message, address sender);
    
    /// @notice Event emitted when a wrapped message is relayed
    event WrapperMessageRelayed(address target, address sender, bytes message, bool success);
    
    constructor() {
        messenger = IL2ToL2CrossDomainMessenger(PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER);
        xDomainMsgSender = DEFAULT_SENDER;
    }
    
    /// @notice Send a message via the wrapper - calls itself on destination chain instead of target directly
    /// @param _destination The destination chain ID
    /// @param _target The target contract address
    /// @param _message The message to send
    /// @return messageHash The hash of the sent message
    function sendMessage(uint256 _destination, address _target, bytes calldata _message) external returns (bytes32) {
        // Use CDM to call ourselves on the destination chain with relayWrappedMessage
        bytes memory wrappedMessage = abi.encodeWithSelector(
            this.relayWrappedMessage.selector,
            msg.sender,  // original sender
            _target,     // final target
            _message     // original message
        );
        
        bytes32 messageHash = messenger.sendMessage(_destination, address(this), wrappedMessage);
        
        emit WrapperMessageSent(_destination, _target, _message, msg.sender);
        
        return messageHash;
    }
    
    /// @notice Relay a wrapped message - called by CDM from another wrapper instance
    /// @param _originalSender The original sender from the source chain
    /// @param _target The target contract address
    /// @param _message The message to send to the target
    function relayWrappedMessage(address _originalSender, address _target, bytes calldata _message) external {
        // Authenticate that this is being called by the CDM
        require(msg.sender == address(messenger), "PromiseAwareMessenger: not called by CDM");
        
        // Authenticate that the CDM was called by another wrapper at the same address
        require(
            messenger.crossDomainMessageSender() == address(this),
            "PromiseAwareMessenger: not called by wrapper"
        );
        
        // Set the cross-domain message sender for the duration of the call
        xDomainMsgSender = _originalSender;
        
        // Make the actual call to the target
        (bool success, ) = _target.call(_message);
        
        // Reset the cross-domain message sender
        xDomainMsgSender = DEFAULT_SENDER;
        
        emit WrapperMessageRelayed(_target, _originalSender, _message, success);
        
        // Don't revert on failure to match CDM behavior - let the calling contract handle failures
    }
    
    /// @notice Get the original sender of the currently executing cross-domain message
    /// @return The address of the original sender
    function xDomainMessageSender() external view returns (address) {
        require(
            xDomainMsgSender != DEFAULT_SENDER,
            "PromiseAwareMessenger: xDomainMessageSender is not set"
        );
        return xDomainMsgSender;
    }
    
    /// @notice Get the message nonce from underlying CDM
    function messageNonce() external view returns (uint256) {
        return messenger.messageNonce();
    }
    
    /// @notice Get the cross domain message sender from underlying CDM
    function crossDomainMessageSender() external view returns (address) {
        return messenger.crossDomainMessageSender();
    }
    
    /// @notice Get the cross domain message source from underlying CDM
    function crossDomainMessageSource() external view returns (uint256) {
        return messenger.crossDomainMessageSource();
    }
} 