// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Twin} from "./Twin.sol";
import {TwinFactory} from "./TwinFactory.sol";
import {CallbackGasTank} from "./CallbackGasTank.sol";

/// @title TwinRouter
/// @notice User-facing entry point. Deploys a twin (if needed) and delegates to a script.
contract TwinRouter {
    TwinFactory public immutable factory;
    CallbackGasTank public immutable gasTank;

    constructor(address _factory, address _gasTank) {
        factory = TwinFactory(_factory);
        gasTank = CallbackGasTank(_gasTank);
    }

    /// @notice Execute a script as your twin
    /// @param script Address of a contract implementing IScript.run()
    /// @return twin The user's twin address
    function execute(address script) external payable returns (address twin) {
        twin = factory.getOrDeployTwin(msg.sender);
        if (msg.value != 0) {
            gasTank.deposit{value: msg.value}(twin);
        }
        Twin(twin).executeScript(script);
    }
}
