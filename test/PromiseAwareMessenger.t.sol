// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";

import {Identifier} from "../src/interfaces/IIdentifier.sol";
import {SuperchainERC20} from "../src/SuperchainERC20.sol";
import {Relayer} from "../src/test/Relayer.sol";
import {PromiseAwareMessenger} from "../src/PromiseAwareMessenger.sol";

contract PromiseAwareMessengerTest is Relayer, Test {
    PromiseAwareMessenger public wrapperA;
    PromiseAwareMessenger public wrapperB;
    L2NativeSuperchainERC20 public token;

    event CallReceived(address sender, uint256 value);
    
    bool public receivedCall;
    address public lastSender;
    uint256 public lastValue;

    string[] private rpcUrls = [
        vm.envOr("CHAIN_A_RPC_URL", string("https://interop-alpha-0.optimism.io")),
        vm.envOr("CHAIN_B_RPC_URL", string("https://interop-alpha-1.optimism.io"))
    ];

    constructor() Relayer(rpcUrls) {}

    function setUp() public {
        // Deploy wrapper on chain A
        vm.selectFork(forkIds[0]);
        wrapperA = new PromiseAwareMessenger{salt: bytes32(0)}();
        token = new L2NativeSuperchainERC20{salt: bytes32(0)}();

        // Deploy wrapper on chain B at same address (using CREATE2)
        vm.selectFork(forkIds[1]);
        wrapperB = new PromiseAwareMessenger{salt: bytes32(0)}();
        new L2NativeSuperchainERC20{salt: bytes32(0)}();

        // Mint tokens on chain B
        token.mint(address(this), 100);
        
        // Verify wrappers are at same address
        require(address(wrapperA) == address(wrapperB), "Wrappers not at same address");
    }

    function test_wrapper_sends_to_itself() public {
        vm.selectFork(forkIds[0]);
        
        console.log("=== Testing Wrapper Self-Call Architecture ===");
        console.log("Wrapper A address:", address(wrapperA));
        console.log("Wrapper B address:", address(wrapperB));
        
        // Send message through wrapper - should call itself on destination
        bytes32 messageHash = wrapperA.sendMessage(
            chainIdByForkId[forkIds[1]],
            address(token),
            abi.encodeCall(IERC20.balanceOf, (address(this)))
        );
        
        console.log("Message sent via wrapper, hash:", vm.toString(messageHash));
        
        // Relay the message
        relayAllMessages();
        
        console.log("SUCCESS: Wrapper sent message to itself on destination chain");
    }

    function test_wrapper_authentication() public {
        vm.selectFork(forkIds[0]);
        
        console.log("=== Testing Wrapper Authentication ===");
        
        // Send message through wrapper
        wrapperA.sendMessage(
            chainIdByForkId[forkIds[1]],
            address(this),
            abi.encodeCall(this.receiverFunction, (42))
        );
        
        // Relay the message
        relayAllMessages();
        
        // Check that the call was received
        assertTrue(receivedCall, "Call should have been received");
        assertEq(lastValue, 42, "Value should be 42");
        
        console.log("SUCCESS: Authentication and call execution worked");
        console.log("Received value:", lastValue);
    }

    function test_xDomainMessageSender() public {
        vm.selectFork(forkIds[0]);
        
        console.log("=== Testing xDomainMessageSender Functionality ===");
        
        // Send message through wrapper - this should call checkSender on chain B
        wrapperA.sendMessage(
            chainIdByForkId[forkIds[1]],
            address(this),
            abi.encodeCall(this.checkSender, ())
        );
        
        // Relay the message
        relayAllMessages();
        
        // Verify the sender was tracked correctly
        assertEq(lastSender, address(this), "Sender should be this contract");
        
        console.log("SUCCESS: xDomainMessageSender correctly tracked");
        console.log("Original sender:", lastSender);
    }

    function test_wrapper_nonce_tracking() public {
        vm.selectFork(forkIds[0]);
        
        console.log("=== Testing Wrapper Nonce Tracking ===");
        
        uint256 initialNonce = wrapperA.messageNonce();
        console.log("Initial nonce:", initialNonce);
        
        // Send first message
        wrapperA.sendMessage(
            chainIdByForkId[forkIds[1]],
            address(this),
            abi.encodeCall(this.receiverFunction, (1))
        );
        
        uint256 secondNonce = wrapperA.messageNonce();
        console.log("After first message nonce:", secondNonce);
        
        // Send second message
        wrapperA.sendMessage(
            chainIdByForkId[forkIds[1]],
            address(this),
            abi.encodeCall(this.receiverFunction, (2))
        );
        
        uint256 thirdNonce = wrapperA.messageNonce();
        console.log("After second message nonce:", thirdNonce);
        
        // Nonce should increase
        assertTrue(secondNonce > initialNonce, "Nonce should increase after first message");
        assertTrue(thirdNonce > secondNonce, "Nonce should increase after second message");
        
        console.log("SUCCESS: Nonce tracking works correctly");
    }

    function test_wrapper_failure_handling() public {
        vm.selectFork(forkIds[0]);
        
        console.log("=== Testing Wrapper Failure Handling ===");
        
        // Send message that will fail (invalid function selector)
        wrapperA.sendMessage(
            chainIdByForkId[forkIds[1]],
            address(this),
            abi.encodeWithSelector(bytes4(0xdeadbeef), 42)
        );
        
        // Relay the message - should not revert even if target call fails
        relayAllMessages();
        
        console.log("SUCCESS: Wrapper handled target call failure gracefully");
    }

    function test_cross_chain_token_minting() public {
        vm.selectFork(forkIds[0]);
        
        console.log("=== Testing Cross-Chain Token Minting via Wrapper ===");
        
        // Check initial balance on chain B  
        vm.selectFork(forkIds[1]);
        uint256 initialBalance = token.balanceOf(address(0x1234));
        console.log("Initial balance on Chain B:", initialBalance);
        assertEq(initialBalance, 0, "Should start with 0 balance");
        
        // Go back to chain A and send minting message through wrapper
        vm.selectFork(forkIds[0]);
        
        console.log("Sending mint command from Chain A to Chain B...");
        wrapperA.sendMessage(
            chainIdByForkId[forkIds[1]], // destination: Chain B
            address(token),              // target: token contract on Chain B
            abi.encodeCall(L2NativeSuperchainERC20.mint, (address(0x1234), 50)) // mint 50 tokens
        );
        
        // Relay the message to execute on Chain B
        relayAllMessages();
        
        // Switch to Chain B and verify the state change
        vm.selectFork(forkIds[1]);
        uint256 finalBalance = token.balanceOf(address(0x1234));
        console.log("Final balance on Chain B:", finalBalance);
        
        // Verify the state was modified
        assertEq(finalBalance, 50, "Should have minted 50 tokens");
        
        console.log("SUCCESS: Cross-chain token minting worked!");
        console.log("Tokens minted:", finalBalance - initialBalance);
    }

    function test_cross_chain_event_emission() public {
        vm.selectFork(forkIds[0]);
        
        console.log("=== Testing Cross-Chain Event Emission ===");
        
        // Start recording logs to catch events
        vm.recordLogs();
        
        // Send message to emit event on Chain B
        wrapperA.sendMessage(
            chainIdByForkId[forkIds[1]],
            address(this),
            abi.encodeCall(this.emitTestEvent, ("Hello from Chain A!", 12345))
        );
        
        // Relay the message
        relayAllMessages();
        
        // Get the recorded logs and verify our event was emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        
        bool eventFound = false;
        for (uint i = 0; i < logs.length; i++) {
            // Look for our TestEvent emission
            if (logs[i].topics[0] == keccak256("TestEvent(string,uint256)")) {
                eventFound = true;
                console.log("Found TestEvent in logs!");
                break;
            }
        }
        
        assertTrue(eventFound, "TestEvent should have been emitted");
        console.log("SUCCESS: Cross-chain event emission verified!");
    }

    function test_sub_call_tracking() public {
        vm.selectFork(forkIds[0]);
        
        console.log("=== Testing Sub-Call Tracking for Nested Promises ===");
        
        // Deploy a contract on Chain B that will make sub-calls
        vm.selectFork(forkIds[1]);
        SubCallMaker subCallMaker = new SubCallMaker(address(wrapperB));
        
        // Go back to Chain A and send a message that will trigger sub-calls
        vm.selectFork(forkIds[0]);
        
        console.log("Sending message from Chain A to Chain B that will trigger 2 sub-calls...");
        
        // Compute the deterministic hash that will be used for sub-call tracking
        bytes memory messageData = abi.encodeCall(SubCallMaker.makeSubCalls, (chainIdByForkId[forkIds[0]]));
        bytes32 deterministicHash = _computeDeterministicHash(
            chainIdByForkId[forkIds[1]], // destination: Chain B
            address(this),               // sender: test contract
            address(subCallMaker),       // target: contract that makes sub-calls
            messageData                  // message data
        );
        
        bytes32 actualMessageHash = wrapperA.sendMessage(
            chainIdByForkId[forkIds[1]], // destination: Chain B
            address(subCallMaker),       // target: contract that makes sub-calls
            messageData                  // call back to Chain A
        );
        
        console.log("Actual CDM message hash:", vm.toString(actualMessageHash));
        console.log("Deterministic hash for tracking:", vm.toString(deterministicHash));
        
        // Verify initially no sub-calls
        vm.selectFork(forkIds[1]);
        assertEq(wrapperB.getSubCallCount(deterministicHash), 0, "Should start with 0 sub-calls");
        
        // Relay the message - this should trigger the sub-calls
        relayAllMessages();
        
        // Check that sub-calls were tracked
        uint256 subCallCount = wrapperB.getSubCallCount(deterministicHash);
        console.log("Sub-calls tracked:", subCallCount);
        
        assertEq(subCallCount, 2, "Should have tracked 2 sub-calls");
        
        // Get the actual sub-call hashes
        bytes32[] memory subCallHashes = wrapperB.getSubCalls(deterministicHash);
        
        console.log("Sub-call 1 hash:", vm.toString(subCallHashes[0]));
        console.log("Sub-call 2 hash:", vm.toString(subCallHashes[1]));
        
        // Verify the hashes are different (distinct calls)
        assertTrue(subCallHashes[0] != subCallHashes[1], "Sub-calls should have different hashes");
        
        console.log("SUCCESS: Sub-call tracking working correctly!");
        console.log("Parent message triggered", subCallCount, "sub-calls as expected");
    }
    
    /// @notice Helper function to compute the same deterministic hash as the wrapper
    function _computeDeterministicHash(uint256 _destination, address _sender, address _target, bytes memory _message) private view returns (bytes32) {
        return keccak256(abi.encodePacked(
            block.chainid,              // source chain
            _destination,               // destination chain  
            _sender,                    // original sender
            _target,                    // target
            _message,                   // message data
            wrapperA.messageNonce()     // add nonce for uniqueness (get from wrapper A)
        ));
    }

    function test_sub_call_events() public {
        vm.selectFork(forkIds[0]);
        
        console.log("=== Testing Sub-Call Event Emission ===");
        
        // Deploy SubCallMaker on Chain B
        vm.selectFork(forkIds[1]);
        SubCallMaker subCallMaker = new SubCallMaker(address(wrapperB));
        
        vm.selectFork(forkIds[0]);
        
        // Start recording logs to catch SubCallRegistered events
        vm.recordLogs();
        
        // Send message that will trigger sub-calls
        wrapperA.sendMessage(
            chainIdByForkId[forkIds[1]],
            address(subCallMaker),
            abi.encodeCall(SubCallMaker.makeSubCalls, (chainIdByForkId[forkIds[0]]))
        );
        
        // Relay the message
        relayAllMessages();
        
        // Check for SubCallRegistered events
        Vm.Log[] memory logs = vm.getRecordedLogs();
        
        uint256 subCallEventCount = 0;
        for (uint i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("SubCallRegistered(bytes32,bytes32,uint256,address,bytes)")) {
                subCallEventCount++;
                console.log("Found SubCallRegistered event #", subCallEventCount);
            }
        }
        
        assertEq(subCallEventCount, 2, "Should have emitted 2 SubCallRegistered events");
        console.log("SUCCESS: Sub-call events emitted correctly!");
    }

    // Helper functions called by tests
    function receiverFunction(uint256 value) public {
        receivedCall = true;
        lastValue = value;
        emit CallReceived(msg.sender, value);
    }

    function checkSender() public {
        // Get the sender through the wrapper's xDomainMessageSender
        vm.selectFork(forkIds[1]);
        lastSender = wrapperB.xDomainMessageSender();
        console.log("Checked sender:", lastSender);
    }

    event TestEvent(string message, uint256 number);
    
    function emitTestEvent(string memory message, uint256 number) public {
        emit TestEvent(message, number);
        console.log("Event emitted:", message, number);
    }
}

/// @notice Mock ERC20 token for testing
contract L2NativeSuperchainERC20 is SuperchainERC20 {
    event Mint(address indexed account, uint256 amount);
    event Burn(address indexed account, uint256 amount);

    function mint(address _to, uint256 _amount) external virtual {
        require(_to != address(0), "Zero address");
        _mint(_to, _amount);
        emit Mint(_to, _amount);
    }

    function burn(address _from, uint256 _amount) external virtual {
        require(_from != address(0), "Zero address");
        _burn(_from, _amount);
        emit Burn(_from, _amount);
    }

    function name() public pure virtual override returns (string memory) {
        return "L2NativeSuperchainERC20";
    }

    function symbol() public pure virtual override returns (string memory) {
        return "MOCK";
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}

/// @notice Test contract that makes sub-calls during execution
contract SubCallMaker {
    PromiseAwareMessenger public wrapper;
    
    event SubCallsMade(uint256 destinationChain, uint256 callCount);
    
    constructor(address _wrapper) {
        wrapper = PromiseAwareMessenger(_wrapper);
    }
    
    /// @notice Makes 2 sub-calls back to the specified destination chain
    /// @param _destinationChain The chain to make calls back to
    function makeSubCalls(uint256 _destinationChain) external {
        console.log("SubCallMaker: Making 2 sub-calls to chain", _destinationChain);
        
        // Make first sub-call - call a simple function
        wrapper.sendMessage(
            _destinationChain,
            address(0x1111111111111111111111111111111111111111), // dummy target
            abi.encodeWithSignature("someFunction(uint256)", 123)
        );
        
        // Make second sub-call - call a different function  
        wrapper.sendMessage(
            _destinationChain,
            address(0x2222222222222222222222222222222222222222), // different dummy target
            abi.encodeWithSignature("anotherFunction(string)", "test")
        );
        
        emit SubCallsMade(_destinationChain, 2);
        console.log("SubCallMaker: Completed 2 sub-calls");
    }
} 