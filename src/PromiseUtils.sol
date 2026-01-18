// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PromiseAll} from "./PromiseAll.sol";

/// @title PromiseUtils
/// @notice Convenience functions for promise aggregation
/// @dev Provides variadic-style helpers to avoid manual array construction
///
/// Example usage:
///   using PromiseUtils for PromiseAll;
///   bytes32 allId = promiseAll.all(p1, p2, p3);
library PromiseUtils {
    /// @notice Create a PromiseAll with 2 promises
    /// @param pa The PromiseAll contract
    /// @param p1 First promise ID
    /// @param p2 Second promise ID
    /// @return promiseAllId The ID of the created PromiseAll
    function all(PromiseAll pa, bytes32 p1, bytes32 p2) internal returns (bytes32) {
        bytes32[] memory arr = new bytes32[](2);
        arr[0] = p1;
        arr[1] = p2;
        return pa.create(arr);
    }

    /// @notice Create a PromiseAll with 3 promises
    /// @param pa The PromiseAll contract
    /// @param p1 First promise ID
    /// @param p2 Second promise ID
    /// @param p3 Third promise ID
    /// @return promiseAllId The ID of the created PromiseAll
    function all(PromiseAll pa, bytes32 p1, bytes32 p2, bytes32 p3) internal returns (bytes32) {
        bytes32[] memory arr = new bytes32[](3);
        arr[0] = p1;
        arr[1] = p2;
        arr[2] = p3;
        return pa.create(arr);
    }

    /// @notice Create a PromiseAll with 4 promises
    /// @param pa The PromiseAll contract
    /// @param p1 First promise ID
    /// @param p2 Second promise ID
    /// @param p3 Third promise ID
    /// @param p4 Fourth promise ID
    /// @return promiseAllId The ID of the created PromiseAll
    function all(PromiseAll pa, bytes32 p1, bytes32 p2, bytes32 p3, bytes32 p4) internal returns (bytes32) {
        bytes32[] memory arr = new bytes32[](4);
        arr[0] = p1;
        arr[1] = p2;
        arr[2] = p3;
        arr[3] = p4;
        return pa.create(arr);
    }

    /// @notice Create a PromiseAll with 5 promises
    /// @param pa The PromiseAll contract
    /// @param p1 First promise ID
    /// @param p2 Second promise ID
    /// @param p3 Third promise ID
    /// @param p4 Fourth promise ID
    /// @param p5 Fifth promise ID
    /// @return promiseAllId The ID of the created PromiseAll
    function all(PromiseAll pa, bytes32 p1, bytes32 p2, bytes32 p3, bytes32 p4, bytes32 p5) internal returns (bytes32) {
        bytes32[] memory arr = new bytes32[](5);
        arr[0] = p1;
        arr[1] = p2;
        arr[2] = p3;
        arr[3] = p4;
        arr[4] = p5;
        return pa.create(arr);
    }
}
