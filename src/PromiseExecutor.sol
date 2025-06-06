// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {LocalPromise} from "./LocalPromise.sol";

/// @notice Helper contract for executing promise chains with gas control
/// @dev Provides convenient functions to execute entire promise chains
contract PromiseExecutor {
    LocalPromise public immutable promises;
    
    /// @notice Event emitted when a chain execution step is completed
    event ChainStepExecuted(bytes32 indexed promiseId, uint256 callbacksExecuted, bytes32[] nextPromiseIds);
    
    /// @notice Event emitted when a chain execution is completed
    event ChainExecutionCompleted(bytes32 indexed startPromiseId, uint256 totalSteps);
    
    constructor(address _promises) {
        promises = LocalPromise(_promises);
    }
    
    /// @notice Execute all callbacks for a single promise
    /// @param promiseId The promise to execute callbacks for
    /// @return nextPromiseIds Array of next promise IDs from chaining
    function executePromiseCallbacks(bytes32 promiseId) external returns (bytes32[] memory nextPromiseIds) {
        require(promises.isReadyForExecution(promiseId), "PromiseExecutor: promise not ready");
        
        nextPromiseIds = promises.executeAllCallbacks(promiseId);
        uint256 callbackCount = promises.getCallbackCount(promiseId);
        
        emit ChainStepExecuted(promiseId, callbackCount, nextPromiseIds);
    }
    
    /// @notice Execute an entire promise chain starting from a resolved promise
    /// @param startPromiseId The first promise in the chain (must be resolved/rejected)
    /// @param maxSteps Maximum number of steps to execute (gas limit protection)
    /// @return stepsExecuted Number of execution steps completed
    function flushChain(bytes32 startPromiseId, uint256 maxSteps) external returns (uint256 stepsExecuted) {
        require(promises.isReadyForExecution(startPromiseId), "PromiseExecutor: start promise not ready");
        require(maxSteps > 0, "PromiseExecutor: maxSteps must be > 0");
        
        bytes32[] memory currentPromises = new bytes32[](1);
        currentPromises[0] = startPromiseId;
        
        while (stepsExecuted < maxSteps && currentPromises.length > 0) {
            bytes32[] memory nextLevelPromises;
            uint256 nextCount = 0;
            bool anyExecuted = false;
            
            // Execute all promises at current level
            for (uint256 i = 0; i < currentPromises.length; i++) {
                bytes32 promiseId = currentPromises[i];
                
                if (promises.isReadyForExecution(promiseId)) {
                    uint256 callbackCount = promises.getCallbackCount(promiseId);
                    if (callbackCount > 0) {
                        anyExecuted = true;
                        bytes32[] memory nextPromises = promises.executeAllCallbacks(promiseId);
                        
                        // Collect next level promises
                        if (nextPromises.length > 0) {
                            bytes32[] memory newNextLevel = new bytes32[](nextCount + nextPromises.length);
                            
                            // Copy existing next level promises
                            for (uint256 j = 0; j < nextCount; j++) {
                                newNextLevel[j] = nextLevelPromises[j];
                            }
                            
                            // Add new next promises
                            for (uint256 j = 0; j < nextPromises.length; j++) {
                                newNextLevel[nextCount + j] = nextPromises[j];
                            }
                            
                            nextLevelPromises = newNextLevel;
                            nextCount += nextPromises.length;
                        }
                        
                        emit ChainStepExecuted(promiseId, callbackCount, nextPromises);
                    }
                }
            }
            
            // Only count as a step if we actually executed something
            if (anyExecuted) {
                stepsExecuted++;
            }
            
            currentPromises = nextLevelPromises;
            
            // Break if no callbacks were executed (to avoid infinite loop)
            if (!anyExecuted) {
                break;
            }
        }
        
        emit ChainExecutionCompleted(startPromiseId, stepsExecuted);
    }
    
    /// @notice Execute an entire promise chain with unlimited steps (use carefully!)
    /// @param startPromiseId The first promise in the chain
    /// @return stepsExecuted Number of execution steps completed
    function flushChainUnlimited(bytes32 startPromiseId) external returns (uint256 stepsExecuted) {
        return this.flushChain(startPromiseId, type(uint256).max);
    }
    
    /// @notice Execute a single step of a promise chain
    /// @param promiseIds Array of promises to execute in this step
    /// @return nextPromiseIds Array of next promise IDs for the next step
    function executeChainStep(bytes32[] calldata promiseIds) external returns (bytes32[] memory nextPromiseIds) {
        uint256 totalNext = 0;
        bytes32[][] memory allNextPromises = new bytes32[][](promiseIds.length);
        
        // Execute all promises and collect next promises
        for (uint256 i = 0; i < promiseIds.length; i++) {
            if (promises.isReadyForExecution(promiseIds[i])) {
                allNextPromises[i] = promises.executeAllCallbacks(promiseIds[i]);
                totalNext += allNextPromises[i].length;
                
                emit ChainStepExecuted(promiseIds[i], promises.getCallbackCount(promiseIds[i]), allNextPromises[i]);
            }
        }
        
        // Flatten next promises into single array
        nextPromiseIds = new bytes32[](totalNext);
        uint256 index = 0;
        
        for (uint256 i = 0; i < allNextPromises.length; i++) {
            for (uint256 j = 0; j < allNextPromises[i].length; j++) {
                nextPromiseIds[index] = allNextPromises[i][j];
                index++;
            }
        }
    }
    
    /// @notice Get pending promises in a chain (promises that are ready but not executed)
    /// @param startPromiseId The first promise to check
    /// @param maxDepth Maximum depth to search
    /// @return pendingPromises Array of promise IDs ready for execution
    function getPendingPromises(bytes32 startPromiseId, uint256 maxDepth) external view returns (bytes32[] memory pendingPromises) {
        // This is a simplified version - a full implementation would traverse the entire chain
        // For now, just return the start promise if it's ready
        if (promises.isReadyForExecution(startPromiseId)) {
            pendingPromises = new bytes32[](1);
            pendingPromises[0] = startPromiseId;
        } else {
            pendingPromises = new bytes32[](0);
        }
    }
} 