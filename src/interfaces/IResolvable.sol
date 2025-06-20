// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @title IResolvable
/// @notice Interface for contracts that can resolve promises
interface IResolvable {
    /// @notice Check if a promise can be resolved by this contract
    /// @param promiseId The ID of the promise to check
    /// @return canResolve Whether the promise can be resolved now
    function canResolve(uint256 promiseId) external view returns (bool canResolve);

    /// @notice Resolve a promise managed by this contract
    /// @param promiseId The ID of the promise to resolve
    function resolve(uint256 promiseId) external;
} 