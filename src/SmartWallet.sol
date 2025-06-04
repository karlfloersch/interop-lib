// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/**
 * @title SmartWallet
 * @notice A smart contract wallet that can execute superscripts by deploying them and delegatecalling
 */
contract SmartWallet {
    // Events for tracking superscript execution
    event SuperScriptDeployed(address indexed superscriptAddress, bytes32 indexed codeHash);
    event SuperScriptExecuted(address indexed superscriptAddress, bool success);
    
    // Store deployed superscripts to avoid redeployment
    mapping(bytes32 => address) public deployedSuperScripts;
    
    /**
     * @notice Execute a superscript by deploying it and calling execute()
     * @param bytecode The creation bytecode of the superscript contract
     * @param params The parameters to pass to the superscript's execute function
     */
    function executeSuperScript(bytes memory bytecode, bytes memory params) external {
        // Calculate hash of bytecode to check if already deployed
        bytes32 codeHash = keccak256(bytecode);
        address superscriptAddress = deployedSuperScripts[codeHash];
        
        // Deploy if not already deployed
        if (superscriptAddress == address(0)) {
            assembly {
                superscriptAddress := create(0, add(bytecode, 0x20), mload(bytecode))
            }
            require(superscriptAddress != address(0), "SmartWallet: SuperScript deployment failed");
            
            deployedSuperScripts[codeHash] = superscriptAddress;
            emit SuperScriptDeployed(superscriptAddress, codeHash);
        }
        
        // DELEGATECALL to execute function - this runs in wallet's context
        (bool success, ) = superscriptAddress.delegatecall(
            abi.encodeWithSignature("execute(bytes)", params)
        );
        
        emit SuperScriptExecuted(superscriptAddress, success);
        require(success, "SmartWallet: SuperScript execution failed");
    }
    
    /**
     * @notice Check if a superscript is already deployed
     * @param bytecode The bytecode to check
     * @return The address of the deployed superscript, or address(0) if not deployed
     */
    function getSuperScriptAddress(bytes memory bytecode) external view returns (address) {
        bytes32 codeHash = keccak256(bytecode);
        return deployedSuperScripts[codeHash];
    }
    
    // Allow the wallet to receive ETH
    receive() external payable {}
} 