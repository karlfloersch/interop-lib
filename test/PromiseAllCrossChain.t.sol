// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Relayer} from "../src/test/Relayer.sol";

import {Promise} from "../src/Promise.sol";
import {PromiseAll} from "../src/PromiseAll.sol";
import {Callback} from "../src/Callback.sol";
import {PredeployAddresses} from "../src/libraries/PredeployAddresses.sol";

/// @title PromiseAllCrossChain
/// @notice Tests for cross-chain PromiseAll functionality where PromiseAll aggregates promises from multiple chains
contract PromiseAllCrossChainTest is Test, Relayer {
    // Contracts on each chain
    Promise public promiseA;
    Promise public promiseB;
    PromiseAll public promiseAllA;
    PromiseAll public promiseAllB;
    Callback public callbackA;
    Callback public callbackB;

    string[] private rpcUrls = [
        vm.envOr("CHAIN_A_RPC_URL", string("https://interop-alpha-0.optimism.io")),
        vm.envOr("CHAIN_B_RPC_URL", string("https://interop-alpha-1.optimism.io"))
    ];

    constructor() Relayer(rpcUrls) {}

    function setUp() public {
        // Deploy contracts using CREATE2 for same addresses across chains
        vm.selectFork(forkIds[0]);
        promiseA = new Promise{salt: bytes32(0)}(
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        promiseAllA = new PromiseAll{salt: bytes32(0)}(address(promiseA));
        callbackA = new Callback{salt: bytes32(0)}(
            address(promiseA),
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        
        vm.selectFork(forkIds[1]);
        promiseB = new Promise{salt: bytes32(0)}(
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        promiseAllB = new PromiseAll{salt: bytes32(0)}(address(promiseB));
        callbackB = new Callback{salt: bytes32(0)}(
            address(promiseB),
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        
        // Verify contracts have same addresses
        require(address(promiseA) == address(promiseB), "Promise contracts must have same address");
        require(address(promiseAllA) == address(promiseAllB), "PromiseAll contracts must have same address");
        require(address(callbackA) == address(callbackB), "Callback contracts must have same address");
    }

    /// @notice Test cross-chain promise aggregation - promises created on different chains, aggregated on one chain
    function test_CrossChainPromiseAggregation() public {
        vm.selectFork(forkIds[0]);
        
        // Create promises on Chain A
        uint256 promiseA1 = promiseA.create();
        uint256 promiseA2 = promiseA.create();
        
        // Create promises on Chain B
        vm.selectFork(forkIds[1]);
        uint256 promiseB1 = promiseB.create();
        uint256 promiseB2 = promiseB.create();
        
        // Create PromiseAll on Chain A that watches promises from both chains
        vm.selectFork(forkIds[0]);
        uint256[] memory inputPromises = new uint256[](4);
        inputPromises[0] = promiseA1;  // Local to Chain A
        inputPromises[1] = promiseA2;  // Local to Chain A  
        inputPromises[2] = promiseB1;  // From Chain B (doesn't exist on A yet)
        inputPromises[3] = promiseB2;  // From Chain B (doesn't exist on A yet)
        
        uint256 promiseAllId = promiseAllA.create(inputPromises);
        
        // Verify PromiseAll was created and is not resolvable yet
        assertTrue(promiseAllA.exists(promiseAllId), "PromiseAll should exist");
        assertFalse(promiseAllA.canResolve(promiseAllId), "PromiseAll should not be resolvable yet");
        
        // Resolve promises on their origin chains
        // Resolve Chain A promises
        promiseA.resolve(promiseA1, abi.encode("Chain A Result 1"));
        promiseA.resolve(promiseA2, abi.encode("Chain A Result 2"));
        
        // Resolve Chain B promises
        vm.selectFork(forkIds[1]);
        promiseB.resolve(promiseB1, abi.encode("Chain B Result 1"));
        promiseB.resolve(promiseB2, abi.encode("Chain B Result 2"));
        
        // Share Chain B promises to Chain A
        uint256 chainAId = chainIdByForkId[forkIds[0]];
        promiseB.shareResolvedPromise(chainAId, promiseB1);
        promiseB.shareResolvedPromise(chainAId, promiseB2);
        relayAllMessages();
        
        // Now PromiseAll on Chain A should be resolvable
        vm.selectFork(forkIds[0]);
        assertTrue(promiseAllA.canResolve(promiseAllId), "PromiseAll should be resolvable after sharing");
        
        // Check status before resolution
        (uint256 resolvedCount, uint256 totalCount, bool settled) = promiseAllA.getStatus(promiseAllId);
        assertEq(resolvedCount, 4, "All 4 promises should be resolved");
        assertEq(totalCount, 4, "Should have 4 total promises");
        assertFalse(settled, "Should not be settled yet");
        
        // Resolve PromiseAll
        promiseAllA.resolve(promiseAllId);
        
        // Verify aggregated results
        assertEq(uint8(promiseA.status(promiseAllId)), uint8(Promise.PromiseStatus.Resolved), "PromiseAll should be resolved");
        
        Promise.PromiseData memory aggregatedData = promiseA.getPromise(promiseAllId);
        bytes[] memory results = abi.decode(aggregatedData.returnData, (bytes[]));
        
        assertEq(results.length, 4, "Should have 4 results");
        assertEq(results[0], abi.encode("Chain A Result 1"), "First result should match");
        assertEq(results[1], abi.encode("Chain A Result 2"), "Second result should match");
        assertEq(results[2], abi.encode("Chain B Result 1"), "Third result should match");
        assertEq(results[3], abi.encode("Chain B Result 2"), "Fourth result should match");
        
        // Verify cleanup
        assertFalse(promiseAllA.exists(promiseAllId), "PromiseAll should be cleaned up");
    }

    /// @notice Test sharing PromiseAll results across chains
    function test_PromiseAllResultSharing() public {
        vm.selectFork(forkIds[0]);
        
        // Create local promises on Chain A
        uint256 promise1 = promiseA.create();
        uint256 promise2 = promiseA.create();
        
        uint256[] memory inputPromises = new uint256[](2);
        inputPromises[0] = promise1;
        inputPromises[1] = promise2;
        
        // Create PromiseAll on Chain A
        uint256 promiseAllId = promiseAllA.create(inputPromises);
        
        // Resolve all promises
        promiseA.resolve(promise1, abi.encode("Local Result 1"));
        promiseA.resolve(promise2, abi.encode("Local Result 2"));
        
        // Resolve PromiseAll
        promiseAllA.resolve(promiseAllId);
        
        // Share PromiseAll result to Chain B
        uint256 chainBId = chainIdByForkId[forkIds[1]];
        promiseA.shareResolvedPromise(chainBId, promiseAllId);
        relayAllMessages();
        
        // Verify PromiseAll result exists on Chain B
        vm.selectFork(forkIds[1]);
        assertTrue(promiseB.exists(promiseAllId), "PromiseAll result should exist on Chain B");
        assertEq(uint8(promiseB.status(promiseAllId)), uint8(Promise.PromiseStatus.Resolved), "PromiseAll should be resolved on Chain B");
        
        // Verify aggregated data is preserved
        Promise.PromiseData memory sharedData = promiseB.getPromise(promiseAllId);
        bytes[] memory sharedResults = abi.decode(sharedData.returnData, (bytes[]));
        
        assertEq(sharedResults.length, 2, "Should have 2 results");
        assertEq(sharedResults[0], abi.encode("Local Result 1"), "First shared result should match");
        assertEq(sharedResults[1], abi.encode("Local Result 2"), "Second shared result should match");
    }

    /// @notice Test PromiseAll with cross-chain callback
    function test_CrossChainPromiseAllWithCallback() public {
        vm.selectFork(forkIds[0]);
        
        // Create promises on Chain A
        uint256 promise1 = promiseA.create();
        uint256 promise2 = promiseA.create();
        
        uint256[] memory inputPromises = new uint256[](2);
        inputPromises[0] = promise1;
        inputPromises[1] = promise2;
        
        // Create PromiseAll on Chain A
        uint256 promiseAllId = promiseAllA.create(inputPromises);
        
        // Create target contract on Chain B
        vm.selectFork(forkIds[1]);
        PromiseAllTarget target = new PromiseAllTarget();
        
        // Register cross-chain callback from Chain A to Chain B
        vm.selectFork(forkIds[0]);
        uint256 chainBId = chainIdByForkId[forkIds[1]];
        uint256 callbackPromise = callbackA.thenOn(
            chainBId,
            promiseAllId,
            address(target),
            target.handlePromiseAll.selector
        );
        
        // Relay callback registration
        relayAllMessages();
        
        // Resolve all input promises
        promiseA.resolve(promise1, abi.encode("Aggregated 1"));
        promiseA.resolve(promise2, abi.encode("Aggregated 2"));
        
        // Resolve PromiseAll
        promiseAllA.resolve(promiseAllId);
        
        // Share PromiseAll result to Chain B for callback
        promiseA.shareResolvedPromise(chainBId, promiseAllId);
        relayAllMessages();
        
        // Execute callback on Chain B
        vm.selectFork(forkIds[1]);
        assertTrue(callbackB.canResolve(callbackPromise), "Callback should be resolvable");
        callbackB.resolve(callbackPromise);
        
        // Verify callback executed with aggregated data
        assertTrue(target.promiseAllHandled(), "PromiseAll handler should have been called");
        assertEq(target.resultCount(), 2, "Should have received 2 aggregated results");
        assertEq(target.getResult(0), "Aggregated 1", "First result should match");
        assertEq(target.getResult(1), "Aggregated 2", "Second result should match");
    }

    /// @notice Test mixed local and cross-chain promises in PromiseAll
    function test_MixedLocalAndCrossChainPromises() public {
        vm.selectFork(forkIds[0]);
        
        // Create local promises on Chain A
        uint256 localPromise1 = promiseA.create();
        uint256 localPromise2 = promiseA.create();
        
        // Create promises on Chain B and share one immediately  
        vm.selectFork(forkIds[1]);
        uint256 remotePromise1 = promiseB.create();
        uint256 remotePromise2 = promiseB.create();
        
        // Resolve and share one remote promise early
        promiseB.resolve(remotePromise1, abi.encode("Early Remote Result"));
        uint256 chainAId = chainIdByForkId[forkIds[0]];
        promiseB.shareResolvedPromise(chainAId, remotePromise1);
        relayAllMessages();
        
        // Create PromiseAll on Chain A with mix of local, shared, and not-yet-shared promises
        vm.selectFork(forkIds[0]);
        uint256[] memory inputPromises = new uint256[](4);
        inputPromises[0] = localPromise1;    // Local pending
        inputPromises[1] = localPromise2;    // Local pending  
        inputPromises[2] = remotePromise1;   // Remote resolved & shared
        inputPromises[3] = remotePromise2;   // Remote not shared yet
        
        uint256 promiseAllId = promiseAllA.create(inputPromises);
        
        // Check initial status - 1 already resolved (the shared one)
        (uint256 resolvedCount, uint256 totalCount, bool settled) = promiseAllA.getStatus(promiseAllId);
        assertEq(resolvedCount, 1, "Should have 1 resolved (the shared one)");
        assertEq(totalCount, 4, "Should have 4 total promises");
        assertFalse(settled, "Should not be settled yet");
        
        // Resolve local promises
        promiseA.resolve(localPromise1, abi.encode("Local Result 1"));
        promiseA.resolve(localPromise2, abi.encode("Local Result 2"));
        
        // Still not resolvable - missing remotePromise2
        assertFalse(promiseAllA.canResolve(promiseAllId), "Should not be resolvable yet");
        
        // Resolve and share the remaining remote promise
        vm.selectFork(forkIds[1]);
        promiseB.resolve(remotePromise2, abi.encode("Late Remote Result"));
        promiseB.shareResolvedPromise(chainAId, remotePromise2);
        relayAllMessages();
        
        // Now should be resolvable
        vm.selectFork(forkIds[0]);
        assertTrue(promiseAllA.canResolve(promiseAllId), "Should be resolvable now");
        
        // Resolve and verify mixed results
        promiseAllA.resolve(promiseAllId);
        
        Promise.PromiseData memory aggregatedData = promiseA.getPromise(promiseAllId);
        bytes[] memory results = abi.decode(aggregatedData.returnData, (bytes[]));
        
        assertEq(results.length, 4, "Should have 4 results");
        assertEq(results[0], abi.encode("Local Result 1"), "Local result 1 should match");
        assertEq(results[1], abi.encode("Local Result 2"), "Local result 2 should match");
        assertEq(results[2], abi.encode("Early Remote Result"), "Early remote result should match");
        assertEq(results[3], abi.encode("Late Remote Result"), "Late remote result should match");
    }

    /// @notice Test PromiseAll rejection with cross-chain promises
    function test_CrossChainPromiseAllRejection() public {
        vm.selectFork(forkIds[0]);
        
        // Create promises on both chains
        uint256 localPromise = promiseA.create();
        
        vm.selectFork(forkIds[1]);
        uint256 remotePromise = promiseB.create();
        
        // Create PromiseAll on Chain A
        vm.selectFork(forkIds[0]);
        uint256[] memory inputPromises = new uint256[](2);
        inputPromises[0] = localPromise;
        inputPromises[1] = remotePromise;
        
        uint256 promiseAllId = promiseAllA.create(inputPromises);
        
        // Resolve local promise successfully
        promiseA.resolve(localPromise, abi.encode("Local Success"));
        
        // Reject remote promise
        vm.selectFork(forkIds[1]);
        promiseB.reject(remotePromise, abi.encode("Remote Failure"));
        
        // Share rejected promise to Chain A
        uint256 chainAId = chainIdByForkId[forkIds[0]];
        promiseB.shareResolvedPromise(chainAId, remotePromise);
        relayAllMessages();
        
        // PromiseAll should be resolvable (will reject due to fail-fast)
        vm.selectFork(forkIds[0]);
        assertTrue(promiseAllA.canResolve(promiseAllId), "PromiseAll should be resolvable for rejection");
        
        // Resolve PromiseAll (it will reject)
        promiseAllA.resolve(promiseAllId);
        
        // Verify rejection
        assertEq(uint8(promiseA.status(promiseAllId)), uint8(Promise.PromiseStatus.Rejected), "PromiseAll should be rejected");
        
        // Verify error data from the rejected remote promise
        Promise.PromiseData memory rejectedData = promiseA.getPromise(promiseAllId);
        assertEq(rejectedData.returnData, abi.encode("Remote Failure"), "Should contain remote failure data");
        
        // Verify cleanup
        assertFalse(promiseAllA.exists(promiseAllId), "PromiseAll should be cleaned up after rejection");
    }

    /// @notice Test PromiseAll with global promise IDs
    function test_GlobalPromiseIdsInPromiseAll() public {
        vm.selectFork(forkIds[0]);
        
        // Create promise on Chain A
        uint256 promiseOnA = promiseA.create();
        
        // Create promise on Chain B  
        vm.selectFork(forkIds[1]);
        uint256 promiseOnB = promiseB.create();
        
        // Verify these are global hash-based IDs, not sequential
        uint256 expectedGlobalIdA = promiseA.generateGlobalPromiseId(chainIdByForkId[forkIds[0]], 1);
        uint256 expectedGlobalIdB = promiseB.generateGlobalPromiseId(chainIdByForkId[forkIds[1]], 1);
        
        vm.selectFork(forkIds[0]);
        assertEq(promiseOnA, expectedGlobalIdA, "Chain A promise should have global ID");
        
        vm.selectFork(forkIds[1]);
        assertEq(promiseOnB, expectedGlobalIdB, "Chain B promise should have global ID");
        
        // Verify IDs are different (no collision)
        assertNotEq(promiseOnA, promiseOnB, "Global IDs should be different");
        
        // Create PromiseAll on Chain A using both global IDs
        vm.selectFork(forkIds[0]);
        uint256[] memory inputPromises = new uint256[](2);
        inputPromises[0] = promiseOnA;  // Local global ID
        inputPromises[1] = promiseOnB;  // Remote global ID
        
        uint256 promiseAllId = promiseAllA.create(inputPromises);
        
        // Verify PromiseAll contains the correct global IDs
        uint256[] memory retrievedInputs = promiseAllA.getInputPromises(promiseAllId);
        assertEq(retrievedInputs.length, 2, "Should have 2 input promises");
        assertEq(retrievedInputs[0], expectedGlobalIdA, "First input should be global ID A");
        assertEq(retrievedInputs[1], expectedGlobalIdB, "Second input should be global ID B");
        
        // Resolve both promises and share the remote one
        promiseA.resolve(promiseOnA, abi.encode("Global A Result"));
        
        vm.selectFork(forkIds[1]);
        promiseB.resolve(promiseOnB, abi.encode("Global B Result"));
        uint256 chainAId = chainIdByForkId[forkIds[0]];
        promiseB.shareResolvedPromise(chainAId, promiseOnB);
        relayAllMessages();
        
        // Resolve PromiseAll and verify global ID handling
        vm.selectFork(forkIds[0]);
        promiseAllA.resolve(promiseAllId);
        
        Promise.PromiseData memory aggregatedData = promiseA.getPromise(promiseAllId);
        bytes[] memory results = abi.decode(aggregatedData.returnData, (bytes[]));
        
        assertEq(results[0], abi.encode("Global A Result"), "Global A result should match");
        assertEq(results[1], abi.encode("Global B Result"), "Global B result should match");
    }

    /// @notice Test PromiseAll with non-existent cross-chain promises
    function test_PromiseAllWithNonExistentCrossChainPromises() public {
        vm.selectFork(forkIds[0]);
        
        // Create one local promise
        uint256 localPromise = promiseA.create();
        
        // Use fake promise IDs that could represent cross-chain promises not yet shared
        uint256 fakePromise1 = 999999;
        uint256 fakePromise2 = 888888;
        
        uint256[] memory inputPromises = new uint256[](3);
        inputPromises[0] = localPromise;    // Real local promise
        inputPromises[1] = fakePromise1;    // Non-existent (could be cross-chain)
        inputPromises[2] = fakePromise2;    // Non-existent (could be cross-chain)
        
        // Should be able to create PromiseAll with non-existent promises
        uint256 promiseAllId = promiseAllA.create(inputPromises);
        assertTrue(promiseAllA.exists(promiseAllId), "PromiseAll should exist with non-existent promises");
        
        // Should not be resolvable with non-existent promises (they appear as Pending)
        assertFalse(promiseAllA.canResolve(promiseAllId), "Should not be resolvable with non-existent promises");
        
        // Resolve the local promise
        promiseA.resolve(localPromise, abi.encode("Local Result"));
        
        // Still not resolvable - non-existent promises are still Pending
        assertFalse(promiseAllA.canResolve(promiseAllId), "Still not resolvable with pending non-existent promises");
        
        // Check status - only 1 of 3 resolved
        (uint256 resolvedCount, uint256 totalCount, bool settled) = promiseAllA.getStatus(promiseAllId);
        assertEq(resolvedCount, 1, "Only 1 promise should be resolved");
        assertEq(totalCount, 3, "Should have 3 total promises");
        assertFalse(settled, "Should not be settled");
        
        // For this test, we won't resolve the fake promises to demonstrate the waiting behavior
        // In a real scenario, these would eventually be shared from other chains
    }
}

/// @notice Test contract for PromiseAll callback functionality
contract PromiseAllTarget {
    bool public promiseAllHandled;
    uint256 public resultCount;
    mapping(uint256 => string) private results;

    function handlePromiseAll(bytes memory aggregatedData) external returns (string memory) {
        promiseAllHandled = true;
        
        bytes[] memory resultArray = abi.decode(aggregatedData, (bytes[]));
        resultCount = resultArray.length;
        
        for (uint256 i = 0; i < resultArray.length; i++) {
            results[i] = abi.decode(resultArray[i], (string));
        }
        
        return "PromiseAll handled successfully";
    }

    function getResult(uint256 index) external view returns (string memory) {
        return results[index];
    }

    function reset() external {
        promiseAllHandled = false;
        resultCount = 0;
        // Note: mapping values remain but will be overwritten
    }
} 