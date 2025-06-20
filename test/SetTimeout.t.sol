// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {Promise} from "../src/Promise.sol";
import {SetTimeout} from "../src/SetTimeout.sol";

contract SetTimeoutTest is Test {
    Promise public promiseContract;
    SetTimeout public setTimeout;
    
    address public alice = address(0x1);
    address public bob = address(0x2);

    event TimeoutCreated(uint256 indexed promiseId, uint256 timestamp);
    event TimeoutResolved(uint256 indexed promiseId, uint256 timestamp);
    event PromiseResolved(uint256 indexed promiseId, bytes returnData);

    function setUp() public {
        promiseContract = new Promise(address(0));
        setTimeout = new SetTimeout(address(promiseContract));
    }

    function test_createTimeout() public {
        uint256 futureTimestamp = block.timestamp + 100;
        uint256 expectedPromiseId = promiseContract.generatePromiseId(1);
        
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit TimeoutCreated(expectedPromiseId, futureTimestamp);
        
        uint256 promiseId = setTimeout.create(futureTimestamp);
        
        assertEq(promiseId, expectedPromiseId, "Promise ID should match expected global ID");
        assertEq(setTimeout.getTimeout(promiseId), futureTimestamp, "Timeout should match");
        assertEq(setTimeout.getRemainingTime(promiseId), 100, "Remaining time should be 100 seconds");
        assertFalse(setTimeout.canResolve(promiseId), "Should not be resolvable yet");
        
        // Check that the promise exists and is pending
        assertTrue(promiseContract.exists(promiseId), "Promise should exist");
        assertEq(uint256(promiseContract.status(promiseId)), uint256(Promise.PromiseStatus.Pending), "Promise should be pending");
    }

    function test_cannotCreateTimeoutInPast() public {
        // Set current time to 1000 to avoid underflow
        vm.warp(1000);
        uint256 pastTimestamp = block.timestamp - 100;
        
        vm.prank(alice);
        vm.expectRevert("SetTimeout: timestamp must be in the future");
        setTimeout.create(pastTimestamp);
    }

    function test_cannotCreateTimeoutAtCurrentTime() public {
        uint256 currentTimestamp = block.timestamp;
        
        vm.prank(alice);
        vm.expectRevert("SetTimeout: timestamp must be in the future");
        setTimeout.create(currentTimestamp);
    }

    function test_resolveTimeout() public {
        uint256 futureTimestamp = block.timestamp + 100;
        
        vm.prank(alice);
        uint256 promiseId = setTimeout.create(futureTimestamp);
        
        // Fast forward time
        vm.warp(futureTimestamp);
        
        assertTrue(setTimeout.canResolve(promiseId), "Should be resolvable now");
        assertEq(setTimeout.getRemainingTime(promiseId), 0, "Remaining time should be 0");
        
        vm.expectEmit(true, false, false, true);
        emit TimeoutResolved(promiseId, futureTimestamp);
        
        setTimeout.resolve(promiseId);
        
        // Check that promise is resolved
        assertEq(uint256(promiseContract.status(promiseId)), uint256(Promise.PromiseStatus.Resolved), "Promise should be resolved");
        
        // Check that timeout is cleaned up
        assertEq(setTimeout.getTimeout(promiseId), 0, "Timeout should be cleaned up");
        assertFalse(setTimeout.canResolve(promiseId), "Should not be resolvable after resolution");
    }

    function test_cannotResolveBeforeTimeout() public {
        uint256 futureTimestamp = block.timestamp + 100;
        
        vm.prank(alice);
        uint256 promiseId = setTimeout.create(futureTimestamp);
        
        // Try to resolve before timeout
        vm.expectRevert("SetTimeout: timeout not reached");
        setTimeout.resolve(promiseId);
    }

    function test_cannotResolveNonExistentTimeout() public {
        vm.expectRevert("SetTimeout: promise does not exist");
        setTimeout.resolve(999);
    }

    function test_cannotResolveAlreadyResolvedTimeout() public {
        uint256 futureTimestamp = block.timestamp + 100;
        
        vm.prank(alice);
        uint256 promiseId = setTimeout.create(futureTimestamp);
        
        // Fast forward and resolve
        vm.warp(futureTimestamp);
        setTimeout.resolve(promiseId);
        
        // Try to resolve again
        vm.expectRevert("SetTimeout: promise does not exist");
        setTimeout.resolve(promiseId);
    }

    function test_multipleTimeouts() public {
        uint256 timestamp1 = block.timestamp + 50;
        uint256 timestamp2 = block.timestamp + 100;
        uint256 expectedPromiseId1 = promiseContract.generatePromiseId(1);
        uint256 expectedPromiseId2 = promiseContract.generatePromiseId(2);
        
        vm.prank(alice);
        uint256 promiseId1 = setTimeout.create(timestamp1);
        
        vm.prank(bob);
        uint256 promiseId2 = setTimeout.create(timestamp2);
        
        assertEq(promiseId1, expectedPromiseId1, "First promise ID should match expected global ID");
        assertEq(promiseId2, expectedPromiseId2, "Second promise ID should match expected global ID");
        
        assertEq(setTimeout.getTimeout(promiseId1), timestamp1, "First timeout should match");
        assertEq(setTimeout.getTimeout(promiseId2), timestamp2, "Second timeout should match");
        
        // Fast forward to first timeout
        vm.warp(timestamp1);
        
        assertTrue(setTimeout.canResolve(promiseId1), "First promise should be resolvable");
        assertFalse(setTimeout.canResolve(promiseId2), "Second promise should not be resolvable yet");
        
        setTimeout.resolve(promiseId1);
        
        // Check first is resolved, second is still pending
        assertEq(uint256(promiseContract.status(promiseId1)), uint256(Promise.PromiseStatus.Resolved), "First promise should be resolved");
        assertEq(uint256(promiseContract.status(promiseId2)), uint256(Promise.PromiseStatus.Pending), "Second promise should still be pending");
        
        // Fast forward to second timeout
        vm.warp(timestamp2);
        
        assertTrue(setTimeout.canResolve(promiseId2), "Second promise should be resolvable now");
        setTimeout.resolve(promiseId2);
        
        assertEq(uint256(promiseContract.status(promiseId2)), uint256(Promise.PromiseStatus.Resolved), "Second promise should be resolved");
    }

    function test_getRemainingTimeAccuracy() public {
        uint256 futureTimestamp = block.timestamp + 1000;
        
        vm.prank(alice);
        uint256 promiseId = setTimeout.create(futureTimestamp);
        
        assertEq(setTimeout.getRemainingTime(promiseId), 1000, "Initial remaining time should be 1000");
        
        // Fast forward 300 seconds
        vm.warp(block.timestamp + 300);
        assertEq(setTimeout.getRemainingTime(promiseId), 700, "Remaining time should be 700");
        
        // Fast forward to exactly the timeout
        vm.warp(futureTimestamp);
        assertEq(setTimeout.getRemainingTime(promiseId), 0, "Remaining time should be 0 at timeout");
        
        // Fast forward past the timeout
        vm.warp(futureTimestamp + 100);
        assertEq(setTimeout.getRemainingTime(promiseId), 0, "Remaining time should be 0 past timeout");
    }

    function test_getTimeoutForNonExistentPromise() public {
        assertEq(setTimeout.getTimeout(999), 0, "Non-existent promise should return 0 timeout");
    }

    function test_getRemainingTimeForNonExistentPromise() public {
        assertEq(setTimeout.getRemainingTime(999), 0, "Non-existent promise should return 0 remaining time");
    }

    function test_canResolveForNonExistentPromise() public {
        assertFalse(setTimeout.canResolve(999), "Non-existent promise should not be resolvable");
    }

    function test_promiseContractIntegration() public {
        uint256 futureTimestamp = block.timestamp + 100;
        
        vm.prank(alice);
        uint256 promiseId = setTimeout.create(futureTimestamp);
        
        // Verify the promise was created with correct creator
        Promise.PromiseData memory data = promiseContract.getPromise(promiseId);
        assertEq(data.creator, address(setTimeout), "Promise creator should be SetTimeout contract");
        assertEq(uint256(data.status), uint256(Promise.PromiseStatus.Pending), "Promise should be pending");
        assertEq(data.returnData, "", "Promise should have empty return data initially");
        
        // Fast forward and resolve
        vm.warp(futureTimestamp);
        setTimeout.resolve(promiseId);
        
        // Check final state
        data = promiseContract.getPromise(promiseId);
        assertEq(uint256(data.status), uint256(Promise.PromiseStatus.Resolved), "Promise should be resolved");
        assertEq(data.returnData, "", "Promise should have empty return data after resolution");
    }

    function test_anyoneCanResolveTimeout() public {
        uint256 futureTimestamp = block.timestamp + 100;
        
        vm.prank(alice);
        uint256 promiseId = setTimeout.create(futureTimestamp);
        
        vm.warp(futureTimestamp);
        
        // Bob can resolve Alice's timeout
        vm.prank(bob);
        setTimeout.resolve(promiseId);
        
        assertEq(uint256(promiseContract.status(promiseId)), uint256(Promise.PromiseStatus.Resolved), "Promise should be resolved");
    }

    function testFuzz_createAndResolveTimeout(uint256 delay) public {
        // Bound delay to reasonable range (1 second to 1 year)
        delay = bound(delay, 1, 365 days);
        
        uint256 futureTimestamp = block.timestamp + delay;
        
        vm.prank(alice);
        uint256 promiseId = setTimeout.create(futureTimestamp);
        
        assertEq(setTimeout.getTimeout(promiseId), futureTimestamp, "Timeout should match");
        assertEq(setTimeout.getRemainingTime(promiseId), delay, "Remaining time should match delay");
        assertFalse(setTimeout.canResolve(promiseId), "Should not be resolvable yet");
        
        // Fast forward to timeout
        vm.warp(futureTimestamp);
        
        assertTrue(setTimeout.canResolve(promiseId), "Should be resolvable now");
        assertEq(setTimeout.getRemainingTime(promiseId), 0, "Remaining time should be 0");
        
        setTimeout.resolve(promiseId);
        
        assertEq(uint256(promiseContract.status(promiseId)), uint256(Promise.PromiseStatus.Resolved), "Promise should be resolved");
    }
} 