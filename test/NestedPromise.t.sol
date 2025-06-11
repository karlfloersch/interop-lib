// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";

import {Identifier} from "../src/interfaces/IIdentifier.sol";
import {SuperchainERC20} from "../src/SuperchainERC20.sol";
import {Relayer} from "../src/test/Relayer.sol";
import {Promise} from "../src/Promise.sol";
import {IPromise} from "../src/interfaces/IPromise.sol";
import {PredeployAddresses} from "../src/libraries/PredeployAddresses.sol";

contract NestedPromiseTest is Relayer, Test {
    Promise public promises; // Use our modified Promise contract directly
    L2NativeSuperchainERC20 public token;
    Calculator public calculator;

    event HandlerCalled();

    bool public handlerCalled;

    string[] private rpcUrls = [
        vm.envOr("CHAIN_A_RPC_URL", string("https://interop-alpha-0.optimism.io")),
        vm.envOr("CHAIN_B_RPC_URL", string("https://interop-alpha-1.optimism.io"))
    ];

    constructor() Relayer(rpcUrls) {}

    function setUp() public {
        vm.selectFork(forkIds[0]);
        
        // Deploy our modified Promise contract directly (not using predeploy)
        // Use salt to get same address on both chains
        promises = new Promise{salt: bytes32(0)}();
        token = new L2NativeSuperchainERC20{salt: bytes32(0)}();
        calculator = new Calculator{salt: bytes32(0)}();

        vm.selectFork(forkIds[1]);
        // Deploy same contracts on Chain B with same salt for same addresses
        new Promise{salt: bytes32(0)}();
        new L2NativeSuperchainERC20{salt: bytes32(0)}();
        new Calculator{salt: bytes32(0)}();

        // mint tokens on chain B
        token.mint(address(this), 100);
        
        console.log("Promise contract deployed at:", address(promises));
    }

    modifier async() {
        require(msg.sender == address(promises), "NestedPromiseTest: caller not Promise");
        _;
    }

    // ===== NESTED PROMISE TEST =====
    
    uint256[] public executionOrder;
    uint256 public finalValue;
    
    function test_true_nested_promise_execution() public {
        vm.selectFork(forkIds[0]);
        
        // Reset state
        delete executionOrder;
        finalValue = 0;
        
        console.log("=== Testing TRUE Nested Promise Execution ===");
        console.log("Using our modified Promise contract with nested support");
        
        // Send a promise that returns 100 (token balance)
        bytes32 promise1 = promises.sendMessage(
            chainIdByForkId[forkIds[1]], 
            address(token), 
            abi.encodeCall(IERC20.balanceOf, (address(this)))
        );
        
        console.log("Sent message with hash:", vm.toString(promise1));
        console.log("Destination chain:", chainIdByForkId[forkIds[1]]);
        console.log("Source chain:", chainIdByForkId[forkIds[0]]);
        
        // Attach two callbacks to the SAME promise:
        // 1. transformingCallback - sends another promise to double the value
        // 2. observingCallback - records what value it receives
        promises.then(promise1, this.transformingCallback.selector);
        promises.then(promise1, this.observingCallback.selector);
        
        console.log("Callbacks registered, starting relay...");
        console.log("Promise contract address:", address(promises));
        
        // Relay the first promise
        console.log("=== Relaying messages ===");
        relayAllMessages();
        console.log("=== Relaying promise callbacks ===");
        relayAllPromises(IPromise(address(promises)), chainIdByForkId[forkIds[0]]);
        
        console.log("First round complete");
        console.log("Execution order so far:");
        for (uint256 i = 0; i < executionOrder.length; i++) {
            console.log("  Step", executionOrder[i]);
        }
        console.log("Final value recorded:", finalValue);
        
        // With TRUE nested promises:
        // - transformingCallback would return a promise hash
        // - observingCallback would wait for that nested promise to resolve
        // - finalValue would be 200 (doubled)
        // - executionOrder would be [1, 3, 2]
        
        // Let's see what actually happens...
        console.log("Expected for NESTED: finalValue=200, order=[1,3,2]");
        console.log("Expected for SERIAL: finalValue=100, order=[1,2]");
        console.log("Actual finalValue:", finalValue);
        
        // Always relay remaining nested promises
        console.log("\n=== Relaying any remaining nested promises ===");
        relayAllMessages();
        relayAllPromises(IPromise(address(promises)), chainIdByForkId[forkIds[0]]);
        
        // Additional relay round to ensure nested callbacks execute
        console.log("=== Additional relay round for nested callbacks ===");
        relayAllMessages();
        relayAllPromises(IPromise(address(promises)), chainIdByForkId[forkIds[0]]);
        
        console.log("Final execution order:");
        for (uint256 i = 0; i < executionOrder.length; i++) {
            console.log("  Step", executionOrder[i]);
        }
        
        // Check if we achieved true nested behavior
        if (finalValue == 200) {
            console.log("\nSUCCESS: NESTED PROMISE BEHAVIOR DETECTED!");
            console.log("observingCallback received nested result (200) instead of original (100)");
            console.log("This proves the parent promise waited for the nested promise to resolve!");
            
            if (executionOrder.length >= 3 && executionOrder[1] == 3) {
                console.log("PERFECT: Full nested execution order [1,3,2] achieved!");
            } else {
                console.log("PARTIAL: Nested waiting works, but callback ordering could be improved");
            }
        }
    }
    
    function transformingCallback(uint256 value) public async returns (bytes32) {
        console.log("transformingCallback called with value:", value);
        executionOrder.push(1);
        
        // Send a nested promise to double the value
        bytes32 nestedPromise = promises.sendMessage(
            chainIdByForkId[forkIds[1]], 
            address(calculator), 
            abi.encodeCall(Calculator.multiply, (value, 2))
        );
        
        // Register callback for the nested promise
        promises.then(nestedPromise, this.nestedCompleteCallback.selector);
        
        console.log("transformingCallback sent nested promise, returning hash:", vm.toString(nestedPromise));
        
        // In TRUE nested promises, returning this hash should make the parent wait
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
        // In nested promises, this should execute BEFORE observingCallback
    }
}

/// @notice Thrown when attempting to mint or burn tokens and the account is the zero address.
error ZeroAddress();

/// @title L2NativeSuperchainERC20
/// @notice Mock implementation of a native Superchain ERC20 token that is L2 native (not backed by an L1 native token).
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