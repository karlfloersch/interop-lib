// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {BaseMessenger} from "./BaseMessenger.sol";

/// @notice Base contract for sending cross-domain messages
/// @dev Handles outgoing message logic and CDM integration
contract MessageSender is BaseMessenger {
    /// @notice Address of the receiver contract (for authentication)
    address public immutable receiver;
    
    /// @notice Event emitted when a message is sent through the wrapper
    event WrapperMessageSent(uint256 destination, address target, bytes message, address sender);
    
    constructor(address _receiver) {
        receiver = _receiver;
    }
    
    /// @notice Send a message via the wrapper - calls receiver on destination chain
    /// @param _destination The destination chain ID
    /// @param _target The target contract address
    /// @param _message The message to send
    /// @return messageHash The hash of the sent message
    function sendMessage(uint256 _destination, address _target, bytes calldata _message) external virtual returns (bytes32) {
        // Create a deterministic hash for this call (independent of CDM hash)
        bytes32 deterministicHash = _createDeterministicHash(_destination, msg.sender, _target, _message);
        
        // Use CDM to call receiver on the destination chain with relayWrappedMessage
        bytes memory wrappedMessage = abi.encodeWithSelector(
            bytes4(keccak256("relayWrappedMessage(bytes32,address,address,bytes)")),
            deterministicHash, // parent message hash for future promise tracking
            msg.sender,        // original sender
            _target,           // final target
            _message           // original message
        );
        
        bytes32 actualMessageHash = messenger.sendMessage(_destination, receiver, wrappedMessage);
        
        emit WrapperMessageSent(_destination, _target, _message, msg.sender);
        
        return actualMessageHash;
    }
    

    
    /// @notice Create a deterministic hash for message tracking
    /// @dev This hash is independent of CDM's message hash and used for future promise tracking
    function _createDeterministicHash(uint256 _destination, address _originalSender, address _target, bytes calldata _message) internal view returns (bytes32) {
        return keccak256(abi.encode(
            block.chainid,   // source chain
            _destination,    // destination chain
            _originalSender, // original sender
            _target,         // target
            _message,        // message data
            messenger.messageNonce() // add nonce for uniqueness
        ));
    }
} 