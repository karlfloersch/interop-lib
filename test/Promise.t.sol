// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";

import {Identifier} from "../src/interfaces/IIdentifier.sol";
import {SuperchainERC20} from "../src/SuperchainERC20.sol";
import {Relayer} from "../src/test/Relayer.sol";
import {IPromise, Handle} from "../src/interfaces/IPromise.sol";
import {Promise} from "../src/Promise.sol";
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
        
        // Deploy Promise contract at predeploy address
        Promise promiseImpl = new Promise();
        vm.etch(PredeployAddresses.PROMISE, address(promiseImpl).code);
        
        token = new L2NativeSuperchainERC20{salt: bytes32(0)}();

        vm.selectFork(forkIds[1]);
        
        // Deploy Promise contract at predeploy address on second fork too
        promiseImpl = new Promise();
        vm.etch(PredeployAddresses.PROMISE, address(promiseImpl).code);
        
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

    function test_andThen_creates_handle() public {
        vm.selectFork(forkIds[0]);

        // Send a message to attach the andThen to
        bytes32 msgHash = p.sendMessage(
            chainIdByForkId[forkIds[1]], address(token), abi.encodeCall(IERC20.balanceOf, (address(this)))
        );

        // Use andThen to register a destination-side callback
        Handle memory handle = p.andThen(
            msgHash,
            address(token),
            abi.encodeCall(IERC20.balanceOf, (address(this)))
        );

        // Verify handle properties
        assertTrue(handle.messageHash != bytes32(0));
        assertEq(handle.destinationChain, chainIdByForkId[forkIds[0]]);
        assertFalse(handle.completed);
        assertEq(handle.returnData.length, 0);
    }

    function test_handle_storage_and_retrieval() public {
        vm.selectFork(forkIds[0]);

        // Send a message to attach the andThen to
        bytes32 msgHash = p.sendMessage(
            chainIdByForkId[forkIds[1]], address(token), abi.encodeCall(IERC20.balanceOf, (address(this)))
        );

        // Use andThen to register a destination-side callback
        Handle memory handle = p.andThen(
            msgHash,
            address(token),
            abi.encodeCall(IERC20.balanceOf, (address(this)))
        );

        // Test handle retrieval
        Handle memory retrievedHandle = p.getHandle(handle.messageHash);
        assertEq(retrievedHandle.messageHash, handle.messageHash);
        assertEq(retrievedHandle.destinationChain, handle.destinationChain);
        assertEq(retrievedHandle.completed, handle.completed);
        assertEq(retrievedHandle.returnData.length, handle.returnData.length);

        // Test completion check
        assertFalse(p.isHandleCompleted(handle.messageHash));
    }

    function test_andThen_integration_with_relay() public {
        vm.selectFork(forkIds[0]);

        // Reset state for this test
        handlerCalled = false;

        // Step 1: Send initial message (A→B: query balance)
        bytes32 msgHash = p.sendMessage(
            chainIdByForkId[forkIds[1]], address(token), abi.encodeCall(IERC20.balanceOf, (address(this)))
        );

        // Step 2: Attach destination-side continuation (andThen: mint tokens on B)
        Handle memory handle = p.andThen(
            msgHash,
            address(token),
            abi.encodeCall(token.mint, (address(this), 50))
        );

        // Verify handle was created correctly
        assertTrue(handle.messageHash != bytes32(0));
        assertEq(handle.destinationChain, chainIdByForkId[forkIds[0]]);
        assertFalse(handle.completed);
        assertEq(handle.returnData.length, 0);

        // Step 3: Also attach source-side callback (then: handle result on A)
        p.then(msgHash, this.balanceHandler.selector, "abc");

        // Step 4: Relay the initial message (A→B)
        relayAllMessages();

        // Step 5: Relay the promise callbacks back to A
        relayAllPromises(p, chainIdByForkId[forkIds[0]]);

        // Verify source-side callback executed
        assertTrue(handlerCalled);

        // Step 6: Check that destination-side handle exists and can be queried
        Handle memory updatedHandle = p.getHandle(handle.messageHash);
        assertEq(updatedHandle.messageHash, handle.messageHash);
        assertEq(updatedHandle.destinationChain, handle.destinationChain);
        
        // Note: In this basic implementation, the handle completion tracking
        // will be enhanced in Phase 2 to actually execute destination-side logic
    }

    function test_handle_completion_execution() public {
        vm.selectFork(forkIds[0]);

        // Reset state for this test
        handlerCalled = false;

        // Step 1: Send initial message (A→B: query balance)
        bytes32 msgHash = p.sendMessage(
            chainIdByForkId[forkIds[1]], address(token), abi.encodeCall(IERC20.balanceOf, (address(this)))
        );

        // Step 2: Attach destination-side continuation (andThen: mint tokens on B)
        Handle memory handle = p.andThen(
            msgHash,
            address(token),
            abi.encodeCall(token.mint, (address(this), 50))
        );

        // Verify handle is not completed initially
        assertFalse(p.isHandleCompleted(handle.messageHash));

        // Step 3: Relay ALL messages (including handle registration) 
        // This ensures handles are registered on destination before original message executes
        relayAllMessages();

        // Step 4: Check handle completion on the destination chain (B)
        vm.selectFork(forkIds[1]);
        
        // The handle should now be completed
        assertTrue(p.isHandleCompleted(handle.messageHash));
        
        // Get the completed handle to check return data
        Handle memory completedHandle = p.getHandle(handle.messageHash);
        assertTrue(completedHandle.completed);
        assertTrue(completedHandle.returnData.length > 0);
        
        // Verify the mint actually happened (token balance should be 150 = 100 initial + 50 minted)
        assertEq(token.balanceOf(address(this)), 150);
    }

    function test_cross_chain_handle_registration() public {
        vm.selectFork(forkIds[0]);

        // Step 1: Send initial message (A→B: query balance)
        bytes32 msgHash = p.sendMessage(
            chainIdByForkId[forkIds[1]], address(token), abi.encodeCall(IERC20.balanceOf, (address(this)))
        );

        // Step 2: Attach destination-side continuation (andThen: mint tokens on B)
        // This should send a cross-chain message to register the handle on chain B
        Handle memory handle = p.andThen(
            msgHash,
            address(token),
            abi.encodeCall(token.mint, (address(this), 50))
        );

        // Verify no pending handles on source chain (they should be sent to destination)
        Handle[] memory pendingOnSource = p.getPendingHandles(msgHash);
        assertEq(pendingOnSource.length, 0);

        // Step 3: Relay all messages (including handle registration)
        relayAllMessages();

        // Step 4: Check that handles were registered on destination chain (B)
        vm.selectFork(forkIds[1]);
        Handle[] memory pendingOnDest = p.getPendingHandles(msgHash);
        assertEq(pendingOnDest.length, 1);
        assertEq(pendingOnDest[0].target, address(token));
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
