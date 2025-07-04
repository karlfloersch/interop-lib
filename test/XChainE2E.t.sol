// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Relayer} from "../src/test/Relayer.sol";

import {Promise} from "../src/Promise.sol";
import {SetTimeout} from "../src/SetTimeout.sol";
import {Callback} from "../src/Callback.sol";
import {PromiseAll} from "../src/PromiseAll.sol";
import {PredeployAddresses} from "../src/libraries/PredeployAddresses.sol";

/// @title XChainE2E - Cross-Chain Periodic Fee Collection and Burning
/// @notice End-to-end test demonstrating automatic periodic fee collection from multiple chains
/// @dev This test shows a realistic cross-chain cron job system that:
///      1. Uses SetTimeout for periodic scheduling (cron job)
///      2. Uses cross-chain Callbacks to collect fees from Chain A and Chain B
///      3. Uses PromiseAll to wait for both fee collections to complete
///      4. Uses Callback to burn collected fees when aggregation is complete
///      5. Schedules the next cycle automatically
contract XChainE2ETest is Test, Relayer {
    // Contracts on each chain
    Promise public promiseA;
    Promise public promiseB;
    SetTimeout public setTimeoutA;
    SetTimeout public setTimeoutB;
    Callback public callbackA;
    Callback public callbackB;
    PromiseAll public promiseAllA;
    PromiseAll public promiseAllB;

    // Test contracts for fee collection and burning
    FeeCollector public feeCollectorA;
    FeeCollector public feeCollectorB;
    FeeBurner public feeBurner;
    CronScheduler public cronScheduler;

    string[] private rpcUrls = [
        vm.envOr("CHAIN_A_RPC_URL", string("https://interop-alpha-0.optimism.io")),
        vm.envOr("CHAIN_B_RPC_URL", string("https://interop-alpha-1.optimism.io"))
    ];

    constructor() Relayer(rpcUrls) {}

    function setUp() public {
        // Deploy promise system contracts using CREATE2 for same addresses
        vm.selectFork(forkIds[0]);
        promiseA = new Promise{salt: bytes32(0)}(
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        setTimeoutA = new SetTimeout{salt: bytes32(0)}(address(promiseA));
        callbackA = new Callback{salt: bytes32(0)}(
            address(promiseA),
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        promiseAllA = new PromiseAll{salt: bytes32(0)}(address(promiseA));
        
        vm.selectFork(forkIds[1]);
        promiseB = new Promise{salt: bytes32(0)}(
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        setTimeoutB = new SetTimeout{salt: bytes32(0)}(address(promiseB));
        callbackB = new Callback{salt: bytes32(0)}(
            address(promiseB),
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        promiseAllB = new PromiseAll{salt: bytes32(0)}(address(promiseB));
        
        // Verify contracts have same addresses
        require(address(promiseA) == address(promiseB), "Promise contracts must have same address");
        require(address(setTimeoutA) == address(setTimeoutB), "SetTimeout contracts must have same address");
        require(address(callbackA) == address(callbackB), "Callback contracts must have same address");
        require(address(promiseAllA) == address(promiseAllB), "PromiseAll contracts must have same address");

        // Deploy application contracts
        vm.selectFork(forkIds[0]);
        feeCollectorA = new FeeCollector{salt: bytes32(0)}();
        feeBurner = new FeeBurner{salt: bytes32(0)}();
        cronScheduler = new CronScheduler{salt: bytes32(0)}(
            address(promiseA),
            address(setTimeoutA),
            address(callbackA),
            address(promiseAllA),
            chainIdByForkId[forkIds[1]]
        );
        
        vm.selectFork(forkIds[1]);
        feeCollectorB = new FeeCollector{salt: bytes32(0)}();
        
        // Verify application contracts have same addresses where needed
        require(address(feeCollectorA) == address(feeCollectorB), "FeeCollector contracts must have same address");
    }

    /// @notice Test complete periodic fee collection and burning cycle
    function test_PeriodicFeeCollectionAndBurning() public {
        vm.selectFork(forkIds[0]);
        
        // Simulate accumulated fees on both chains
        feeCollectorA.simulateAccumulatedFees(1000 ether);
        vm.selectFork(forkIds[1]);
        feeCollectorB.simulateAccumulatedFees(500 ether);
        
        // Start the first cycle
        vm.selectFork(forkIds[0]);
        uint256 cycleId = cronScheduler.startPeriodicFeeCollection(
            3600, // Run every hour (interval in seconds)
            address(feeCollectorA),  // Chain A fee collector
            address(feeCollectorB),  // Chain B fee collector (same address)
            address(feeBurner)       // Fee burner
        );
        
        // Verify the cycle was set up correctly
        CronScheduler.CycleInfo memory cycle = cronScheduler.getCycle(cycleId);
        assertTrue(cycle.active, "Cycle should be active");
        assertEq(cycle.interval, 3600, "Interval should be 1 hour");
        assertEq(cycle.executionCount, 0, "Should start with 0 executions");
        
        // Fast forward to trigger the first execution
        vm.warp(block.timestamp + 3700); // Slightly past the interval
        
        // Resolve the timeout that should trigger this cycle (this will automatically execute the cycle)
        bytes32 triggerTimeoutId = cronScheduler.getNextTimeoutId(cycleId);
        assertTrue(setTimeoutA.canResolve(triggerTimeoutId), "Trigger timeout should be resolvable");
        setTimeoutA.resolve(triggerTimeoutId);
        
        // Resolve the automatic cycle execution callback
        bytes32 executionCallbackId = cronScheduler.getExecutionCallbackId(cycleId);
        assertTrue(executionCallbackId > 0, "Should have execution callback ID");
        assertTrue(callbackA.canResolve(executionCallbackId), "Execution callback should be resolvable");
        callbackA.resolve(executionCallbackId);
        
        // Relay all cross-chain messages for callback registration
        relayAllMessages();
        
        // Share the resolved timeout to Chain B so cross-chain callbacks can see it
        uint256 chainBId = chainIdByForkId[forkIds[1]];
        promiseA.shareResolvedPromise(chainBId, triggerTimeoutId);
        relayAllMessages();
        
        // Now the fee collection callbacks should be resolvable
        // Resolve Chain A fee collection
        bytes32 chainAFeeCollectionPromise = cronScheduler.getLastChainAFeePromise(cycleId);
        assertTrue(callbackA.canResolve(chainAFeeCollectionPromise), "Chain A fee collection should be resolvable");
        callbackA.resolve(chainAFeeCollectionPromise);
        
        // Resolve Chain B fee collection
        bytes32 chainBFeeCollectionPromise = cronScheduler.getLastChainBFeePromise(cycleId);
        vm.selectFork(forkIds[1]);
        assertTrue(callbackB.canResolve(chainBFeeCollectionPromise), "Chain B fee collection should be resolvable");
        callbackB.resolve(chainBFeeCollectionPromise);
        
        // Share Chain B fee collection result back to Chain A
        uint256 chainAId = chainIdByForkId[forkIds[0]];
        promiseB.shareResolvedPromise(chainAId, chainBFeeCollectionPromise);
        relayAllMessages();
        
        // Now the PromiseAll on Chain A should be resolvable
        vm.selectFork(forkIds[0]);
        bytes32 promiseAllId = cronScheduler.getLastPromiseAllId(cycleId);
        assertTrue(promiseAllA.canResolve(promiseAllId), "PromiseAll should be resolvable");
        promiseAllA.resolve(promiseAllId);
        
        // The burn callback should now be resolvable
        bytes32 burnCallbackId = cronScheduler.getLastBurnCallbackId(cycleId);
        assertTrue(callbackA.canResolve(burnCallbackId), "Burn callback should be resolvable");
        callbackA.resolve(burnCallbackId);
        
        // Verify the fees were collected and burned
        assertTrue(feeCollectorA.wasCollected(), "Chain A fees should be collected");
        vm.selectFork(forkIds[1]);
        assertTrue(feeCollectorB.wasCollected(), "Chain B fees should be collected");
        vm.selectFork(forkIds[0]);
        assertTrue(feeBurner.wasBurned(), "Fees should be burned");
        
        // Verify the amounts
        assertEq(feeBurner.totalBurned(), 1500 ether, "Should burn total of 1500 ETH");
        assertEq(feeBurner.lastBurnAmount(), 1500 ether, "Last burn should be 1500 ETH");
        
        // Verify cycle state
        cycle = cronScheduler.getCycle(cycleId);
        assertEq(cycle.executionCount, 1, "Should have 1 execution");
        assertTrue(cycle.active, "Cycle should still be active");
        
        // Verify the next timeout was scheduled
        bytes32 nextTimeoutId = cronScheduler.getNextTimeoutId(cycleId);
        assertTrue(nextTimeoutId > 0, "Next timeout should be scheduled");
        assertEq(uint8(promiseA.status(nextTimeoutId)), uint8(Promise.PromiseStatus.Pending), "Next timeout should be pending");
    }

    /// @notice Test multiple cycles running
    function test_MultipleCycles() public {
        vm.selectFork(forkIds[0]);
        
        // Set up initial fees
        feeCollectorA.simulateAccumulatedFees(1000 ether);
        vm.selectFork(forkIds[1]);
        feeCollectorB.simulateAccumulatedFees(500 ether);
        
        vm.selectFork(forkIds[0]);
        
        // Start cycle
        uint256 cycleId = cronScheduler.startPeriodicFeeCollection(
            1800, // 30 minutes interval
            address(feeCollectorA),
            address(feeCollectorB),
            address(feeBurner)
        );
        
        // Time passes and first cycle triggers automatically
        vm.warp(block.timestamp + 1900);
        
        // Resolve the trigger timeout (this will automatically execute the cycle)
        bytes32 timeoutId = cronScheduler.getNextTimeoutId(cycleId);
        setTimeoutA.resolve(timeoutId);
        
        // Resolve the automatic cycle execution callback
        bytes32 executionCallbackId = cronScheduler.getExecutionCallbackId(cycleId);
        assertTrue(executionCallbackId > 0, "Should have execution callback ID");
        assertTrue(callbackA.canResolve(executionCallbackId), "Execution callback should be resolvable");
        callbackA.resolve(executionCallbackId);
        relayAllMessages();
        
        // Share timeout to Chain B for cross-chain callbacks
        promiseA.shareResolvedPromise(chainIdByForkId[forkIds[1]], timeoutId);
        relayAllMessages();
        
        // Resolve everything for first cycle
        bytes32 chainAPromise = cronScheduler.getLastChainAFeePromise(cycleId);
        callbackA.resolve(chainAPromise);
        
        bytes32 chainBPromise = cronScheduler.getLastChainBFeePromise(cycleId);
        vm.selectFork(forkIds[1]);
        callbackB.resolve(chainBPromise);
        promiseB.shareResolvedPromise(chainIdByForkId[forkIds[0]], chainBPromise);
        relayAllMessages();
        
        vm.selectFork(forkIds[0]);
        bytes32 promiseAllId = cronScheduler.getLastPromiseAllId(cycleId);
        promiseAllA.resolve(promiseAllId);
        bytes32 burnCallbackId = cronScheduler.getLastBurnCallbackId(cycleId);
        callbackA.resolve(burnCallbackId);
        
        // Verify first cycle completed
        assertEq(feeBurner.totalBurned(), 1500 ether, "First cycle should burn 1500 ETH");
        
        // Add more fees for second cycle
        feeCollectorA.simulateAccumulatedFees(800 ether);
        vm.selectFork(forkIds[1]);
        feeCollectorB.simulateAccumulatedFees(300 ether);
        vm.selectFork(forkIds[0]);
        
        // Time passes and second cycle triggers automatically  
        vm.selectFork(forkIds[0]);
        vm.warp(block.timestamp + 1800); // Another 30 minutes
        
        // Resolve the next timeout (this will automatically execute the second cycle)
        bytes32 nextTimeoutId = cronScheduler.getNextTimeoutId(cycleId);
        setTimeoutA.resolve(nextTimeoutId);
        
        // Resolve the automatic cycle execution callback for second cycle
        executionCallbackId = cronScheduler.getExecutionCallbackId(cycleId);
        assertTrue(executionCallbackId > 0, "Should have execution callback ID for second cycle");
        assertTrue(callbackA.canResolve(executionCallbackId), "Second cycle execution callback should be resolvable");
        callbackA.resolve(executionCallbackId);
        relayAllMessages();
        
        // The timeout that just resolved becomes the "last" timeout for this cycle
        timeoutId = nextTimeoutId;
        
        // Share timeout to Chain B for cross-chain callbacks
        promiseA.shareResolvedPromise(chainIdByForkId[forkIds[1]], timeoutId);
        relayAllMessages();
        
        // Resolve second cycle
        chainAPromise = cronScheduler.getLastChainAFeePromise(cycleId);
        callbackA.resolve(chainAPromise);
        
        chainBPromise = cronScheduler.getLastChainBFeePromise(cycleId);
        vm.selectFork(forkIds[1]);
        callbackB.resolve(chainBPromise);
        promiseB.shareResolvedPromise(chainIdByForkId[forkIds[0]], chainBPromise);
        relayAllMessages();
        
        vm.selectFork(forkIds[0]);
        promiseAllId = cronScheduler.getLastPromiseAllId(cycleId);
        promiseAllA.resolve(promiseAllId);
        burnCallbackId = cronScheduler.getLastBurnCallbackId(cycleId);
        callbackA.resolve(burnCallbackId);
        
        // Verify second cycle completed
        assertEq(feeBurner.totalBurned(), 2600 ether, "Total should be 2600 ETH after second cycle");
        assertEq(feeBurner.lastBurnAmount(), 1100 ether, "Second cycle should burn 1100 ETH");
        
        // Verify cycle state
        CronScheduler.CycleInfo memory cycle = cronScheduler.getCycle(cycleId);
        assertEq(cycle.executionCount, 2, "Should have 2 executions");
    }

    /// @notice Test stopping a cycle
    function test_StopCycle() public {
        vm.selectFork(forkIds[0]);
        
        uint256 cycleId = cronScheduler.startPeriodicFeeCollection(
            3600, // 1 hour interval
            address(feeCollectorA),
            address(feeCollectorB),
            address(feeBurner)
        );
        
        // Verify cycle is active
        CronScheduler.CycleInfo memory cycle = cronScheduler.getCycle(cycleId);
        assertTrue(cycle.active, "Cycle should be active");
        
        // Stop the cycle
        cronScheduler.stopCycle(cycleId);
        
        // Verify cycle is stopped
        cycle = cronScheduler.getCycle(cycleId);
        assertFalse(cycle.active, "Cycle should be stopped");
        
        // Try to execute stopped cycle (should revert)
        vm.warp(block.timestamp + 3700);
        vm.expectRevert("CronScheduler: cycle not active");
        cronScheduler.executeCycle(cycleId);
    }

    /// @notice Test error handling when fee collection fails
    function test_FeeCollectionFailureHandling() public {
        vm.selectFork(forkIds[0]);
        
        // Set up fee collector to fail
        feeCollectorA.setFailureMode(true);
        
        uint256 cycleId = cronScheduler.startPeriodicFeeCollection(
            3600, // 1 hour interval
            address(feeCollectorA),
            address(feeCollectorB),
            address(feeBurner)
        );
        
        vm.warp(block.timestamp + 3700);
        
        // Resolve the timeout that should trigger this cycle (this will automatically execute the cycle)
        bytes32 triggerTimeoutId = cronScheduler.getNextTimeoutId(cycleId);
        setTimeoutA.resolve(triggerTimeoutId);
        
        // Resolve the automatic cycle execution callback
        bytes32 executionCallbackId = cronScheduler.getExecutionCallbackId(cycleId);
        assertTrue(executionCallbackId > 0, "Should have execution callback ID");
        assertTrue(callbackA.canResolve(executionCallbackId), "Execution callback should be resolvable");
        callbackA.resolve(executionCallbackId);
        relayAllMessages();
        
        // Share timeout to Chain B for cross-chain callbacks
        promiseA.shareResolvedPromise(chainIdByForkId[forkIds[1]], triggerTimeoutId);
        relayAllMessages();
        
        // Try to resolve the failing fee collection
        bytes32 chainAPromise = cronScheduler.getLastChainAFeePromise(cycleId);
        assertTrue(callbackA.canResolve(chainAPromise), "Should be resolvable for rejection");
        callbackA.resolve(chainAPromise);
        
        // Verify the promise was rejected due to failure
        assertEq(uint8(promiseA.status(chainAPromise)), uint8(Promise.PromiseStatus.Rejected), "Chain A fee collection should be rejected");
        
        // Also resolve Chain B fee collection (should succeed)
        bytes32 chainBPromise = cronScheduler.getLastChainBFeePromise(cycleId);
        vm.selectFork(forkIds[1]);
        assertTrue(callbackB.canResolve(chainBPromise), "Chain B fee collection should be resolvable");
        callbackB.resolve(chainBPromise);
        
        // Share Chain B result to Chain A
        uint256 chainAId = chainIdByForkId[forkIds[0]];
        promiseB.shareResolvedPromise(chainAId, chainBPromise);
        relayAllMessages();
        
        // The PromiseAll should now be resolvable (for rejection due to Chain A failure)
        vm.selectFork(forkIds[0]);
        bytes32 promiseAllId = cronScheduler.getLastPromiseAllId(cycleId);
        assertTrue(promiseAllA.canResolve(promiseAllId), "PromiseAll should be resolvable for rejection");
        promiseAllA.resolve(promiseAllId);
        
        // Verify PromiseAll was rejected
        assertEq(uint8(promiseA.status(promiseAllId)), uint8(Promise.PromiseStatus.Rejected), "PromiseAll should be rejected");
        
        // The burn callback might be resolvable but should get rejected
        bytes32 burnCallbackId = cronScheduler.getLastBurnCallbackId(cycleId);
        if (callbackA.canResolve(burnCallbackId)) {
            // If it's resolvable, resolve it and verify it gets rejected
            callbackA.resolve(burnCallbackId);
            assertEq(uint8(promiseA.status(burnCallbackId)), uint8(Promise.PromiseStatus.Rejected), "Burn callback should be rejected when PromiseAll fails");
        }
        
        // Verify no fees were burned
        vm.selectFork(forkIds[0]);
        assertEq(feeBurner.totalBurned(), 0, "No fees should be burned on failure");
    }

    /// @notice Test remote promise callback orchestration - Chain A orchestrates workflow triggered by Chain B timeout
    /// @dev This demonstrates the new functionality where callbacks can be created for promises that don't exist locally
    function test_RemotePromiseTimeoutOrchestration() public {
        vm.selectFork(forkIds[0]);
        
        // Simulate accumulated fees on both chains
        feeCollectorA.simulateAccumulatedFees(800 ether);
        vm.selectFork(forkIds[1]);
        feeCollectorB.simulateAccumulatedFees(400 ether);
        
        // **KEY DEMONSTRATION**: Chain B creates the timeout (the trigger)
        vm.selectFork(forkIds[1]);
        bytes32 remoteTimeoutId = setTimeoutB.create(1800); // 30 minutes
        
        // **REMOTE PROMISE CALLBACKS**: Chain A creates callbacks for the remote timeout promise
        // This demonstrates the new functionality - callbacks for promises that don't exist locally
        vm.selectFork(forkIds[0]);
        
        // Verify the timeout promise doesn't exist on Chain A yet
        assertFalse(promiseA.exists(remoteTimeoutId), "Remote timeout should not exist locally on Chain A");
        
        // Chain A creates callbacks for the remote timeout (this is the new functionality!)
        bytes32 chainAFeeCallback = callbackA.then(
            remoteTimeoutId,  // Remote promise ID from Chain B
            address(feeCollectorA),
            FeeCollector.collectFees.selector
        );
        
        bytes32 chainBFeeCallback = callbackA.thenOn(
            chainIdByForkId[forkIds[1]],
            remoteTimeoutId,  // Remote promise ID from Chain B  
            address(feeCollectorB),
            FeeCollector.collectFees.selector
        );
        
        // Debug: Check what IDs were returned
        assertTrue(chainAFeeCallback > 0, "Chain A fee callback ID should be non-zero");
        assertTrue(chainBFeeCallback > 0, "Chain B fee callback ID should be non-zero");
        
        // Verify callbacks were created correctly
        // Local callback should exist on Chain A
        assertTrue(callbackA.exists(chainAFeeCallback), "Chain A fee callback should exist for remote promise");
        
        // Cross-chain callback should NOT exist on Chain A (transferred to Chain B)
        assertFalse(callbackA.exists(chainBFeeCallback), "Cross-chain callback should not exist on Chain A after transfer");
        
        // Local callback should not be resolvable yet (parent promise not shared)
        assertFalse(callbackA.canResolve(chainAFeeCallback), "Local callback should not be resolvable yet");
        
        // Chain A orchestrates the aggregation using the remote timeout
        bytes32[] memory feeCallbacks = new bytes32[](2);
        feeCallbacks[0] = chainAFeeCallback;
        feeCallbacks[1] = chainBFeeCallback;
        
        bytes32 promiseAllId = promiseAllA.create(feeCallbacks);
        
        // Chain A sets up burning when all fees are collected
        bytes32 burnCallback = callbackA.then(
            promiseAllId,
            address(feeBurner),
            FeeBurner.burnFees.selector
        );
        
        // Relay cross-chain callback registration
        relayAllMessages();
        
        // Verify cross-chain callback was registered on Chain B
        vm.selectFork(forkIds[1]);
        assertTrue(callbackB.exists(chainBFeeCallback), "Cross-chain callback should exist on Chain B after relay");
        vm.selectFork(forkIds[0]);
        
        // Time passes and the timeout triggers on both chains
        vm.warp(block.timestamp + 1900); // Warp time on Chain A first
        vm.selectFork(forkIds[1]);
        vm.warp(block.timestamp + 1900); // Warp time on Chain B fork
        
        // Chain B resolves its timeout
        assertTrue(setTimeoutB.canResolve(remoteTimeoutId), "Remote timeout should be resolvable on Chain B");
        setTimeoutB.resolve(remoteTimeoutId);
        
        // **CRITICAL STEP**: Chain B shares the resolved timeout to Chain A
        uint256 chainAId = chainIdByForkId[forkIds[0]];
        promiseB.shareResolvedPromise(chainAId, remoteTimeoutId);
        relayAllMessages();
        
        // Now Chain A can see the resolved timeout and execute its workflow
        vm.selectFork(forkIds[0]);
        assertTrue(promiseA.exists(remoteTimeoutId), "Remote timeout should now exist on Chain A");
        assertEq(uint8(promiseA.status(remoteTimeoutId)), uint8(Promise.PromiseStatus.Resolved), "Remote timeout should be resolved");
        
        // Chain A local callback should now be resolvable
        assertTrue(callbackA.canResolve(chainAFeeCallback), "Chain A fee callback should be resolvable");
        
        // Chain B callback should be resolvable on Chain B
        vm.selectFork(forkIds[1]);
        assertTrue(callbackB.canResolve(chainBFeeCallback), "Chain B fee callback should be resolvable on Chain B");
        vm.selectFork(forkIds[0]);
        
        // Execute fee collection on Chain A
        callbackA.resolve(chainAFeeCallback);
        
        // Execute fee collection on Chain B (callback was registered cross-chain)
        vm.selectFork(forkIds[1]);
        assertTrue(callbackB.canResolve(chainBFeeCallback), "Chain B callback should be resolvable");
        callbackB.resolve(chainBFeeCallback);
        
        // Share Chain B fee collection result back to Chain A
        promiseB.shareResolvedPromise(chainAId, chainBFeeCallback);
        relayAllMessages();
        
        // Chain A aggregates all results
        vm.selectFork(forkIds[0]);
        assertTrue(promiseAllA.canResolve(promiseAllId), "PromiseAll should be resolvable");
        promiseAllA.resolve(promiseAllId);
        
        // Chain A burns the aggregated fees
        assertTrue(callbackA.canResolve(burnCallback), "Burn callback should be resolvable");
        callbackA.resolve(burnCallback);
        
        // Verify the entire workflow completed successfully
        assertTrue(feeCollectorA.wasCollected(), "Chain A fees should be collected");
        vm.selectFork(forkIds[1]);
        assertTrue(feeCollectorB.wasCollected(), "Chain B fees should be collected");
        vm.selectFork(forkIds[0]);
        assertTrue(feeBurner.wasBurned(), "Fees should be burned");
        
        // Verify the amounts
        assertEq(feeBurner.totalBurned(), 1200 ether, "Should burn total of 1200 ETH (800 + 400)");
        assertEq(feeBurner.lastBurnAmount(), 1200 ether, "Last burn should be 1200 ETH");
        
        // **SUMMARY**: This test demonstrates:
        // 1. Chain A created callbacks for a promise that only existed on Chain B (remote promise callbacks)
        // 2. Chain A orchestrated a complex multi-chain workflow triggered by Chain B's timeout
        // 3. The workflow executed correctly after the remote promise was shared
        // 4. Demonstrates practical use case for remote promise callback functionality
    }
}

/// @notice Mock fee collector contract
contract FeeCollector {
    uint256 public accumulatedFees;
    bool public wasCollected;
    bool public failureMode;
    
    function simulateAccumulatedFees(uint256 amount) external {
        accumulatedFees += amount;
    }
    
    function setFailureMode(bool shouldFail) external {
        failureMode = shouldFail;
    }
    
    function collectFees(bytes memory) external returns (uint256) {
        if (failureMode) {
            revert("Fee collection failed");
        }
        
        wasCollected = true;
        uint256 collected = accumulatedFees;
        accumulatedFees = 0;
        return collected;
    }
    
    function reset() external {
        accumulatedFees = 0;
        wasCollected = false;
        failureMode = false;
    }
}

/// @notice Mock fee burner contract
contract FeeBurner {
    uint256 public totalBurned;
    uint256 public lastBurnAmount;
    bool public wasBurned;
    
    function burnFees(bytes memory aggregatedFeeData) external returns (string memory) {
        wasBurned = true;
        
        // Decode the aggregated fee data from PromiseAll
        bytes[] memory feeResults = abi.decode(aggregatedFeeData, (bytes[]));
        
        uint256 totalToBurn = 0;
        for (uint256 i = 0; i < feeResults.length; i++) {
            uint256 amount = abi.decode(feeResults[i], (uint256));
            totalToBurn += amount;
        }
        
        lastBurnAmount = totalToBurn;
        totalBurned += totalToBurn;
        
        return "Fees burned successfully";
    }
    
    function reset() external {
        totalBurned = 0;
        lastBurnAmount = 0;
        wasBurned = false;
    }
}

/// @notice Cron scheduler that orchestrates the periodic fee collection
contract CronScheduler {
    struct CycleInfo {
        bool active;
        uint256 interval;
        uint256 executionCount;
        uint256 lastExecution;
        address chainAFeeCollector;
        address chainBFeeCollector;
        address feeBurner;
        uint256 chainBId;
    }
    
    // Storage for tracking cycles and their promises
    mapping(uint256 => CycleInfo) public cycles;
    mapping(uint256 => bytes32) public lastTimeoutIds;
    mapping(uint256 => bytes32) public lastChainAFeePromises;
    mapping(uint256 => bytes32) public lastChainBFeePromises;
    mapping(uint256 => bytes32) public lastPromiseAllIds;
    mapping(uint256 => bytes32) public lastBurnCallbackIds;
    mapping(uint256 => bytes32) public nextTimeoutIds;
    mapping(bytes32 => uint256) public timeoutToCycle; // Maps timeout ID to cycle ID
    mapping(uint256 => bytes32) public executionCallbackIds; // Maps cycle ID to execution callback ID
    
    uint256 public nextCycleId = 1;
    
    Promise public promiseContract;
    SetTimeout public setTimeoutContract;
    Callback public callbackContract;
    PromiseAll public promiseAllContract;
    uint256 public chainBId;
    
    constructor(
        address _promiseContract,
        address _setTimeoutContract,
        address _callbackContract,
        address _promiseAllContract,
        uint256 _chainBId
    ) {
        promiseContract = Promise(_promiseContract);
        setTimeoutContract = SetTimeout(_setTimeoutContract);
        callbackContract = Callback(_callbackContract);
        promiseAllContract = PromiseAll(_promiseAllContract);
        chainBId = _chainBId;
    }
    
    function startPeriodicFeeCollection(
        uint256 intervalSeconds,
        address chainAFeeCollector,
        address chainBFeeCollector,
        address feeBurner
    ) external returns (uint256) {
        uint256 cycleId = nextCycleId++;
        
        cycles[cycleId] = CycleInfo({
            active: true,
            interval: intervalSeconds,
            executionCount: 0,
            lastExecution: 0,
            chainAFeeCollector: chainAFeeCollector,
            chainBFeeCollector: chainBFeeCollector,
            feeBurner: feeBurner,
            chainBId: chainBId
        });
        
        // Schedule the first execution
        bytes32 firstTimeoutId = setTimeoutContract.create(intervalSeconds);
        nextTimeoutIds[cycleId] = firstTimeoutId;
        
        // Store the timeout-to-cycle mapping for automatic execution
        timeoutToCycle[firstTimeoutId] = cycleId;
        
        // Create callback for automatic first execution
        bytes32 executionCallbackId = callbackContract.then(
            firstTimeoutId,
            address(this),
            CronScheduler.executeCycleCallback.selector
        );
        executionCallbackIds[cycleId] = executionCallbackId;
        
        return cycleId;
    }
    
    function executeCycle(uint256 cycleId) external {
        CycleInfo storage cycle = cycles[cycleId];
        require(cycle.active, "CronScheduler: cycle not active");
        
        // Create cross-chain fee collection callbacks
        bytes32 chainAFeePromise = callbackContract.then(
            nextTimeoutIds[cycleId],
            cycle.chainAFeeCollector,
            FeeCollector.collectFees.selector
        );
        
        bytes32 chainBFeePromise = callbackContract.thenOn(
            cycle.chainBId,
            nextTimeoutIds[cycleId],
            cycle.chainBFeeCollector,
            FeeCollector.collectFees.selector
        );
        
        // Create PromiseAll to wait for both fee collections
        bytes32[] memory feePromises = new bytes32[](2);
        feePromises[0] = chainAFeePromise;
        feePromises[1] = chainBFeePromise;
        
        bytes32 promiseAllId = promiseAllContract.create(feePromises);
        
        // Create burn callback that executes when both fees are collected
        bytes32 burnCallbackId = callbackContract.then(
            promiseAllId,
            cycle.feeBurner,
            FeeBurner.burnFees.selector
        );
        
        // **CRON MAGIC**: Schedule next execution automatically
        bytes32 nextTimeoutId = setTimeoutContract.create(cycle.interval);
        
        // Store the timeout-to-cycle mapping for automatic execution
        timeoutToCycle[nextTimeoutId] = cycleId;
        
        // **AUTOMATIC TRIGGERING**: Create callback to automatically execute next cycle  
        bytes32 nextExecutionCallbackId = callbackContract.then(
            nextTimeoutId,
            address(this),
            CronScheduler.executeCycleCallback.selector
        );
        executionCallbackIds[cycleId] = nextExecutionCallbackId;
        
        // Store promise IDs for tracking
        lastTimeoutIds[cycleId] = nextTimeoutIds[cycleId];
        lastChainAFeePromises[cycleId] = chainAFeePromise;
        lastChainBFeePromises[cycleId] = chainBFeePromise;
        lastPromiseAllIds[cycleId] = promiseAllId;
        lastBurnCallbackIds[cycleId] = burnCallbackId;
        nextTimeoutIds[cycleId] = nextTimeoutId;
        
        // Update cycle info
        cycle.executionCount++;
        cycle.lastExecution = block.timestamp;
    }
    
    /// @notice Callback wrapper for automatic cycle execution  
    /// @dev This function is called automatically when timeout resolves
    function executeCycleCallback(bytes memory /* data */) external returns (string memory) {
        // Find which cycle needs to be executed by checking which timeout is resolved
        // but hasn't been processed yet (executionCount hasn't been incremented)
        for (uint256 cycleId = 1; cycleId < nextCycleId; cycleId++) {
            if (!cycles[cycleId].active) continue;
            
            bytes32 timeoutId = nextTimeoutIds[cycleId];
            if (timeoutId > 0 && 
                promiseContract.status(timeoutId) == Promise.PromiseStatus.Resolved &&
                (cycles[cycleId].lastExecution == 0 || block.timestamp >= cycles[cycleId].lastExecution + cycles[cycleId].interval)) {
                // This timeout resolved and cycle is ready
                this.executeCycle(cycleId);
                return "Cycle executed automatically";
            }
        }
        return "No cycles ready for execution";
    }
    
    function stopCycle(uint256 cycleId) external {
        cycles[cycleId].active = false;
    }
    
    function getCycle(uint256 cycleId) external view returns (CycleInfo memory) {
        return cycles[cycleId];
    }
    
    function getLastChainAFeePromise(uint256 cycleId) external view returns (bytes32) {
        return lastChainAFeePromises[cycleId];
    }
    
    function getLastChainBFeePromise(uint256 cycleId) external view returns (bytes32) {
        return lastChainBFeePromises[cycleId];
    }
    
    function getLastPromiseAllId(uint256 cycleId) external view returns (bytes32) {
        return lastPromiseAllIds[cycleId];
    }
    
    function getLastBurnCallbackId(uint256 cycleId) external view returns (bytes32) {
        return lastBurnCallbackIds[cycleId];
    }
    
    function getLastTimeoutId(uint256 cycleId) external view returns (bytes32) {
        return lastTimeoutIds[cycleId];
    }
    
    function getNextTimeoutId(uint256 cycleId) external view returns (bytes32) {
        return nextTimeoutIds[cycleId];
    }
    
    function getExecutionCallbackId(uint256 cycleId) external view returns (bytes32) {
        return executionCallbackIds[cycleId];
    }
} 