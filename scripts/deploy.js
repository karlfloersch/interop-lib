import pkg from '@superchain/js'
const { StandardSuperConfig, SuperWallet, getSuperContract } = pkg
import { readFileSync, existsSync, writeFileSync } from 'fs'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))

// Helper function to load contract artifacts
function loadArtifact(contractName) {
  const artifactPath = join(__dirname, '..', 'out', `${contractName}.sol`, `${contractName}.json`)
  
  if (!existsSync(artifactPath)) {
    console.error(`\n❌ ERROR: Contract artifact not found!`)
    console.error(`   Missing: ${artifactPath}`)
    console.error(`\n💡 Solution: Run 'forge build' to generate contract artifacts`)
    console.error(`   cd .. && forge build\n`)
    process.exit(1)
  }

  try {
    const artifact = JSON.parse(readFileSync(artifactPath, 'utf8'))
    return {
      abi: artifact.abi,
      bytecode: artifact.bytecode.object
    }
  } catch (error) {
    console.error(`\n❌ ERROR: Failed to parse artifact for ${contractName}`)
    console.error(`   ${error.message}`)
    console.error(`\n💡 Try running 'forge build' again\n`)
    process.exit(1)
  }
}

// Load environment variables
function loadConfig() {
  const privateKey = process.env.PRIVATE_KEY
  if (!privateKey) {
    console.error(`\n❌ ERROR: PRIVATE_KEY environment variable not set`)
    console.error(`   Example: export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`)
    process.exit(1)
  }

  const chainIds = process.env.CHAIN_IDS
  const rpcUrls = process.env.RPC_URLS
  
  if (!chainIds || !rpcUrls) {
    console.error(`\n❌ ERROR: Missing required environment variables`)
    console.error(`   Required: CHAIN_IDS, RPC_URLS`)
    console.error(`   Example:`)
    console.error(`     export CHAIN_IDS=901,902`)
    console.error(`     export RPC_URLS=http://localhost:9545,http://localhost:9546`)
    process.exit(1)
  }

  const chainIdArray = chainIds.split(',').map(id => parseInt(id.trim()))
  const rpcUrlArray = rpcUrls.split(',').map(url => url.trim())

  if (chainIdArray.length !== rpcUrlArray.length) {
    console.error(`\n❌ ERROR: CHAIN_IDS and RPC_URLS must have the same number of entries`)
    console.error(`   CHAIN_IDS: ${chainIdArray.length} entries`)
    console.error(`   RPC_URLS: ${rpcUrlArray.length} entries`)
    process.exit(1)
  }

  // Build config object
  const config = {}
  for (let i = 0; i < chainIdArray.length; i++) {
    config[chainIdArray[i]] = rpcUrlArray[i]
  }

  return {
    privateKey,
    chainIds: chainIdArray,
    config
  }
}

function createSuperContract(superConfig, wallet, contractName, constructorArgs = [], salt = null) {
  console.log(`📦 Creating SuperContract for ${contractName}...`)
  
  const { abi, bytecode } = loadArtifact(contractName)
  
  try {
    const contract = getSuperContract(
      superConfig,
      wallet,
      abi,
      bytecode,
      constructorArgs,
      salt
    )
    
    console.log(`   ✅ ${contractName} SuperContract created at: ${contract.address}`)
    return contract
  } catch (error) {
    console.error(`   ❌ Error creating SuperContract for ${contractName}:`, error.message)
    throw error
  }
}

async function deployToChain(contract, contractName, chainId) {
  console.log(`   → Deploying ${contractName} to chain ${chainId}`)
  
  try {
    // Check if already deployed
    const isDeployed = await contract.isDeployed(chainId)
    if (isDeployed) {
      console.log(`   ⚠️  ${contractName} already deployed on chain ${chainId}`)
      return
    }
    
    const deployment = await contract.deployManual(chainId)
    console.log(`   ✅ ${contractName} deployed on chain ${chainId}`)
    return deployment
  } catch (error) {
    console.error(`   ❌ Error deploying ${contractName} to chain ${chainId}:`, error.message)
    throw error
  }
}

async function deployContractToAllChains(contract, contractName, chainIds) {
  console.log(`\n🚀 Deploying ${contractName} to all chains...`)
  
  for (const chainId of chainIds) {
    await deployToChain(contract, contractName, chainId)
  }
  
  console.log(`   🎉 ${contractName} deployment complete on all chains`)
}

async function main() {
  console.log(`🚀 Starting deployment of interop-lib contracts...\n`)

  // Load configuration
  const { privateKey, chainIds, config: chainConfig } = loadConfig()
  
  console.log(`📋 Configuration:`)
  console.log(`   Chains: ${chainIds.join(', ')}`)
  console.log(`   RPCs: ${Object.values(chainConfig).join(', ')}`)
  
  // Configure chains
  const config = new StandardSuperConfig(chainConfig)
  
  // Create wallet
  const wallet = new SuperWallet(privateKey)
  console.log(`   Wallet: ${wallet.account.address}\n`)

  try {
    // Create SuperContracts for all contracts
    console.log(`📋 Creating SuperContracts...`)
    
    const crossDomainMessenger = process.env.CROSS_DOMAIN_MESSENGER || '0x4200000000000000000000000000000000000023'
    
    // 1. Create Promise SuperContract
    const promiseContract = createSuperContract(
      config, 
      wallet, 
      'Promise', 
      [crossDomainMessenger]
    )

    // 2. Create Callback SuperContract (depends on Promise address)
    const callbackContract = createSuperContract(
      config, 
      wallet, 
      'Callback', 
      [promiseContract.address, crossDomainMessenger]
    )

    // 3. Create SetTimeout SuperContract (depends on Promise address)
    const setTimeoutContract = createSuperContract(
      config, 
      wallet, 
      'SetTimeout', 
      [promiseContract.address]
    )

    // 4. Create PromiseAll SuperContract (depends on Promise address)
    const promiseAllContract = createSuperContract(
      config, 
      wallet, 
      'PromiseAll', 
      [promiseContract.address]
    )

    console.log(`\n🌍 Deploying all contracts to all chains...`)

    // Deploy each contract to all chains
    await deployContractToAllChains(promiseContract, 'Promise', chainIds)
    await deployContractToAllChains(callbackContract, 'Callback', chainIds)
    await deployContractToAllChains(setTimeoutContract, 'SetTimeout', chainIds)
    await deployContractToAllChains(promiseAllContract, 'PromiseAll', chainIds)

    console.log(`\n🎉 Deployment complete!`)
    console.log(`\n📋 Contract Addresses (same on all chains):`)
    console.log(`   Promise:    ${promiseContract.address}`)
    console.log(`   Callback:   ${callbackContract.address}`)
    console.log(`   SetTimeout: ${setTimeoutContract.address}`)
    console.log(`   PromiseAll: ${promiseAllContract.address}`)
    
    // Save addresses to file for future reference
    const addresses = {
      Promise: promiseContract.address,
      Callback: callbackContract.address,
      SetTimeout: setTimeoutContract.address,
      PromiseAll: promiseAllContract.address,
      deployedAt: new Date().toISOString(),
      chainIds,
      crossDomainMessenger,
      note: "All contracts deployed to all specified chains with same addresses (CREATE2)"
    }
    
    const addressFile = join(__dirname, 'deployed-addresses.json')
    writeFileSync(addressFile, JSON.stringify(addresses, null, 2))
    console.log(`\n💾 Addresses saved to: ${addressFile}`)

  } catch (error) {
    console.error(`\n❌ Deployment failed:`)
    console.error(`   ${error.message}`)
    process.exit(1)
  }
}

// Run deployment
main().catch(console.error) 