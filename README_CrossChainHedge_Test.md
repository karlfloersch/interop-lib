# CrossChain Hedged BTC Position Test

## Overview

This test demonstrates a complete cross-chain hedged BTC position workflow using the Promise infrastructure. It showcases how to:

1. **Check BTC price** on Unichain via cross-chain message
2. **Conditionally purchase BTC** if price is favorable  
3. **Open hedge position** on OP Mainnet perpetual exchange

## Test Structure

### Progressive Testing Approach

The main test `test_crossChainHedgedBTC_progressive()` allows you to enable/disable steps progressively:

```solidity
// STEP 1: Price Check (Always enabled)
test_step1_price_check();

// STEP 2: Conditional BTC Purchase (Comment out to disable)
test_step2_conditional_purchase();

// STEP 3: Hedge Position Opening (Comment out to disable)  
test_step3_hedge_position();
```

### Test Results

✅ **All 5 tests implemented:**
- `test_crossChainHedgedBTC_progressive()` - **PASS** (all 3 steps)
- `test_step1_price_check()` - **PASS** (cross-chain price check)
- `test_step2_conditional_purchase()` - **PASS** (BTC purchase simulation)
- `test_step3_hedge_position()` - **PASS** (hedge position opening)
- `test_complete_e2e_workflow()` - **FAIL** (PromiseAwareMessenger integration needs work)

## Architecture

### Core Components

1. **EnhancedCrossChainHedgedBTCPosition** - Enhanced superscript using Promise infrastructure
2. **MockUnichainDEX** - Mock DEX returning $57,500 BTC price
3. **MockOPMainnetPerp** - Mock perpetual exchange for hedge positions
4. **MockBTCPriceOracle** - Mock price oracle
5. **PromiseAwareMessenger** - Wrapper for automatic child promise tracking

### Cross-Chain Flow

```
1. OP Mainnet → Unichain: Check BTC price
2. Unichain → OP Mainnet: Return price ($57,500)
3. OP Mainnet: Execute callback with price data
4. Enhanced Script: Store price and update execution result
```

### Promise Callback Mechanism

The test uses the Promise contract's callback system:

```solidity
// Send cross-chain message
bytes32 priceCheckMsg = promiseContract.sendMessage(
    params.unichainId,
    params.unichainDEX,
    abi.encodeWithSignature("getCurrentBTCPrice()")
);

// Attach callback
promiseContract.then(priceCheckMsg, this.handlePriceResponse.selector, context);

// Callback receives decoded return data
function handlePriceResponse(uint256 price) external {
    // price = 57500000000000000000000 (57,500 * 1e18)
}
```

## Mock Contracts

### MockUnichainDEX
- `getCurrentBTCPrice()` → returns 57,500 * 1e18 USD
- `buyBTCIfGoodPrice(maxPrice, amount)` → conditional purchase
- `simulateBTCPurchase(amount, price)` → direct purchase for testing

### MockOPMainnetPerp  
- `openShortPosition(amount)` → opens hedge position
- `getShortPosition(trader)` → query position size

### MockBTCPriceOracle
- `getPrice()` → returns 57,500 * 1e18 USD

## Key Learnings

### Promise Callback Parameters
Promise callbacks receive **decoded return data** as typed parameters, not raw bytes:
```solidity
// ✅ Correct - receives decoded uint256
function handlePriceResponse(uint256 price) external

// ❌ Wrong - would receive raw bytes
function handlePriceResponse(bytes memory data) external  
```

### Cross-Fork Test Setup
Each mock contract must be deployed on the correct fork:
```solidity
// OP Mainnet (fork 0)
vm.selectFork(forkIds[0]);
opMainnetPerp = new MockOPMainnetPerp();

// Unichain (fork 1)  
vm.selectFork(forkIds[1]);
unichainDEX = new MockUnichainDEX();
```

### Promise Infrastructure Integration
The Promise contract handles:
- Cross-chain message routing
- Return data capture and decoding
- Callback execution with proper context
- Automatic promise resolution tracking

## Next Steps

1. **Fix PromiseAwareMessenger** - Complete the wrapper integration
2. **Add Atomic Promises** - Make parent promise wait for child completion
3. **Enhanced Conditional Logic** - Add real price threshold checking
4. **Error Handling** - Test failure scenarios and rollback mechanisms
5. **Integration Testing** - Connect to real DEX/Perp contracts

## Running Tests

```bash
# Run the progressive test (all 3 steps)
forge test --match-contract CrossChainHedgedBTCE2ETest --match-test test_crossChainHedgedBTC_progressive -vv

# Run individual steps  
forge test --match-contract CrossChainHedgedBTCE2ETest --match-test test_step1_price_check -vv
forge test --match-contract CrossChainHedgedBTCE2ETest --match-test test_step2_conditional_purchase -vv
forge test --match-contract CrossChainHedgedBTCE2ETest --match-test test_step3_hedge_position -vv

# Run all CrossChainHedge tests
forge test --match-contract CrossChainHedgedBTCE2ETest -v
```

## Test Output Example

```
=== CrossChain Hedged BTC Position Test ===
--- Step 1: Cross-chain BTC Price Check ---
PASS: Price response received: 57500 USD
PASS: Enhanced script received price: 57500 USD  
BTC Price retrieved: 57500 USD
PASS: Step 1 Complete: Price check successful
--- Step 2: Conditional BTC Purchase ---
PASS: Step 2 Complete: BTC purchase executed
--- Step 3: Hedge Position Opening ---  
PASS: Step 3 Complete: Hedge position opened
=== Test Complete ===
Step 1 (Price Check): PASS
Step 2 (BTC Purchase): PASS  
Step 3 (Hedge Position): PASS
```

This test framework provides a solid foundation for developing and testing complex cross-chain DeFi workflows using the Promise infrastructure. 