// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Promise} from "../../../src/Promise.sol";
import {Callback} from "../../../src/Callback.sol";
import {IERC7802} from "../../../src/interfaces/IERC7802.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";
import {MockSuperchainERC20} from "./MockSuperchainERC20.sol";

/// @title PromiseBridge
/// @notice Cross-chain token bridge using the promise library for coordination
/// @dev Burns tokens on source chain and registers remote callback to mint on destination
contract PromiseBridge {
    /// @notice Promise contract instance
    Promise public immutable promiseContract;
    
    /// @notice Callback contract instance
    Callback public immutable callbackContract;
    
    /// @notice Current chain ID
    uint256 public immutable currentChainId;

    /// @notice Bridge operation data
    struct BridgeOperation {
        address token;           // Token being bridged
        address user;           // User initiating the bridge
        uint256 amount;         // Amount being bridged
        uint256 destinationChain; // Destination chain ID
        address recipient;      // Recipient on destination chain
        bool completed;         // Whether the operation completed
    }

    /// @notice Mapping from promise ID to bridge operation data
    mapping(bytes32 => BridgeOperation) public bridgeOperations;

    /// @notice Event emitted when tokens are burned on source chain
    event TokensBurned(
        address indexed token,
        address indexed user,
        uint256 amount,
        uint256 indexed destinationChain,
        address recipient,
        bytes32 promiseId
    );

    /// @notice Event emitted when tokens are minted on destination chain
    event TokensMinted(
        address indexed token,
        address indexed recipient,
        uint256 amount,
        uint256 indexed sourceChain,
        bytes32 promiseId
    );

    /// @notice Event emitted when bridge operation completes
    event BridgeCompleted(
        bytes32 indexed promiseId,
        bool success
    );

    /// @notice Error thrown for invalid bridge operations
    error InvalidBridgeOperation(string reason);
    
    /// @notice Error thrown for unauthorized calls
    error Unauthorized();

    /// @notice Constructor
    /// @param _promiseContract Address of the Promise contract
    /// @param _callbackContract Address of the Callback contract
    constructor(address _promiseContract, address _callbackContract) {
        promiseContract = Promise(_promiseContract);
        callbackContract = Callback(_callbackContract);
        currentChainId = block.chainid;
    }

    /// @notice Bridge tokens to another chain
    /// @param token Address of the token to bridge
    /// @param amount Amount of tokens to bridge
    /// @param destinationChain Destination chain ID
    /// @param recipient Recipient address on destination chain
    /// @return promiseId Promise ID that will resolve when bridge completes
    /// @return callbackPromiseId Callback promise ID for cross-chain minting
    function bridgeTokens(
        address token,
        uint256 amount,
        uint256 destinationChain,
        address recipient
    ) external returns (bytes32 promiseId, bytes32 callbackPromiseId) {
        require(destinationChain != currentChainId, "Cannot bridge to same chain");
        require(amount > 0, "Amount must be greater than zero");
        require(recipient != address(0), "Invalid recipient");
        
        // Check that token supports crosschain operations
        if (!IERC7802(token).supportsInterface(type(IERC7802).interfaceId)) {
            revert InvalidBridgeOperation("Token does not support cross-chain operations");
        }
        
        // Create a promise for this bridge operation
        promiseId = promiseContract.create();
        
        // Store bridge operation data
        bridgeOperations[promiseId] = BridgeOperation({
            token: token,
            user: msg.sender,
            amount: amount,
            destinationChain: destinationChain,
            recipient: recipient,
            completed: false
        });
        
        // Burn tokens on this chain
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        IERC7802(token).crosschainBurn(address(this), amount);
        
        emit TokensBurned(token, msg.sender, amount, destinationChain, recipient, promiseId);
        
        // Register cross-chain callback to mint tokens on destination
        callbackPromiseId = callbackContract.thenOn(
            destinationChain,
            promiseId,
            address(this),
            this.mintTokensCallback.selector
        );
        
        // Auto-resolve the promise to trigger the minting callback
        // In a real implementation, this might wait for block confirmations
        promiseContract.resolve(promiseId, abi.encode(token, recipient, amount, currentChainId));
        
        // CRITICAL: Share the resolved promise to the destination chain so the callback can access it
        promiseContract.shareResolvedPromise(destinationChain, promiseId);
        
        return (promiseId, callbackPromiseId);
    }

    /// @notice Callback function to mint tokens on destination chain
    /// @param bridgeData Encoded bridge data from the source chain
    /// @return success Whether the minting succeeded
    function mintTokensCallback(bytes memory bridgeData) external returns (bool success) {
        // Verify this is called by the callback contract
        require(msg.sender == address(callbackContract), "Only callback contract can call");
        
        // Decode bridge data
        (address token, address recipient, uint256 amount, uint256 sourceChain) = 
            abi.decode(bridgeData, (address, address, uint256, uint256));
        
        // First check if this bridge is the authorized minter
        address authorizedMinter = MockSuperchainERC20(token).authorizedMinter();
        require(authorizedMinter == address(this), "Bridge must be authorized minter");
        
        try IERC7802(token).crosschainMint(recipient, amount) {
            emit TokensMinted(token, recipient, amount, sourceChain, 0); // Promise ID not available in callback
            success = true;
        } catch Error(string memory reason) {
            emit TokensMinted(token, recipient, 0, sourceChain, 0); // Emit failed mint for debugging
            success = false;
        } catch {
            emit TokensMinted(token, recipient, 0, sourceChain, 0); // Emit failed mint for debugging  
            success = false;
        }
        
        return success;
    }

    /// @notice Get bridge operation details
    /// @param promiseId Promise ID of the bridge operation
    /// @return operation Bridge operation data
    function getBridgeOperation(bytes32 promiseId) external view returns (BridgeOperation memory operation) {
        return bridgeOperations[promiseId];
    }

    /// @notice Check if a bridge operation exists
    /// @param promiseId Promise ID to check
    /// @return exists Whether the bridge operation exists
    function bridgeExists(bytes32 promiseId) external view returns (bool exists) {
        return bridgeOperations[promiseId].user != address(0);
    }

    /// @notice Emergency function to rollback a failed bridge
    /// @param promiseId Promise ID of the failed bridge
    /// @dev In a real implementation, this would have proper access control and verification
    function rollback(bytes32 promiseId) external {
        BridgeOperation storage operation = bridgeOperations[promiseId];
        require(operation.user == msg.sender, "Only bridge initiator can rollback");
        require(!operation.completed, "Bridge already completed");
        
        // Check if the promise was rejected (indicating failure)
        Promise.PromiseStatus status = promiseContract.status(promiseId);
        require(status == Promise.PromiseStatus.Rejected, "Can only rollback rejected bridges");
        
        // Mint back the tokens on the source chain
        IERC7802(operation.token).crosschainMint(operation.user, operation.amount);
        
        // Mark as completed to prevent double rollback
        operation.completed = true;
        
        emit BridgeCompleted(promiseId, false);
    }

    /// @notice Advanced bridge with failure handling
    /// @param token Address of the token to bridge
    /// @param amount Amount of tokens to bridge
    /// @param destinationChain Destination chain ID
    /// @param recipient Recipient address on destination chain
    /// @return bridgePromiseId Promise ID for the bridge operation
    /// @return rollbackPromiseId Promise ID for potential rollback operation
    function bridgeWithRollback(
        address token,
        uint256 amount,
        uint256 destinationChain,
        address recipient
    ) external returns (bytes32 bridgePromiseId, bytes32 rollbackPromiseId) {
        // Execute normal bridge
        (bridgePromiseId, ) = this.bridgeTokens(token, amount, destinationChain, recipient);
        
        // Create rollback promise that triggers if bridge fails
        rollbackPromiseId = promiseContract.create();
        
        // Register rollback callback for rejection case
        callbackContract.catchError(
            bridgePromiseId,
            address(this),
            this.executeRollback.selector
        );
        
        return (bridgePromiseId, rollbackPromiseId);
    }

    /// @notice Execute rollback when bridge fails
    /// @param errorData Error data from the failed bridge
    /// @return success Whether rollback succeeded
    function executeRollback(bytes memory errorData) external returns (bool success) {
        // This would contain logic to automatically rollback failed bridges
        // Implementation depends on specific requirements
        return true;
    }

    /// @notice Withdraw stuck tokens (emergency function)
    /// @param token Token address
    /// @param amount Amount to withdraw
    /// @dev In a real implementation, this would have proper access control
    function emergencyWithdraw(address token, uint256 amount) external {
        IERC20(token).transfer(msg.sender, amount);
    }
} 