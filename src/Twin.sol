// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Promise} from "./Promise.sol";
import {Callback} from "./Callback.sol";
import {TwinChain} from "./TwinChain.sol";
import {IScript} from "./interfaces/IScript.sol";
import {IL2ToL2CrossDomainMessenger} from "./interfaces/IL2ToL2CrossDomainMessenger.sol";

/// @title Twin
/// @notice Deterministic CREATE2 contract that acts as a user's agent across chains.
///         Wraps the Callback contract so that callback targets see msg.sender == twin address.
contract Twin {
    struct DispatchInfo {
        address target;
        bytes4 selector;
    }

    /// @notice The chain where the owner originally created their twin
    uint256 public immutable originChainId;
    /// @notice The owner's address on the origin chain
    address public immutable originAddress;
    /// @notice The Callback contract
    Callback public immutable callbackContract;
    /// @notice The Promise contract
    Promise public immutable promiseContract;
    /// @notice Cross-domain messenger
    IL2ToL2CrossDomainMessenger public immutable messenger;
    /// @notice The factory that deployed this twin
    address public immutable factory;

    /// @notice Dispatch info for callbacks: callbackPromiseId → (realTarget, realSelector)
    mapping(bytes32 => DispatchInfo) public dispatches;

    error NotAuthorized();
    error NotCallback();
    error NotCrossDomainTwin();
    error DispatchNotFound();

    modifier onlyOwner() {
        if (
            !((msg.sender == originAddress && block.chainid == originChainId) || msg.sender == address(this))
        ) {
            revert NotAuthorized();
        }
        _;
    }

    modifier onlyCallback() {
        if (msg.sender != address(callbackContract)) revert NotCallback();
        _;
    }

    modifier onlyCrossDomainTwin() {
        if (msg.sender != address(messenger)) revert NotCrossDomainTwin();
        if (messenger.crossDomainMessageSender() != address(this)) revert NotCrossDomainTwin();
        _;
    }

    constructor(
        uint256 _originChainId,
        address _originAddress,
        address _callbackContract,
        address _promiseContract,
        address _messenger
    ) {
        originChainId = _originChainId;
        originAddress = _originAddress;
        callbackContract = Callback(_callbackContract);
        promiseContract = Promise(_promiseContract);
        messenger = IL2ToL2CrossDomainMessenger(_messenger);
        factory = msg.sender;
    }

    // ─── Entry Points ──────────────────────────────────────────────────

    /// @notice Execute a call locally and create a promise for the result
    /// @param target The contract to call
    /// @param data The calldata
    /// @return chain A TwinChain.Chain for fluent chaining
    function makeCall(address target, bytes calldata data)
        external
        onlyOwner
        returns (TwinChain.Chain memory chain)
    {
        bytes32 promiseId = promiseContract.create();

        (bool success, bytes memory returnData) = target.call(data);

        if (success) {
            promiseContract.resolve(promiseId, returnData);
        } else {
            promiseContract.reject(promiseId, returnData);
        }

        chain = TwinChain.Chain({currentPromiseId: promiseId, twin: this});
    }

    /// @notice Execute a call on a destination chain and create a promise
    /// @param destChain The destination chain ID
    /// @param target The contract to call on the destination chain
    /// @param data The calldata
    /// @return chain A TwinChain.Chain for fluent chaining
    function makeCallOn(uint256 destChain, address target, bytes calldata data)
        external
        onlyOwner
        returns (TwinChain.Chain memory chain)
    {
        bytes32 promiseId = promiseContract.create();

        // Transfer resolution rights to the twin on dest chain
        promiseContract.transferResolve(promiseId, destChain, address(this));

        // Send cross-chain message to twin on dest chain
        messenger.sendMessage(
            destChain,
            address(this),
            abi.encodeCall(this.receiveCall, (promiseId, target, data))
        );

        chain = TwinChain.Chain({currentPromiseId: promiseId, twin: this});
    }

    /// @notice Receive a cross-chain call from twin on another chain
    /// @param promiseId The promise to resolve with the call result
    /// @param target The contract to call
    /// @param data The calldata
    function receiveCall(bytes32 promiseId, address target, bytes calldata data)
        external
        onlyCrossDomainTwin
    {
        (bool success, bytes memory returnData) = target.call(data);

        if (success) {
            promiseContract.resolve(promiseId, returnData);
        } else {
            promiseContract.reject(promiseId, returnData);
        }

        // Share resolved promise back to source chain
        uint256 sourceChain = messenger.crossDomainMessageSource();
        promiseContract.shareResolvedPromise(sourceChain, promiseId);
    }

    // ─── Callback Registration ─────────────────────────────────────────

    /// @notice Register a same-chain .then() callback routed through this twin
    /// @param parentPromiseId The promise to watch
    /// @param target The real target to call when the callback fires
    /// @param selector The real selector to call
    /// @return callbackPromiseId The callback promise ID
    function then(bytes32 parentPromiseId, address target, bytes4 selector)
        external
        onlyOwner
        returns (bytes32 callbackPromiseId)
    {
        callbackPromiseId = callbackContract.then(
            parentPromiseId, address(this), this.executeCallback.selector
        );
        dispatches[callbackPromiseId] = DispatchInfo(target, selector);
    }

    /// @notice Register a cross-chain .then() callback routed through this twin
    /// @param destChain The destination chain where the callback should execute
    /// @param parentPromiseId The promise to watch
    /// @param target The real target to call when the callback fires
    /// @param selector The real selector to call
    /// @return callbackPromiseId The callback promise ID
    function thenOn(uint256 destChain, bytes32 parentPromiseId, address target, bytes4 selector)
        external
        onlyOwner
        returns (bytes32 callbackPromiseId)
    {
        callbackPromiseId = callbackContract.thenOn(
            destChain, parentPromiseId, address(this), this.executeCallback.selector
        );

        // Send dispatch info to twin on dest chain
        messenger.sendMessage(
            destChain,
            address(this),
            abi.encodeCall(this.receiveDispatchInfo, (callbackPromiseId, target, selector))
        );
    }

    /// @notice Register a same-chain .catchError() callback routed through this twin
    /// @param parentPromiseId The promise to watch
    /// @param target The real target to call when the callback fires
    /// @param selector The real selector to call
    /// @return callbackPromiseId The callback promise ID
    function catchError(bytes32 parentPromiseId, address target, bytes4 selector)
        external
        onlyOwner
        returns (bytes32 callbackPromiseId)
    {
        callbackPromiseId = callbackContract.catchError(
            parentPromiseId, address(this), this.executeCallback.selector
        );
        dispatches[callbackPromiseId] = DispatchInfo(target, selector);
    }

    /// @notice Register a cross-chain .catchError() callback routed through this twin
    /// @param destChain The destination chain where the callback should execute
    /// @param parentPromiseId The promise to watch
    /// @param target The real target to call when the callback fires
    /// @param selector The real selector to call
    /// @return callbackPromiseId The callback promise ID
    function catchErrorOn(uint256 destChain, bytes32 parentPromiseId, address target, bytes4 selector)
        external
        onlyOwner
        returns (bytes32 callbackPromiseId)
    {
        callbackPromiseId = callbackContract.catchErrorOn(
            destChain, parentPromiseId, address(this), this.executeCallback.selector
        );

        messenger.sendMessage(
            destChain,
            address(this),
            abi.encodeCall(this.receiveDispatchInfo, (callbackPromiseId, target, selector))
        );
    }

    // ─── Callback Execution ────────────────────────────────────────────

    /// @notice Called by the Callback contract during resolve. Dispatches to the real target.
    /// @dev Uses assembly to pass through raw return/revert data so the callback promise
    ///      stores the same data as if Callback had called the real target directly.
    /// @param parentReturnData The parent promise's return data
    function executeCallback(bytes calldata parentReturnData) external onlyCallback {
        bytes32 cbPromiseId = callbackContract.callbackPromiseId();
        DispatchInfo memory info = dispatches[cbPromiseId];
        if (info.target == address(0)) revert DispatchNotFound();

        delete dispatches[cbPromiseId];

        (bool success, bytes memory result) = info.target.call(
            abi.encodeWithSelector(info.selector, parentReturnData)
        );

        // Pass through raw return/revert data for transparent proxying
        assembly {
            switch success
            case 0 { revert(add(result, 32), mload(result)) }
            default { return(add(result, 32), mload(result)) }
        }
    }

    /// @notice Receive dispatch info from twin on another chain
    /// @param callbackPromiseId The callback promise this dispatch is for
    /// @param target The real target to call
    /// @param selector The real selector to call
    function receiveDispatchInfo(bytes32 callbackPromiseId, address target, bytes4 selector)
        external
        onlyCrossDomainTwin
    {
        dispatches[callbackPromiseId] = DispatchInfo(target, selector);
    }

    // ─── Script & Direct Execution ─────────────────────────────────────

    /// @notice Execute a script via delegatecall. The script runs in this twin's context.
    /// @param script Address of a contract implementing IScript.run()
    function executeScript(address script) external {
        if (
            !(_isRouterOrOwner())
        ) {
            revert NotAuthorized();
        }

        (bool success, bytes memory result) = script.delegatecall(
            abi.encodeCall(IScript.run, ())
        );

        if (!success) {
            assembly { revert(add(result, 32), mload(result)) }
        }
    }

    /// @notice Direct arbitrary call as the twin (no promise created)
    /// @param target The contract to call
    /// @param data The calldata
    /// @return result The return data
    function execute(address target, bytes calldata data)
        external
        onlyOwner
        returns (bytes memory result)
    {
        bool success;
        (success, result) = target.call(data);
        if (!success) {
            assembly { revert(add(result, 32), mload(result)) }
        }
    }

    // ─── Internal ──────────────────────────────────────────────────────

    function _isRouterOrOwner() internal view returns (bool) {
        // Check owner first (cheapest)
        if (msg.sender == originAddress && block.chainid == originChainId) return true;
        if (msg.sender == address(this)) return true;

        // Check router via factory
        (bool ok, bytes memory data) = factory.staticcall(abi.encodeWithSignature("router()"));
        if (ok && data.length >= 32) {
            address router = abi.decode(data, (address));
            if (msg.sender == router) return true;
        }

        return false;
    }
}
