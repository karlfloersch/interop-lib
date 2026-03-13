// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Twin} from "./Twin.sol";
import {Callback} from "./Callback.sol";
import {Promise} from "./Promise.sol";
import {IL2ToL2CrossDomainMessenger} from "./interfaces/IL2ToL2CrossDomainMessenger.sol";

/// @title TwinFactory
/// @notice CREATE2 factory for deterministic Twin deployment across chains.
///         Must be deployed at the same address on all chains for twins to have consistent addresses.
contract TwinFactory {
    Callback public immutable callbackContract;
    Promise public immutable promiseContract;
    IL2ToL2CrossDomainMessenger public immutable messenger;
    address public immutable owner;

    /// @notice The TwinRouter address (set once after deployment)
    address public router;

    /// @notice Tracks deployed twins
    mapping(address => bool) public isTwin;

    event TwinDeployed(address indexed twin, uint256 indexed originChainId, address indexed originAddress);
    event RouterSet(address router);

    error RouterAlreadySet();
    error NotOwner();

    constructor(address _callbackContract, address _promiseContract, address _messenger) {
        callbackContract = Callback(_callbackContract);
        promiseContract = Promise(_promiseContract);
        messenger = IL2ToL2CrossDomainMessenger(_messenger);
        owner = msg.sender;
    }

    /// @notice Set the router address (can only be called once)
    /// @param _router The TwinRouter contract address
    function setRouter(address _router) external {
        if (msg.sender != owner) revert NotOwner();
        if (router != address(0)) revert RouterAlreadySet();
        router = _router;
        emit RouterSet(_router);
    }

    /// @notice Deploy a twin for originAddress on the current chain (uses block.chainid)
    /// @param originAddress The owner's address
    /// @return twin The twin contract address
    function getOrDeployTwin(address originAddress) external returns (address twin) {
        return deployTwin(block.chainid, originAddress);
    }

    /// @notice Deploy a twin for any origin chain + address combination
    /// @param _originChainId The origin chain ID
    /// @param _originAddress The owner's address on the origin chain
    /// @return twin The twin contract address
    function deployTwin(uint256 _originChainId, address _originAddress) public returns (address twin) {
        twin = computeTwinAddress(_originChainId, _originAddress);

        // Already deployed
        if (twin.code.length > 0) return twin;

        bytes32 salt = keccak256(abi.encode(_originChainId, _originAddress));

        Twin deployed = new Twin{salt: salt}(
            _originChainId,
            _originAddress,
            address(callbackContract),
            address(promiseContract),
            address(messenger)
        );

        twin = address(deployed);
        isTwin[twin] = true;

        emit TwinDeployed(twin, _originChainId, _originAddress);
    }

    /// @notice Compute the deterministic address for a twin
    /// @param _originChainId The origin chain ID
    /// @param _originAddress The owner's address on the origin chain
    /// @return The twin's address (same on all chains where factory is at the same address)
    function computeTwinAddress(uint256 _originChainId, address _originAddress)
        public
        view
        returns (address)
    {
        bytes32 salt = keccak256(abi.encode(_originChainId, _originAddress));
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(Twin).creationCode,
                abi.encode(
                    _originChainId,
                    _originAddress,
                    address(callbackContract),
                    address(promiseContract),
                    address(messenger)
                )
            )
        );

        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)
                    )
                )
            )
        );
    }
}
