# Callback Authentication Context

The Callback contract now provides authentication context that allows target contracts to query information about who registered the callback and from which chain during callback execution.

## Available Context Methods

During callback execution, target contracts can call these methods on the Callback contract:

- `callbackRegistrant()` - Returns the address that originally registered the callback
- `callbackSourceChain()` - Returns the chain ID where the callback was originally registered  
- `callbackContext()` - Returns both registrant and source chain as a tuple

## Example Usage

```solidity
contract MyTarget {
    address public callbackContract;
    
    constructor(address _callbackContract) {
        callbackContract = _callbackContract;
    }
    
    function handleCallback(bytes memory data) external returns (bytes memory) {
        // Get authentication context during callback execution
        (address registrant, uint256 sourceChain) = Callback(callbackContract).callbackContext();
        
        // Apply business logic based on who registered the callback
        if (registrant == trustedAddress) {
            return processWithPrivileges(data);
        } else {
            return processWithLimitations(data);
        }
    }
    
    function processWithPrivileges(bytes memory data) internal pure returns (bytes memory) {
        // Enhanced processing for trusted registrants
        return abi.encode("Privileged result");
    }
    
    function processWithLimitations(bytes memory data) internal pure returns (bytes memory) {
        // Limited processing for untrusted registrants
        return abi.encode("Limited result");
    }
}
```

## Cross-Chain Context

The context is preserved even for cross-chain callbacks:

```solidity
// Alice registers a cross-chain callback from Chain A to Chain B
uint256 callbackId = callbackA.thenOn(
    chainB,
    parentPromiseId,
    address(myTarget),
    myTarget.handleCallback.selector
);

// When executed on Chain B, myTarget can still access:
// - registrant = alice (original registrant on Chain A)
// - sourceChain = chainA (where callback was registered)
```

## Authentication Patterns

### Permission-Based Access Control

```solidity
function restrictedCallback(bytes memory data) external returns (bytes memory) {
    address registrant = Callback(callbackContract).callbackRegistrant();
    require(hasPermission[registrant], "Unauthorized callback registrant");
    
    return processRestrictedOperation(data);
}
```

### Chain-Specific Logic

```solidity
function handleCallback(bytes memory data) external returns (bytes memory) {
    uint256 sourceChain = Callback(callbackContract).callbackSourceChain();
    
    if (sourceChain == MAINNET_CHAIN_ID) {
        return processMainnetCallback(data);
    } else if (sourceChain == TESTNET_CHAIN_ID) {
        return processTestnetCallback(data);
    } else {
        revert("Unsupported source chain");
    }
}
```

## Error Handling

Context methods will revert if called outside of callback execution:

```solidity
// This will revert with "Callback: no callback currently executing"
try Callback(callbackContract).callbackRegistrant() returns (address registrant) {
    // Context is available
} catch {
    // No callback currently executing
}
```

## Security Considerations

1. **Context Isolation**: Context is automatically cleared after each callback execution
2. **Reentrancy Protection**: Context remains consistent during the entire callback execution
3. **Cross-Chain Integrity**: Original registrant and source chain are preserved across chains
4. **Trust Model**: Target contracts can make authorization decisions based on callback registrant 