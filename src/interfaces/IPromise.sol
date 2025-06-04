// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Identifier} from "./IIdentifier.sol";

/// @notice a struct to represent a callback to be executed when the return value of
///         a sent message is captured.
struct Callback {
    address target;
    bytes4 selector;
    bytes context;
}

/// @notice Handle representing a promise that executes on the destination chain
struct Handle {
    bytes32 messageHash;
    uint256 destinationChain;
    address target;
    bytes message;
    bool completed;
    bytes returnData;
    bytes32 nestedPromiseHash; // Points to a nested promise if this handle returns a promise
}

interface IPromise {
    /// @notice Get the callbacks registered for a message hash
    /// @param messageHash The hash of the message
    /// @return The array of callbacks registered for the message hash
    function callbacks(bytes32 messageHash) external view returns (Callback[] memory);

    /// @notice an event emitted when a callback is registered
    event CallbackRegistered(bytes32 messageHash);

    /// @notice an event emitted when all callbacks for a message are dispatched
    event CallbacksCompleted(bytes32 messageHash);

    /// @notice an event emitted when a message is relayed
    event RelayedMessage(bytes32 messageHash, bytes returnData);

    /// @notice an event emitted when a handle is created for destination-side execution
    event HandleCreated(bytes32 messageHash, uint256 destinationChain);

    /// @notice an event emitted when a handle is completed with return data
    event HandleCompleted(bytes32 handleHash, bytes returnData);

    /// @notice an event emitted when a handle creates a nested promise
    event NestedPromiseCreated(bytes32 parentHandleHash, bytes32 nestedPromiseHash);

    /// @notice an event emitted when a nested promise chain is resolved
    event NestedPromiseResolved(bytes32 rootPromiseHash, bytes32 finalValue);

    /// @notice send a message to the destination contract capturing the return value. this cannot call
    ///         contracts that rely on the L2ToL2CrossDomainMessenger, such as the SuperchainTokenBridge.
    function sendMessage(uint256 _destination, address _target, bytes calldata _message) external returns (bytes32);

    /// @dev handler to dispatch and emit the return value of a message
    function handleMessage(uint256 _nonce, address _target, bytes calldata _message) external;

    /// @notice attach a continuation dependent only on the return value of the remote message
    function then(bytes32 _msgHash, bytes4 _selector) external;

    /// @notice attach a continuation dependent on the return value and some additional saved context
    function then(bytes32 _msgHash, bytes4 _selector, bytes calldata _context) external;

    /// @notice attach a destination-side continuation that executes on the destination chain
    /// @param _msgHash The message hash to attach the destination callback to
    /// @param _target The contract to call on the destination chain
    /// @param _message The message to send to the destination contract
    /// @return handle A handle representing the destination-side promise
    function andThen(bytes32 _msgHash, address _target, bytes calldata _message) external returns (Handle memory);

    /// @notice get a handle by its message hash
    /// @param _handleHash The hash of the handle to retrieve
    /// @return handle The handle struct
    function getHandle(bytes32 _handleHash) external view returns (Handle memory);

    /// @notice check if a handle is completed
    /// @param _handleHash The hash of the handle to check
    /// @return completed Whether the handle is completed
    function isHandleCompleted(bytes32 _handleHash) external view returns (bool);

    /// @notice get pending handles for a message hash
    /// @param _msgHash The message hash to get pending handles for
    /// @return handles Array of pending handles
    function getPendingHandles(bytes32 _msgHash) external view returns (Handle[] memory);

    /// @notice Manually execute all pending handles for a specific message hash
    /// @dev This is a helper function for testing to execute handles after they've been registered
    /// @param _messageHash The message hash to execute handles for
    function executePendingHandles(bytes32 _messageHash) external;

    /// @notice invoke continuations present on the completion of a remote message. for now this requires all
    ///         callbacks to be dispatched in a single call. A failing callback will halt the entire process.
    function dispatchCallbacks(Identifier calldata _id, bytes calldata _payload) external payable;

    /// @notice get the context that is being propagated with the promise
    function promiseContext() external view returns (bytes memory);

    /// @notice get the relay identifier that is satisfying the promise
    function promiseRelayIdentifier() external view returns (Identifier memory);

    /// @notice Check if a handle's return data represents a nested promise
    /// @param _handleHash The hash of the handle to check
    /// @return isNested Whether the handle contains a nested promise
    /// @return nestedPromiseHash The hash of the nested promise if it exists
    function getNestedPromise(bytes32 _handleHash) external view returns (bool isNested, bytes32 nestedPromiseHash);

    /// @notice Resolve a nested promise chain by following promise links
    /// @param _rootPromiseHash The starting promise hash
    /// @return resolved Whether the chain is fully resolved  
    /// @return finalReturnData The final return data from the resolved chain
    function resolveNestedPromise(bytes32 _rootPromiseHash) external view returns (bool resolved, bytes memory finalReturnData);

    /// @notice Chain another promise to execute after this handle completes
    /// @dev This creates a nested promise relationship where the new promise depends on this handle's completion
    /// @param _handleHash The handle to chain from
    /// @param _destination The destination chain for the new promise
    /// @param _target The target contract for the new promise  
    /// @param _message The message for the new promise
    /// @return nestedPromiseHash The hash of the newly created nested promise
    function chainPromise(bytes32 _handleHash, uint256 _destination, address _target, bytes calldata _message) external returns (bytes32 nestedPromiseHash);

    /// @notice Check if a promise is fully resolved (no more nested promises)
    /// @param _promiseHash The promise hash to check
    /// @return resolved Whether the promise is fully resolved
    function isPromiseResolved(bytes32 _promiseHash) external view returns (bool);

    /// @notice Automatically track a child promise if called during promise execution
    /// @dev Called by PromiseAwareMessenger to automatically track child promises
    /// @param childPromiseHash The hash of the child promise to track
    function autoTrackChildPromise(bytes32 childPromiseHash) external;

    /// @notice Check if we're currently in promise execution context
    /// @dev Used by PromiseAwareMessenger to determine if tracking is needed
    /// @return inContext Whether we're currently executing within a promise
    function inPromiseExecutionContext() external view returns (bool);

    /// @notice Get the current promise context
    /// @dev Used for debugging and testing
    /// @return contextHash The current promise being executed
    function getCurrentPromiseContext() external view returns (bytes32);
}
