// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Promise} from "../src/Promise.sol";
import {IResolvable} from "../src/interfaces/IResolvable.sol";

/// @title PromiseHarness
/// @notice Test harness that automatically resolves pending promises to improve test readability
contract PromiseHarness {
    Promise public immutable promiseContract;
    IResolvable[] public resolvableContracts;

    /// @notice Structure to hold resolvable promises
    struct ResolvablePromise {
        IResolvable resolvableContract;
        uint256 promiseId;
    }

    /// @notice Event emitted when promises are resolved
    event PromisesResolved(uint256 promisesResolved);

    constructor(address _promise, address[] memory _resolvableContracts) {
        promiseContract = Promise(_promise);
        for (uint256 i = 0; i < _resolvableContracts.length; i++) {
            resolvableContracts.push(IResolvable(_resolvableContracts[i]));
        }
    }

    /// @notice Attempt to resolve one layer of pending promises
    /// @dev Collects all resolvable promises first, then resolves them to avoid ordering issues
    /// @param maxPromiseId The maximum promise ID to check (for efficiency)
    /// @return promisesResolved Number of promises resolved
    function resolveAllPending(uint256 maxPromiseId) external returns (uint256 promisesResolved) {
        // First pass: collect all resolvable promises
        ResolvablePromise[] memory resolvablePromises = new ResolvablePromise[](maxPromiseId * resolvableContracts.length);
        uint256 resolvableCount = 0;

        for (uint256 i = 1; i <= maxPromiseId; i++) {
            if (!promiseContract.exists(i)) continue;

            for (uint256 j = 0; j < resolvableContracts.length; j++) {
                if (resolvableContracts[j].canResolve(i)) {
                    resolvablePromises[resolvableCount] = ResolvablePromise({
                        resolvableContract: resolvableContracts[j],
                        promiseId: i
                    });
                    resolvableCount++;
                }
            }
        }

        // Second pass: resolve all collected promises
        promisesResolved = 0;
        for (uint256 i = 0; i < resolvableCount; i++) {
            try resolvablePromises[i].resolvableContract.resolve(resolvablePromises[i].promiseId) {
                promisesResolved++;
            } catch {
                // Ignore errors (promise might have been resolved elsewhere)
            }
        }

        emit PromisesResolved(promisesResolved);
    }

    /// @notice Resolve all pending promises up to the current max promise ID (one layer only)
    /// @return promisesResolved Number of promises resolved
    function resolveAllPendingAuto() external returns (uint256 promisesResolved) {
        uint256 maxPromiseId = promiseContract.getNextPromiseId() - 1;
        return this.resolveAllPending(maxPromiseId);
    }

    /// @notice Resolve all promise layers until nothing more can be resolved
    /// @dev Calls resolveAllPendingAuto() repeatedly until no more promises are resolved
    /// @return totalPromises Total promises resolved across all layers
    /// @return layers Number of resolution layers processed
    function resolveAllLayers() external returns (uint256 totalPromises, uint256 layers) {
        totalPromises = 0;
        layers = 0;

        while (true) {
            uint256 resolved = this.resolveAllPendingAuto();
            
            if (resolved == 0) {
                break; // No more promises to resolve
            }
            
            totalPromises += resolved;
            layers++;
            
            // Safety check to prevent infinite loops (max 10 layers)
            if (layers >= 10) {
                break;
            }
        }
    }

    /// @notice Check how many promises are pending resolution
    /// @param maxPromiseId The maximum promise ID to check
    /// @return pendingPromises Number of pending promises
    function countPending(uint256 maxPromiseId) external view returns (uint256 pendingPromises) {
        pendingPromises = 0;

        for (uint256 i = 1; i <= maxPromiseId; i++) {
            if (!promiseContract.exists(i)) continue;

            for (uint256 j = 0; j < resolvableContracts.length; j++) {
                if (resolvableContracts[j].canResolve(i)) {
                    pendingPromises++;
                    break; // Don't double count if multiple contracts can resolve the same promise
                }
            }
        }
    }

    /// @notice Check how many promises are pending resolution (auto max ID)
    /// @return pendingPromises Number of pending promises
    function countPendingAuto() external view returns (uint256 pendingPromises) {
        uint256 maxPromiseId = promiseContract.getNextPromiseId() - 1;
        return this.countPending(maxPromiseId);
    }

    /// @notice Get the status of all promises for debugging
    /// @param maxPromiseId The maximum promise ID to check
    /// @return statuses Array of promise statuses (0=Pending, 1=Resolved, 2=Rejected)
    function getAllPromiseStatuses(uint256 maxPromiseId) external view returns (uint8[] memory statuses) {
        statuses = new uint8[](maxPromiseId);
        
        for (uint256 i = 1; i <= maxPromiseId; i++) {
            if (promiseContract.exists(i)) {
                statuses[i-1] = uint8(promiseContract.status(i));
            } else {
                statuses[i-1] = 255; // Non-existent
            }
        }
    }

    /// @notice Get the number of resolvable contracts registered
    /// @return count Number of resolvable contracts
    function getResolvableContractCount() external view returns (uint256 count) {
        return resolvableContracts.length;
    }

    /// @notice Get a resolvable contract by index
    /// @param index The index of the resolvable contract
    /// @return resolvableContract The resolvable contract at the given index
    function getResolvableContract(uint256 index) external view returns (IResolvable resolvableContract) {
        require(index < resolvableContracts.length, "PromiseHarness: index out of bounds");
        return resolvableContracts[index];
    }
} 