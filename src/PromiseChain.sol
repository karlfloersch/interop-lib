// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Callback} from "./Callback.sol";
import {Promise} from "./Promise.sol";

/// @title PromiseChain
/// @notice Fluent builder for promise chains - enables JS-like chaining syntax
/// @dev Use with `using PromiseChain for PromiseChain.Chain;`
///
/// Example usage:
///   bytes32 finalId = PromiseChain
///       .from(callback, initialPromise)
///       .then(target1, selector1)
///       .thenOn(chainB, target2, selector2)
///       .catchError(errorHandler, errorSelector)
///       .build();
library PromiseChain {
    /// @notice Chain state for fluent building
    struct Chain {
        bytes32 currentPromiseId;
        Callback callback;
    }

    /// @notice Start a chain from an existing promise
    /// @param cb The Callback contract to use for registering callbacks
    /// @param promiseId The initial promise ID to chain from
    /// @return A new Chain struct for fluent chaining
    function from(Callback cb, bytes32 promiseId) internal pure returns (Chain memory) {
        return Chain({
            currentPromiseId: promiseId,
            callback: cb
        });
    }

    /// @notice Add a .then() callback on the same chain
    /// @param self The current chain state
    /// @param target The contract address to call when promise resolves
    /// @param selector The function selector to call
    /// @return The updated chain with new promise ID
    function then(
        Chain memory self,
        address target,
        bytes4 selector
    ) internal returns (Chain memory) {
        self.currentPromiseId = self.callback.then(
            self.currentPromiseId,
            target,
            selector
        );
        return self;
    }

    /// @notice Add a .then() callback on a destination chain
    /// @param self The current chain state
    /// @param destChain The destination chain ID
    /// @param target The contract address to call when promise resolves
    /// @param selector The function selector to call
    /// @return The updated chain with new promise ID
    function thenOn(
        Chain memory self,
        uint256 destChain,
        address target,
        bytes4 selector
    ) internal returns (Chain memory) {
        self.currentPromiseId = self.callback.thenOn(
            destChain,
            self.currentPromiseId,
            target,
            selector
        );
        return self;
    }

    /// @notice Add a .catchError() callback on the same chain
    /// @param self The current chain state
    /// @param target The contract address to call when promise rejects
    /// @param selector The function selector to call
    /// @return The updated chain with new promise ID
    function catchError(
        Chain memory self,
        address target,
        bytes4 selector
    ) internal returns (Chain memory) {
        self.currentPromiseId = self.callback.catchError(
            self.currentPromiseId,
            target,
            selector
        );
        return self;
    }

    /// @notice Add a .catchError() callback on a destination chain
    /// @param self The current chain state
    /// @param destChain The destination chain ID
    /// @param target The contract address to call when promise rejects
    /// @param selector The function selector to call
    /// @return The updated chain with new promise ID
    function catchErrorOn(
        Chain memory self,
        uint256 destChain,
        address target,
        bytes4 selector
    ) internal returns (Chain memory) {
        self.currentPromiseId = self.callback.catchErrorOn(
            destChain,
            self.currentPromiseId,
            target,
            selector
        );
        return self;
    }

    /// @notice Get the current promise ID (can continue chaining after this)
    /// @param self The current chain state
    /// @return The current promise ID in the chain
    function current(Chain memory self) internal pure returns (bytes32) {
        return self.currentPromiseId;
    }

    /// @notice Finalize the chain and get the final promise ID
    /// @param self The current chain state
    /// @return The final promise ID
    function build(Chain memory self) internal pure returns (bytes32) {
        return self.currentPromiseId;
    }

    /// @notice Fork the chain to create a parallel branch (error handling)
    /// @dev Creates a new chain starting from the same promise ID
    /// @param self The current chain state
    /// @return A new Chain struct starting from the same promise
    function fork(Chain memory self) internal pure returns (Chain memory) {
        return Chain({
            currentPromiseId: self.currentPromiseId,
            callback: self.callback
        });
    }
}
