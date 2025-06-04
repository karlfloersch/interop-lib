// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IL2ToL2CrossDomainMessenger} from "../interfaces/IL2ToL2CrossDomainMessenger.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";
import {console} from "forge-std/console.sol";

/// @title AtomicPromiseExample
/// @notice Example contract showing transparent promise tracking with atomic resolution
/// @dev This contract uses PromiseAwareMessenger transparently - same API as regular messenger
contract AtomicPromiseExample {
    /// @notice The promise-aware messenger (looks identical to regular messenger)
    IL2ToL2CrossDomainMessenger public immutable messenger;
    
    constructor(address _promiseAwareMessenger) {
        messenger = IL2ToL2CrossDomainMessenger(_promiseAwareMessenger);
    }
    
    /// @notice Example: Complex cross-chain operation that creates multiple child promises
    /// @dev This function will create 3 child promises. The parent promise won't resolve until ALL children resolve
    /// @param chainA First destination chain
    /// @param chainB Second destination chain  
    /// @param chainC Third destination chain
    /// @param tokenA Token contract on chain A
    /// @param tokenB Token contract on chain B
    /// @param tokenC Token contract on chain C
    /// @param recipient Address to receive tokens
    /// @return summary A summary of the operation
    function distributeTokensAtomically(
        uint256 chainA,
        uint256 chainB, 
        uint256 chainC,
        address tokenA,
        address tokenB,
        address tokenC,
        address recipient
    ) external returns (bytes memory summary) {
        // These look like normal cross-domain messenger calls
        // But they're automatically tracked as child promises!
        
        // Child promise 1: Mint 100 tokens on chain A
        bytes32 child1 = messenger.sendMessage(
            chainA,
            tokenA,
            abi.encodeCall(IERC20.transfer, (recipient, 100))
        );
        
        // Child promise 2: Mint 200 tokens on chain B  
        bytes32 child2 = messenger.sendMessage(
            chainB,
            tokenB,
            abi.encodeCall(IERC20.transfer, (recipient, 200))
        );
        
        // Child promise 3: Mint 300 tokens on chain C
        bytes32 child3 = messenger.sendMessage(
            chainC,
            tokenC, 
            abi.encodeCall(IERC20.transfer, (recipient, 300))
        );
        
        // The parent promise calling this function won't resolve until 
        // ALL three child promises (child1, child2, child3) are fully resolved!
        
        return abi.encode("Distributed tokens", child1, child2, child3);
    }
    
    /// @notice Example: Nested atomic operations
    /// @dev Creates a child promise that itself creates more children
    function nestedAtomicOperation(
        uint256 destinationChain,
        address targetContract
    ) external returns (bytes32) {
        // This child promise will itself create more child promises
        // The parent won't resolve until the entire nested tree resolves
        bytes32 nestedChild = messenger.sendMessage(
            destinationChain,
            targetContract,
            abi.encodeCall(this.distributeTokensAtomically, (
                1, 2, 3,                    // chain IDs
                address(0), address(0), address(0),  // token addresses
                msg.sender                  // recipient
            ))
        );
        
        return nestedChild;
    }
    
    /// @notice Example: Conditional child promise creation
    /// @dev Shows how child promises can be created conditionally
    function conditionalOperation(
        bool shouldCreateChild,
        uint256 destinationChain,
        address targetContract
    ) external returns (bytes memory result) {
        if (shouldCreateChild) {
            // This child promise is only created if condition is true
            bytes32 childPromise = messenger.sendMessage(
                destinationChain,
                targetContract,
                abi.encodeCall(IERC20.balanceOf, (msg.sender))
            );
            
            return abi.encode("Created child", childPromise);
        } else {
            // No child promises created - parent resolves immediately
            return abi.encode("No children");
        }
    }
} 