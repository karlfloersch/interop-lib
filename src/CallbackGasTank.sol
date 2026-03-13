// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Callback} from "./Callback.sol";

/// @title CallbackGasTank
/// @notice Funds callback resolvers from a user-funded balance during callback execution.
/// @dev Intended to be called from a callback script while `Callback` execution context is active.
contract CallbackGasTank {
    Callback public immutable callbackContract;
    bytes32 public lastPaidCallbackPromiseId;
    address public lastPaidGasProvider;
    address public lastPaidRelayer;
    uint256 public lastPaidAmount;

    mapping(address gasProvider => uint256 balance) public balanceOf;

    event Deposit(address indexed gasProvider, uint256 amount);
    event Withdrawal(address indexed gasProvider, address indexed to, uint256 amount);
    event RelayerPaid(
        bytes32 indexed callbackPromiseId,
        address indexed gasProvider,
        address indexed relayer,
        uint256 amount
    );

    error InsufficientBalance();
    error TransferFailed();

    constructor(address _callbackContract) {
        callbackContract = Callback(_callbackContract);
    }

    function deposit(address _to) external payable {
        balanceOf[_to] += msg.value;
        emit Deposit(_to, msg.value);
    }

    function withdraw(uint256 _amount, address _to) external {
        if (balanceOf[msg.sender] < _amount) revert InsufficientBalance();

        balanceOf[msg.sender] -= _amount;
        (bool success,) = payable(_to).call{value: _amount}("");
        if (!success) revert TransferFailed();

        emit Withdrawal(msg.sender, _to, _amount);
    }

    /// @notice Pays the resolver currently executing the callback.
    /// @dev Intended to be called from a callback script via `Twin.execute(...)`.
    /// @param _amount The amount to pay the current callback resolver.
    function payCurrentResolver(uint256 _amount) external returns (bool) {
        bytes32 callbackPromiseId = callbackContract.callbackPromiseId();
        address gasProvider = callbackContract.callbackRegistrant();
        address relayer = callbackContract.callbackResolver();
        if (balanceOf[gasProvider] < _amount) revert InsufficientBalance();

        balanceOf[gasProvider] -= _amount;

        (bool success,) = payable(relayer).call{value: _amount}("");
        if (!success) revert TransferFailed();

        lastPaidCallbackPromiseId = callbackPromiseId;
        lastPaidGasProvider = gasProvider;
        lastPaidRelayer = relayer;
        lastPaidAmount = _amount;

        emit RelayerPaid(callbackPromiseId, gasProvider, relayer, _amount);
        return true;
    }
}
