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
        address creator;
        PromiseStatus status;
        bytes returnData;
    }

    /// @notice Promise counter for generating unique IDs
    uint256 private nextPromiseId = 1;

    /// @notice Mapping from promise ID to promise data
    mapping(uint256 => PromiseData) public promises;

    /// @notice Cross-domain messenger for sending cross-chain messages (optional)
    IL2ToL2CrossDomainMessenger public immutable messenger;
    
    /// @notice Current chain ID for generating global promise IDs (optional)
    uint256 public immutable currentChainId;

    /// @notice Event emitted when a new promise is created
    event PromiseCreated(uint256 indexed promiseId, address indexed creator);

    /// @notice Event emitted when a promise is resolved
    event PromiseResolved(uint256 indexed promiseId, bytes returnData);

    /// @notice Event emitted when a promise is rejected
    event PromiseRejected(uint256 indexed promiseId, bytes errorData);

    /// @notice Event emitted when a resolved promise is shared to another chain
    event ResolvedPromiseShared(uint256 indexed promiseId, uint256 indexed destinationChain);

    /// @notice Event emitted when resolution is transferred to another chain
    event ResolutionTransferred(uint256 indexed promiseId, uint256 indexed destinationChain, address indexed newResolver);

    /// @notice Constructor
    /// @param _messenger The cross-domain messenger contract address (use address(0) for local-only mode)
    constructor(address _messenger) {
        messenger = IL2ToL2CrossDomainMessenger(_messenger);
        currentChainId = block.chainid;
    }



    /// @notice Generate a global promise ID from chain ID and local ID
    /// @param chainId The chain ID where the promise was created
    /// @param localPromiseId The local promise ID on that chain
    /// @return globalPromiseId The globally unique promise ID
    function generateGlobalPromiseId(uint256 chainId, uint256 localPromiseId) public pure returns (uint256 globalPromiseId) {
        return uint256(keccak256(abi.encode(chainId, localPromiseId)));
    }

    /// @notice Generate a promise ID using the current chain
    /// @param localPromiseId The local promise ID
    /// @return promiseId The global promise ID for this chain
    function generatePromiseId(uint256 localPromiseId) external view returns (uint256 promiseId) {
        return generateGlobalPromiseId(currentChainId, localPromiseId);
    }

    /// @notice Create a new promise
    /// @return promiseId The unique identifier for the new promise
    function create() external returns (uint256 promiseId) {
        uint256 localPromiseId = nextPromiseId++;
        promiseId = generateGlobalPromiseId(currentChainId, localPromiseId);
        
        promises[promiseId] = PromiseData({
            creator: msg.sender,
            status: PromiseStatus.Pending,
            returnData: ""
        });

        emit PromiseCreated(promiseId, msg.sender);
    }

    /// @notice Resolve a promise with return data
    /// @param promiseId The ID of the promise to resolve
    /// @param returnData The data to resolve the promise with
    function resolve(uint256 promiseId, bytes memory returnData) external {
        PromiseData storage promiseData = promises[promiseId];
        require(promiseData.status == PromiseStatus.Pending, "Promise: promise already settled");
        require(msg.sender == promiseData.creator, "Promise: only creator can resolve");

        promiseData.status = PromiseStatus.Resolved;
        promiseData.returnData = returnData;

        emit PromiseResolved(promiseId, returnData);
    }

    /// @notice Reject a promise with error data
    /// @param promiseId The ID of the promise to reject
    /// @param errorData The error data to reject the promise with
    function reject(uint256 promiseId, bytes memory errorData) external {
        PromiseData storage promiseData = promises[promiseId];
        require(promiseData.status == PromiseStatus.Pending, "Promise: promise already settled");
        require(msg.sender == promiseData.creator, "Promise: only creator can reject");

        promiseData.status = PromiseStatus.Rejected;
        promiseData.returnData = errorData;

        emit PromiseRejected(promiseId, errorData);
    }

    /// @notice Get the status of a promise
    /// @param promiseId The ID of the promise to check
    /// @return status The current status of the promise (Pending for non-existent promises)
    function status(uint256 promiseId) external view returns (PromiseStatus status) {
        return promises[promiseId].status;
    }

    /// @notice Get the full promise data
    /// @param promiseId The ID of the promise to get
    /// @return promiseData The complete promise data
    function getPromise(uint256 promiseId) external view returns (PromiseData memory promiseData) {
        return promises[promiseId];
    }

    /// @notice Check if a promise exists
    /// @param promiseId The ID of the promise to check
    /// @return exists Whether the promise exists
    function exists(uint256 promiseId) external view returns (bool exists) {
        return promises[promiseId].creator != address(0);
    }

    /// @notice Get the current promise counter (useful for testing)
    /// @return The next promise ID that will be assigned
    function getNextPromiseId() external view returns (uint256) {
        return nextPromiseId;
    }

    /// @notice Share a resolved promise with its current state to another chain
    /// @param destinationChain The chain ID to share the resolved promise with
    /// @param promiseId The ID of the promise to share
    function shareResolvedPromise(uint256 destinationChain, uint256 promiseId) external {
        require(address(messenger) != address(0), "Promise: cross-chain not enabled");
        require(destinationChain != currentChainId, "Promise: cannot share to same chain");
        
        PromiseData memory promiseData = promises[promiseId];
        require(promiseData.status != PromiseStatus.Pending, "Promise: can only share settled promises");
        
        // Encode the call to receiveSharedPromise
        bytes memory message = abi.encodeWithSignature(
            "receiveSharedPromise(uint256,uint8,bytes,address)", 
            promiseId, 
            uint8(promiseData.status), 
            promiseData.returnData,
            promiseData.creator
        );
        
        // Send cross-chain message
        messenger.sendMessage(destinationChain, address(this), message);
        
        emit ResolvedPromiseShared(promiseId, destinationChain);
    }

    /// @notice Transfer resolution rights of a promise to another chain
    /// @param promiseId The ID of the promise to transfer resolution for
    /// @param destinationChain The chain ID to transfer resolution to
    /// @param newResolver The address on the destination chain that can resolve the promise
    function transferResolve(uint256 promiseId, uint256 destinationChain, address newResolver) external {
        require(address(messenger) != address(0), "Promise: cross-chain not enabled");
        require(destinationChain != currentChainId, "Promise: cannot transfer to same chain");
        
        PromiseData storage promiseData = promises[promiseId];
        require(promiseData.status == PromiseStatus.Pending, "Promise: promise already settled");
        require(msg.sender == promiseData.creator, "Promise: only creator can transfer");
        
        // Encode the call to receiveResolverTransfer
        bytes memory message = abi.encodeWithSignature(
            "receiveResolverTransfer(uint256,address)", 
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
    /// @param creator The creator address of the shared promise
    function receiveSharedPromise(
        uint256 promiseId, 
        uint8 promiseStatus, 
        bytes memory returnData,
        address creator
    ) external {
        // Verify the message comes from another Promise contract via cross-domain messenger
        require(msg.sender == address(messenger), "Promise: only messenger can call");
        require(messenger.crossDomainMessageSender() == address(this), "Promise: only from Promise contract");
        
        // Store the shared promise data
        promises[promiseId] = PromiseData({
            creator: creator,
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
    function receiveResolverTransfer(uint256 promiseId, address newResolver) external {
        // Verify the message comes from another Promise contract via cross-domain messenger
        require(msg.sender == address(messenger), "Promise: only messenger can call");
        require(messenger.crossDomainMessageSender() == address(this), "Promise: only from Promise contract");
        
        // Create or update the promise with the new resolver
        promises[promiseId] = PromiseData({
            creator: newResolver,
            status: PromiseStatus.Pending,
            returnData: ""
        });
        
        emit PromiseCreated(promiseId, newResolver);
    }
}
