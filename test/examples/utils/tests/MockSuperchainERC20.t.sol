// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {MockSuperchainERC20} from "../MockSuperchainERC20.sol";
import {IERC7802, IERC165} from "../../../../src/interfaces/IERC7802.sol";

contract MockSuperchainERC20Test is Test {
    MockSuperchainERC20 public token;
    address public bridge;
    address public user1;
    address public user2;

    function setUp() public {
        bridge = makeAddr("bridge");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        
        token = new MockSuperchainERC20(
            "Test Token",
            "TEST",
            1000 ether,
            bridge
        );
    }

    function test_BasicProperties() public {
        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TEST");
        assertEq(token.totalSupply(), 1000 ether);
        assertEq(token.balanceOf(address(this)), 1000 ether);
        assertEq(token.authorizedMinter(), bridge);
    }

    function test_CrosschainMint() public {
        vm.prank(bridge);
        token.crosschainMint(user1, 100 ether);
        
        assertEq(token.balanceOf(user1), 100 ether);
        assertEq(token.totalSupply(), 1100 ether);
    }

    function test_CrosschainMint_Unauthorized() public {
        vm.prank(user1);
        vm.expectRevert(MockSuperchainERC20.Unauthorized.selector);
        token.crosschainMint(user1, 100 ether);
    }

    function test_CrosschainBurn() public {
        // First mint some tokens to user1
        vm.prank(bridge);
        token.crosschainMint(user1, 100 ether);
        
        // Then burn them
        vm.prank(bridge);
        token.crosschainBurn(user1, 50 ether);
        
        assertEq(token.balanceOf(user1), 50 ether);
        assertEq(token.totalSupply(), 1050 ether);
    }

    function test_CrosschainBurn_Unauthorized() public {
        vm.prank(user1);
        vm.expectRevert(MockSuperchainERC20.Unauthorized.selector);
        token.crosschainBurn(user1, 100 ether);
    }

    function test_SetAuthorizedMinter() public {
        address newMinter = makeAddr("newMinter");
        
        token.setAuthorizedMinter(newMinter);
        assertEq(token.authorizedMinter(), newMinter);
        
        // Old minter should no longer work
        vm.prank(bridge);
        vm.expectRevert(MockSuperchainERC20.Unauthorized.selector);
        token.crosschainMint(user1, 100 ether);
        
        // New minter should work
        vm.prank(newMinter);
        token.crosschainMint(user1, 100 ether);
        assertEq(token.balanceOf(user1), 100 ether);
    }

    function test_SupportsInterface() public {
        assertTrue(token.supportsInterface(type(IERC7802).interfaceId));
        assertTrue(token.supportsInterface(type(IERC165).interfaceId));
    }

    function test_Version() public {
        assertEq(token.version(), "1.0.0-mock");
    }

    function test_StandardERC20Functions() public {
        // Transfer some tokens to user1
        token.transfer(user1, 100 ether);
        assertEq(token.balanceOf(user1), 100 ether);
        assertEq(token.balanceOf(address(this)), 900 ether);
        
        // User1 approves user2
        vm.prank(user1);
        token.approve(user2, 50 ether);
        assertEq(token.allowance(user1, user2), 50 ether);
        
        // User2 transfers from user1
        vm.prank(user2);
        token.transferFrom(user1, user2, 30 ether);
        assertEq(token.balanceOf(user1), 70 ether);
        assertEq(token.balanceOf(user2), 30 ether);
        assertEq(token.allowance(user1, user2), 20 ether);
    }
} 