// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Twin} from "./Twin.sol";
import {TwinFactory} from "./TwinFactory.sol";

/// @title TwinRouter
/// @notice User-facing entry point. Deploys a twin (if needed) and delegates to a script.
contract TwinRouter {
    TwinFactory public immutable factory;

    constructor(address _factory) {
        factory = TwinFactory(_factory);
    }

    /// @notice Execute a script as your twin
    /// @param script Address of a contract implementing IScript.run()
    /// @return twin The user's twin address
    function execute(address script) external returns (address twin) {
        twin = factory.getOrDeployTwin(msg.sender);
        Twin(twin).executeScript(script);
    }
}
