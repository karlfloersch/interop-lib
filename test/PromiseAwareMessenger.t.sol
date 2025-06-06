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
    /// REMAINING FUNCTIONALITY TESTS
    /// =============================================================




    
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


} 