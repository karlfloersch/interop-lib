// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Relayer} from "../src/test/Relayer.sol";

import {Promise} from "../src/Promise.sol";
import {SetTimeout} from "../src/SetTimeout.sol";
import {Callback} from "../src/Callback.sol";
import {PredeployAddresses} from "../src/libraries/PredeployAddresses.sol";

/// @title XChainSetTimeout
/// @notice Tests for cross-chain SetTimeout functionality where timeouts created on one chain are referenced from another
contract XChainSetTimeoutTest is Test, Relayer {
    // Contracts on each chain
    Promise public promiseA;
    Promise public promiseB;
    SetTimeout public setTimeoutA;
    SetTimeout public setTimeoutB;
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
        setTimeoutA = new SetTimeout{salt: bytes32(0)}(address(promiseA));
        callbackA = new Callback{salt: bytes32(0)}(
            address(promiseA),
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        
        vm.selectFork(forkIds[1]);
        promiseB = new Promise{salt: bytes32(0)}(
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        setTimeoutB = new SetTimeout{salt: bytes32(0)}(address(promiseB));
        callbackB = new Callback{salt: bytes32(0)}(
            address(promiseB),
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        
        // Verify contracts have same addresses
        require(address(promiseA) == address(promiseB), "Promise contracts must have same address");
        require(address(setTimeoutA) == address(setTimeoutB), "SetTimeout contracts must have same address");
        require(address(callbackA) == address(callbackB), "Callback contracts must have same address");
    }

    /// @notice Test creating timeout on Chain A and using it from Chain B via callback
    function test_CrossChainTimeoutWithCallback() public {
        vm.selectFork(forkIds[0]);
        
        // Create timeout promise on Chain A
        uint256 timeoutPromise = setTimeoutA.create(block.timestamp + 100);
        
        // Create target contract on Chain B
        vm.selectFork(forkIds[1]);
        TimeoutTarget target = new TimeoutTarget();
        
        // Register callback on Chain A that targets Chain B when timeout resolves
        vm.selectFork(forkIds[0]);
        uint256 chainBId = chainIdByForkId[forkIds[1]];
        uint256 callbackPromise = callbackA.thenOn(
            chainBId,
            timeoutPromise,
            address(target),
            target.handleTimeout.selector
        );
        
        // Relay callback registration (transfers resolution rights to Chain B)
        relayAllMessages();
        
        // Verify callback was registered on Chain B after cross-chain setup
        vm.selectFork(forkIds[1]);
        assertTrue(callbackB.exists(callbackPromise), "Callback should be registered on Chain B after relay");
        
        // Fast forward time and resolve timeout on Chain A
        vm.selectFork(forkIds[0]);
        vm.warp(block.timestamp + 150);
        assertTrue(setTimeoutA.canResolve(timeoutPromise), "Timeout should be resolvable");
        setTimeoutA.resolve(timeoutPromise);
        
        // Verify timeout resolved on Chain A
        assertEq(uint8(promiseA.status(timeoutPromise)), uint8(Promise.PromiseStatus.Resolved), "Timeout should be resolved");
        assertEq(setTimeoutA.getTimeout(timeoutPromise), 0, "Timeout mapping should be cleaned up");
        
        // Share the resolved timeout to Chain B so callback can see it
        promiseA.shareResolvedPromise(chainBId, timeoutPromise);
        relayAllMessages();
        
        // Now resolve the callback from Chain B (where resolution rights were transferred)
        vm.selectFork(forkIds[1]);
        assertTrue(callbackB.canResolve(callbackPromise), "Callback should be resolvable on Chain B");
        callbackB.resolve(callbackPromise);
        
        // Verify callback executed successfully on Chain B
        assertTrue(target.timeoutHandled(), "Timeout handler should have been called on Chain B");
        
        // Verify callback promise is resolved on Chain B
        assertEq(uint8(promiseB.status(callbackPromise)), uint8(Promise.PromiseStatus.Resolved), "Callback should be resolved on Chain B");
    }

    /// @notice Test creating timeout on Chain A, then resolving it from Chain B
    function test_CrossChainTimeoutResolution() public {
        vm.selectFork(forkIds[0]);
        
        // Create timeout promise on Chain A
        uint256 timeoutPromise = setTimeoutA.create(block.timestamp + 100);
        uint256 chainBId = chainIdByForkId[forkIds[1]];
        
        // Note: SetTimeout doesn't have cross-chain functionality for sharing timeout mappings,
        // so this test focuses on the promise aspect being cross-chain
        
        // Verify timeout promise exists locally on Chain A but not on Chain B yet
        vm.selectFork(forkIds[1]);
        assertFalse(promiseB.exists(timeoutPromise), "Promise should not exist on Chain B yet");
        assertEq(setTimeoutB.getTimeout(timeoutPromise), 0, "Timeout mapping should not exist on Chain B");
        
        // Fast forward time on both chains
        vm.warp(block.timestamp + 150);
        vm.selectFork(forkIds[0]);
        vm.warp(block.timestamp + 150);
        
        // Resolve timeout on Chain A
        assertTrue(setTimeoutA.canResolve(timeoutPromise), "Timeout should be resolvable on Chain A");
        setTimeoutA.resolve(timeoutPromise);
        
        // Share the resolved promise to Chain B
        promiseA.shareResolvedPromise(chainBId, timeoutPromise);
        relayAllMessages();
        
        // Verify resolved promise on Chain B
        vm.selectFork(forkIds[1]);
        assertEq(uint8(promiseB.status(timeoutPromise)), uint8(Promise.PromiseStatus.Resolved), "Promise should be resolved on Chain B");
    }

    /// @notice Test multiple timeouts on Chain A being watched by callbacks on Chain B
    function test_MultipleCrossChainTimeouts() public {
        vm.selectFork(forkIds[0]);
        
        // Create multiple timeout promises on Chain A with different delays
        uint256 timeout1 = setTimeoutA.create(block.timestamp + 50);
        uint256 timeout2 = setTimeoutA.create(block.timestamp + 100);
        uint256 timeout3 = setTimeoutA.create(block.timestamp + 150);
        
        // Create target contracts on Chain B
        vm.selectFork(forkIds[1]);
        TimeoutTarget target1 = new TimeoutTarget();
        TimeoutTarget target2 = new TimeoutTarget();
        TimeoutTarget target3 = new TimeoutTarget();
        
        // Register callbacks on Chain A that target Chain B for all timeouts
        vm.selectFork(forkIds[0]);
        uint256 chainBId = chainIdByForkId[forkIds[1]];
        uint256 callback1 = callbackA.thenOn(chainBId, timeout1, address(target1), target1.handleTimeout.selector);
        uint256 callback2 = callbackA.thenOn(chainBId, timeout2, address(target2), target2.handleTimeout.selector);
        uint256 callback3 = callbackA.thenOn(chainBId, timeout3, address(target3), target3.handleTimeout.selector);
        
        // Relay callback registrations
        relayAllMessages();
        
        // Resolve timeouts one by one and verify callbacks execute
        vm.selectFork(forkIds[0]);
        
        // Resolve first timeout
        vm.warp(block.timestamp + 60);
        setTimeoutA.resolve(timeout1);
        
        // Share resolved timeout to Chain B and resolve callback on Chain B
        promiseA.shareResolvedPromise(chainBId, timeout1);
        relayAllMessages();
        
        vm.selectFork(forkIds[1]);
        callbackB.resolve(callback1);
        assertTrue(target1.timeoutHandled(), "First timeout should be handled");
        assertFalse(target2.timeoutHandled(), "Second timeout should not be handled yet");
        assertFalse(target3.timeoutHandled(), "Third timeout should not be handled yet");
        
        // Resolve second timeout
        vm.selectFork(forkIds[0]);
        vm.warp(block.timestamp + 50); // Total 110 seconds
        setTimeoutA.resolve(timeout2);
        promiseA.shareResolvedPromise(chainBId, timeout2);
        relayAllMessages();
        
        vm.selectFork(forkIds[1]);
        callbackB.resolve(callback2);
        assertTrue(target2.timeoutHandled(), "Second timeout should be handled");
        assertFalse(target3.timeoutHandled(), "Third timeout should not be handled yet");
        
        // Resolve third timeout
        vm.selectFork(forkIds[0]);
        vm.warp(block.timestamp + 50); // Total 160 seconds
        setTimeoutA.resolve(timeout3);
        promiseA.shareResolvedPromise(chainBId, timeout3);
        relayAllMessages();
        
        vm.selectFork(forkIds[1]);
        callbackB.resolve(callback3);
        assertTrue(target3.timeoutHandled(), "Third timeout should be handled");
    }

    /// @notice Test that timeout promises have global IDs that work across chains
    function test_TimeoutGlobalPromiseIds() public {
        vm.selectFork(forkIds[0]);
        
        // Create timeout on Chain A
        uint256 timeoutPromise = setTimeoutA.create(block.timestamp + 100);
        
        // Verify the promise ID is a global hash-based ID
        uint256 expectedGlobalId = promiseA.generateGlobalPromiseId(chainIdByForkId[forkIds[0]], 1);
        assertEq(timeoutPromise, expectedGlobalId, "Timeout promise should have global ID");
        
        // Verify that the same global ID would be generated on Chain B
        vm.selectFork(forkIds[1]);
        uint256 sameGlobalId = promiseB.generateGlobalPromiseId(chainIdByForkId[forkIds[0]], 1);
        assertEq(timeoutPromise, sameGlobalId, "Promise ID should be globally consistent across chains");
        
        // Resolve the timeout and then share it to verify cross-chain functionality
        vm.selectFork(forkIds[0]);
        vm.warp(block.timestamp + 150);
        setTimeoutA.resolve(timeoutPromise);
        
        uint256 chainBId = chainIdByForkId[forkIds[1]];
        promiseA.shareResolvedPromise(chainBId, timeoutPromise);
        relayAllMessages();
        
        // Verify the same promise ID exists on Chain B after sharing
        vm.selectFork(forkIds[1]);
        assertTrue(promiseB.exists(timeoutPromise), "Same promise ID should exist on Chain B after sharing");
    }
}

/// @notice Test contract for timeout callback functionality
contract TimeoutTarget {
    bool public timeoutHandled;
    uint256 public callCount;

    function handleTimeout(bytes memory) external returns (string memory) {
        timeoutHandled = true;
        callCount++;
        return "timeout handled";
    }

    function reset() external {
        timeoutHandled = false;
        callCount = 0;
    }
} 