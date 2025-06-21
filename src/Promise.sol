// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IL2ToL2CrossDomainMessenger} from "./interfaces/IL2ToL2CrossDomainMessenger.sol";

/// @title Promise
/// @notice Core promise state management contract with optional cross-chain support
contract Promise {
    /// @notice Promise states matching JavaScript promise semantics
    enum PromiseStatus {
        Pending,
        Resolved,
        Rejected
    }

    /// @notice Promise data structure
    struct PromiseData {
        address resolver;
        PromiseStatus status;
        bytes returnData;
    }

    /// @notice Promise counter for generating unique IDs
    uint256 private nonce = 1;

    /// @notice Mapping from promise ID to promise data
    mapping(bytes32 => PromiseData) public promises;

    /// @notice Cross-domain messenger for sending cross-chain messages (optional)
    IL2ToL2CrossDomainMessenger public immutable messenger;
    
    /// @notice Current chain ID for generating global promise IDs (optional)
    uint256 public immutable currentChainId;

    /// @notice Event emitted when a new promise is created
    event PromiseCreated(bytes32 indexed promiseId, address indexed resolver);

    /// @notice Event emitted when a promise is resolved
    event PromiseResolved(bytes32 indexed promiseId, bytes returnData);

    /// @notice Event emitted when a promise is rejected
    event PromiseRejected(bytes32 indexed promiseId, bytes errorData);

    /// @notice Event emitted when a resolved promise is shared to another chain
    event ResolvedPromiseShared(bytes32 indexed promiseId, uint256 indexed destinationChain);

    /// @notice Event emitted when resolution is transferred to another chain
    event ResolutionTransferred(bytes32 indexed promiseId, uint256 indexed destinationChain, address indexed newResolver);

    /// @notice Constructor
    /// @param _messenger The cross-domain messenger contract address (use address(0) for local-only mode)
    constructor(address _messenger) {
        messenger = IL2ToL2CrossDomainMessenger(_messenger);
        currentChainId = block.chainid;
    }



    /// @notice Generate a global promise ID from chain ID and nonce
    /// @param chainId The chain ID where the promise was created
    /// @param nonceValue The nonce on that chain
    /// @return globalPromiseId The globally unique promise ID
    function generateGlobalPromiseId(uint256 chainId, bytes32 nonceValue) public pure returns (bytes32 globalPromiseId) {
        return keccak256(abi.encode(chainId, nonceValue));
    }

    /// @notice Generate a promise ID using the current chain
    /// @param nonceValue The nonce for this chain
    /// @return promiseId The global promise ID for this chain
    function generatePromiseId(bytes32 nonceValue) external view returns (bytes32 promiseId) {
        return generateGlobalPromiseId(currentChainId, nonceValue);
    }

    /// @notice Create a new promise
    /// @return promiseId The unique identifier for the new promise
    function create() external returns (bytes32 promiseId) {
        uint256 currentNonce = nonce++;
        promiseId = generateGlobalPromiseId(currentChainId, bytes32(currentNonce));
        
        promises[promiseId] = PromiseData({
            resolver: msg.sender,
            status: PromiseStatus.Pending,
            returnData: ""
        });

        emit PromiseCreated(promiseId, msg.sender);
    }

    /// @notice Resolve a promise with return data
    /// @param promiseId The ID of the promise to resolve
    /// @param returnData The data to resolve the promise with
    function resolve(bytes32 promiseId, bytes memory returnData) external {
        PromiseData storage promiseData = promises[promiseId];
        require(promiseData.status == PromiseStatus.Pending, "Promise: promise already settled");
        require(msg.sender == promiseData.resolver, "Promise: only resolver can resolve");

        promiseData.status = PromiseStatus.Resolved;
        promiseData.returnData = returnData;

        emit PromiseResolved(promiseId, returnData);
    }

    /// @notice Reject a promise with error data
    /// @param promiseId The ID of the promise to reject
    /// @param errorData The error data to reject the promise with
    function reject(bytes32 promiseId, bytes memory errorData) external {
        PromiseData storage promiseData = promises[promiseId];
        require(promiseData.status == PromiseStatus.Pending, "Promise: promise already settled");
        require(msg.sender == promiseData.resolver, "Promise: only resolver can reject");

        promiseData.status = PromiseStatus.Rejected;
        promiseData.returnData = errorData;

        emit PromiseRejected(promiseId, errorData);
    }

    /// @notice Get the status of a promise
    /// @param promiseId The ID of the promise to check
    /// @return promiseStatus The current status of the promise (Pending for non-existent promises)
    function status(bytes32 promiseId) external view returns (PromiseStatus promiseStatus) {
        return promises[promiseId].status;
    }

    /// @notice Get the full promise data
    /// @param promiseId The ID of the promise to get
    /// @return promiseData The complete promise data
    function getPromise(bytes32 promiseId) external view returns (PromiseData memory promiseData) {
        return promises[promiseId];
    }

    /// @notice Check if a promise exists
    /// @param promiseId The ID of the promise to check
    /// @return promiseExists Whether the promise exists
    function exists(bytes32 promiseId) external view returns (bool promiseExists) {
        return promises[promiseId].resolver != address(0);
    }

    /// @notice Get the current nonce (useful for testing)
    /// @return The next nonce that will be assigned
    function getNonce() external view returns (uint256) {
        return nonce;
    }

    /// @notice Share a resolved promise with its current state to another chain
    /// @param destinationChain The chain ID to share the resolved promise with
    /// @param promiseId The ID of the promise to share
    function shareResolvedPromise(uint256 destinationChain, bytes32 promiseId) external {
        require(address(messenger) != address(0), "Promise: cross-chain not enabled");
        require(destinationChain != currentChainId, "Promise: cannot share to same chain");
        
        PromiseData memory promiseData = promises[promiseId];
        require(promiseData.status != PromiseStatus.Pending, "Promise: can only share settled promises");
        
        // Encode the call to receiveSharedPromise
        bytes memory message = abi.encodeWithSignature(
            "receiveSharedPromise(bytes32,uint8,bytes,address)", 
            promiseId, 
            uint8(promiseData.status), 
            promiseData.returnData,
            promiseData.resolver
        );
        
        // Send cross-chain message
        messenger.sendMessage(destinationChain, address(this), message);
        
        emit ResolvedPromiseShared(promiseId, destinationChain);
    }

    /// @notice Transfer resolution rights of a promise to another chain
    /// @param promiseId The ID of the promise to transfer resolution for
    /// @param destinationChain The chain ID to transfer resolution to
    /// @param newResolver The address on the destination chain that can resolve the promise
    function transferResolve(bytes32 promiseId, uint256 destinationChain, address newResolver) external {
        require(address(messenger) != address(0), "Promise: cross-chain not enabled");
        require(destinationChain != currentChainId, "Promise: cannot transfer to same chain");
        
        PromiseData storage promiseData = promises[promiseId];
        require(promiseData.status == PromiseStatus.Pending, "Promise: promise already settled");
        require(msg.sender == promiseData.resolver, "Promise: only resolver can transfer");
        
        // Encode the call to receiveResolverTransfer
        bytes memory message = abi.encodeWithSignature(
            "receiveResolverTransfer(bytes32,address)", 
            promiseId, 
            newResolver
        );
        
        // Send cross-chain message
        messenger.sendMessage(destinationChain, address(this), message);
        
        // Clear local promise data after transfer
        delete promises[promiseId];
        
        emit ResolutionTransferred(promiseId, destinationChain, newResolver);
    }

    /// @notice Receive a shared promise from another chain
    /// @param promiseId The global promise ID
    /// @param promiseStatus The status of the shared promise
    /// @param returnData The return data of the shared promise
    /// @param resolver The resolver address of the shared promise
    function receiveSharedPromise(
        bytes32 promiseId, 
        uint8 promiseStatus, 
        bytes memory returnData,
        address resolver
    ) external {
        // Verify the message comes from another Promise contract via cross-domain messenger
        require(msg.sender == address(messenger), "Promise: only messenger can call");
        require(messenger.crossDomainMessageSender() == address(this), "Promise: only from Promise contract");
        
        // Store the shared promise data
        promises[promiseId] = PromiseData({
            resolver: resolver,
            status: PromiseStatus(promiseStatus),
            returnData: returnData
        });
        
        // Emit appropriate event based on status
        if (PromiseStatus(promiseStatus) == PromiseStatus.Resolved) {
            emit PromiseResolved(promiseId, returnData);
        } else if (PromiseStatus(promiseStatus) == PromiseStatus.Rejected) {
            emit PromiseRejected(promiseId, returnData);
        }
    }

    /// @notice Receive resolver transfer from another chain
    /// @param promiseId The global promise ID
    /// @param newResolver The new resolver address for this chain
    function receiveResolverTransfer(bytes32 promiseId, address newResolver) external {
        // Verify the message comes from another Promise contract via cross-domain messenger
        require(msg.sender == address(messenger), "Promise: only messenger can call");
        require(messenger.crossDomainMessageSender() == address(this), "Promise: only from Promise contract");
        
        // Create or update the promise with the new resolver
        promises[promiseId] = PromiseData({
            resolver: newResolver,
            status: PromiseStatus.Pending,
            returnData: ""
        });
        
        emit PromiseCreated(promiseId, newResolver);
    }
}
