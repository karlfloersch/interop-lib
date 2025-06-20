// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Promise} from "../src/Promise.sol";
import {SetTimeout} from "../src/SetTimeout.sol";
import {Callback} from "../src/Callback.sol";

/// @title PromiseHarness
/// @notice Test harness that automatically resolves pending promises to improve test readability
contract PromiseHarness {
    Promise public immutable promiseContract;
    SetTimeout public immutable setTimeoutContract;
    Callback public immutable callbackContract;

    /// @notice Event emitted when promises are resolved
    event PromisesResolved(uint256 timeoutsResolved, uint256 callbacksResolved);

    constructor(address _promise, address _setTimeout, address _callback) {
        promiseContract = Promise(_promise);
        setTimeoutContract = SetTimeout(_setTimeout);
        callbackContract = Callback(_callback);
    }

    /// @notice Attempt to resolve all pending timeouts and callbacks
    /// @param maxPromiseId The maximum promise ID to check (for efficiency)
    /// @return timeoutsResolved Number of timeouts resolved
    /// @return callbacksResolved Number of callbacks resolved
    function resolveAllPending(uint256 maxPromiseId) external returns (uint256 timeoutsResolved, uint256 callbacksResolved) {
        timeoutsResolved = 0;
        callbacksResolved = 0;

        // Resolve timeouts first (they create the base resolved promises)
        for (uint256 i = 1; i <= maxPromiseId; i++) {
            if (promiseContract.exists(i) && setTimeoutContract.canResolve(i)) {
                try setTimeoutContract.resolve(i) {
                    timeoutsResolved++;
                } catch {
                    // Ignore errors (promise might have been resolved elsewhere)
                }
            }
        }

        // Then resolve callbacks (they depend on resolved parent promises)
        for (uint256 i = 1; i <= maxPromiseId; i++) {
            if (promiseContract.exists(i) && callbackContract.canResolve(i)) {
                try callbackContract.resolve(i) {
                    callbacksResolved++;
                } catch {
                    // Ignore errors (callback might have been resolved elsewhere)
                }
            }
        }

        emit PromisesResolved(timeoutsResolved, callbacksResolved);
    }

    /// @notice Resolve all pending promises up to the current max promise ID
    /// @return timeoutsResolved Number of timeouts resolved
    /// @return callbacksResolved Number of callbacks resolved
    function resolveAllPendingAuto() external returns (uint256 timeoutsResolved, uint256 callbacksResolved) {
        uint256 maxPromiseId = promiseContract.getNextPromiseId() - 1;
        return this.resolveAllPending(maxPromiseId);
    }

    /// @notice Check how many promises are pending resolution
    /// @param maxPromiseId The maximum promise ID to check
    /// @return pendingTimeouts Number of pending timeouts
    /// @return pendingCallbacks Number of pending callbacks
    function countPending(uint256 maxPromiseId) external view returns (uint256 pendingTimeouts, uint256 pendingCallbacks) {
        pendingTimeouts = 0;
        pendingCallbacks = 0;

        for (uint256 i = 1; i <= maxPromiseId; i++) {
            if (promiseContract.exists(i)) {
                if (setTimeoutContract.canResolve(i)) {
                    pendingTimeouts++;
                }
                if (callbackContract.canResolve(i)) {
                    pendingCallbacks++;
                }
            }
        }
    }

    /// @notice Check how many promises are pending resolution (auto max ID)
    /// @return pendingTimeouts Number of pending timeouts
    /// @return pendingCallbacks Number of pending callbacks
    function countPendingAuto() external view returns (uint256 pendingTimeouts, uint256 pendingCallbacks) {
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

    /// @notice Force resolve timeouts by warping time far into the future
    /// @dev Only use in tests! This advances block.timestamp
    function forceResolveTimeouts() external {
        // Warp time to very far in the future
        uint256 futureTime = block.timestamp + 365 days;
        
        // Note: This function relies on vm.warp being available in the test environment
        // It cannot actually warp time on its own, but serves as a helper for tests
        
        // In actual usage, tests should call vm.warp(futureTime) before calling this
        uint256 maxPromiseId = promiseContract.getNextPromiseId() - 1;
        
        for (uint256 i = 1; i <= maxPromiseId; i++) {
            if (promiseContract.exists(i) && setTimeoutContract.canResolve(i)) {
                try setTimeoutContract.resolve(i) {
                    // Successfully resolved
                } catch {
                    // Ignore errors
                }
            }
        }
    }
} 