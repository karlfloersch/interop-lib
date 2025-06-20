// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @title Promise
/// @notice Core promise state management contract
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

    /// @notice Event emitted when a new promise is created
    event PromiseCreated(uint256 indexed promiseId, address indexed creator);

    /// @notice Event emitted when a promise is resolved
    event PromiseResolved(uint256 indexed promiseId, bytes returnData);

    /// @notice Event emitted when a promise is rejected
    event PromiseRejected(uint256 indexed promiseId, bytes errorData);

    /// @notice Create a new promise
    /// @return promiseId The unique identifier for the new promise
    function create() external returns (uint256 promiseId) {
        promiseId = nextPromiseId++;
        
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
        require(promiseData.creator != address(0), "Promise: promise does not exist");
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
        require(promiseData.creator != address(0), "Promise: promise does not exist");
        require(promiseData.status == PromiseStatus.Pending, "Promise: promise already settled");
        require(msg.sender == promiseData.creator, "Promise: only creator can reject");

        promiseData.status = PromiseStatus.Rejected;
        promiseData.returnData = errorData;

        emit PromiseRejected(promiseId, errorData);
    }

    /// @notice Get the status of a promise
    /// @param promiseId The ID of the promise to check
    /// @return status The current status of the promise
    function status(uint256 promiseId) external view returns (PromiseStatus status) {
        PromiseData storage promiseData = promises[promiseId];
        require(promiseData.creator != address(0), "Promise: promise does not exist");
        return promiseData.status;
    }

    /// @notice Get the full promise data
    /// @param promiseId The ID of the promise to get
    /// @return promiseData The complete promise data
    function getPromise(uint256 promiseId) external view returns (PromiseData memory promiseData) {
        PromiseData storage storedPromise = promises[promiseId];
        require(storedPromise.creator != address(0), "Promise: promise does not exist");
        return storedPromise;
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
}
