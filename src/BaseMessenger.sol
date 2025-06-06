// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IL2ToL2CrossDomainMessenger} from "./interfaces/IL2ToL2CrossDomainMessenger.sol";
import {PredeployAddresses} from "./libraries/PredeployAddresses.sol";

/// @notice Base contract with common messenger functionality
/// @dev Provides shared CDM access and helper functions
contract BaseMessenger {
    /// @notice The underlying cross domain messenger
    IL2ToL2CrossDomainMessenger public immutable messenger;
    
    constructor() {
        messenger = IL2ToL2CrossDomainMessenger(PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER);
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