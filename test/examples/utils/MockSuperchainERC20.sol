// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC20} from "@solady-v0.0.245/tokens/ERC20.sol";
import {ISuperchainERC20} from "../../../src/interfaces/ISuperchainERC20.sol";
import {IERC7802, IERC165} from "../../../src/interfaces/IERC7802.sol";

/// @title MockSuperchainERC20
/// @notice Mock implementation of SuperchainERC20 for testing purposes
/// @dev Simplified version without predeploy address restrictions for easy testing
contract MockSuperchainERC20 is ERC20, IERC7802 {
    /// @notice Name of the token
    string private _name;
    
    /// @notice Symbol of the token
    string private _symbol;
    
    /// @notice Address authorized to mint/burn tokens (the bridge)
    address public authorizedMinter;
    
    /// @notice Track total supply for verification
    uint256 private _totalSupply;

    /// @notice Error thrown when unauthorized address tries to mint/burn
    error Unauthorized();

    /// @notice Constructor
    /// @param name_ Token name
    /// @param symbol_ Token symbol  
    /// @param initialSupply Initial supply to mint to deployer
    /// @param minter Address authorized to mint/burn (typically the bridge)
    constructor(string memory name_, string memory symbol_, uint256 initialSupply, address minter) {
        _name = name_;
        _symbol = symbol_;
        authorizedMinter = minter;
        
        if (initialSupply > 0) {
            _mint(msg.sender, initialSupply);
            _totalSupply = initialSupply;
        }
    }

    /// @notice Returns the name of the token
    function name() public view override returns (string memory) {
        return _name;
    }

    /// @notice Returns the symbol of the token
    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// @notice Returns the total supply
    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    /// @notice Mint tokens through a crosschain transfer
    /// @param _to Address to mint tokens to
    /// @param _amount Amount of tokens to mint
    function crosschainMint(address _to, uint256 _amount) external override {
        if (msg.sender != authorizedMinter) revert Unauthorized();
        
        _mint(_to, _amount);
        _totalSupply += _amount;
        
        emit CrosschainMint(_to, _amount, msg.sender);
    }

    /// @notice Burn tokens through a crosschain transfer
    /// @param _from Address to burn tokens from
    /// @param _amount Amount of tokens to burn
    function crosschainBurn(address _from, uint256 _amount) external override {
        if (msg.sender != authorizedMinter) revert Unauthorized();
        
        _burn(_from, _amount);
        _totalSupply -= _amount;
        
        emit CrosschainBurn(_from, _amount, msg.sender);
    }

    /// @notice Update the authorized minter (for testing purposes)
    /// @param newMinter New authorized minter address
    function setAuthorizedMinter(address newMinter) external {
        // In a real implementation, this would have proper access control
        // For testing, we allow anyone to update it
        authorizedMinter = newMinter;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 _interfaceId) public view virtual override returns (bool) {
        return _interfaceId == type(IERC7802).interfaceId 
            || _interfaceId == type(IERC165).interfaceId;
    }

    /// @notice Semantic version (required by ISuperchainERC20)
    function version() external pure returns (string memory) {
        return "1.0.0-mock";
    }
} 