// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IScript
/// @notice Interface for script contracts that run inside a Twin via delegatecall
interface IScript {
    function run() external;
}
