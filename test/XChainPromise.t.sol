// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Relayer} from "../src/test/Relayer.sol";

import {Promise} from "../src/Promise.sol";
import {PredeployAddresses} from "../src/libraries/PredeployAddresses.sol";

/// @title XChainPromise
/// @notice Focused tests for Promise.sol cross-chain functionality
contract XChainPromiseTest is Test, Relayer {
    // Promise contracts
    Promise public promiseA;
    Promise public promiseB;

    string[] private rpcUrls = [
        vm.envOr("CHAIN_A_RPC_URL", string("https://interop-alpha-0.optimism.io")),
        vm.envOr("CHAIN_B_RPC_URL", string("https://interop-alpha-1.optimism.io"))
    ];

    constructor() Relayer(rpcUrls) {}

    function setUp() public {
        // Deploy Promise contract on Chain A (fork 0) using CREATE2 with same salt
        vm.selectFork(forkIds[0]);
        promiseA = new Promise{salt: bytes32(0)}(
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        
        // Deploy Promise contract on Chain B (fork 1) using CREATE2 with same salt
        vm.selectFork(forkIds[1]);
        promiseB = new Promise{salt: bytes32(0)}(
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        
        // Verify contracts are deployed at the same address on both chains
        require(address(promiseA) == address(promiseB), "Promise contracts must have same address on both chains");
    }

    /// @notice Test basic promise creation and resolution on single chain
    function test_BasicPromiseOperations() public {
        vm.selectFork(forkIds[0]);
        
        // Create a promise
        uint256 promiseId = promiseA.create();
        assertEq(uint8(promiseA.status(promiseId)), uint8(Promise.PromiseStatus.Pending));
        assertTrue(promiseA.exists(promiseId));
        
        // Resolve the promise
        promiseA.resolve(promiseId, abi.encode("Hello World"));
        
        // Verify resolution
        assertEq(uint8(promiseA.status(promiseId)), uint8(Promise.PromiseStatus.Resolved));
        Promise.PromiseData memory data = promiseA.getPromise(promiseId);
        assertEq(data.returnData, abi.encode("Hello World"));
        assertEq(data.creator, address(this));
    }

    /// @notice Test basic promise rejection on single chain
    function test_BasicPromiseRejection() public {
        vm.selectFork(forkIds[0]);
        
        // Create and reject a promise
        uint256 promiseId = promiseA.create();
        promiseA.reject(promiseId, abi.encode("Error occurred"));
        
        // Verify rejection
        assertEq(uint8(promiseA.status(promiseId)), uint8(Promise.PromiseStatus.Rejected));
        Promise.PromiseData memory data = promiseA.getPromise(promiseId);
        assertEq(data.returnData, abi.encode("Error occurred"));
    }

    /// @notice Test global promise ID generation
    function test_GlobalPromiseIds() public {
        vm.selectFork(forkIds[0]);
        
        // Create a promise on Chain A
        uint256 promiseIdA = promiseA.create();
        uint256 chainAId = chainIdByForkId[forkIds[0]];
        
        // Verify the global ID generation is deterministic
        uint256 expectedGlobalId = promiseA.generateGlobalPromiseId(chainAId, 1); // First promise
        assertEq(promiseIdA, expectedGlobalId);
        
        // Create a promise on Chain B
        vm.selectFork(forkIds[1]);
        uint256 promiseIdB = promiseB.create();
        uint256 chainBId = chainIdByForkId[forkIds[1]];
        
        // Verify it generates a different global ID
        uint256 expectedGlobalIdB = promiseB.generateGlobalPromiseId(chainBId, 1); // First promise
        assertEq(promiseIdB, expectedGlobalIdB);
        assertNotEq(promiseIdA, promiseIdB);
        
        // Verify promises can be distinguished by their origin chain
        vm.selectFork(forkIds[0]);
        uint256 chainAIdFromA = promiseA.generateGlobalPromiseId(chainAId, 1);
        uint256 chainBIdFromA = promiseA.generateGlobalPromiseId(chainBId, 1);
        assertEq(chainAIdFromA, promiseIdA);
        assertEq(chainBIdFromA, promiseIdB);
    }

    /// @notice Test sharing a resolved promise across chains
    function test_ShareResolvedPromise_Resolved() public {
        vm.selectFork(forkIds[0]);
        
        // Create and resolve a promise on Chain A
        uint256 promiseId = promiseA.create();
        promiseA.resolve(promiseId, abi.encode("Data from Chain A"));
        
        // Share the resolved promise to Chain B
        uint256 chainBId = chainIdByForkId[forkIds[1]];
        promiseA.shareResolvedPromise(chainBId, promiseId);
        
        // Relay the message to Chain B
        relayAllMessages();
        
        // Switch to Chain B and verify the promise exists with correct data
        vm.selectFork(forkIds[1]);
        Promise.PromiseData memory sharedPromise = promiseB.getPromise(promiseId);
        assertEq(uint8(sharedPromise.status), uint8(Promise.PromiseStatus.Resolved));
        assertEq(sharedPromise.returnData, abi.encode("Data from Chain A"));
        assertTrue(promiseB.exists(promiseId));
    }

    /// @notice Test sharing a rejected promise across chains
    function test_ShareResolvedPromise_Rejected() public {
        vm.selectFork(forkIds[0]);
        
        // Create and reject a promise on Chain A
        uint256 promiseId = promiseA.create();
        promiseA.reject(promiseId, abi.encode("Error from Chain A"));
        
        // Share the rejected promise to Chain B
        uint256 chainBId = chainIdByForkId[forkIds[1]];
        promiseA.shareResolvedPromise(chainBId, promiseId);
        
        // Relay the message to Chain B
        relayAllMessages();
        
        // Switch to Chain B and verify the promise exists with correct error data
        vm.selectFork(forkIds[1]);
        Promise.PromiseData memory sharedPromise = promiseB.getPromise(promiseId);
        assertEq(uint8(sharedPromise.status), uint8(Promise.PromiseStatus.Rejected));
        assertEq(sharedPromise.returnData, abi.encode("Error from Chain A"));
        assertTrue(promiseB.exists(promiseId));
    }

    /// @notice Test transferring resolution rights to another chain
    function test_TransferResolve() public {
        vm.selectFork(forkIds[0]);
        
        // Create a promise on Chain A
        uint256 promiseId = promiseA.create();
        
        // Transfer resolution rights to Chain B
        address newResolver = address(0x123);
        uint256 chainBId = chainIdByForkId[forkIds[1]];
        promiseA.transferResolve(promiseId, chainBId, newResolver);
        
        // Relay the message to Chain B
        relayAllMessages();
        
        // Switch to Chain B and verify the promise was transferred
        vm.selectFork(forkIds[1]);
        Promise.PromiseData memory transferredPromise = promiseB.getPromise(promiseId);
        assertEq(transferredPromise.creator, newResolver);
        assertEq(uint8(transferredPromise.status), uint8(Promise.PromiseStatus.Pending));
        assertTrue(promiseB.exists(promiseId));
        
        // Verify the promise is deleted on Chain A
        vm.selectFork(forkIds[0]);
        Promise.PromiseData memory deletedPromise = promiseA.getPromise(promiseId);
        assertEq(deletedPromise.creator, address(0));
        assertEq(uint8(deletedPromise.status), uint8(Promise.PromiseStatus.Pending));
        assertFalse(promiseA.exists(promiseId));
        
        // Verify new creator can resolve on Chain B
        vm.selectFork(forkIds[1]);
        vm.prank(newResolver);
        promiseB.resolve(promiseId, abi.encode("Resolved on Chain B"));
        
        Promise.PromiseData memory resolvedPromise = promiseB.getPromise(promiseId);
        assertEq(uint8(resolvedPromise.status), uint8(Promise.PromiseStatus.Resolved));
        assertEq(resolvedPromise.returnData, abi.encode("Resolved on Chain B"));
    }

    /// @notice Test error handling in cross-chain operations
    function test_CrossChainErrorHandling() public {
        vm.selectFork(forkIds[0]);
        
        // Try to share to the same chain (should revert)
        uint256 promiseId = promiseA.create();
        uint256 chainAId = chainIdByForkId[forkIds[0]];
        vm.expectRevert("Promise: cannot share to same chain");
        promiseA.shareResolvedPromise(chainAId, promiseId);
        
        // Try to transfer to the same chain (should revert)
        vm.expectRevert("Promise: cannot transfer to same chain");
        promiseA.transferResolve(promiseId, chainAId, address(0x123));
    }

    /// @notice Test that only creator can resolve/reject promises
    function test_CreatorPermissions() public {
        vm.selectFork(forkIds[0]);
        
        // Create a promise
        uint256 promiseId = promiseA.create();
        
        // Try to resolve from wrong account (should revert)
        vm.prank(address(0x999));
        vm.expectRevert("Promise: only creator can resolve");
        promiseA.resolve(promiseId, abi.encode("unauthorized"));
        
        // Try to reject from wrong account (should revert)
        vm.prank(address(0x999));
        vm.expectRevert("Promise: only creator can reject");
        promiseA.reject(promiseId, abi.encode("unauthorized"));
        
        // Verify original creator can still resolve
        promiseA.resolve(promiseId, abi.encode("authorized"));
        assertEq(uint8(promiseA.status(promiseId)), uint8(Promise.PromiseStatus.Resolved));
    }

    /// @notice Test that promises cannot be resolved twice
    function test_PromiseCannotBeResolvedTwice() public {
        vm.selectFork(forkIds[0]);
        
        // Create and resolve a promise
        uint256 promiseId = promiseA.create();
        promiseA.resolve(promiseId, abi.encode("first resolution"));
        
        // Try to resolve again (should revert)
        vm.expectRevert("Promise: promise already settled");
        promiseA.resolve(promiseId, abi.encode("second resolution"));
        
        // Try to reject resolved promise (should revert)
        vm.expectRevert("Promise: promise already settled");
        promiseA.reject(promiseId, abi.encode("cannot reject resolved"));
    }

    /// @notice Test non-existent promises return Pending status
    function test_NonExistentPromisesArePending() public {
        vm.selectFork(forkIds[0]);
        
        // Check non-existent promise
        uint256 fakePromiseId = 99999;
        assertEq(uint8(promiseA.status(fakePromiseId)), uint8(Promise.PromiseStatus.Pending));
        assertFalse(promiseA.exists(fakePromiseId));
        
        // getPromise should return empty data for non-existent promise
        Promise.PromiseData memory emptyPromise = promiseA.getPromise(fakePromiseId);
        assertEq(emptyPromise.creator, address(0));
        assertEq(uint8(emptyPromise.status), uint8(Promise.PromiseStatus.Pending));
        assertEq(emptyPromise.returnData.length, 0);
    }

    /// @notice Test that sharing pending promises is not allowed
    function test_CannotSharePendingPromise() public {
        vm.selectFork(forkIds[0]);
        
        // Create a pending promise
        uint256 promiseId = promiseA.create();
        
        // Verify it's pending
        assertEq(uint8(promiseA.status(promiseId)), uint8(Promise.PromiseStatus.Pending), "Promise should be pending");
        
        // Try to share the pending promise - should revert
        uint256 chainBId = chainIdByForkId[forkIds[1]];
        vm.expectRevert("Promise: can only share settled promises");
        promiseA.shareResolvedPromise(chainBId, promiseId);
    }

    /// @notice Test that sharing resolved promises works
    function test_CanShareResolvedPromise() public {
        vm.selectFork(forkIds[0]);
        
        // Create and resolve a promise
        uint256 promiseId = promiseA.create();
        promiseA.resolve(promiseId, "test data");
        
        // Verify it's resolved
        assertEq(uint8(promiseA.status(promiseId)), uint8(Promise.PromiseStatus.Resolved), "Promise should be resolved");
        
        // Share the resolved promise - should work
        uint256 chainBId = chainIdByForkId[forkIds[1]];
        promiseA.shareResolvedPromise(chainBId, promiseId);
        relayAllMessages();
        
        // Verify on Chain B
        vm.selectFork(forkIds[1]);
        assertTrue(promiseB.exists(promiseId), "Promise should exist on Chain B");
        assertEq(uint8(promiseB.status(promiseId)), uint8(Promise.PromiseStatus.Resolved), "Promise should be resolved on Chain B");
    }

    /// @notice Test that sharing rejected promises works
    function test_CanShareRejectedPromise() public {
        vm.selectFork(forkIds[0]);
        
        // Create and reject a promise
        uint256 promiseId = promiseA.create();
        promiseA.reject(promiseId, "test error");
        
        // Verify it's rejected
        assertEq(uint8(promiseA.status(promiseId)), uint8(Promise.PromiseStatus.Rejected), "Promise should be rejected");
        
        // Share the rejected promise - should work
        uint256 chainBId = chainIdByForkId[forkIds[1]];
        promiseA.shareResolvedPromise(chainBId, promiseId);
        relayAllMessages();
        
        // Verify on Chain B
        vm.selectFork(forkIds[1]);
        assertTrue(promiseB.exists(promiseId), "Promise should exist on Chain B");
        assertEq(uint8(promiseB.status(promiseId)), uint8(Promise.PromiseStatus.Rejected), "Promise should be rejected on Chain B");
    }
} 