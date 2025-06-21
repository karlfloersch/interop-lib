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

async function deployContract(superConfig, wallet, contractName, constructorArgs = [], salt = null) {
  console.log(`\n📦 Deploying ${contractName}...`)
  
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

    // Deploy to first chain
    const chainIds = superConfig.getChainIds()
    const chainId = chainIds[0]
    console.log(`   → Deploying to chain ${chainId}`)
    
    const deployment = await contract.deployManual(chainId)
    console.log(`   ✅ ${contractName} deployed at: ${deployment.contractAddress || contract.address}`)
    
    return { contract, address: deployment.contractAddress || contract.address }
  } catch (error) {
    console.error(`   ❌ Error deploying ${contractName}:`, error.message)
    throw error
  }
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
  console.log(`   Wallet: ${wallet.account.address}`)

  try {
    // Deploy contracts in dependency order
    
    // 1. Deploy Promise contract
    const crossDomainMessenger = process.env.CROSS_DOMAIN_MESSENGER || '0x4200000000000000000000000000000000000023'
    const promise = await deployContract(
      config, 
      wallet, 
      'Promise', 
      [crossDomainMessenger]
    )

    // 2. Deploy Callback contract
    const callback = await deployContract(
      config, 
      wallet, 
      'Callback', 
      [promise.address, crossDomainMessenger]
    )

    // 3. Deploy SetTimeout contract
    const setTimeout = await deployContract(
      config, 
      wallet, 
      'SetTimeout', 
      [promise.address]
    )

    // 4. Deploy PromiseAll contract
    const promiseAll = await deployContract(
      config, 
      wallet, 
      'PromiseAll', 
      [promise.address]
    )

    console.log(`\n🎉 Deployment complete!`)
    console.log(`\n📋 Contract Addresses:`)
    console.log(`   Promise:    ${promise.address}`)
    console.log(`   Callback:   ${callback.address}`)
    console.log(`   SetTimeout: ${setTimeout.address}`)
    console.log(`   PromiseAll: ${promiseAll.address}`)
    
    // Save addresses to file for future reference
    const addresses = {
      Promise: promise.address,
      Callback: callback.address,
      SetTimeout: setTimeout.address,
      PromiseAll: promiseAll.address,
      deployedAt: new Date().toISOString(),
      chainIds,
      crossDomainMessenger
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