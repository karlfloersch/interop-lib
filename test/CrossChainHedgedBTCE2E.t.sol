// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";

import {Relayer} from "../src/test/Relayer.sol";
import {SmartWallet} from "../src/SmartWallet.sol";
import {CrossChainHedgedBTCPosition} from "../src/superscripts/CrossChainHedgedBTCPosition.sol";
import {IPromise} from "../src/interfaces/IPromise.sol";
import {Promise} from "../src/Promise.sol";
import {PromiseAwareMessenger} from "../src/PromiseAwareMessenger.sol";
import {PredeployAddresses} from "../src/libraries/PredeployAddresses.sol";

/**
 * @title CrossChainHedgedBTCE2ETest
 * @notice End-to-end test for cross-chain aggregated BTC swap with hedge using Promise infrastructure
 */
contract CrossChainHedgedBTCE2ETest is Relayer, Test {
    SmartWallet public wallet;
    IPromise public promiseContract = IPromise(PredeployAddresses.PROMISE);
    PromiseAwareMessenger public promiseMessenger;
    
    // Mock contracts for testing
    MockUnichainDEX public unichainDEX;
    MockOPMainnetPerp public opMainnetPerp;
    MockBTCPriceOracle public priceOracle;
    
    // Test state tracking
    bool public step1Completed;
    bool public step2Completed;
    bool public step3Completed;
    
    // Mock chain setup
    string[] private rpcUrls = [
        vm.envOr("CHAIN_A_RPC_URL", string("https://interop-alpha-0.optimism.io")), // OP Mainnet
        vm.envOr("CHAIN_B_RPC_URL", string("https://interop-alpha-1.optimism.io"))  // Unichain
    ];
    
    constructor() Relayer(rpcUrls) {}
    
    function setUp() public {
        vm.selectFork(forkIds[0]); // Start on OP Mainnet
        
        // Deploy Promise contract at predeploy address
        Promise promiseImpl = new Promise();
        vm.etch(PredeployAddresses.PROMISE, address(promiseImpl).code);
        
        // Deploy PromiseAwareMessenger
        promiseMessenger = new PromiseAwareMessenger();
        
        // Deploy SmartWallet
        wallet = new SmartWallet();
        vm.deal(address(wallet), 10 ether);
        
        // Deploy mock contracts on OP Mainnet
        opMainnetPerp = new MockOPMainnetPerp();
        priceOracle = new MockBTCPriceOracle();
        
        // Switch to Unichain fork
        vm.selectFork(forkIds[1]);
        
        // Deploy Promise contract on Unichain too
        promiseImpl = new Promise();
        vm.etch(PredeployAddresses.PROMISE, address(promiseImpl).code);
        
        // Deploy PromiseAwareMessenger on Unichain
        promiseMessenger = new PromiseAwareMessenger();
        
        // Deploy mock contracts on Unichain
        unichainDEX = new MockUnichainDEX();
        
        // Reset state
        step1Completed = false;
        step2Completed = false;
        step3Completed = false;
    }
    
    /// @notice Comprehensive test with progressive steps
    function test_crossChainHedgedBTC_progressive() public {
        console.log("=== CrossChain Hedged BTC Position Test ===");
        
        // STEP 1: Price Check (Always enabled)
        test_step1_price_check();
        
        // STEP 2: Conditional BTC Purchase (Comment out to disable)
        // test_step2_conditional_purchase();
        
        // STEP 3: Hedge Position Opening (Comment out to disable)
        // test_step3_hedge_position();
        
        console.log("=== Test Complete ===");
        console.log("Step 1 (Price Check):", step1Completed ? "PASS" : "FAIL");
        console.log("Step 2 (BTC Purchase):", step2Completed ? "PASS" : "FAIL");
        console.log("Step 3 (Hedge Position):", step3Completed ? "PASS" : "FAIL");
    }
    
    /// @notice Test Step 1: Cross-chain BTC price check
    function test_step1_price_check() public {
        vm.selectFork(forkIds[0]); // OP Mainnet
        
        console.log("--- Step 1: Cross-chain BTC Price Check ---");
        
        // Create an enhanced CrossChainHedgedBTCPosition that uses promises
        EnhancedCrossChainHedgedBTCPosition enhancedScript = new EnhancedCrossChainHedgedBTCPosition(
            promiseMessenger,
            promiseContract
        );
        
        // Set up parameters
        CrossChainHedgedBTCPosition.Params memory params = CrossChainHedgedBTCPosition.Params({
            priceThreshold: 58000e18,  // $58,000 USDC
            btcAmount: 2.5e18,         // 2.5 BTC
            unichainId: chainIdByForkId[forkIds[1]],
            opMainnetId: chainIdByForkId[forkIds[0]],
            unichainDEX: address(unichainDEX),
            opMainnetPerp: address(opMainnetPerp)
        });
        
        // Use Promise contract directly for now
        bytes32 priceCheckMsg = promiseContract.sendMessage(
            params.unichainId,
            params.unichainDEX,
            abi.encodeWithSignature("getCurrentBTCPrice()")
        );
        
        // Attach callback to process the price
        promiseContract.then(priceCheckMsg, this.handlePriceResponse.selector, abi.encode(address(enhancedScript)));
        
        console.log("Price check message sent");
        console.logBytes32(priceCheckMsg);
        
        // Relay messages to execute price check
        relayAllMessages();
        
        // Process promise callbacks
        Vm.Log[] memory logs = vm.getRecordedLogs();
        relayPromises(logs, promiseContract, chainIdByForkId[forkIds[0]]);
        
        // Verify price was checked
        uint256 retrievedPrice = enhancedScript.getCurrentBTCPrice();
        assertGt(retrievedPrice, 0, "Price should be retrieved");
        console.log("BTC Price retrieved:", retrievedPrice / 1e18, "USD");
        
        step1Completed = true;
        console.log("PASS: Step 1 Complete: Price check successful");
    }
    
    /// @notice Callback handler for price responses (forwards to EnhancedCrossChainHedgedBTCPosition)
    function handlePriceResponse(uint256 price) external {
        require(msg.sender == address(promiseContract), "Only Promise can call");
        
        // Decode the enhanced script address from context
        bytes memory context = promiseContract.promiseContext();
        address enhancedScriptAddr = abi.decode(context, (address));
        
        console.log("PASS: Price response received:", price / 1e18, "USD");
        
        // Forward to the enhanced script
        EnhancedCrossChainHedgedBTCPosition(enhancedScriptAddr).handlePriceResponseFromTest(price);
    }
    
    /// @notice Test Step 2: Conditional BTC purchase
    function test_step2_conditional_purchase() public {
        vm.selectFork(forkIds[0]);
        
        console.log("--- Step 2: Conditional BTC Purchase ---");
        
        // This step would execute the conditional purchase logic
        // For now, we'll mock it
        MockUnichainDEX(address(unichainDEX)).simulateBTCPurchase(2.5e18, 57000e18);
        
        step2Completed = true;
        console.log("PASS: Step 2 Complete: BTC purchase executed");
    }
    
    /// @notice Test Step 3: Hedge position opening
    function test_step3_hedge_position() public {
        vm.selectFork(forkIds[0]);
        
        console.log("--- Step 3: Hedge Position Opening ---");
        
        // This step would open the hedge position
        // For now, we'll mock it
        opMainnetPerp.openShortPosition(1.25e18); // 50% hedge
        
        step3Completed = true;
        console.log("PASS: Step 3 Complete: Hedge position opened");
    }
    
    /// @notice Test the complete end-to-end workflow (when all steps are enabled)
    function test_complete_e2e_workflow() public {
        vm.selectFork(forkIds[0]);
        
        console.log("=== Complete E2E Workflow Test ===");
        
        EnhancedCrossChainHedgedBTCPosition enhancedScript = new EnhancedCrossChainHedgedBTCPosition(
            promiseMessenger,
            promiseContract
        );
        
        CrossChainHedgedBTCPosition.Params memory params = CrossChainHedgedBTCPosition.Params({
            priceThreshold: 58000e18,
            btcAmount: 2.5e18,
            unichainId: chainIdByForkId[forkIds[1]],
            opMainnetId: chainIdByForkId[forkIds[0]],
            unichainDEX: address(unichainDEX),
            opMainnetPerp: address(opMainnetPerp)
        });
        
        // Execute complete workflow
        enhancedScript.executeComplete(params);
        
        // Relay all messages and process callbacks
        relayAllMessages();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        relayPromises(logs, promiseContract, chainIdByForkId[forkIds[0]]);
        
        // Verify final state
        CrossChainHedgedBTCPosition.ExecutionResult memory result = enhancedScript.getExecutionResult();
        assertTrue(result.success, "Execution should be successful");
        assertGt(result.executionPrice, 0, "Execution price should be set");
        
        console.log("PASS: Complete E2E workflow successful");
    }
}

/**
 * @title EnhancedCrossChainHedgedBTCPosition
 * @notice Enhanced version of the superscript that uses the Promise infrastructure
 */
contract EnhancedCrossChainHedgedBTCPosition is CrossChainHedgedBTCPosition {
    PromiseAwareMessenger public immutable messenger;
    IPromise public immutable promiseContract;
    
    uint256 public currentBTCPrice;
    bool public priceCheckCompleted;
    
    constructor(PromiseAwareMessenger _messenger, IPromise _promiseContract) {
        messenger = _messenger;
        promiseContract = _promiseContract;
    }
    
    /// @notice Execute only Step 1: Price check
    function executeStep1(Params memory params) external {
        console.log("Executing Step 1: Price check on chain", params.unichainId);
        
        // Send message to check BTC price
        bytes32 priceCheckMsg = messenger.sendMessage(
            params.unichainId,
            params.unichainDEX,
            abi.encodeWithSignature("getCurrentBTCPrice()")
        );
        
        // Attach callback to process the price
        promiseContract.then(priceCheckMsg, this.handlePriceResponse.selector, abi.encode(params));
        
        console.log("Price check message sent");
        console.logBytes32(priceCheckMsg);
    }
    
    /// @notice Execute complete workflow
    function executeComplete(Params memory params) external {
        // For now, just execute step 1
        this.executeStep1(params);
        
        // TODO: Add step 2 and 3 when ready
        console.log("Complete workflow initiated (Step 1 only for now)");
    }
    
    /// @notice Handle price response from Unichain
    function handlePriceResponse(bytes memory priceData) external {
        require(msg.sender == address(promiseContract), "Only Promise can call");
        
        // If priceData is empty, the call didn't return data properly
        if (priceData.length == 0) {
            console.log("ERROR: Empty price data received");
            return;
        }
        
        currentBTCPrice = abi.decode(priceData, (uint256));
        priceCheckCompleted = true;
        
        console.log("PASS: Price response received:", currentBTCPrice / 1e18, "USD");
        
        // Update execution result
        executionResult.executionPrice = currentBTCPrice;
        executionResult.status = "Price check completed";
    }
    
    /// @notice Handle price response from test contract
    function handlePriceResponseFromTest(uint256 price) external {
        currentBTCPrice = price;
        priceCheckCompleted = true;
        
        console.log("PASS: Enhanced script received price:", currentBTCPrice / 1e18, "USD");
        
        // Update execution result
        executionResult.executionPrice = currentBTCPrice;
        executionResult.status = "Price check completed";
    }
    
    /// @notice Get current BTC price
    function getCurrentBTCPrice() external view returns (uint256) {
        return currentBTCPrice;
    }
    
    /// @notice Check if price check is completed
    function isPriceCheckCompleted() external view returns (bool) {
        return priceCheckCompleted;
    }
}

/**
 * @title MockUnichainDEX
 * @notice Mock DEX contract for testing
 */
contract MockUnichainDEX {
    uint256 public constant MOCK_BTC_PRICE = 57500e18; // $57,500
    
    mapping(address => uint256) public btcBalances;
    
    event BTCPurchased(address buyer, uint256 amount, uint256 price);
    
    /// @notice Mock function to get current BTC price
    function getCurrentBTCPrice() external pure returns (uint256) {
        return MOCK_BTC_PRICE;
    }
    
    /// @notice Mock function to buy BTC if price is good
    function buyBTCIfGoodPrice(uint256 maxPrice, uint256 amount) external returns (bool) {
        uint256 currentPrice = this.getCurrentBTCPrice();
        
        if (currentPrice <= maxPrice) {
            btcBalances[msg.sender] += amount;
            emit BTCPurchased(msg.sender, amount, currentPrice);
            return true;
        }
        
        return false;
    }
    
    /// @notice Simulate BTC purchase for testing
    function simulateBTCPurchase(uint256 amount, uint256 price) external {
        btcBalances[msg.sender] += amount;
        emit BTCPurchased(msg.sender, amount, price);
    }
}

/**
 * @title MockOPMainnetPerp
 * @notice Mock perpetual exchange contract for testing
 */
contract MockOPMainnetPerp {
    mapping(address => uint256) public shortPositions;
    
    event ShortPositionOpened(address trader, uint256 amount);
    
    /// @notice Open a short BTC position
    function openShortPosition(uint256 amount) external {
        shortPositions[msg.sender] += amount;
        emit ShortPositionOpened(msg.sender, amount);
    }
    
    /// @notice Get short position size
    function getShortPosition(address trader) external view returns (uint256) {
        return shortPositions[trader];
    }
}

/**
 * @title MockBTCPriceOracle
 * @notice Mock price oracle for testing
 */
contract MockBTCPriceOracle {
    uint256 public constant PRICE = 57500e18; // $57,500
    
    /// @notice Get BTC price
    function getPrice() external pure returns (uint256) {
        return PRICE;
    }
} 