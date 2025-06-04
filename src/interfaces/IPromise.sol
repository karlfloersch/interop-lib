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

    /// @notice invoke continuations present on the completion of a remote message. for now this requires all
    ///         callbacks to be dispatched in a single call. A failing callback will halt the entire process.
    function dispatchCallbacks(Identifier calldata _id, bytes calldata _payload) external payable;

    /// @notice get the context that is being propagated with the promise
    function promiseContext() external view returns (bytes memory);

    /// @notice get the relay identifier that is satisfying the promise
    function promiseRelayIdentifier() external view returns (Identifier memory);
}
