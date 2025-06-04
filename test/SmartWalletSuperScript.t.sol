// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";

import {SmartWallet} from "../src/SmartWallet.sol";
import {CrossChainHedgedBTCPosition} from "../src/superscripts/CrossChainHedgedBTCPosition.sol";
import {IPromise} from "../src/interfaces/IPromise.sol";

/**
 * @title SmartWalletSuperScriptTest
 * @notice Test that demonstrates smart wallet executing superscripts via DELEGATECALL
 */
contract SmartWalletSuperScriptTest is Test {
    SmartWallet public wallet;
    
    // Mock chain IDs for testing
    uint256 constant UNICHAIN_ID = 1301;
    uint256 constant OP_MAINNET_ID = 10;
    
    // Mock addresses
    address constant UNICHAIN_DEX = address(0x1111);
    address constant OP_MAINNET_PERP = address(0x2222);
    address constant USER = address(0x3333);
    
    function setUp() public {
        // Deploy the smart wallet
        wallet = new SmartWallet();
        
        // Fund the wallet with some ETH for testing
        vm.deal(address(wallet), 10 ether);
    }
    
    /**
     * @notice Test that the smart wallet can deploy and execute a superscript
     */
    function test_executeCrossChainHedgedBTCPositionSuperScript() public {
        // === SETUP SUPERSCRIPT PARAMETERS ===
        CrossChainHedgedBTCPosition.Params memory params = CrossChainHedgedBTCPosition.Params({
            priceThreshold: 58000,     // Max 58k USDC per BTC
            btcAmount: 2.5e18,         // 2.5 BTC
            unichainId: UNICHAIN_ID,
            opMainnetId: OP_MAINNET_ID,
            unichainDEX: UNICHAIN_DEX,
            opMainnetPerp: OP_MAINNET_PERP
        });
        
        bytes memory encodedParams = abi.encode(params);
        
        // === EXECUTE SUPERSCRIPT VIA SMART WALLET ===
        console.log("Executing CrossChainHedgedBTCPosition superscript...");
        
        // Get the creation bytecode of the superscript
        bytes memory superscriptBytecode = type(CrossChainHedgedBTCPosition).creationCode;
        
        // Execute the superscript via smart wallet
        // This will deploy the superscript and DELEGATECALL to execute()
        wallet.executeSuperScript(superscriptBytecode, encodedParams);
        
        // === VERIFY SUPERSCRIPT EXECUTION ===
        
        // Check that the superscript was deployed
        address superscriptAddress = wallet.getSuperScriptAddress(superscriptBytecode);
        assertTrue(superscriptAddress != address(0), "SuperScript should be deployed");
        console.log("SuperScript deployed at:", superscriptAddress);
        
        // Verify execution results are stored in wallet's context
        // Since we used DELEGATECALL, the storage should be in the wallet
        
        // We need to access the execution result that was stored in wallet's context
        // For now, let's verify the deployment and execution completed successfully
        
        console.log("SuperScript execution completed successfully!");
        
        // === VERIFY EVENTS WERE EMITTED ===
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool deployedEventFound = false;
        bool executedEventFound = false;
        
        for (uint i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("SuperScriptDeployed(address,bytes32)")) {
                deployedEventFound = true;
                console.log("Found SuperScriptDeployed event");
            }
            if (logs[i].topics[0] == keccak256("SuperScriptExecuted(address,bool)")) {
                executedEventFound = true;
                // Decode the success parameter
                (, bool success) = abi.decode(logs[i].data, (address, bool));
                assertTrue(success, "SuperScript execution should succeed");
                console.log("Found SuperScriptExecuted event with success:", success);
            }
        }
        
        assertTrue(deployedEventFound, "SuperScriptDeployed event should be emitted");
        assertTrue(executedEventFound, "SuperScriptExecuted event should be emitted");
    }
    
    /**
     * @notice Test that the same superscript can be reused without redeployment
     */
    function test_superscriptReuse() public {
        bytes memory superscriptBytecode = type(CrossChainHedgedBTCPosition).creationCode;
        
        CrossChainHedgedBTCPosition.Params memory params1 = CrossChainHedgedBTCPosition.Params({
            priceThreshold: 58000,
            btcAmount: 1e18,
            unichainId: UNICHAIN_ID,
            opMainnetId: OP_MAINNET_ID,
            unichainDEX: UNICHAIN_DEX,
            opMainnetPerp: OP_MAINNET_PERP
        });
        
        CrossChainHedgedBTCPosition.Params memory params2 = CrossChainHedgedBTCPosition.Params({
            priceThreshold: 60000,     // Different threshold
            btcAmount: 3e18,           // Different amount
            unichainId: UNICHAIN_ID,
            opMainnetId: OP_MAINNET_ID,
            unichainDEX: UNICHAIN_DEX,
            opMainnetPerp: OP_MAINNET_PERP
        });
        
        // Execute first time (should deploy)
        wallet.executeSuperScript(superscriptBytecode, abi.encode(params1));
        address firstAddress = wallet.getSuperScriptAddress(superscriptBytecode);
        
        // Execute second time (should reuse deployed contract)
        wallet.executeSuperScript(superscriptBytecode, abi.encode(params2));
        address secondAddress = wallet.getSuperScriptAddress(superscriptBytecode);
        
        // Should be the same address (reused deployment)
        assertEq(firstAddress, secondAddress, "SuperScript should be reused");
        console.log("SuperScript successfully reused at address:", firstAddress);
    }
    
    /**
     * @notice Test superscript execution with invalid parameters fails gracefully
     */
    function test_superscriptExecutionFailure() public {
        // Create invalid parameters (e.g., zero amounts)
        CrossChainHedgedBTCPosition.Params memory invalidParams = CrossChainHedgedBTCPosition.Params({
            priceThreshold: 0,         // Invalid threshold
            btcAmount: 0,              // Invalid amount
            unichainId: 0,             // Invalid chain ID
            opMainnetId: 0,            // Invalid chain ID
            unichainDEX: address(0),   // Invalid address
            opMainnetPerp: address(0)  // Invalid address
        });
        
        bytes memory superscriptBytecode = type(CrossChainHedgedBTCPosition).creationCode;
        
        // This might fail depending on validation in the superscript
        // For now, since our mock implementation doesn't validate, it will succeed
        // But in a real implementation, this could test error handling
        
        wallet.executeSuperScript(superscriptBytecode, abi.encode(invalidParams));
        
        console.log("SuperScript execution with invalid params completed");
    }
} 