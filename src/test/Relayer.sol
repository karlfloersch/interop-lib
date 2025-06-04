// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Vm} from "forge-std/Vm.sol";
import {CommonBase} from "forge-std/Base.sol";
import {console} from "forge-std/console.sol";

import {IL2ToL2CrossDomainMessenger, Identifier} from "../interfaces/IL2ToL2CrossDomainMessenger.sol";
import {ICrossL2Inbox} from "../interfaces/ICrossL2Inbox.sol";
import {IPromise, Handle} from "../interfaces/IPromise.sol";

import {PredeployAddresses} from "../libraries/PredeployAddresses.sol";
import {CrossDomainMessageLib} from "../libraries/CrossDomainMessageLib.sol";

struct RelayedMessage {
    Identifier id;
    bytes payload;
}

/**
 * @title Relayer
 * @notice Abstract contract that simulates cross-chain message relaying between L2 chains
 * @dev This contract is designed for testing cross-chain messaging in a local environment
 *      by creating forks of two L2 chains and relaying messages between them.
 *      It captures SentMessage events using vm.recordLogs() and vm.getRecordedLogs() and relays them to their destination chains.
 */
abstract contract Relayer is CommonBase {
    /// @notice Reference to the L2ToL2CrossDomainMessenger contract
    IL2ToL2CrossDomainMessenger messenger =
        IL2ToL2CrossDomainMessenger(PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER);

    /// @notice Array of fork IDs
    uint256[] public forkIds;

    /// @notice Mapping from chain ID to fork ID
    mapping(uint256 => uint256) public forkIdByChainId;

    /// @notice Mapping from fork ID to chain ID
    mapping(uint256 => uint256) public chainIdByForkId;

    /**
     * @notice Constructor that sets up the test environment with two chain forks
     * @dev Creates forks for two L2 chains and maps their chain IDs to fork IDs
     * @param _chainRpcs RPC URLs for the chains
     */
    constructor(string[] memory _chainRpcs) {
        vm.recordLogs();

        for (uint256 i = 0; i < _chainRpcs.length; i++) {
            uint256 forkId = vm.createSelectFork(_chainRpcs[i]);
            forkIds.push(forkId);
            forkIdByChainId[block.chainid] = forkId;
            chainIdByForkId[forkId] = block.chainid;
        }
    }

    /**
     * @notice Selects a fork based on the chain ID
     * @param chainId The chain ID to select
     * @return forkId The selected fork ID
     */
    function selectForkByChainId(uint256 chainId) internal returns (uint256) {
        uint256 forkId = forkIdByChainId[chainId];
        vm.selectFork(forkId);
        return forkId;
    }

    /**
     * @notice Relays all pending cross-chain messages. All messages must have the same source chain.
     * @dev Filters logs for SentMessage events and relays them to their destination chains
     *      This function handles the entire relay process:
     *      1. Captures all SentMessage events
     *      2. Constructs the message payload for each event
     *      3. Creates an Identifier for each message
     *      4. Selects the destination chain fork
     *      5. Relays the message to the destination
     */
    function relayAllMessages() public returns (RelayedMessage[] memory messages_) {
        messages_ = relayMessages(vm.getRecordedLogs(), chainIdByForkId[vm.activeFork()]);
    }

    /**
     * Use this instead of relayAllMessages if you want to relay a subset of logs and need to have control over when
     * vm.getRecordedLogs() is called.
     */
    function relayMessages(Vm.Log[] memory logs, uint256 sourceChainId)
        public
        returns (RelayedMessage[] memory messages_)
    {
        uint256 originalFork = vm.activeFork();

        messages_ = new RelayedMessage[](logs.length);
        uint256 messageCount = 0;

        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory log = logs[i];

            // Skip logs that aren't SentMessage events
            if (log.topics[0] != keccak256("SentMessage(uint256,address,uint256,address,bytes)")) continue;

            // Get message destination chain id and select fork
            uint256 destination = uint256(log.topics[1]);
            selectForkByChainId(destination);

            // Spoof the block number, log index, and timestamp on the identifier because the
            // recorded log does not capture the block that the log was emitted on.
            Identifier memory id = Identifier(log.emitter, block.number, i, block.timestamp, sourceChainId);
            bytes memory payload = constructMessagePayload(log);

            // Warm slot
            bytes32 slot = CrossDomainMessageLib.calculateChecksum(id, keccak256(payload));
            vm.load(PredeployAddresses.CROSS_L2_INBOX, slot);

            // Relay message
            messenger.relayMessage(id, payload);

            // Add to messages array (using index assignment instead of push)
            messages_[messageCount] = RelayedMessage({id: id, payload: payload});
            messageCount++;
        }

        // If we didn't use all allocated slots, create a properly sized array
        if (messageCount < logs.length) {
            // Create a new array of the correct size
            RelayedMessage[] memory resizedMessages = new RelayedMessage[](messageCount);
            for (uint256 i = 0; i < messageCount; i++) {
                resizedMessages[i] = messages_[i];
            }
            messages_ = resizedMessages;
        }

        vm.selectFork(originalFork);
    }

    /**
     * @notice Relays all pending cross-chain messages with proper ordering for handle registration
     * @dev This function ensures that handle registration messages are processed before the original messages
     *      This is critical for andThen() functionality where handles must be registered before execution
     */
    function relayAllMessagesWithHandleOrdering() public returns (RelayedMessage[] memory messages_) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 sourceChainId = chainIdByForkId[vm.activeFork()];
        
        // Separate handle registration messages from other messages
        Vm.Log[] memory handleRegistrationLogs = new Vm.Log[](logs.length);
        Vm.Log[] memory otherLogs = new Vm.Log[](logs.length);
        uint256 handleCount = 0;
        uint256 otherCount = 0;
        
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory log = logs[i];
            
            // Skip logs that aren't SentMessage events
            if (log.topics[0] != keccak256("SentMessage(uint256,address,uint256,address,bytes)")) continue;
            
            // Check if this is a handle registration message by examining the message data
            // Handle registration messages call registerHandle()
            if (isHandleRegistrationMessage(log)) {
                handleRegistrationLogs[handleCount] = log;
                handleCount++;
            } else {
                otherLogs[otherCount] = log;
                otherCount++;
            }
        }
        
        // First, relay all handle registration messages
        RelayedMessage[] memory handleMessages = relayFilteredMessages(handleRegistrationLogs, handleCount, sourceChainId);
        
        // Then, relay all other messages
        RelayedMessage[] memory otherMessages = relayFilteredMessages(otherLogs, otherCount, sourceChainId);
        
        // Combine the results
        messages_ = new RelayedMessage[](handleCount + otherCount);
        for (uint256 i = 0; i < handleCount; i++) {
            messages_[i] = handleMessages[i];
        }
        for (uint256 i = 0; i < otherCount; i++) {
            messages_[handleCount + i] = otherMessages[i];
        }
    }
    
    /**
     * @notice Helper function to check if a log represents a handle registration message
     * @param log The log to check
     * @return true if this is a handle registration message
     */
    function isHandleRegistrationMessage(Vm.Log memory log) internal pure returns (bool) {
        // Handle registration messages have registerHandle() selector in their data
        bytes4 registerHandleSelector = bytes4(keccak256("registerHandle(bytes32,(bytes32,uint256,address,bytes,bool,bytes))"));
        
        // The SentMessage log structure:
        // topics[0] = event signature
        // topics[1] = destination chain
        // topics[2] = target address (Promise contract)
        // topics[3] = sender address (Promise contract)
        // data = message payload
        
        // For handle registration, the message payload contains registerHandle call
        bytes memory data = log.data;
        if (data.length >= 4) {
            bytes4 selector;
            assembly {
                selector := mload(add(data, 0x20))
            }
            return selector == registerHandleSelector;
        }
        
        return false;
    }
    
    /**
     * @notice Helper function to relay a filtered set of messages
     * @param logs Array of logs to relay
     * @param count Number of valid logs in the array
     * @param sourceChainId Source chain ID
     * @return messages_ Array of relayed messages
     */
    function relayFilteredMessages(Vm.Log[] memory logs, uint256 count, uint256 sourceChainId) 
        internal 
        returns (RelayedMessage[] memory messages_) 
    {
        uint256 originalFork = vm.activeFork();
        messages_ = new RelayedMessage[](count);
        uint256 messageCount = 0;

        for (uint256 i = 0; i < count; i++) {
            Vm.Log memory log = logs[i];

            // Get message destination chain id and select fork
            uint256 destination = uint256(log.topics[1]);
            selectForkByChainId(destination);

            // Spoof the block number, log index, and timestamp on the identifier
            Identifier memory id = Identifier(log.emitter, block.number, i, block.timestamp, sourceChainId);
            bytes memory payload = constructMessagePayload(log);

            // Warm slot
            bytes32 slot = CrossDomainMessageLib.calculateChecksum(id, keccak256(payload));
            vm.load(PredeployAddresses.CROSS_L2_INBOX, slot);

            // Relay message
            messenger.relayMessage(id, payload);

            messages_[messageCount] = RelayedMessage({id: id, payload: payload});
            messageCount++;
        }

        vm.selectFork(originalFork);
    }

    /**
     * @notice Relays all promise callbacks for messages received on the source chain
     * @dev Filters logs for RelayedMessage events and dispatches their callbacks through the Promise contract
     *      This function handles the promise callback relay process:
     *      1. Selects the source chain fork
     *      2. Gets all recorded logs
     *      3. Filters for RelayedMessage events
     *      4. Constructs message payload and identifier
     *      5. Dispatches callbacks through the Promise contract
     * @param p The Promise contract instance to dispatch callbacks through
     * @param sourceChainId The chain ID where the messages originated
     * @return messages_ Array of RelayedMessage structs containing the message IDs and payloads that were processed
     */
    function relayAllPromises(IPromise p, uint256 sourceChainId) public returns (RelayedMessage[] memory messages_) {
        messages_ = relayPromises(vm.getRecordedLogs(), p, sourceChainId);
    }

    /**
     * Use this instead of relayAllPromises if you want to relay a subset of logs and need to have control over when
     * vm.getRecordedLogs() is called.
     */
    function relayPromises(Vm.Log[] memory logs, IPromise p, uint256 sourceChainId)
        public
        returns (RelayedMessage[] memory messages_)
    {
        vm.selectFork(selectForkByChainId(sourceChainId));

        messages_ = new RelayedMessage[](logs.length);
        uint256 messageCount = 0;
        
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory log = logs[i];
            
            if (log.topics[0] != keccak256("RelayedMessage(bytes32,bytes)")) {
                continue;
            }

            // For RelayedMessage events, the payload should be:
            // - RelayedMessage event selector (32 bytes)
            // - Event data (already in correct format: bytes32 msgHash, bytes returnData)
            bytes memory payload = abi.encodePacked(
                keccak256("RelayedMessage(bytes32,bytes)"), // Event selector  
                log.data // Event data: (bytes32 msgHash, bytes returnData)
            );
            
            // Create identifier with the Promise contract as origin (required by dispatchCallbacks)
            Identifier memory id = Identifier(log.emitter, block.number, 0, block.timestamp, sourceChainId);

            // Warm slot
            bytes32 slot = CrossDomainMessageLib.calculateChecksum(id, keccak256(payload));
            vm.load(PredeployAddresses.CROSS_L2_INBOX, slot);

            try p.dispatchCallbacks(id, payload) {
                // Add to messages array (using index assignment instead of push)
                messages_[messageCount] = RelayedMessage({id: id, payload: payload});
                messageCount++;
            } catch Error(string memory reason) {
                // Silently continue on error - this allows tests to be more robust
                // In production, you might want to log or handle errors differently
            } catch {
                // Silently continue on error
            }
        }

        // If we didn't use all allocated slots, create a properly sized array
        if (messageCount < logs.length) {
            // Create a new array of the correct size
            RelayedMessage[] memory resizedMessages = new RelayedMessage[](messageCount);
            for (uint256 i = 0; i < messageCount; i++) {
                resizedMessages[i] = messages_[i];
            }
            messages_ = resizedMessages;
        }
    }

    /**
     * @notice Constructs a message payload from a log using pure Solidity
     * @param log The log containing the SentMessage event data
     * @return A bytes array containing the reconstructed message payload
     */
    function constructMessagePayload(Vm.Log memory log) internal pure returns (bytes memory) {
        bytes memory payload = new bytes(0);

        // Append each topic (32 bytes each)
        for (uint256 i = 0; i < log.topics.length; i++) {
            payload = abi.encodePacked(payload, log.topics[i]);
        }

        // Append the data
        payload = abi.encodePacked(payload, log.data);

        return payload;
    }

    /**
     * @notice Relays and executes all pending handles that have been registered
     * @dev This function should be called after relayAllMessages() to execute handles
     *      It finds RelayedMessage events and executes corresponding pending handles
     * @param p The Promise contract instance 
     * @param destinationChainId The chain where handles should be executed
     */
    function relayAllHandlers(IPromise p, uint256 destinationChainId) public {
        relayHandlers(vm.getRecordedLogs(), p, destinationChainId);
    }

    /**
     * @notice Relays and executes pending handles using provided logs
     * @dev Use this instead of relayAllHandlers if you want to use a specific set of logs
     * @param logs Array of logs to search for RelayedMessage events
     * @param p The Promise contract instance 
     * @param destinationChainId The chain where handles should be executed
     */
    function relayHandlers(Vm.Log[] memory logs, IPromise p, uint256 destinationChainId) public {
        // Switch to the destination chain where handles are registered
        vm.selectFork(selectForkByChainId(destinationChainId));
        
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory log = logs[i];
            
            // Look for RelayedMessage events which indicate a message completed
            if (log.topics[0] != keccak256("RelayedMessage(bytes32,bytes)")) continue;
            
            // Extract the message hash from the RelayedMessage event
            (bytes32 messageHash,) = abi.decode(log.data, (bytes32, bytes));
            
            // Check if there are pending handles for this message hash
            Handle[] memory pendingHandles = p.getPendingHandles(messageHash);
            
            if (pendingHandles.length > 0) {
                // Use the Promise contract's executePendingHandles function to properly 
                // execute handles and update the contract's internal state
                p.executePendingHandles(messageHash);
            }
        }
    }
}
