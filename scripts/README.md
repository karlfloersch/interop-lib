# Deployment Scripts

Scripts for deploying interop-lib contracts using `@superchain/js`.

## Prerequisites

1. **Build contracts**: Run `forge build` from the root directory to generate artifacts
2. **Set environment variables**: Configure the required environment variables (see below)
3. **Running chains**: Ensure your target chains are running (e.g., Anvil, local nodes, etc.)

## Environment Variables

Create a `.env` file or export these variables:

```bash
# Private key for deployment wallet (example is Anvil's default account #0)
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Chain IDs (comma-separated)
export CHAIN_IDS=901,902

# RPC URLs corresponding to the chain IDs (comma-separated)
export RPC_URLS=http://localhost:9545,http://localhost:9546

# Optional: Cross Domain Messenger address (defaults to standard precompile)
export CROSS_DOMAIN_MESSENGER=0x4200000000000000000000000000000000000023
```

## Usage

```bash
# Install dependencies
pnpm install

# Deploy all contracts
pnpm run deploy

# Or run directly
node deploy.js
```

## What Gets Deployed

The script deploys contracts in dependency order using CREATE2 for deterministic addresses:

1. **Promise** - Core promise state management
2. **Callback** - Callback system with authentication context (depends on Promise)
3. **SetTimeout** - Timeout functionality (depends on Promise)
4. **PromiseAll** - Promise aggregation (depends on Promise)

## Features

- ✅ **Deterministic addresses** using CREATE2
- ✅ **Comprehensive error handling** with helpful messages
- ✅ **Artifact validation** checks for missing forge build
- ✅ **Environment validation** ensures all required vars are set
- ✅ **Address persistence** saves deployment info to JSON

## Output

- Contract addresses are logged to console
- Deployment info saved to `deployed-addresses.json` with:
  - Contract addresses
  - Deployment timestamp
  - Chain IDs used
  - Cross Domain Messenger address

## Error Handling

The script provides helpful error messages for common issues:

- **Missing contract artifacts** → Run `forge build`
- **Missing environment variables** → Set required env vars with examples
- **Mismatched chain/RPC counts** → Ensure arrays have same length
- **Deployment failures** → Check network connectivity and wallet balance

## Example Output

```
🚀 Starting deployment of interop-lib contracts...

📋 Configuration:
   Chains: 901, 902
   RPCs: http://localhost:9545, http://localhost:9546
   Wallet: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

📦 Deploying Promise...
   → Deploying to chain 901
   ✅ Promise deployed at: 0xada77B20f22736791d7d98803aa28ea1e2813677

📦 Deploying Callback...
   → Deploying to chain 901
   ✅ Callback deployed at: 0x9D1099bC64D73f612BD359d09d70AD25d805f6b7

🎉 Deployment complete!

💾 Addresses saved to: deployed-addresses.json
``` 