// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {Promise} from "../src/Promise.sol";
import {SetTimeout} from "../src/SetTimeout.sol";
import {Callback} from "../src/Callback.sol";
import {PromiseAll} from "../src/PromiseAll.sol";
import {PromiseChain} from "../src/PromiseChain.sol";
import {PromiseUtils} from "../src/PromiseUtils.sol";
import {PromiseHarness} from "./PromiseHarness.sol";

/// @title PromiseChain Test
/// @notice Tests for the fluent promise chaining API
contract PromiseChainTest is Test {
    using PromiseChain for PromiseChain.Chain;
    using PromiseUtils for PromiseAll;

    Promise public promiseContract;
    SetTimeout public setTimeoutContract;
    Callback public callbackContract;
    PromiseAll public promiseAllContract;
    PromiseHarness public harness;

    address public alice = address(0x1);
    address public bob = address(0x2);

    function setUp() public {
        promiseContract = new Promise(address(0));
        setTimeoutContract = new SetTimeout(address(promiseContract));
        callbackContract = new Callback(address(promiseContract), address(0));
        promiseAllContract = new PromiseAll(address(promiseContract));

        address[] memory resolvableContracts = new address[](3);
        resolvableContracts[0] = address(setTimeoutContract);
        resolvableContracts[1] = address(callbackContract);
        resolvableContracts[2] = address(promiseAllContract);

        harness = new PromiseHarness(
            address(promiseContract),
            resolvableContracts
        );
    }

    /// @notice Test basic fluent chaining with .then()
    function test_FluentThenChaining() public {
        SimpleTarget target1 = new SimpleTarget();
        SimpleTarget target2 = new SimpleTarget();
        SimpleTarget target3 = new SimpleTarget();

        // Create initial timeout promise
        vm.prank(alice);
        bytes32 timeoutPromise = setTimeoutContract.create(100);

        // Use fluent API to chain callbacks
        bytes32 finalId = PromiseChain
            .from(callbackContract, timeoutPromise)
            .then(address(target1), target1.onCallback.selector)
            .then(address(target2), target2.onCallback.selector)
            .then(address(target3), target3.onCallback.selector)
            .build();

        // Verify chain was created
        assertTrue(finalId != bytes32(0), "Final promise ID should not be zero");
        assertTrue(finalId != timeoutPromise, "Final ID should differ from initial");

        // Fast forward and resolve
        vm.warp(block.timestamp + 150);

        // Resolve in layers: timeout -> callback1 -> callback2 -> callback3
        harness.resolveAllPendingAuto();
        harness.resolveAllPendingAuto();
        harness.resolveAllPendingAuto();
        harness.resolveAllPendingAuto();

        // All targets should have been called
        assertTrue(target1.called(), "Target 1 should be called");
        assertTrue(target2.called(), "Target 2 should be called");
        assertTrue(target3.called(), "Target 3 should be called");

        // Final promise should be resolved
        assertEq(
            uint256(promiseContract.status(finalId)),
            uint256(Promise.PromiseStatus.Resolved),
            "Final promise should be resolved"
        );
    }

    /// @notice Test fluent chaining with .catchError()
    function test_FluentCatchErrorChaining() public {
        FailingTarget failingTarget = new FailingTarget();
        ErrorHandler errorHandler = new ErrorHandler();

        // Create initial timeout promise
        vm.prank(alice);
        bytes32 timeoutPromise = setTimeoutContract.create(100);

        // Create a chain that will fail
        bytes32 failingChainId = PromiseChain
            .from(callbackContract, timeoutPromise)
            .then(address(failingTarget), failingTarget.alwaysFails.selector)
            .build();

        // Create error handler chain using fork
        bytes32 errorChainId = PromiseChain
            .from(callbackContract, failingChainId)
            .catchError(address(errorHandler), errorHandler.handleError.selector)
            .build();

        // Fast forward and resolve
        vm.warp(block.timestamp + 150);

        // Resolve layers
        harness.resolveAllPendingAuto(); // timeout
        harness.resolveAllPendingAuto(); // failing callback (will reject)
        harness.resolveAllPendingAuto(); // error handler

        // Error handler should have been called
        assertTrue(errorHandler.called(), "Error handler should be called");

        // Error chain should be resolved (error was handled)
        assertEq(
            uint256(promiseContract.status(errorChainId)),
            uint256(Promise.PromiseStatus.Resolved),
            "Error chain should be resolved"
        );
    }

    /// @notice Test the fork() method for parallel error handling
    function test_FluentFork() public {
        SimpleTarget successTarget = new SimpleTarget();
        ErrorHandler errorHandler = new ErrorHandler();

        // Create initial timeout
        vm.prank(alice);
        bytes32 timeoutPromise = setTimeoutContract.create(100);

        // Create main chain
        PromiseChain.Chain memory chain = PromiseChain.from(callbackContract, timeoutPromise);

        // Add success callback
        chain = chain.then(address(successTarget), successTarget.onCallback.selector);
        bytes32 successChainId = chain.build();

        // Fork for error handling (from the same point)
        bytes32 errorChainId = PromiseChain
            .from(callbackContract, timeoutPromise)
            .catchError(address(errorHandler), errorHandler.handleError.selector)
            .build();

        // Both chains should exist
        assertTrue(successChainId != bytes32(0), "Success chain should exist");
        assertTrue(errorChainId != bytes32(0), "Error chain should exist");
        assertTrue(successChainId != errorChainId, "Chains should be different");
    }

    /// @notice Test PromiseUtils.all() helper
    function test_PromiseUtilsAll() public {
        // Create three timeout promises
        vm.startPrank(alice);
        bytes32 p1 = setTimeoutContract.create(100);
        bytes32 p2 = setTimeoutContract.create(100);
        bytes32 p3 = setTimeoutContract.create(100);
        vm.stopPrank();

        // Use helper to create PromiseAll
        bytes32 allId = promiseAllContract.all(p1, p2, p3);

        assertTrue(allId != bytes32(0), "PromiseAll ID should not be zero");

        // Fast forward and resolve
        vm.warp(block.timestamp + 150);

        // Resolve all timeouts
        harness.resolveAllPendingAuto();
        // Resolve promise all
        harness.resolveAllPendingAuto();

        assertEq(
            uint256(promiseContract.status(allId)),
            uint256(Promise.PromiseStatus.Resolved),
            "PromiseAll should be resolved"
        );
    }

    /// @notice Test combining PromiseChain with PromiseUtils
    function test_CombinedFluentAPI() public {
        SimpleTarget finalTarget = new SimpleTarget();

        // Create two parallel promises
        vm.startPrank(alice);
        bytes32 timeout1 = setTimeoutContract.create(100);
        bytes32 timeout2 = setTimeoutContract.create(100);
        vm.stopPrank();

        // Use PromiseUtils to aggregate them
        bytes32 allId = promiseAllContract.all(timeout1, timeout2);

        // Chain a callback on the aggregated promise using fluent API
        bytes32 finalId = PromiseChain
            .from(callbackContract, allId)
            .then(address(finalTarget), finalTarget.onCallback.selector)
            .build();

        // Fast forward and resolve
        vm.warp(block.timestamp + 150);

        // Resolve: timeouts -> promiseAll -> callback
        harness.resolveAllPendingAuto();
        harness.resolveAllPendingAuto();
        harness.resolveAllPendingAuto();

        assertTrue(finalTarget.called(), "Final target should be called");
        assertEq(
            uint256(promiseContract.status(finalId)),
            uint256(Promise.PromiseStatus.Resolved),
            "Final promise should be resolved"
        );
    }

    /// @notice Test current() method for intermediate access
    function test_CurrentMethod() public {
        SimpleTarget target1 = new SimpleTarget();
        SimpleTarget target2 = new SimpleTarget();

        vm.prank(alice);
        bytes32 timeoutPromise = setTimeoutContract.create(100);

        // Build chain and capture intermediate ID
        PromiseChain.Chain memory chain = PromiseChain.from(callbackContract, timeoutPromise);

        chain = chain.then(address(target1), target1.onCallback.selector);
        bytes32 intermediateId = chain.current();

        chain = chain.then(address(target2), target2.onCallback.selector);
        bytes32 finalId = chain.build();

        // IDs should be different
        assertTrue(intermediateId != timeoutPromise, "Intermediate should differ from initial");
        assertTrue(finalId != intermediateId, "Final should differ from intermediate");

        // Both should be valid promise IDs
        assertTrue(promiseContract.exists(intermediateId), "Intermediate promise should exist");
        assertTrue(promiseContract.exists(finalId), "Final promise should exist");
    }

    /// @notice Compare old verbose API vs new fluent API (same result)
    function test_FluentVsVerbose_SameResult() public {
        SimpleTarget target1 = new SimpleTarget();
        SimpleTarget target2 = new SimpleTarget();

        // Create two identical timeouts
        vm.startPrank(alice);
        bytes32 timeout1 = setTimeoutContract.create(100);
        bytes32 timeout2 = setTimeoutContract.create(100);
        vm.stopPrank();

        // VERBOSE API (old way)
        bytes32 verboseCallback1 = callbackContract.then(
            timeout1,
            address(target1),
            target1.onCallback.selector
        );
        bytes32 verboseCallback2 = callbackContract.then(
            verboseCallback1,
            address(target2),
            target2.onCallback.selector
        );

        // FLUENT API (new way)
        bytes32 fluentFinal = PromiseChain
            .from(callbackContract, timeout2)
            .then(address(target1), target1.onCallback.selector)
            .then(address(target2), target2.onCallback.selector)
            .build();

        // Both should create valid promises
        assertTrue(promiseContract.exists(verboseCallback2), "Verbose chain should exist");
        assertTrue(promiseContract.exists(fluentFinal), "Fluent chain should exist");

        // Fast forward and resolve both
        vm.warp(block.timestamp + 150);
        harness.resolveAllPendingAuto();
        harness.resolveAllPendingAuto();
        harness.resolveAllPendingAuto();

        // Both should be resolved
        assertEq(
            uint256(promiseContract.status(verboseCallback2)),
            uint256(Promise.PromiseStatus.Resolved),
            "Verbose chain should be resolved"
        );
        assertEq(
            uint256(promiseContract.status(fluentFinal)),
            uint256(Promise.PromiseStatus.Resolved),
            "Fluent chain should be resolved"
        );
    }
}

/// @notice Simple test target that records when called
contract SimpleTarget {
    bool public called;
    bytes public lastData;

    function onCallback(bytes memory data) external returns (bytes memory) {
        called = true;
        lastData = data;
        return data;
    }
}

/// @notice Target that always fails
contract FailingTarget {
    function alwaysFails(bytes memory) external pure returns (bytes memory) {
        revert("Always fails");
    }
}

/// @notice Error handler target
contract ErrorHandler {
    bool public called;
    bytes public errorData;

    function handleError(bytes memory data) external returns (bytes memory) {
        called = true;
        errorData = data;
        return abi.encode("Error handled");
    }
}
