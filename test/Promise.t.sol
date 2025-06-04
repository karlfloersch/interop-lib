// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";

import {Identifier} from "../src/interfaces/IIdentifier.sol";
import {SuperchainERC20} from "../src/SuperchainERC20.sol";
import {Relayer} from "../src/test/Relayer.sol";
import {IPromise} from "../src/interfaces/IPromise.sol";
import {PredeployAddresses} from "../src/libraries/PredeployAddresses.sol";

contract PromiseTest is Relayer, Test {
    IPromise public p = IPromise(PredeployAddresses.PROMISE);
    L2NativeSuperchainERC20 public token;

    event HandlerCalled();

    bool public handlerCalled;

    string[] private rpcUrls = [
        vm.envOr("CHAIN_A_RPC_URL", string("https://interop-alpha-0.optimism.io")),
        vm.envOr("CHAIN_B_RPC_URL", string("https://interop-alpha-1.optimism.io"))
    ];

    constructor() Relayer(rpcUrls) {}

    function setUp() public {
        vm.selectFork(forkIds[0]);
        token = new L2NativeSuperchainERC20{salt: bytes32(0)}();

        vm.selectFork(forkIds[1]);
        new L2NativeSuperchainERC20{salt: bytes32(0)}();

        // mint tokens on chain B
        token.mint(address(this), 100);
    }

    modifier async() {
        require(msg.sender == address(p), "PromiseTest: caller not Promise");
        _;
    }

    function test_then_succeeds() public {
        vm.selectFork(forkIds[0]);

        // context is empty
        assertEq(p.promiseContext().length, 0);
        assertEq(p.promiseRelayIdentifier().origin, address(0));

        // example IERC20 remote balanceOf query
        bytes32 msgHash = p.sendMessage(
            chainIdByForkId[forkIds[1]], address(token), abi.encodeCall(IERC20.balanceOf, (address(this)))
        );
        p.then(msgHash, this.balanceHandler.selector, "abc");

        relayAllMessages();

        relayAllPromises(p, chainIdByForkId[forkIds[0]]);

        assertEq(handlerCalled, true);
        // context is empty
        assertEq(p.promiseContext().length, 0);
        assertEq(p.promiseRelayIdentifier().origin, address(0));
    }

    function balanceHandler(uint256 balance) public async {
        handlerCalled = true;
        require(balance == 100, "PromiseTest: balance mismatch");

        Identifier memory id = p.promiseRelayIdentifier();
        require(id.origin == address(p), "PromiseTest: origin mismatch");

        bytes memory context = p.promiseContext();
        require(keccak256(context) == keccak256("abc"), "PromiseTest: context mismatch");

        emit HandlerCalled();
    }

    // ===== NESTED vs SERIAL PROMISE TEST =====
    
    uint256[] public executionOrder;
    uint256 public finalValue;
    Calculator public calculator;
    
    function test_demonstrates_serial_not_nested_execution() public {
        vm.selectFork(forkIds[0]);
        
        // Deploy calculator on both chains
        calculator = new Calculator();
        vm.selectFork(forkIds[1]);
        calculator = new Calculator();
        vm.selectFork(forkIds[0]);
        
        // Reset state
        delete executionOrder;
        finalValue = 0;
        
        console.log("=== Testing Promise Execution Order ===");
        console.log("Initial setup complete");
        
        // Send a promise that returns 100 (token balance)
        bytes32 promise1 = p.sendMessage(
            chainIdByForkId[forkIds[1]], 
            address(token), 
            abi.encodeCall(IERC20.balanceOf, (address(this)))
        );
        
        // Attach two callbacks to the SAME promise:
        // 1. transformingCallback - sends another promise to double the value
        // 2. observingCallback - records what value it receives
        p.then(promise1, this.transformingCallback.selector);
        p.then(promise1, this.observingCallback.selector);
        
        console.log("Callbacks registered, starting relay...");
        
        // Relay the first promise
        relayAllMessages();
        relayAllPromises(p, chainIdByForkId[forkIds[0]]);
        
        console.log("First round complete");
        console.log("Execution order so far:");
        for (uint256 i = 0; i < executionOrder.length; i++) {
            console.log("  Step", executionOrder[i]);
        }
        console.log("Final value recorded:", finalValue);
        
        // If this were NESTED promises:
        // - transformingCallback would return a promise hash
        // - observingCallback would wait for that nested promise to resolve
        // - finalValue would be 200 (doubled)
        // - executionOrder would be [1, 3, 2]
        
        // If this is SERIAL promises (current implementation):
        // - transformingCallback sends a new promise but doesn't delay the parent
        // - observingCallback executes immediately with original value
        // - finalValue would be 100 (original)
        // - executionOrder would be [1, 2]
        
        // Let's see what actually happens...
        console.log("Expected for SERIAL: finalValue=100, order=[1,2]");
        console.log("Expected for NESTED: finalValue=200, order=[1,3,2]");
        console.log("Actual finalValue:", finalValue);
        
        // This assertion will pass with SERIAL behavior, fail with NESTED
        assertEq(finalValue, 100, "Should be 100 with SERIAL execution");
        assertEq(executionOrder.length, 2, "Should have 2 steps with SERIAL execution");
        assertEq(executionOrder[0], 1, "First step should be transforming callback");
        assertEq(executionOrder[1], 2, "Second step should be observing callback");
        
        console.log("SUCCESS: This demonstrates SERIAL promise execution");
        console.log("The observing callback got the original value (100)");
        console.log("It did NOT wait for the nested promise to complete");
        
        // Now let's manually relay the nested promise to prove it works separately
        console.log("\n=== Manually relaying nested promise ===");
        relayAllMessages();
        relayAllPromises(p, chainIdByForkId[forkIds[0]]);
        
        console.log("After nested promise relay:");
        console.log("Final execution order:");
        for (uint256 i = 0; i < executionOrder.length; i++) {
            console.log("  Step", executionOrder[i]);
        }
        
        // Now we should see step 3 (nested callback) executed
        assertEq(executionOrder.length, 3, "Should have 3 steps after nested relay");
        assertEq(executionOrder[2], 3, "Third step should be nested callback");
        
        console.log("PROVEN: Nested promise executed separately as step 3");
        console.log("This confirms SERIAL behavior - parent didn't wait for child");
    }
    
    function transformingCallback(uint256 value) public async returns (bytes32) {
        console.log("transformingCallback called with value:", value);
        executionOrder.push(1);
        
        // Send a nested promise to double the value
        bytes32 nestedPromise = p.sendMessage(
            chainIdByForkId[forkIds[1]], 
            address(calculator), 
            abi.encodeCall(Calculator.multiply, (value, 2))
        );
        
        // Register callback for the nested promise
        p.then(nestedPromise, this.nestedCompleteCallback.selector);
        
        console.log("transformingCallback sent nested promise");
        
        // In TRUE nested promises, returning this hash should make the parent wait
        // But in SERIAL promises, it's just ignored
        return nestedPromise;
    }
    
    function observingCallback(uint256 value) public async {
        console.log("observingCallback called with value:", value);
        executionOrder.push(2);
        finalValue = value;
        
        console.log("observingCallback set finalValue to:", value);
        // In SERIAL: value = 100 (original), executes immediately  
        // In NESTED: value = 200 (doubled), executes after nested resolves
    }
    
    function nestedCompleteCallback(uint256 doubledValue) public async {
        console.log("nestedCompleteCallback called with value:", doubledValue);
        executionOrder.push(3);
        
        console.log("Nested promise completed with doubled value:", doubledValue);
        // This proves the nested promise worked, but parent didn't wait for it
    }
}

/// @notice Thrown when attempting to mint or burn tokens and the account is the zero address.
error ZeroAddress();

/// @title L2NativeSuperchainERC20
/// @notice Mock implementation of a native Superchain ERC20 token that is L2 native (not backed by an L1 native token).
/// The mint/burn functionality is intentionally open to ANYONE to make it easier to test with. For production use,
/// this functionality should be restricted.
contract L2NativeSuperchainERC20 is SuperchainERC20 {
    /// @notice Emitted whenever tokens are minted for an account.
    /// @param account Address of the account tokens are being minted for.
    /// @param amount  Amount of tokens minted.
    event Mint(address indexed account, uint256 amount);

    /// @notice Emitted whenever tokens are burned from an account.
    /// @param account Address of the account tokens are being burned from.
    /// @param amount  Amount of tokens burned.
    event Burn(address indexed account, uint256 amount);

    /// @notice Allows ANYONE to mint tokens. For production use, this should be restricted.
    /// @param _to     Address to mint tokens to.
    /// @param _amount Amount of tokens to mint.
    function mint(address _to, uint256 _amount) external virtual {
        if (_to == address(0)) revert ZeroAddress();

        _mint(_to, _amount);

        emit Mint(_to, _amount);
    }

    /// @notice Allows ANYONE to burn tokens. For production use, this should be restricted.
    /// @param _from   Address to burn tokens from.
    /// @param _amount Amount of tokens to burn.
    function burn(address _from, uint256 _amount) external virtual {
        if (_from == address(0)) revert ZeroAddress();

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

/// @notice Helper contract to perform calculations for testing nested promises
contract Calculator {
    /// @notice Multiply two numbers
    function multiply(uint256 a, uint256 b) external pure returns (uint256) {
        return a * b;
    }
    
    /// @notice Add two numbers  
    function add(uint256 a, uint256 b) external pure returns (uint256) {
        return a + b;
    }
}
