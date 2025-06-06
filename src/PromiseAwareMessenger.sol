// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {MessageSender} from "./MessageSender.sol";
import {MessageReceiver} from "./MessageReceiver.sol";

/// @notice A wrapper around IL2ToL2CrossDomainMessenger that adds proper authentication and sender tracking
/// @dev This wrapper uses the CDM to call itself on the destination chain, then makes the actual call
contract PromiseAwareMessenger is MessageSender, MessageReceiver {
    
    constructor() 
        MessageSender(address(this))
        MessageReceiver(address(this)) 
    {
        // Both sender and receiver point to this contract for unified interface
    }
} 