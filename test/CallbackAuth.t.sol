// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {Promise} from "../src/Promise.sol";
import {Callback} from "../src/Callback.sol";

contract CallbackAuthTest is Test {
    Promise public promiseContract;
    Callback public callbackContract;
    SecureVault public vault;
    ContextAwareTarget public contextTarget;
    MaliciousTarget public maliciousTarget;
    
    address public admin = address(0x1);
    address public alice = address(0x1);  // alias for admin
    address public bob = address(0x2);
    address public trustedUser = address(0x2);  // alias for bob
    address public untrustedUser = address(0x3);
    address public unauthorizedUser = address(0x4);

    function setUp() public {
        promiseContract = new Promise(address(0));
        callbackContract = new Callback(address(promiseContract), address(0));
        vault = new SecureVault(address(callbackContract));
        contextTarget = new ContextAwareTarget(address(callbackContract));
        maliciousTarget = new MaliciousTarget(address(callbackContract));
        
        // Set up permissions
        vm.prank(admin);
        vault.grantPermission(trustedUser);
    }

    // ============ CONTEXT TESTS ============

    function test_callbackContextAvailableDuringExecution() public {
        // Alice creates a parent promise
        vm.prank(alice);
        uint256 parentPromiseId = promiseContract.create();
        
        // Bob registers a callback
        vm.prank(bob);
        uint256 callbackPromiseId = callbackContract.then(
            parentPromiseId,
            address(contextTarget),
            contextTarget.handleWithContext.selector
        );
        
        // Alice resolves the parent promise
        vm.prank(alice);
        promiseContract.resolve(parentPromiseId, abi.encode("test data"));
        
        // Execute the callback - during execution, target should have access to context
        callbackContract.resolve(callbackPromiseId);
        
        // Verify the target received the correct context
        assertEq(contextTarget.lastRegistrant(), bob, "Target should know callback was registered by bob");
        assertEq(contextTarget.lastSourceChain(), block.chainid, "Target should know callback was registered on current chain");
        assertTrue(contextTarget.contextWasAvailable(), "Context should have been available during execution");
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
        vm.prank(alice);
        uint256 parentPromiseId = promiseContract.create();
        
        vm.prank(bob);
        uint256 callbackPromiseId = callbackContract.then(
            parentPromiseId,
            address(contextTarget),
            contextTarget.handleWithContext.selector
        );
        
        vm.prank(alice);
        promiseContract.resolve(parentPromiseId, abi.encode("test data"));
        
        // Execute callback
        callbackContract.resolve(callbackPromiseId);
        
        // After execution, context should not be available
        vm.expectRevert("Callback: no callback currently executing");
        callbackContract.callbackRegistrant();
    }

    // ============ AUTHENTICATION TESTS ============

    function test_authorizedCallbackSucceeds() public {
        // Admin creates a promise that will trigger a vault operation
        vm.prank(admin);
        uint256 promiseId = promiseContract.create();
        
        // Trusted user registers a callback to perform a privileged operation
        vm.prank(trustedUser);
        uint256 callbackId = callbackContract.then(
            promiseId,
            address(vault),
            vault.performPrivilegedOperation.selector
        );
        
        // Admin resolves the promise with operation data
        vm.prank(admin);
        promiseContract.resolve(promiseId, abi.encode("withdraw", uint256(100)));
        
        // Execute the callback - should succeed because trustedUser registered it
        callbackContract.resolve(callbackId);
        
        // Verify the operation was performed
        assertTrue(vault.operationExecuted(), "Privileged operation should have been executed");
        assertEq(vault.lastOperation(), "withdraw", "Should record the operation type");
        assertEq(vault.lastAmount(), 100, "Should record the operation amount");
        assertEq(vault.lastAuthorizedUser(), trustedUser, "Should record who was authorized");
    }

    function test_unauthorizedCallbackFails() public {
        // Admin creates a promise
        vm.prank(admin);
        uint256 promiseId = promiseContract.create();
        
        // Untrusted user tries to register a callback for privileged operation
        vm.prank(untrustedUser);
        uint256 callbackId = callbackContract.then(
            promiseId,
            address(vault),
            vault.performPrivilegedOperation.selector
        );
        
        // Admin resolves the promise
        vm.prank(admin);
        promiseContract.resolve(promiseId, abi.encode("withdraw", uint256(100)));
        
        // Execute the callback - should fail and reject the callback promise
        callbackContract.resolve(callbackId);
        
        // Verify the operation was rejected
        assertFalse(vault.operationExecuted(), "Privileged operation should have been rejected");
        
        // Verify the callback promise was rejected due to authorization failure
        Promise.PromiseStatus status = promiseContract.status(callbackId);
        assertEq(uint256(status), uint256(Promise.PromiseStatus.Rejected), "Callback should be rejected");
    }

    function test_publicCallbackWorksForEveryone() public {
        // Admin creates a promise
        vm.prank(admin);
        uint256 promiseId = promiseContract.create();
        
        // Even unauthorized user can register public callbacks
        vm.prank(unauthorizedUser);
        uint256 callbackId = callbackContract.then(
            promiseId,
            address(vault),
            vault.performPublicOperation.selector
        );
        
        // Admin resolves the promise
        vm.prank(admin);
        promiseContract.resolve(promiseId, abi.encode("public_data"));
        
        // Execute the callback - should succeed because it's a public operation
        callbackContract.resolve(callbackId);
        
        // Verify the public operation was performed
        assertTrue(vault.publicOperationExecuted(), "Public operation should have been executed");
        assertEq(vault.lastPublicData(), "public_data", "Should record the public data");
    }

    function test_crossChainAuthenticationPreserved() public {
        // This test simulates cross-chain scenario where context is preserved
        // We'll test that the vault correctly identifies the original registrant
        // even when callback data comes from "cross-chain" (simulated)
        
        vm.prank(admin);
        uint256 promiseId = promiseContract.create();
        
        // Trusted user registers callback
        vm.prank(trustedUser);
        uint256 callbackId = callbackContract.then(
            promiseId,
            address(vault),
            vault.performChainSpecificOperation.selector
        );
        
        // Resolve with chain-specific data
        vm.prank(admin);
        promiseContract.resolve(promiseId, abi.encode(block.chainid, "cross_chain_data"));
        
        // Execute callback
        callbackContract.resolve(callbackId);
        
        // Verify chain-specific operation was performed with correct auth
        assertTrue(vault.chainOperationExecuted(), "Chain operation should have been executed");
        assertEq(vault.lastOperationChain(), block.chainid, "Should record the correct chain");
        assertEq(vault.lastRegistrant(), trustedUser, "Should preserve original registrant");
    }

    // ============ REENTRANCY TESTS ============

    function test_reentrancyProtectionWorks() public {
        // Alice creates a parent promise
        vm.prank(alice);
        uint256 parentPromiseId = promiseContract.create();
        
        // Alice registers a callback with the malicious target
        vm.prank(alice);
        uint256 callbackId = callbackContract.then(
            parentPromiseId,
            address(maliciousTarget),
            maliciousTarget.maliciousCallback.selector
        );
        
        // Set up the attack target
        maliciousTarget.setAttackTarget(callbackId);
        
        // Alice resolves the parent promise
        vm.prank(alice);
        promiseContract.resolve(parentPromiseId, abi.encode("trigger"));
        
        // Execute the callback - malicious target will try to re-enter and revert
        callbackContract.resolve(callbackId);
        
        // Verify the callback was rejected due to re-entrancy protection
        Promise.PromiseStatus status = promiseContract.status(callbackId);
        assertEq(uint256(status), uint256(Promise.PromiseStatus.Rejected), "Callback should be rejected due to re-entrancy");
        
        // Verify the error data contains re-entrancy detection message
        Promise.PromiseData memory data = promiseContract.getPromise(callbackId);
        
        // The revert data should contain our re-entrancy error message
        // We'll just check that the bytes contain the expected text
        bool containsReentrancyError = false;
        bytes memory expectedError = bytes("Callback: re-entrant call detected");
        bytes memory actualError = data.returnData;
        
        if (actualError.length >= expectedError.length) {
            for (uint i = 0; i <= actualError.length - expectedError.length; i++) {
                bool matches = true;
                for (uint j = 0; j < expectedError.length; j++) {
                    if (actualError[i + j] != expectedError[j]) {
                        matches = false;
                        break;
                    }
                }
                if (matches) {
                    containsReentrancyError = true;
                    break;
                }
            }
        }
        
        assertTrue(containsReentrancyError, "Error data should contain re-entrancy message");
    }

    function test_normalOperationUnaffected() public {
        // Test that normal callbacks work fine
        vm.prank(alice);
        uint256 parentPromiseId = promiseContract.create();
        
        vm.prank(alice);
        uint256 callbackId = callbackContract.then(
            parentPromiseId,
            address(maliciousTarget),
            maliciousTarget.normalCallback.selector
        );
        
        vm.prank(alice);
        promiseContract.resolve(parentPromiseId, abi.encode("normal_data"));
        
        callbackContract.resolve(callbackId);
        
        // Verify it worked normally
        Promise.PromiseStatus status = promiseContract.status(callbackId);
        assertEq(uint256(status), uint256(Promise.PromiseStatus.Resolved), "Normal callback should succeed");
        
        assertTrue(maliciousTarget.normalCallbackExecuted(), "Normal callback should have executed");
    }
}

// ============ SUPPORTING CONTRACTS ============

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

/// @notice Example vault contract that uses callback authentication for access control
contract SecureVault {
    error UnauthorizedCallbackRegistrant();
    error InvalidCallbackSender();
    
    address public immutable callbackContract;
    mapping(address => bool) public hasPermission;
    
    // State for testing
    bool public operationExecuted;
    string public lastOperation;
    uint256 public lastAmount;
    address public lastAuthorizedUser;
    
    bool public publicOperationExecuted;
    string public lastPublicData;
    
    bool public chainOperationExecuted;
    uint256 public lastOperationChain;
    address public lastRegistrant;
    
    constructor(address _callbackContract) {
        callbackContract = _callbackContract;
    }
    
    function grantPermission(address user) external {
        hasPermission[user] = true;
    }
    
    /// @notice Privileged operation that requires authorized callback registrant
    function performPrivilegedOperation(bytes memory data) external returns (bytes memory) {
        // Following SuperchainTokenBridge pattern:
        // 1. Verify the call comes from the callback contract
        if (msg.sender != callbackContract) revert InvalidCallbackSender();
        
        // 2. Get the callback authentication context
        (address registrant, uint256 sourceChain) = Callback(callbackContract).callbackContext();
        
        // 3. Verify the registrant is authorized
        if (!hasPermission[registrant]) revert UnauthorizedCallbackRegistrant();
        
        // 4. Perform the operation
        (string memory operation, uint256 amount) = abi.decode(data, (string, uint256));
        
        operationExecuted = true;
        lastOperation = operation;
        lastAmount = amount;
        lastAuthorizedUser = registrant;
        
        return abi.encode("privileged_operation_completed");
    }
    
    /// @notice Public operation that anyone can trigger via callback
    function performPublicOperation(bytes memory data) external returns (bytes memory) {
        // Still verify it comes from callback contract, but don't check permissions
        if (msg.sender != callbackContract) revert InvalidCallbackSender();
        
        string memory publicData = abi.decode(data, (string));
        
        publicOperationExecuted = true;
        lastPublicData = publicData;
        
        return abi.encode("public_operation_completed");
    }
    
    /// @notice Chain-specific operation that logs both registrant and source chain
    function performChainSpecificOperation(bytes memory data) external returns (bytes memory) {
        if (msg.sender != callbackContract) revert InvalidCallbackSender();
        
        // Get full context including source chain
        (address registrant, uint256 sourceChain) = Callback(callbackContract).callbackContext();
        
        // Require permission for chain operations
        if (!hasPermission[registrant]) revert UnauthorizedCallbackRegistrant();
        
        (uint256 chainId, string memory chainData) = abi.decode(data, (uint256, string));
        
        chainOperationExecuted = true;
        lastOperationChain = chainId;
        lastRegistrant = registrant;
        
        return abi.encode("chain_operation_completed", sourceChain);
    }
}

/// @notice Target contract that attempts re-entrancy attacks
contract MaliciousTarget {
    address public callbackContract;
    uint256 public attackTarget;
    bool public attackAttempted;
    bool public reentrancyBlocked;
    bool public normalCallbackExecuted;
    
    constructor(address _callbackContract) {
        callbackContract = _callbackContract;
    }
    
    function setAttackTarget(uint256 _callbackId) external {
        attackTarget = _callbackId;
    }
    
    function maliciousCallback(bytes memory data) external returns (bytes memory) {
        // Set this flag before attempting re-entrancy
        attackAttempted = true;
        
        // Try to re-enter by calling resolve on our own callback
        // This should revert due to the re-entrancy guard
        Callback(callbackContract).resolve(attackTarget);
        
        // If we get here, the re-entrancy attack succeeded (bad!)
        reentrancyBlocked = false;
        return abi.encode("attack_succeeded");
    }
    
    function normalCallback(bytes memory data) external returns (bytes memory) {
        normalCallbackExecuted = true;
        return abi.encode("normal_completed");
    }
} 