// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {Promise} from "../src/Promise.sol";

contract PromiseBasicTest is Test {
    Promise public promiseContract;
    
    address public alice = address(0x1);
    address public bob = address(0x2);

    event PromiseCreated(uint256 indexed promiseId, address indexed creator);
    event PromiseResolved(uint256 indexed promiseId, bytes returnData);
    event PromiseRejected(uint256 indexed promiseId, bytes errorData);

    function setUp() public {
        promiseContract = new Promise();
    }

    function test_createPromise() public {
        vm.prank(alice);
        
        vm.expectEmit(true, true, false, true);
        emit PromiseCreated(1, alice);
        
        uint256 promiseId = promiseContract.create();
        
        assertEq(promiseId, 1, "First promise should have ID 1");
        
        Promise.PromiseData memory data = promiseContract.getPromise(promiseId);
        assertEq(data.creator, alice, "Creator should be alice");
        assertEq(uint256(data.status), uint256(Promise.PromiseStatus.Pending), "Status should be Pending");
        assertEq(data.returnData, "", "Return data should be empty");
        
        assertTrue(promiseContract.exists(promiseId), "Promise should exist");
        assertEq(uint256(promiseContract.status(promiseId)), uint256(Promise.PromiseStatus.Pending), "Status should be Pending");
    }

    function test_createMultiplePromises() public {
        vm.prank(alice);
        uint256 promiseId1 = promiseContract.create();
        
        vm.prank(bob);
        uint256 promiseId2 = promiseContract.create();
        
        assertEq(promiseId1, 1, "First promise should have ID 1");
        assertEq(promiseId2, 2, "Second promise should have ID 2");
        
        Promise.PromiseData memory data1 = promiseContract.getPromise(promiseId1);
        Promise.PromiseData memory data2 = promiseContract.getPromise(promiseId2);
        
        assertEq(data1.creator, alice, "First promise creator should be alice");
        assertEq(data2.creator, bob, "Second promise creator should be bob");
    }

    function test_resolvePromise() public {
        vm.prank(alice);
        uint256 promiseId = promiseContract.create();
        
        bytes memory returnData = abi.encode(uint256(42));
        
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit PromiseResolved(promiseId, returnData);
        
        promiseContract.resolve(promiseId, returnData);
        
        Promise.PromiseData memory data = promiseContract.getPromise(promiseId);
        assertEq(uint256(data.status), uint256(Promise.PromiseStatus.Resolved), "Status should be Resolved");
        assertEq(data.returnData, returnData, "Return data should match");
        assertEq(uint256(promiseContract.status(promiseId)), uint256(Promise.PromiseStatus.Resolved), "Status should be Resolved");
    }

    function test_rejectPromise() public {
        vm.prank(alice);
        uint256 promiseId = promiseContract.create();
        
        bytes memory errorData = abi.encode("Something went wrong");
        
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit PromiseRejected(promiseId, errorData);
        
        promiseContract.reject(promiseId, errorData);
        
        Promise.PromiseData memory data = promiseContract.getPromise(promiseId);
        assertEq(uint256(data.status), uint256(Promise.PromiseStatus.Rejected), "Status should be Rejected");
        assertEq(data.returnData, errorData, "Error data should match");
        assertEq(uint256(promiseContract.status(promiseId)), uint256(Promise.PromiseStatus.Rejected), "Status should be Rejected");
    }

    function test_onlyCreatorCanResolve() public {
        vm.prank(alice);
        uint256 promiseId = promiseContract.create();
        
        bytes memory returnData = abi.encode(uint256(42));
        
        vm.prank(bob);
        vm.expectRevert("Promise: only creator can resolve");
        promiseContract.resolve(promiseId, returnData);
    }

    function test_onlyCreatorCanReject() public {
        vm.prank(alice);
        uint256 promiseId = promiseContract.create();
        
        bytes memory errorData = abi.encode("Error");
        
        vm.prank(bob);
        vm.expectRevert("Promise: only creator can reject");
        promiseContract.reject(promiseId, errorData);
    }

    function test_cannotResolveNonExistentPromise() public {
        bytes memory returnData = abi.encode(uint256(42));
        
        vm.expectRevert("Promise: promise does not exist");
        promiseContract.resolve(999, returnData);
    }

    function test_cannotRejectNonExistentPromise() public {
        bytes memory errorData = abi.encode("Error");
        
        vm.expectRevert("Promise: promise does not exist");
        promiseContract.reject(999, errorData);
    }

    function test_cannotResolveAlreadyResolvedPromise() public {
        vm.prank(alice);
        uint256 promiseId = promiseContract.create();
        
        bytes memory returnData1 = abi.encode(uint256(42));
        bytes memory returnData2 = abi.encode(uint256(100));
        
        vm.prank(alice);
        promiseContract.resolve(promiseId, returnData1);
        
        vm.prank(alice);
        vm.expectRevert("Promise: promise already settled");
        promiseContract.resolve(promiseId, returnData2);
    }

    function test_cannotRejectAlreadyResolvedPromise() public {
        vm.prank(alice);
        uint256 promiseId = promiseContract.create();
        
        bytes memory returnData = abi.encode(uint256(42));
        bytes memory errorData = abi.encode("Error");
        
        vm.prank(alice);
        promiseContract.resolve(promiseId, returnData);
        
        vm.prank(alice);
        vm.expectRevert("Promise: promise already settled");
        promiseContract.reject(promiseId, errorData);
    }

    function test_cannotResolveAlreadyRejectedPromise() public {
        vm.prank(alice);
        uint256 promiseId = promiseContract.create();
        
        bytes memory errorData = abi.encode("Error");
        bytes memory returnData = abi.encode(uint256(42));
        
        vm.prank(alice);
        promiseContract.reject(promiseId, errorData);
        
        vm.prank(alice);
        vm.expectRevert("Promise: promise already settled");
        promiseContract.resolve(promiseId, returnData);
    }

    function test_cannotRejectedAlreadyRejectedPromise() public {
        vm.prank(alice);
        uint256 promiseId = promiseContract.create();
        
        bytes memory errorData1 = abi.encode("Error 1");
        bytes memory errorData2 = abi.encode("Error 2");
        
        vm.prank(alice);
        promiseContract.reject(promiseId, errorData1);
        
        vm.prank(alice);
        vm.expectRevert("Promise: promise already settled");  
        promiseContract.reject(promiseId, errorData2);
    }

    function test_statusOfNonExistentPromise() public {
        vm.expectRevert("Promise: promise does not exist");
        promiseContract.status(999);
    }

    function test_getPromiseOfNonExistentPromise() public {
        vm.expectRevert("Promise: promise does not exist");
        promiseContract.getPromise(999);
    }

    function test_existsReturnsFalseForNonExistentPromise() public {
        assertFalse(promiseContract.exists(999), "Non-existent promise should not exist");
    }

    function test_getNextPromiseId() public {
        assertEq(promiseContract.getNextPromiseId(), 1, "Next promise ID should start at 1");
        
        vm.prank(alice);
        promiseContract.create();
        
        assertEq(promiseContract.getNextPromiseId(), 2, "Next promise ID should be 2 after creating one promise");
        
        vm.prank(bob);
        promiseContract.create();
        
        assertEq(promiseContract.getNextPromiseId(), 3, "Next promise ID should be 3 after creating two promises");
    }

    function testFuzz_createAndResolvePromise(uint256 value, string memory message) public {
        vm.prank(alice);
        uint256 promiseId = promiseContract.create();
        
        bytes memory returnData = abi.encode(value, message);
        
        vm.prank(alice);
        promiseContract.resolve(promiseId, returnData);
        
        Promise.PromiseData memory data = promiseContract.getPromise(promiseId);
        assertEq(uint256(data.status), uint256(Promise.PromiseStatus.Resolved), "Status should be Resolved");
        assertEq(data.returnData, returnData, "Return data should match");
        
        (uint256 decodedValue, string memory decodedMessage) = abi.decode(data.returnData, (uint256, string));
        assertEq(decodedValue, value, "Decoded value should match");
        assertEq(decodedMessage, message, "Decoded message should match");
    }
} 