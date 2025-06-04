// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IL2ToL2CrossDomainMessenger} from "./interfaces/IL2ToL2CrossDomainMessenger.sol";
import {Identifier} from "./interfaces/IIdentifier.sol";
import {PredeployAddresses} from "./libraries/PredeployAddresses.sol";

/// @notice A wrapper around IL2ToL2CrossDomainMessenger that can add custom logic
/// @dev This wrapper delegates all calls to the underlying CDM but allows for extensions
contract PromiseAwareMessenger {
    /// @notice The underlying cross domain messenger
    IL2ToL2CrossDomainMessenger public immutable messenger;
    
    /// @notice Event emitted when a message is sent through the wrapper
    event WrapperMessageSent(uint256 destination, address target, bytes message, bytes32 messageHash);
    
    /// @notice Event emitted when a message is relayed through the wrapper  
    event WrapperMessageRelayed(Identifier id, bytes message);
    
    constructor() {
        messenger = IL2ToL2CrossDomainMessenger(PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER);
    }
    
    /// @notice Send a message via the wrapper (delegates to underlying CDM)
    /// @param _destination The destination chain ID
    /// @param _target The target contract address
    /// @param _message The message to send
    /// @return messageHash The hash of the sent message
    function sendMessage(uint256 _destination, address _target, bytes calldata _message) external returns (bytes32) {
        // Custom logic can go here (before)
        
        // Delegate to underlying CDM
        bytes32 messageHash = messenger.sendMessage(_destination, _target, _message);
        
        // Custom logic can go here (after)
        emit WrapperMessageSent(_destination, _target, _message, messageHash);
        
        return messageHash;
    }
    
    /// @notice Relay a message via the wrapper (delegates to underlying CDM)
    /// @param _id The message identifier
    /// @param _sentMessage The sent message
    /// @return The return data from the relayed message
    function relayMessage(Identifier calldata _id, bytes calldata _sentMessage) external payable returns (bytes memory) {
        // Custom logic can go here (before)
        emit WrapperMessageRelayed(_id, _sentMessage);
        
        // Delegate to underlying CDM  
        bytes memory returnData = messenger.relayMessage(_id, _sentMessage);
        
        // Custom logic can go here (after)
        
        return returnData;
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