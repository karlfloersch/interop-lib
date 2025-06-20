// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Promise} from "./Promise.sol";

/// @title SetTimeout
/// @notice Time-based promise contract that resolves promises after a specified timestamp
contract SetTimeout {
    /// @notice The Promise contract instance
    Promise public immutable promiseContract;

    /// @notice Mapping from promise ID to target timestamp
    mapping(uint256 => uint256) public timeouts;

    /// @notice Event emitted when a timeout promise is created
    event TimeoutCreated(uint256 indexed promiseId, uint256 timestamp);

    /// @notice Event emitted when a timeout promise is resolved
    event TimeoutResolved(uint256 indexed promiseId, uint256 timestamp);

    /// @param _promiseContract The address of the Promise contract
    constructor(address _promiseContract) {
        promiseContract = Promise(_promiseContract);
    }

    /// @notice Create a new timeout promise that resolves after the specified timestamp
    /// @param timestamp The timestamp after which the promise can be resolved
    /// @return promiseId The ID of the created promise
    function create(uint256 timestamp) external returns (uint256 promiseId) {
        require(timestamp > block.timestamp, "SetTimeout: timestamp must be in the future");
        
        // Create a promise via the Promise contract
        promiseId = promiseContract.create();
        
        // Store the timeout mapping
        timeouts[promiseId] = timestamp;
        
        emit TimeoutCreated(promiseId, timestamp);
    }

    /// @notice Resolve a timeout promise if the timestamp has passed
    /// @param promiseId The ID of the promise to resolve
    function resolve(uint256 promiseId) external {
        uint256 targetTimestamp = timeouts[promiseId];
        require(targetTimestamp != 0, "SetTimeout: promise does not exist");
        require(block.timestamp >= targetTimestamp, "SetTimeout: timeout not reached");
        
        // Check that the promise is still pending
        Promise.PromiseStatus status = promiseContract.status(promiseId);
        require(status == Promise.PromiseStatus.Pending, "SetTimeout: promise already settled");
        
        // Resolve the promise with empty data (timeouts don't return values)
        promiseContract.resolve(promiseId, "");
        
        // Clean up storage
        delete timeouts[promiseId];
        
        emit TimeoutResolved(promiseId, targetTimestamp);
    }

    /// @notice Check if a timeout promise can be resolved
    /// @param promiseId The ID of the promise to check
    /// @return canResolve Whether the promise can be resolved now
    function canResolve(uint256 promiseId) external view returns (bool canResolve) {
        uint256 targetTimestamp = timeouts[promiseId];
        if (targetTimestamp == 0) return false;
        
        Promise.PromiseStatus status = promiseContract.status(promiseId);
        if (status != Promise.PromiseStatus.Pending) return false;
        
        return block.timestamp >= targetTimestamp;
    }

    /// @notice Get the target timestamp for a timeout promise
    /// @param promiseId The ID of the promise
    /// @return timestamp The target timestamp, or 0 if promise doesn't exist
    function getTimeout(uint256 promiseId) external view returns (uint256 timestamp) {
        return timeouts[promiseId];
    }

    /// @notice Get the remaining time until a timeout promise can be resolved
    /// @param promiseId The ID of the promise
    /// @return remainingTime The remaining time in seconds, or 0 if can be resolved now
    function getRemainingTime(uint256 promiseId) external view returns (uint256 remainingTime) {
        uint256 targetTimestamp = timeouts[promiseId];
        if (targetTimestamp == 0) return 0;
        
        if (block.timestamp >= targetTimestamp) {
            return 0;
        } else {
            return targetTimestamp - block.timestamp;
        }
    }
} 