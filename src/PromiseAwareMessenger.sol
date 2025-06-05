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
    
    /// @notice Hash of the parent message currently being executed (for sub-call tracking)
    /// @dev Set during relayWrappedMessage, used to track nested sendMessage calls
    bytes32 private currentlyExecutingParentHash;
    
    /// @notice Mapping from parent message hash to array of sub-call message hashes
    /// @dev Tracks all sendMessage calls made during relayWrappedMessage execution
    mapping(bytes32 => bytes32[]) public subCalls;
    
    /// @notice Event emitted when a message is sent through the wrapper
    event WrapperMessageSent(uint256 destination, address target, bytes message, address sender);
    
    /// @notice Event emitted when a wrapped message is relayed
    event WrapperMessageRelayed(address target, address sender, bytes message, bool success);
    
    /// @notice Event emitted when a sub-call is made during message relay execution
    event SubCallRegistered(bytes32 indexed parentHash, bytes32 indexed subCallHash, uint256 destination, address target, bytes message);
    
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
        // Create a deterministic hash for this call (independent of CDM hash)
        bytes32 deterministicHash = _createDeterministicHash(_destination, msg.sender, _target, _message);
        
        // Use CDM to call ourselves on the destination chain with relayWrappedMessage
        // Include the deterministic hash so the destination knows the parent hash
        bytes memory wrappedMessage = abi.encodeWithSelector(
            this.relayWrappedMessage.selector,
            deterministicHash, // parent message hash for sub-call tracking
            msg.sender,        // original sender
            _target,           // final target
            _message           // original message
        );
        
        bytes32 actualMessageHash = messenger.sendMessage(_destination, address(this), wrappedMessage);
        
        // If we're currently executing a parent message, track this as a sub-call
        if (currentlyExecutingParentHash != bytes32(0)) {
            subCalls[currentlyExecutingParentHash].push(actualMessageHash);
            emit SubCallRegistered(currentlyExecutingParentHash, actualMessageHash, _destination, _target, _message);
        }
        
        emit WrapperMessageSent(_destination, _target, _message, msg.sender);
        
        return actualMessageHash;
    }
    
    /// @notice Relay a wrapped message - called by CDM from another wrapper instance
    /// @param _parentMessageHash The original message hash for sub-call tracking
    /// @param _originalSender The original sender from the source chain
    /// @param _target The target contract address
    /// @param _message The message to send to the target
    function relayWrappedMessage(bytes32 _parentMessageHash, address _originalSender, address _target, bytes calldata _message) external {
        // Authenticate that this is being called by the CDM
        require(msg.sender == address(messenger), "PromiseAwareMessenger: not called by CDM");
        
        // Authenticate that the CDM was called by another wrapper at the same address
        require(
            messenger.crossDomainMessageSender() == address(this),
            "PromiseAwareMessenger: not called by wrapper"
        );
        
        // Set execution context for sub-call tracking
        currentlyExecutingParentHash = _parentMessageHash;
        
        // Set the cross-domain message sender for the duration of the call
        xDomainMsgSender = _originalSender;
        
        // Make the actual call to the target
        (bool success, ) = _target.call(_message);
        
        // Reset execution context
        currentlyExecutingParentHash = bytes32(0);
        xDomainMsgSender = DEFAULT_SENDER;
        
        emit WrapperMessageRelayed(_target, _originalSender, _message, success);
        
        // Don't revert on failure to match CDM behavior - let the calling contract handle failures
    }
    
    /// @notice Get the sub-calls made during execution of a parent message
    /// @param _parentMessageHash The hash of the parent message
    /// @return Array of sub-call message hashes
    function getSubCalls(bytes32 _parentMessageHash) external view returns (bytes32[] memory) {
        return subCalls[_parentMessageHash];
    }
    
    /// @notice Get the number of sub-calls made during execution of a parent message
    /// @param _parentMessageHash The hash of the parent message
    /// @return Number of sub-calls
    function getSubCallCount(bytes32 _parentMessageHash) external view returns (uint256) {
        return subCalls[_parentMessageHash].length;
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
    

    
    /// @notice Create a deterministic hash for message tracking
    /// @dev This hash is independent of CDM's message hash and used for sub-call tracking
    function _createDeterministicHash(uint256 _destination, address _originalSender, address _target, bytes calldata _message) private view returns (bytes32) {
        return keccak256(abi.encodePacked(
            block.chainid,   // source chain
            _destination,    // destination chain
            _originalSender, // original sender
            _target,         // target
            _message,        // message data
            messenger.messageNonce() // add nonce for uniqueness
        ));
    }
} 