// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PredeployAddresses} from "./PredeployAddresses.sol";
import {IL2ToL2CrossDomainMessenger} from "../interfaces/IL2ToL2CrossDomainMessenger.sol";
import {Identifier} from "../interfaces/IIdentifier.sol";

library CrossDomainMessageLib {
    /// @notice Thrown when trying to validate a cross chain message with a block number
    ///         that is greater than 2^64.
    error BlockNumberTooHigh();

    /// @notice Thrown when trying to validate a cross chain message with a timestamp
    ///         that is greater than 2^64.
    error TimestampTooHigh();

    /// @notice Thrown when trying to validate a cross chain message with a log index
    ///         that is greater than 2^32.
    error LogIndexTooHigh();
    /// @notice The error emitted when a required message has not been relayed.
    error RequiredMessageNotSuccessful(bytes32 msgHash);
    /// @notice The error emitted when the caller is not the L2toL2CrossDomainMessenger.
    error CallerNotL2toL2CrossDomainMessenger();
    /// @notice The error emitted when the original sender of the cross-domain message is not this same address as this contract.
    error InvalidCrossDomainSender();

    /// @notice The mask for the most significant bits of the checksum.
    /// @dev    Used to set the most significant byte to zero.
    bytes32 internal constant _MSB_MASK = bytes32(~uint256(0xff << 248));

    /// @notice Mask used to set the first byte of the bare checksum to 3 (0x03).
    bytes32 internal constant _TYPE_3_MASK = bytes32(uint256(0x03 << 248));

    /// @notice Checks if the msgHash has been relayed and reverts with a special error signature
    /// that the auto-relayer performs special handling on if the msgHash has not been relayed.
    /// If the auto-relayer encounters this error, it will parse the msgHash and wait for the
    /// msgHash to be relayed before relaying the message that calls this function. This ensures
    /// that any required message is relayed before the message that depends on it.
    /// @param msgHash The hash of the message to check if it has been relayed.
    function requireMessageSuccess(bytes32 msgHash) internal view {
        if (
            !IL2ToL2CrossDomainMessenger(PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER).successfulMessages(msgHash)
        ) {
            revert RequiredMessageNotSuccessful(msgHash);
        }
    }

    /// @notice Checks if the caller is the L2toL2CrossDomainMessenger. It is important to use this check
    /// on cross-domain messages that should only be relayed through the L2toL2CrossDomainMessenger.
    function requireCallerIsCrossDomainMessenger() internal view {
        if (msg.sender != address(PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER)) {
            revert CallerNotL2toL2CrossDomainMessenger();
        }
    }

    /// @notice While relaying a message through the L2toL2CrossDomainMessenger, checks
    /// that the original sender of the cross-domain message is this same address.
    /// It is important to use this check on cross-domain messages that should only be
    /// sent and relayed by the same contract on different chains.
    function requireCrossDomainCallback() internal view {
        requireCallerIsCrossDomainMessenger();

        if (
            IL2ToL2CrossDomainMessenger(PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER).crossDomainMessageSender()
                != address(this)
        ) revert InvalidCrossDomainSender();
    }

    /// @notice Calculates a custom checksum for a cross chain message `Identifier` and `msgHash`.
    /// @param _id The identifier of the message.
    /// @param _msgHash The hash of the message.
    /// @return checksum_ The checksum of the message.
    function calculateChecksum(Identifier memory _id, bytes32 _msgHash) public pure returns (bytes32 checksum_) {
        if (_id.blockNumber > type(uint64).max) revert BlockNumberTooHigh();
        if (_id.logIndex > type(uint32).max) revert LogIndexTooHigh();
        if (_id.timestamp > type(uint64).max) revert TimestampTooHigh();

        // Hash the origin address and message hash together
        bytes32 logHash = keccak256(abi.encode(_id.origin, _msgHash));

        // Downsize the identifier fields to match the needed type for the custom checksum calculation.
        uint64 blockNumber = uint64(_id.blockNumber);
        uint64 timestamp = uint64(_id.timestamp);
        uint32 logIndex = uint32(_id.logIndex);

        // Pack identifier fields with a left zero padding (uint96(0))
        bytes32 idPacked = bytes32(abi.encodePacked(uint96(0), blockNumber, timestamp, logIndex));

        // Hash the logHash with the packed identifier data
        bytes32 idLogHash = keccak256(abi.encode(logHash, idPacked));

        // Create the final hash by combining idLogHash with chainId
        bytes32 bareChecksum = keccak256(abi.encode(idLogHash, _id.chainId));

        // Apply bit masking to create the final checksum
        checksum_ = (bareChecksum & _MSB_MASK) | _TYPE_3_MASK;
    }
}
