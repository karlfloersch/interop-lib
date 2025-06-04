// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IL2ToL2CrossDomainMessenger} from "./interfaces/IL2ToL2CrossDomainMessenger.sol";
import {IPromise} from "./interfaces/IPromise.sol";
import {Identifier} from "./interfaces/IIdentifier.sol";
import {PredeployAddresses} from "./libraries/PredeployAddresses.sol";
import {console} from "forge-std/console.sol";

/// @title PromiseAwareMessenger
/// @notice A wrapper around L2ToL2CrossDomainMessenger that automatically tracks child promises
/// @dev This provides the exact same API as IL2ToL2CrossDomainMessenger but with automatic promise tracking
contract PromiseAwareMessenger {
    /// @notice The underlying cross-domain messenger
    IL2ToL2CrossDomainMessenger public immutable messenger;
    
    /// @notice The promise contract for tracking child promises
    IPromise public immutable promiseContract;
    
    constructor() {
        messenger = IL2ToL2CrossDomainMessenger(PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER);
        promiseContract = IPromise(PredeployAddresses.PROMISE);
    }
    
    /// @notice Send a cross-domain message with automatic promise tracking
    /// @dev If called during promise execution, automatically tracks as child promise
    /// @param _destination Destination chain ID
    /// @param _target Target contract address
    /// @param _message Message to send
    /// @return msgHash The hash of the sent message
    function sendMessage(uint256 _destination, address _target, bytes calldata _message) external returns (bytes32) {
        // Use Promise.sendMessage to ensure proper tracking in sentMessages mapping
        // Send to the PromiseAwareMessenger on the destination chain for consistent wrapper usage
        bytes32 msgHash = promiseContract.sendMessage(
            _destination,
            address(this), // Call the PromiseAwareMessenger on the destination chain
            abi.encodeCall(this.relayToTarget, (_target, _message))
        );
        
        return msgHash;
    }
    
    /// @notice Relay a message to the actual target on the destination chain
    /// @dev This is called by the PromiseAwareMessenger on the destination chain
    /// @param _target The actual target contract to call
    /// @param _message The message to send to the target
    /// @return returnData The return data from the target call
    function relayToTarget(address _target, bytes calldata _message) external returns (bytes memory) {
        // Verify this is a cross-domain call from another PromiseAwareMessenger
        require(msg.sender == address(messenger), "PromiseAwareMessenger: caller not messenger");
        require(messenger.crossDomainMessageSender() == address(this), "PromiseAwareMessenger: invalid sender");
        
        // Call the actual target contract
        (bool success, bytes memory returnData) = _target.call(_message);
        require(success, "PromiseAwareMessenger: target call failed");
        
        return returnData;
    }
    
    /// @notice Get the message nonce - delegate to underlying messenger
    function messageNonce() external view returns (uint256) {
        return messenger.messageNonce();
    }
    
    /// @notice Get cross domain message sender - delegate to underlying messenger  
    function crossDomainMessageSender() external view returns (address) {
        return messenger.crossDomainMessageSender();
    }
    
    /// @notice Get cross domain message source - delegate to underlying messenger
    function crossDomainMessageSource() external view returns (uint256) {
        return messenger.crossDomainMessageSource();
    }
    
    /// @notice Get cross domain message context - delegate to underlying messenger
    function crossDomainMessageContext() external view returns (address sender_, uint256 source_) {
        return messenger.crossDomainMessageContext();
    }
    
    /// @notice Relay a cross-domain message - delegate to underlying messenger
    function relayMessage(
        Identifier calldata _id,
        bytes calldata _sentMessage
    ) external payable returns (bytes memory) {
        return messenger.relayMessage{value: msg.value}(_id, _sentMessage);
    }
    
    /// @notice Check if a message was successfully relayed - delegate to underlying messenger
    function successfulMessages(bytes32 _msgHash) external view returns (bool) {
        return messenger.successfulMessages(_msgHash);
    }
    
    /// @notice Get the version - delegate to underlying messenger
    function version() external view returns (string memory) {
        return messenger.version();
    }
    
    /// @notice Get the message version - delegate to underlying messenger
    function messageVersion() external view returns (uint16) {
        return messenger.messageVersion();
    }
} 