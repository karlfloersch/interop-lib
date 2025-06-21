// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Promise} from "../src/Promise.sol";

contract PromiseTest is Test {
    Promise public promiseContract;
    
    address public alice = address(0x1);
    address public bob = address(0x2);

    event PromiseCreated(bytes32 indexed promiseId, address indexed resolver);
    event PromiseResolved(bytes32 indexed promiseId, bytes returnData);
    event PromiseRejected(bytes32 indexed promiseId, bytes errorData);

    function setUp() public {
        promiseContract = new Promise(address(0));
    }

    function test_createPromise() public {
        bytes32 expectedId = promiseContract.generateGlobalPromiseId(block.chainid, bytes32(uint256(1)));
        
        vm.expectEmit(true, true, false, true);
        emit PromiseCreated(expectedId, alice);
        
        vm.prank(alice);
        bytes32 promiseId = promiseContract.create();
        
        assertEq(promiseId, expectedId, "First promise should have correct global ID");
        
        Promise.PromiseData memory data = promiseContract.getPromise(promiseId);
        assertEq(data.resolver, alice, "Resolver should be alice");
        assertEq(uint256(data.status), uint256(Promise.PromiseStatus.Pending), "Status should be Pending");
        assertEq(data.returnData, "", "Return data should be empty");
        
        assertTrue(promiseContract.exists(promiseId), "Promise should exist");
        assertEq(uint256(promiseContract.status(promiseId)), uint256(Promise.PromiseStatus.Pending), "Status should be Pending");
    }

    function test_createMultiplePromises() public {
        vm.prank(alice);
        bytes32 promiseId1 = promiseContract.create();
        
        vm.prank(bob);
        bytes32 promiseId2 = promiseContract.create();
        
        bytes32 expectedId1 = promiseContract.generateGlobalPromiseId(block.chainid, bytes32(uint256(1)));
        bytes32 expectedId2 = promiseContract.generateGlobalPromiseId(block.chainid, bytes32(uint256(2)));
        
        assertEq(promiseId1, expectedId1, "First promise should have correct global ID");
        assertEq(promiseId2, expectedId2, "Second promise should have correct global ID");
        
        Promise.PromiseData memory data1 = promiseContract.getPromise(promiseId1);
        Promise.PromiseData memory data2 = promiseContract.getPromise(promiseId2);
        
        assertEq(data1.resolver, alice, "First promise resolver should be alice");
        assertEq(data2.resolver, bob, "Second promise resolver should be bob");
    }

    function test_resolvePromise() public {
        vm.prank(alice);
        bytes32 promiseId = promiseContract.create();
        
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
        bytes32 promiseId = promiseContract.create();
        
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

    function test_onlyResolverCanResolve() public {
        vm.prank(alice);
        bytes32 promiseId = promiseContract.create();
        
        bytes memory returnData = abi.encode(uint256(42));
        
        vm.prank(bob);
        vm.expectRevert("Promise: only resolver can resolve");
        promiseContract.resolve(promiseId, returnData);
    }

    function test_onlyResolverCanReject() public {
        vm.prank(alice);
        bytes32 promiseId = promiseContract.create();
        
        bytes memory errorData = abi.encode("Error");
        
        vm.prank(bob);
        vm.expectRevert("Promise: only resolver can reject");
        promiseContract.reject(promiseId, errorData);
    }

    function test_cannotResolveNonExistentPromise() public {
        bytes memory returnData = abi.encode(uint256(42));
        
        vm.expectRevert("Promise: only resolver can resolve");
        promiseContract.resolve(bytes32(uint256(999)), returnData);
    }

    function test_cannotRejectNonExistentPromise() public {
        bytes memory errorData = abi.encode("Error");
        
        vm.expectRevert("Promise: only resolver can reject");
        promiseContract.reject(bytes32(uint256(999)), errorData);
    }

    function test_cannotResolveAlreadyResolvedPromise() public {
        vm.prank(alice);
        bytes32 promiseId = promiseContract.create();
        
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
        bytes32 promiseId = promiseContract.create();
        
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
        bytes32 promiseId = promiseContract.create();
        
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
        bytes32 promiseId = promiseContract.create();
        
        bytes memory errorData1 = abi.encode("Error 1");
        bytes memory errorData2 = abi.encode("Error 2");
        
        vm.prank(alice);
        promiseContract.reject(promiseId, errorData1);
        
        vm.prank(alice);
        vm.expectRevert("Promise: promise already settled");  
        promiseContract.reject(promiseId, errorData2);
    }

    function test_statusOfNonExistentPromise() public {
        // Non-existent promises return Pending status (cross-chain compatible behavior)
        assertEq(uint256(promiseContract.status(bytes32(uint256(999)))), uint256(Promise.PromiseStatus.Pending));
    }

    function test_getPromiseOfNonExistentPromise() public {
        // Non-existent promises return empty data (cross-chain compatible behavior)
        Promise.PromiseData memory data = promiseContract.getPromise(bytes32(uint256(999)));
        assertEq(data.resolver, address(0));
        assertEq(uint256(data.status), uint256(Promise.PromiseStatus.Pending));
        assertEq(data.returnData.length, 0);
    }

    function test_existsReturnsFalseForNonExistentPromise() public {
        assertFalse(promiseContract.exists(bytes32(uint256(999))), "Non-existent promise should not exist");
    }

    function test_getNonce() public {
        assertEq(promiseContract.getNonce(), 1, "Next nonce should start at 1");
        
        vm.prank(alice);
        promiseContract.create();
        
        assertEq(promiseContract.getNonce(), 2, "Next nonce should be 2 after creating one promise");
        
        vm.prank(bob);
        promiseContract.create();
        
        assertEq(promiseContract.getNonce(), 3, "Next nonce should be 3 after creating two promises");
    }

    function testFuzz_createAndResolvePromise(uint256 value, string memory message) public {
        vm.prank(alice);
        bytes32 promiseId = promiseContract.create();
        
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