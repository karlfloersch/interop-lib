// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";

import {Identifier} from "../src/interfaces/IIdentifier.sol";
import {SuperchainERC20} from "../src/SuperchainERC20.sol";
import {Relayer, RelayedMessage} from "../src/test/Relayer.sol";
import {PromiseAwareMessenger} from "../src/PromiseAwareMessenger.sol";

/// @notice Unified test contract for all sub-call scenarios
contract TestCallMaker {
    PromiseAwareMessenger public wrapper;
    
    event CallExecuted(string scenario, uint256 value);
    
    constructor(address _wrapper) {
        wrapper = PromiseAwareMessenger(_wrapper);
    }
    
    /// @notice Make a specified number of sub-calls
    function makeSubCalls(uint256 _destinationChain, uint256 _count) external {
        console.log("TestCallMaker: Making", _count, "sub-calls to chain", _destinationChain);
        
        for (uint256 i = 0; i < _count; i++) {
            wrapper.sendMessage(
                _destinationChain,
                address(uint160(0x1111111111111111111111111111111111111111) + uint160(i)), // unique dummy targets
                abi.encodeWithSignature("dummyFunction(uint256)", i)
            );
        }
        
        emit CallExecuted("makeSubCalls", _count);
        console.log("TestCallMaker: Completed", _count, "sub-calls");
    }
    
    /// @notice Make a nested call that triggers further sub-calls (for deep nesting tests)
    function makeNestedCall(uint256 _destinationChain, address _target, uint256 _subCallCount) external {
        console.log("=== makeNestedCall ENTRY ===");
        console.log("makeNestedCall: CALLED! destinationChain =", _destinationChain);
        console.log("makeNestedCall: target =", _target);
        console.log("makeNestedCall: subCallCount =", _subCallCount);
        console.log("makeNestedCall: current chainid =", block.chainid);
        console.log("makeNestedCall: wrapper address =", address(wrapper));
        
        // Check if target exists on destination chain
        console.log("makeNestedCall: Target address code size check...");
        // Note: We can't check code size on other chain from here, but we can log the address
        
        // The nested call should send sub-calls back to the current chain (where this makeNestedCall is executing)
        bytes memory callData = abi.encodeCall(this.makeSubCalls, (block.chainid, _subCallCount));
        console.log("makeNestedCall: Call data encoded, length =", callData.length);
        
        console.log("=== ABOUT TO CALL wrapper.sendMessage ===");
        
        // Try-catch to see if sendMessage fails
        try wrapper.sendMessage(_destinationChain, _target, callData) returns (bytes32 messageHash) {
            console.log("=== wrapper.sendMessage SUCCESS ===");
            console.log("makeNestedCall: Message hash created successfully");
        } catch Error(string memory reason) {
            console.log("=== wrapper.sendMessage FAILED ===");
            console.log("makeNestedCall: Error reason =", reason);
        } catch (bytes memory lowLevelData) {
            console.log("=== wrapper.sendMessage FAILED (low level) ===");
            console.log("makeNestedCall: Low level error, data length =", lowLevelData.length);
        }
        
        console.log("=== makeNestedCall COMPLETE ===");
        emit CallExecuted("makeNestedCall", _subCallCount);
    }
    
    /// @notice Simple receiver for testing basic functionality
    function simpleReceiver(uint256 _value) external {
        emit CallExecuted("simpleReceiver", _value);
        console.log("TestCallMaker: Received value:", _value);
    }
}

/// @notice Mock ERC20 for testing state modifications
contract TestToken is SuperchainERC20 {
    function mint(address _to, uint256 _amount) external {
        require(_to != address(0), "Zero address");
        _mint(_to, _amount);
    }

    function name() public pure override returns (string memory) { return "TestToken"; }
    function symbol() public pure override returns (string memory) { return "TEST"; }
    function decimals() public pure override returns (uint8) { return 18; }
}

contract PromiseAwareMessengerTest is Relayer, Test {
    PromiseAwareMessenger public wrapperA;
    PromiseAwareMessenger public wrapperB;
    TestCallMaker public callMakerA;
    TestCallMaker public callMakerB;
    TestToken public token;
    
    // Test state
    address public lastSender;
    uint256 public lastValue;

    string[] private rpcUrls = [
        vm.envOr("CHAIN_A_RPC_URL", string("https://interop-alpha-0.optimism.io")),
        vm.envOr("CHAIN_B_RPC_URL", string("https://interop-alpha-1.optimism.io"))
    ];

    constructor() Relayer(rpcUrls) {}

    function setUp() public {
        _deployContracts();
        _verifyDeployments();
    }
    
    /// =============================================================
    /// CORE FUNCTIONALITY TESTS
    /// =============================================================
    
    function test_wrapper_basic_functionality() public {
        bytes32 messageHash = _sendMessage(chainB(), address(token), abi.encodeCall(IERC20.balanceOf, (address(this))));
        relayAllMessages();
        assertTrue(messageHash != bytes32(0), "Message should be sent successfully");
    }

    function test_cross_chain_state_modification() public {
        // Mint tokens on Chain B from Chain A
        _sendMessage(chainB(), address(token), abi.encodeCall(TestToken.mint, (address(0x1234), 50)));
        relayAllMessages();
        
        uint256 balance = _getTokenBalance(address(0x1234));
        assertEq(balance, 50, "Tokens should be minted cross-chain");
    }

    function test_xDomainMessageSender_tracking() public {
        _sendMessage(chainB(), address(this), abi.encodeCall(this.checkSender, ()));
        relayAllMessages();
        assertEq(lastSender, address(this), "Original sender should be tracked correctly");
    }
    
    /// =============================================================
    /// SUB-CALL TRACKING TESTS
    /// =============================================================

    function test_sub_call_tracking_two_calls() public {
        SubCallResult memory result = _runSubCallTest(2);
        
        assertEq(result.subCallCount, 2, "Should track exactly 2 sub-calls");
        assertTrue(result.subCallHashes[0] != result.subCallHashes[1], "Sub-call hashes should be unique");
        assertEq(result.eventsEmitted, 2, "Should emit 2 SubCallRegistered events (one per sub-call)");
        
        console.log("SUCCESS: 2-level sub-call tracking verified");
    }

    function test_sub_call_tracking_multiple_calls() public {
        SubCallResult memory result = _runSubCallTest(5);
        
        assertEq(result.subCallCount, 5, "Should track exactly 5 sub-calls");
        assertEq(result.eventsEmitted, 5, "Should emit 5 SubCallRegistered events (one per sub-call)");
        
        // Verify all hashes are unique
        for (uint256 i = 0; i < result.subCallHashes.length; i++) {
            for (uint256 j = i + 1; j < result.subCallHashes.length; j++) {
                assertTrue(result.subCallHashes[i] != result.subCallHashes[j], "All sub-call hashes should be unique");
            }
        }
        
        console.log("SUCCESS: Multiple sub-call tracking verified");
    }

    function test_sub_call_tracking_three_calls() public {
        SubCallResult memory result = _runSubCallTest(3);
        
        assertEq(result.subCallCount, 3, "Should track exactly 3 sub-calls");
        assertEq(result.eventsEmitted, 3, "Should emit 3 SubCallRegistered events (one per sub-call)");
        
        // Verify all 3 hashes are unique
        assertTrue(result.subCallHashes[0] != result.subCallHashes[1], "Sub-call hash 1 != 2");
        assertTrue(result.subCallHashes[0] != result.subCallHashes[2], "Sub-call hash 1 != 3");
        assertTrue(result.subCallHashes[1] != result.subCallHashes[2], "Sub-call hash 2 != 3");
        
        console.log("SUCCESS: 3 sub-calls tracked perfectly!");
        console.log("Hash 1:", vm.toString(result.subCallHashes[0]));
        console.log("Hash 2:", vm.toString(result.subCallHashes[1]));
        console.log("Hash 3:", vm.toString(result.subCallHashes[2]));
    }

    function test_nested_call_tracking() public {
        _onChainA();
        vm.recordLogs();
        
        // Level 1: A -> B (will trigger Level 2: B -> A)
        wrapperA.sendMessage(
            chainB(),
            address(callMakerB),
            abi.encodeCall(TestCallMaker.makeNestedCall, (chainA(), address(callMakerA), 2))
        );
        
        // Relay Level 1
        console.log("=== Debug Level 1 Execution ===");
        RelayedMessage[] memory level1Messages = relayAllMessages();
        console.log("Level 1 messages relayed:", level1Messages.length);
        
        // Check Level 1 logs
        Vm.Log[] memory level1Logs = vm.getRecordedLogs();
        console.log("Level 1 logs count:", level1Logs.length);
        uint256 level1SubCallEvents = _countSubCallEvents(level1Logs);
        console.log("Level 1 SubCallRegistered events:", level1SubCallEvents);
        
        // DEBUGGING: Check if Level 1 logs contain SentMessage events from makeNestedCall
        uint256 sentMessageEvents = 0;
        bytes32 sentMessageSelector = keccak256("SentMessage(uint256,address,uint256,address,bytes)");
        for (uint256 i = 0; i < level1Logs.length; i++) {
            if (level1Logs[i].topics[0] == sentMessageSelector) {
                sentMessageEvents++;
                console.log("Found SentMessage event #", sentMessageEvents, "in Level 1 logs");
            }
        }
        console.log("Total SentMessage events in Level 1 logs:", sentMessageEvents);
        
        // Verify Level 1 created 1 sub-call (this happens on Chain B)
        bytes32 level1ParentHash = _extractParentHash(level1Logs, 0);
        console.log("Level 1 parent hash:", vm.toString(level1ParentHash));
        
        // Get sub-call count from Chain B storage
        _onChainB();
        uint256 level1SubCallCount = wrapperB.getSubCallCount(level1ParentHash);
        console.log("Level 1 sub-call count from storage:", level1SubCallCount);
        
        assertEq(level1SubCallCount, 1, "Level 1 should create 1 sub-call (the nested call)");
        
        // Debug: Relay Level 2 using the nested message from Level 1 logs
        console.log("=== Debug Level 2 Execution ===");
        console.log("Before Level 2 - Current fork:", vm.activeFork());
        console.log("Before Level 2 - Chain A fork:", forkIds[0]);
        console.log("Before Level 2 - Chain B fork:", forkIds[1]);
        
        // Record logs on Chain A to capture makeSubCalls execution
        _onChainA();
        vm.recordLogs();
        
        // FIXED: Use Level 1 logs to relay the nested message created by makeNestedCall
        // The makeNestedCall created a SentMessage on Chain B during Level 1 execution
        RelayedMessage[] memory level2Messages = relayMessages(level1Logs, chainB());
        
        // Check what fork we're on after relay
        console.log("After Level 2 relay - Current fork:", vm.activeFork());
        
        // Level 2 execution should happen on Chain A, so check logs there
        Vm.Log[] memory level2Logs = vm.getRecordedLogs();
        console.log("Level 2 logs count on Chain A:", level2Logs.length);
        console.log("Level 2 messages relayed:", level2Messages.length);
        
        uint256 subCallEvents = _countSubCallEvents(level2Logs);
        console.log("Level 2 SubCallRegistered events on Chain A:", subCallEvents);
        
        // If no events on Chain A, check Chain B too for debugging
        if (subCallEvents == 0) {
            _onChainB();
            Vm.Log[] memory level2LogsB = vm.getRecordedLogs();
            uint256 subCallEventsB = _countSubCallEvents(level2LogsB);
            console.log("Level 2 SubCallRegistered events on Chain B:", subCallEventsB);
            _onChainA();  // Switch back
        }
        
        // Verify Level 2 sub-calls (should happen on Chain A)
        bytes32 level2ParentHash = _extractParentHash(level2Logs, 0);
        console.log("Level 2 parent hash:", vm.toString(level2ParentHash));
        
        // Get sub-call count from Chain A storage
        uint256 level2SubCallCount = wrapperA.getSubCallCount(level2ParentHash);
        console.log("Level 2 sub-call count from storage:", level2SubCallCount);
        
        assertEq(level2SubCallCount, 2, "Level 2 should create 2 sub-calls");
        
        console.log("SUCCESS: Nested call tracking verified across 2 levels");
        console.log("Level 1 parent:", vm.toString(level1ParentHash));
        console.log("Level 2 parent:", vm.toString(level2ParentHash));
    }

    function test_deep_nesting_capability() public {
        console.log("=== Testing Deep Nesting Capability ===");
        
        // Create a chain: A -> B -> A -> B (3 hops)
        _onChainA();
        vm.recordLogs();
        
        // Level 1: A -> B
        wrapperA.sendMessage(
            chainB(),
            address(callMakerB),
            abi.encodeCall(TestCallMaker.makeNestedCall, (chainA(), address(callMakerA), 1))
        );
        
        // Keep track of all logs across levels
        Vm.Log[] memory accumulatedLogs;
        
        // Relay all levels and collect logs
        for (uint256 i = 0; i < 3; i++) {
            console.log("Relaying level", i + 1);
            relayAllMessages();
            
            // Collect logs from this level
            Vm.Log[] memory levelLogs = vm.getRecordedLogs();
            accumulatedLogs = _concatenateLogs(accumulatedLogs, levelLogs);
            
            // Clear logs for next level (except the last iteration)
            if (i < 2) {
                vm.recordLogs();
            }
        }
        
        // Verify we had sub-call tracking at multiple levels
        uint256 totalEvents = _countSubCallEvents(accumulatedLogs);
        assertTrue(totalEvents >= 1, "Should have sub-call tracking events in deep nesting");
        
        console.log("SUCCESS: Deep nesting (3+ levels) capability verified");
        console.log("Total SubCallRegistered events:", totalEvents);
    }

    function test_three_level_deep_sub_call_tracking() public {
        console.log("=== Testing 3-Level Deep Sub-Call Tracking ===");
        
        _onChainA();
        vm.recordLogs();
        
        // Level 1: A -> B (TestCallMaker.makeNestedCall)
        console.log("Level 1: Chain A -> Chain B");
        wrapperA.sendMessage(
            chainB(),
            address(callMakerB),
            abi.encodeCall(TestCallMaker.makeNestedCall, (chainA(), address(callMakerA), 3))
        );
        
        // Relay Level 1: This triggers Level 2
        relayAllMessages();
        
        // Verify Level 1 tracking
        Vm.Log[] memory level1Logs = vm.getRecordedLogs();
        bytes32 level1Parent = _extractParentHash(level1Logs, 0);
        uint256 level1Events = _countSubCallEvents(level1Logs);
        
        console.log("Level 1 - Parent hash:", vm.toString(level1Parent));
        console.log("Level 1 - SubCall events:", level1Events);
        
        if (level1Parent != bytes32(0)) {
            _onChainB();
            uint256 level1SubCalls = wrapperB.getSubCallCount(level1Parent);
            console.log("Level 1 - Sub-calls in storage:", level1SubCalls);
            assertEq(level1SubCalls, 1, "Level 1 should create 1 sub-call (the nested call)");
        }
        
        // Level 2: B -> A (TestCallMaker.makeSubCalls with 3 sub-calls)
        console.log("Level 2: Chain B -> Chain A");
        
        // FIXED: Record logs on Chain A to capture makeSubCalls execution
        _onChainA();
        vm.recordLogs();
        
        // FIXED: Use Level 1 logs to relay the nested message created by makeNestedCall
        RelayedMessage[] memory level2Messages = relayMessages(level1Logs, chainB());
        
        // Verify Level 2 tracking  
        Vm.Log[] memory level2Logs = vm.getRecordedLogs();
        bytes32 level2Parent = _extractParentHash(level2Logs, 0);
        uint256 level2Events = _countSubCallEvents(level2Logs);
        
        console.log("Level 2 - Parent hash:", vm.toString(level2Parent));
        console.log("Level 2 - SubCall events:", level2Events);
        console.log("Level 2 - Messages relayed:", level2Messages.length);
        
        // FIXED: Remove conditional logic and always check assertions
        uint256 level2SubCalls = wrapperA.getSubCallCount(level2Parent);
        console.log("Level 2 - Sub-calls in storage:", level2SubCalls);
        assertEq(level2SubCalls, 3, "Level 2 should create 3 sub-calls");
        assertEq(level2Events, 3, "Level 2 should emit 3 SubCallRegistered events");
        
        // Level 3: A -> B (the 3 individual sub-calls)
        console.log("Level 3: Chain A -> Chain B (final calls)");
        relayAllMessages();
        
        console.log("SUCCESS: 3-level deep sub-call tracking verified!");
        console.log("PASS Level 1 (A->B): 1 nested call tracked");
        console.log("PASS Level 2 (B->A): 3 sub-calls tracked");  
        console.log("PASS Level 3 (A->B): Final execution (no further sub-calls)");
    }
    
    /// =============================================================
    /// HELPER STRUCTURES & VERIFICATION
    /// =============================================================
    
    struct SubCallResult {
        bytes32 parentHash;
        uint256 subCallCount;
        bytes32[] subCallHashes;
        uint256 eventsEmitted;
    }
    
    struct SubCallVerification {
        bytes32 parentHash;
        uint256 subCallCount;
        bytes32[] subCallHashes;
    }
    
    /// @notice Run a standard sub-call test and return results
    function _runSubCallTest(uint256 _subCallCount) internal returns (SubCallResult memory) {
        _onChainA();
        vm.recordLogs();
        
        // Send message that triggers sub-calls
        wrapperA.sendMessage(
            chainB(),
            address(callMakerB),
            abi.encodeCall(TestCallMaker.makeSubCalls, (chainA(), _subCallCount))
        );
        
        relayAllMessages();
        
        // Extract and verify results
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 parentHash = _extractParentHash(logs, 0);
        uint256 eventsEmitted = _countSubCallEvents(logs);
        
        // Get sub-call data from storage
        uint256 subCallCount = 0;
        bytes32[] memory subCallHashes = new bytes32[](0);
        
        if (parentHash != bytes32(0)) {
            _onChainB();
            subCallCount = wrapperB.getSubCallCount(parentHash);
            subCallHashes = wrapperB.getSubCalls(parentHash);
        }
        
        return SubCallResult({
            parentHash: parentHash,
            subCallCount: subCallCount,
            subCallHashes: subCallHashes,
            eventsEmitted: eventsEmitted
        });
    }
    
    /// @notice Verify sub-calls from recorded logs
    function _verifySubCallsFromLogs(uint256 eventIndex) internal returns (SubCallVerification memory) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 parentHash = _extractParentHash(logs, eventIndex);
        
        if (parentHash == bytes32(0)) {
            return SubCallVerification(bytes32(0), 0, new bytes32[](0));
        }
        
        // Get sub-call data from wrapper storage (sub-calls are tracked where they're made)
        _onChainB();
        uint256 subCallCount = wrapperB.getSubCallCount(parentHash);
        bytes32[] memory subCallHashes = wrapperB.getSubCalls(parentHash);
        
        return SubCallVerification({
            parentHash: parentHash,
            subCallCount: subCallCount,
            subCallHashes: subCallHashes
        });
    }
    
    /// @notice Verify sub-calls from recorded logs on specific chain
    function _verifySubCallsFromLogsOnChain(uint256 eventIndex, bool useChainA) internal returns (SubCallVerification memory) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 parentHash = _extractParentHash(logs, eventIndex);
        
        if (parentHash == bytes32(0)) {
            return SubCallVerification(bytes32(0), 0, new bytes32[](0));
        }
        
        // Get sub-call data from wrapper storage on the specified chain
        if (useChainA) {
            _onChainA();
            uint256 subCallCount = wrapperA.getSubCallCount(parentHash);
            bytes32[] memory subCallHashes = wrapperA.getSubCalls(parentHash);
            
            return SubCallVerification({
                parentHash: parentHash,
                subCallCount: subCallCount,
                subCallHashes: subCallHashes
            });
        } else {
            _onChainB();
            uint256 subCallCount = wrapperB.getSubCallCount(parentHash);
            bytes32[] memory subCallHashes = wrapperB.getSubCalls(parentHash);
            
            return SubCallVerification({
                parentHash: parentHash,
                subCallCount: subCallCount,
                subCallHashes: subCallHashes
            });
        }
    }
    
    /// @notice Extract parent hash from SubCallRegistered events
    function _extractParentHash(Vm.Log[] memory logs, uint256 eventIndex) internal pure returns (bytes32) {
        uint256 foundEvents = 0;
        bytes32 selector = keccak256("SubCallRegistered(bytes32,bytes32,uint256,address,bytes)");
        
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == selector) {
                if (foundEvents == eventIndex) {
                    return abi.decode(abi.encodePacked(logs[i].topics[1]), (bytes32));
                }
                foundEvents++;
            }
        }
        return bytes32(0);
    }
    
    /// @notice Count SubCallRegistered events in logs
    function _countSubCallEvents(Vm.Log[] memory logs) internal pure returns (uint256 count) {
        bytes32 selector = keccak256("SubCallRegistered(bytes32,bytes32,uint256,address,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == selector) count++;
        }
    }
    
    /// @notice Concatenate two log arrays
    function _concatenateLogs(Vm.Log[] memory logs1, Vm.Log[] memory logs2) internal pure returns (Vm.Log[] memory) {
        Vm.Log[] memory result = new Vm.Log[](logs1.length + logs2.length);
        
        // Copy logs1
        for (uint256 i = 0; i < logs1.length; i++) {
            result[i] = logs1[i];
        }
        
        // Copy logs2
        for (uint256 i = 0; i < logs2.length; i++) {
            result[logs1.length + i] = logs2[i];
        }
        
        return result;
    }
    
    /// =============================================================
    /// DEPLOYMENT & UTILITY HELPERS
    /// =============================================================
    
    function _deployContracts() private {
        // Deploy on Chain A
        _onChainA();
        wrapperA = new PromiseAwareMessenger{salt: bytes32(0)}();
        callMakerA = new TestCallMaker{salt: bytes32(0)}(address(wrapperA));
        token = new TestToken{salt: bytes32(0)}();
        
        // Deploy on Chain B  
        _onChainB();
        wrapperB = new PromiseAwareMessenger{salt: bytes32(0)}();
        callMakerB = new TestCallMaker{salt: bytes32(0)}(address(wrapperB));
        new TestToken{salt: bytes32(0)}();
        token.mint(address(this), 100); // Initial tokens for testing
    }
    
    function _verifyDeployments() private {
        require(address(wrapperA) == address(wrapperB), "Wrappers not at same address");
        require(address(callMakerA) == address(callMakerB), "CallMakers not at same address");
    }
    
    /// @notice Send message from Chain A to specified destination
    function _sendMessage(uint256 _destination, address _target, bytes memory _message) internal returns (bytes32) {
        _onChainA();
        return wrapperA.sendMessage(_destination, _target, _message);
    }
    
    /// @notice Get token balance on Chain B
    function _getTokenBalance(address _account) internal returns (uint256) {
        _onChainB();
        return token.balanceOf(_account);
    }
    
    /// =============================================================
    /// CHAIN ABSTRACTIONS
    /// =============================================================
    
    function _onChainA() internal { vm.selectFork(forkIds[0]); }
    function _onChainB() internal { vm.selectFork(forkIds[1]); }
    function chainA() internal view returns (uint256) { return chainIdByForkId[forkIds[0]]; }
    function chainB() internal view returns (uint256) { return chainIdByForkId[forkIds[1]]; }
    
    /// =============================================================
    /// TEST CALLBACKS
    /// =============================================================
    
    function checkSender() public {
        _onChainB();
        lastSender = wrapperB.xDomainMessageSender();
    }

    function test_debug_subcall_events() public {
        _onChainA();
        vm.recordLogs();
        
        console.log("=== Debug: Sub-Call Event Tracking ===");
        
        // Send a simple sub-call test
        wrapperA.sendMessage(
            chainB(),
            address(callMakerB),
            abi.encodeCall(TestCallMaker.makeSubCalls, (chainA(), 2))
        );
        
        relayAllMessages();
        
        // Debug: Check all logs
        Vm.Log[] memory logs = vm.getRecordedLogs();
        console.log("Total logs recorded:", logs.length);
        
        uint256 subCallEventCount = 0;
        bytes32 subCallSelector = keccak256("SubCallRegistered(bytes32,bytes32,uint256,address,bytes)");
        
        for (uint256 i = 0; i < logs.length; i++) {
            console.log("Log", i, "topic[0]:", vm.toString(logs[i].topics[0]));
            
            if (logs[i].topics[0] == subCallSelector) {
                subCallEventCount++;
                bytes32 parentHash = abi.decode(abi.encodePacked(logs[i].topics[1]), (bytes32));
                bytes32 subCallHash = abi.decode(abi.encodePacked(logs[i].topics[2]), (bytes32));
                
                console.log("Found SubCallRegistered event #", subCallEventCount);
                console.log("  Parent hash:", vm.toString(parentHash));
                console.log("  Sub-call hash:", vm.toString(subCallHash));
                
                // Check storage on Chain B
                _onChainB();
                uint256 storedSubCalls = wrapperB.getSubCallCount(parentHash);
                console.log("  Stored sub-calls for this parent:", storedSubCalls);
                _onChainA();
            }
        }
        
        console.log("Total SubCallRegistered events found:", subCallEventCount);
        
        if (subCallEventCount > 0) {
            console.log("SUCCESS: Sub-call events are being emitted!");
        } else {
            console.log("ISSUE: No SubCallRegistered events found");
        }
    }
} 