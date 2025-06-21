// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {Promise} from "../src/Promise.sol";
import {Callback} from "../src/Callback.sol";

contract CallbackContextTest is Test {
    Promise public promiseContract;
    Callback public callbackContract;
    
    address public alice = address(0x1);
    address public bob = address(0x2);

    function setUp() public {
        promiseContract = new Promise(address(0));
        callbackContract = new Callback(address(promiseContract), address(0));
    }

    function test_callbackContextAvailableDuringExecution() public {
        // Create a test target that checks callback context
        ContextAwareTarget target = new ContextAwareTarget(address(callbackContract));
        
        // Alice creates a parent promise
        vm.prank(alice);
        uint256 parentPromiseId = promiseContract.create();
        
        // Bob registers a callback
        vm.prank(bob);
        uint256 callbackPromiseId = callbackContract.then(
            parentPromiseId,
            address(target),
            target.handleWithContext.selector
        );
        
        // Alice resolves the parent promise
        vm.prank(alice);
        promiseContract.resolve(parentPromiseId, abi.encode("test data"));
        
        // Execute the callback - during execution, target should have access to context
        callbackContract.resolve(callbackPromiseId);
        
        // Verify the target received the correct context
        assertEq(target.lastRegistrant(), bob, "Target should know callback was registered by bob");
        assertEq(target.lastSourceChain(), block.chainid, "Target should know callback was registered on current chain");
        assertTrue(target.contextWasAvailable(), "Context should have been available during execution");
    }

    function test_callbackContextNotAvailableOutsideExecution() public {
        // Try to access context when no callback is executing - should revert
        vm.expectRevert("Callback: no callback currently executing");
        callbackContract.callbackRegistrant();
        
        vm.expectRevert("Callback: no callback currently executing");
        callbackContract.callbackSourceChain();
        
        vm.expectRevert("Callback: no callback currently executing");
        callbackContract.callbackContext();
    }

    function test_callbackContextClearedAfterExecution() public {
        ContextAwareTarget target = new ContextAwareTarget(address(callbackContract));
        
        vm.prank(alice);
        uint256 parentPromiseId = promiseContract.create();
        
        vm.prank(bob);
        uint256 callbackPromiseId = callbackContract.then(
            parentPromiseId,
            address(target),
            target.handleWithContext.selector
        );
        
        vm.prank(alice);
        promiseContract.resolve(parentPromiseId, abi.encode("test data"));
        
        // Execute callback
        callbackContract.resolve(callbackPromiseId);
        
        // After execution, context should not be available
        vm.expectRevert("Callback: no callback currently executing");
        callbackContract.callbackRegistrant();
    }
}

/// @notice Test target contract that checks callback context during execution
contract ContextAwareTarget {
    address public callbackContract;
    address public lastRegistrant;
    uint256 public lastSourceChain;
    bool public contextWasAvailable;
    
    constructor(address _callbackContract) {
        callbackContract = _callbackContract;
    }
    
    function handleWithContext(bytes memory data) external returns (string memory) {
        // Try to get callback context during execution
        try Callback(callbackContract).callbackContext() returns (address registrant, uint256 sourceChain) {
            lastRegistrant = registrant;
            lastSourceChain = sourceChain;
            contextWasAvailable = true;
        } catch {
            contextWasAvailable = false;
        }
        
        return string(abi.encodePacked("Processed: ", data));
    }
} 