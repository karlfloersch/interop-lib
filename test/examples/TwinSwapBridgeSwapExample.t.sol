// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";

import {Relayer} from "../../src/test/Relayer.sol";
import {Promise} from "../../src/Promise.sol";
import {Callback} from "../../src/Callback.sol";
import {Twin} from "../../src/Twin.sol";
import {TwinChain} from "../../src/TwinChain.sol";
import {TwinFactory} from "../../src/TwinFactory.sol";
import {TwinRouter} from "../../src/TwinRouter.sol";
import {IScript} from "../../src/interfaces/IScript.sol";
import {PredeployAddresses} from "../../src/libraries/PredeployAddresses.sol";

import {MockSuperchainERC20} from "./utils/MockSuperchainERC20.sol";
import {MockExchange} from "./utils/MockExchange.sol";
import {PromiseBridge} from "./utils/PromiseBridge.sol";

contract TwinSwapBridgeSwapExampleTest is Test, Relayer {
    using TwinChain for TwinChain.Chain;

    Promise public promiseA;
    Promise public promiseB;
    Callback public callbackA;
    Callback public callbackB;
    TwinFactory public factoryA;
    TwinFactory public factoryB;
    TwinRouter public routerA;

    MockExchange public exchangeA;
    MockExchange public exchangeB;
    PromiseBridge public bridgeA;
    PromiseBridge public bridgeB;
    MockSuperchainERC20 public tokenA;
    MockSuperchainERC20 public tokenB;
    MockSuperchainERC20 public tokenC;

    WorkflowRecorder public recorderA;
    WorkflowRecorder public recorderB;
    SwapBridgeSwapInitScript public initScriptA;
    SwapBridgeSwapInitScript public initScriptB;
    AfterLocalSwapScript public afterLocalSwapA;
    AfterLocalSwapScript public afterLocalSwapB;
    DestinationSwapScript public destinationSwapA;
    DestinationSwapScript public destinationSwapB;
    RollbackBridgeBackScript public rollbackA;
    RollbackBridgeBackScript public rollbackB;

    address public alice = address(0xA11CE);
    address public liquidityProvider = address(0xBEEF);
    Twin public aliceTwinA;
    Twin public aliceTwinB;

    uint256 public amountIn = 100 ether;
    uint256 public chainAId;
    uint256 public chainBId;

    string[] private rpcUrls = [
        vm.envOr("CHAIN_A_RPC_URL", string("http://127.0.0.1:9545")),
        vm.envOr("CHAIN_B_RPC_URL", string("http://127.0.0.1:9546"))
    ];

    constructor() Relayer(rpcUrls) {}

    function setUp() public {
        _deployTwinSystem();
        _deployApplicationContracts();
        _deployWorkflowContracts();
        _seedLiquidityAndFunds();
    }

    function test_swapBridgeSwap_success() public {
        vm.selectFork(forkIds[0]);
        vm.prank(alice);
        routerA.execute(address(initScriptA));

        bytes32 afterLocalSwapCallbackId = recorderA.afterLocalSwapCallbackId(address(aliceTwinA));
        assertTrue(afterLocalSwapCallbackId != bytes32(0), "init script should record first callback");

        callbackA.resolve(afterLocalSwapCallbackId);

        bytes32 bridgeMintCallbackId = recorderA.bridgeMintCallbackId(address(aliceTwinA));
        bytes32 secondSwapCallbackId = recorderA.secondSwapCallbackId(address(aliceTwinA));
        assertTrue(bridgeMintCallbackId != bytes32(0), "bridge callback should be recorded");
        assertTrue(secondSwapCallbackId != bytes32(0), "destination callback should be recorded");

        relayAllMessages();

        vm.selectFork(forkIds[1]);
        callbackB.resolve(bridgeMintCallbackId);
        callbackB.resolve(secondSwapCallbackId);

        vm.selectFork(forkIds[0]);
        assertEq(tokenA.balanceOf(address(aliceTwinA)), 0, "source token should be spent on chain A");
        assertEq(tokenB.balanceOf(address(aliceTwinA)), 0, "bridge token should not remain on chain A");

        vm.selectFork(forkIds[1]);
        assertEq(tokenB.balanceOf(address(aliceTwinB)), 0, "bridge token should be swapped away on chain B");
        assertEq(tokenC.balanceOf(address(aliceTwinB)), amountIn, "destination token should be received on chain B");
    }

    function test_swapBridgeSwap_secondSwapFailureBridgesBack() public {
        vm.selectFork(forkIds[1]);
        exchangeB.setFailureMode(address(tokenB), address(tokenC), true);

        vm.selectFork(forkIds[0]);
        vm.prank(alice);
        routerA.execute(address(initScriptA));

        bytes32 afterLocalSwapCallbackId = recorderA.afterLocalSwapCallbackId(address(aliceTwinA));
        callbackA.resolve(afterLocalSwapCallbackId);

        bytes32 bridgeMintCallbackId = recorderA.bridgeMintCallbackId(address(aliceTwinA));
        bytes32 secondSwapCallbackId = recorderA.secondSwapCallbackId(address(aliceTwinA));

        relayAllMessages();

        vm.selectFork(forkIds[1]);
        callbackB.resolve(bridgeMintCallbackId);
        callbackB.resolve(secondSwapCallbackId);

        bytes32 rollbackCallbackId = recorderB.rollbackCallbackId(address(aliceTwinB));
        assertTrue(rollbackCallbackId != bytes32(0), "rollback callback should be recorded");
        callbackB.resolve(rollbackCallbackId);

        bytes32 bridgeBackMintCallbackId = recorderB.bridgeBackMintCallbackId(address(aliceTwinB));
        assertTrue(bridgeBackMintCallbackId != bytes32(0), "bridge-back mint callback should be recorded");

        relayAllMessages();

        vm.selectFork(forkIds[0]);
        callbackA.resolve(bridgeBackMintCallbackId);

        assertEq(tokenA.balanceOf(address(aliceTwinA)), 0, "initial token stays swapped away");
        assertEq(tokenB.balanceOf(address(aliceTwinA)), amountIn, "bridge token should be returned to chain A");

        vm.selectFork(forkIds[1]);
        assertEq(tokenB.balanceOf(address(aliceTwinB)), 0, "bridge token should be burned on chain B");
        assertEq(tokenC.balanceOf(address(aliceTwinB)), 0, "destination swap should not complete");
    }

    function _deployTwinSystem() internal {
        vm.selectFork(forkIds[0]);
        promiseA = new Promise{salt: bytes32(0)}(
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        callbackA = new Callback{salt: bytes32(0)}(
            address(promiseA),
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        factoryA = new TwinFactory{salt: bytes32(0)}(
            address(callbackA),
            address(promiseA),
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );

        vm.selectFork(forkIds[1]);
        promiseB = new Promise{salt: bytes32(0)}(
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        callbackB = new Callback{salt: bytes32(0)}(
            address(promiseB),
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        factoryB = new TwinFactory{salt: bytes32(0)}(
            address(callbackB),
            address(promiseB),
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );

        require(address(promiseA) == address(promiseB), "promise addresses differ");
        require(address(callbackA) == address(callbackB), "callback addresses differ");
        require(address(factoryA) == address(factoryB), "factory addresses differ");

        chainAId = chainIdByForkId[forkIds[0]];
        chainBId = chainIdByForkId[forkIds[1]];

        vm.selectFork(forkIds[0]);
        routerA = new TwinRouter(address(factoryA));
        factoryA.setRouter(address(routerA));
        aliceTwinA = Twin(factoryA.getOrDeployTwin(alice));

        vm.selectFork(forkIds[1]);
        aliceTwinB = Twin(factoryB.deployTwin(chainAId, alice));

        require(address(aliceTwinA) == address(aliceTwinB), "twin addresses differ");
    }

    function _deployApplicationContracts() internal {
        vm.selectFork(forkIds[0]);
        exchangeA = new MockExchange{salt: bytes32(uint256(1))}();
        bridgeA = new PromiseBridge{salt: bytes32(uint256(2))}(address(promiseA), address(callbackA));
        tokenA = new MockSuperchainERC20{salt: bytes32(uint256(3))}(
            "TokenA",
            "TKA",
            100000 ether,
            address(bridgeA)
        );
        tokenB = new MockSuperchainERC20{salt: bytes32(uint256(4))}(
            "TokenB",
            "TKB",
            100000 ether,
            address(bridgeA)
        );
        tokenC = new MockSuperchainERC20{salt: bytes32(uint256(5))}(
            "TokenC",
            "TKC",
            100000 ether,
            address(bridgeA)
        );

        vm.selectFork(forkIds[1]);
        exchangeB = new MockExchange{salt: bytes32(uint256(1))}();
        bridgeB = new PromiseBridge{salt: bytes32(uint256(2))}(address(promiseB), address(callbackB));
        MockSuperchainERC20 tokenAB = new MockSuperchainERC20{salt: bytes32(uint256(3))}(
            "TokenA",
            "TKA",
            100000 ether,
            address(bridgeB)
        );
        MockSuperchainERC20 tokenBB = new MockSuperchainERC20{salt: bytes32(uint256(4))}(
            "TokenB",
            "TKB",
            100000 ether,
            address(bridgeB)
        );
        MockSuperchainERC20 tokenCB = new MockSuperchainERC20{salt: bytes32(uint256(5))}(
            "TokenC",
            "TKC",
            100000 ether,
            address(bridgeB)
        );

        require(address(exchangeA) == address(exchangeB), "exchange addresses differ");
        require(address(bridgeA) == address(bridgeB), "bridge addresses differ");
        require(address(tokenA) == address(tokenAB), "tokenA addresses differ");
        require(address(tokenB) == address(tokenBB), "tokenB addresses differ");
        require(address(tokenC) == address(tokenCB), "tokenC addresses differ");
    }

    function _deployWorkflowContracts() internal {
        vm.selectFork(forkIds[0]);
        recorderA = new WorkflowRecorder{salt: bytes32(uint256(10))}();
        rollbackA = new RollbackBridgeBackScript{salt: bytes32(uint256(11))}(
            address(tokenB),
            address(bridgeA),
            address(recorderA),
            chainAId
        );
        destinationSwapA = new DestinationSwapScript{salt: bytes32(uint256(12))}(
            address(tokenB),
            address(tokenC),
            address(exchangeA),
            address(recorderA),
            address(rollbackA)
        );
        afterLocalSwapA = new AfterLocalSwapScript{salt: bytes32(uint256(13))}(
            address(tokenB),
            address(bridgeA),
            address(recorderA),
            address(destinationSwapA),
            chainBId
        );
        initScriptA = new SwapBridgeSwapInitScript{salt: bytes32(uint256(14))}(
            address(tokenA),
            address(tokenB),
            address(exchangeA),
            address(recorderA),
            address(afterLocalSwapA),
            amountIn
        );

        vm.selectFork(forkIds[1]);
        recorderB = new WorkflowRecorder{salt: bytes32(uint256(10))}();
        rollbackB = new RollbackBridgeBackScript{salt: bytes32(uint256(11))}(
            address(tokenB),
            address(bridgeB),
            address(recorderB),
            chainAId
        );
        destinationSwapB = new DestinationSwapScript{salt: bytes32(uint256(12))}(
            address(tokenB),
            address(tokenC),
            address(exchangeB),
            address(recorderB),
            address(rollbackB)
        );
        afterLocalSwapB = new AfterLocalSwapScript{salt: bytes32(uint256(13))}(
            address(tokenB),
            address(bridgeB),
            address(recorderB),
            address(destinationSwapB),
            chainBId
        );
        initScriptB = new SwapBridgeSwapInitScript{salt: bytes32(uint256(14))}(
            address(tokenA),
            address(tokenB),
            address(exchangeB),
            address(recorderB),
            address(afterLocalSwapB),
            amountIn
        );

        require(address(recorderA) == address(recorderB), "recorder addresses differ");
        require(address(rollbackA) == address(rollbackB), "rollback script addresses differ");
        require(address(destinationSwapA) == address(destinationSwapB), "destination script addresses differ");
        require(address(afterLocalSwapA) == address(afterLocalSwapB), "bridge script addresses differ");
        require(address(initScriptA) == address(initScriptB), "init script addresses differ");
    }

    function _seedLiquidityAndFunds() internal {
        vm.selectFork(forkIds[0]);
        tokenA.transfer(address(aliceTwinA), amountIn);
        tokenA.transfer(liquidityProvider, 5000 ether);
        tokenB.transfer(liquidityProvider, 5000 ether);

        vm.startPrank(liquidityProvider);
        tokenA.approve(address(exchangeA), 5000 ether);
        tokenB.approve(address(exchangeA), 5000 ether);
        exchangeA.provideLiquidity(address(tokenA), 5000 ether);
        exchangeA.provideLiquidity(address(tokenB), 5000 ether);
        exchangeA.addPair(address(tokenA), address(tokenB), 10000);
        vm.stopPrank();

        vm.selectFork(forkIds[1]);
        tokenB.transfer(liquidityProvider, 5000 ether);
        tokenC.transfer(liquidityProvider, 5000 ether);

        vm.startPrank(liquidityProvider);
        tokenB.approve(address(exchangeB), 5000 ether);
        tokenC.approve(address(exchangeB), 5000 ether);
        exchangeB.provideLiquidity(address(tokenB), 5000 ether);
        exchangeB.provideLiquidity(address(tokenC), 5000 ether);
        exchangeB.addPair(address(tokenB), address(tokenC), 10000);
        vm.stopPrank();
    }
}

contract WorkflowRecorder {
    mapping(address => bytes32) public afterLocalSwapCallbackId;
    mapping(address => bytes32) public bridgeMintCallbackId;
    mapping(address => bytes32) public secondSwapCallbackId;
    mapping(address => bytes32) public rollbackCallbackId;
    mapping(address => bytes32) public bridgeBackMintCallbackId;

    function noteAfterLocalSwapCallbackId(bytes32 promiseId) external {
        afterLocalSwapCallbackId[msg.sender] = promiseId;
    }

    function noteBridgeMintCallbackId(bytes32 promiseId) external {
        bridgeMintCallbackId[msg.sender] = promiseId;
    }

    function noteSecondSwapCallbackId(bytes32 promiseId) external {
        secondSwapCallbackId[msg.sender] = promiseId;
    }

    function noteRollbackCallbackId(bytes32 promiseId) external {
        rollbackCallbackId[msg.sender] = promiseId;
    }

    function noteBridgeBackMintCallbackId(bytes32 promiseId) external {
        bridgeBackMintCallbackId[msg.sender] = promiseId;
    }
}

contract SwapBridgeSwapInitScript is IScript {
    using TwinChain for TwinChain.Chain;

    address public immutable tokenA;
    address public immutable tokenB;
    address public immutable exchange;
    address public immutable recorder;
    address public immutable afterLocalSwapScript;
    uint256 public immutable amountIn;

    constructor(
        address _tokenA,
        address _tokenB,
        address _exchange,
        address _recorder,
        address _afterLocalSwapScript,
        uint256 _amountIn
    ) {
        tokenA = _tokenA;
        tokenB = _tokenB;
        exchange = _exchange;
        recorder = _recorder;
        afterLocalSwapScript = _afterLocalSwapScript;
        amountIn = _amountIn;
    }

    function run() external {
        Twin twin = Twin(address(this));
        twin.execute(
            tokenA,
            abi.encodeCall(IERC20.approve, (exchange, amountIn))
        );

        bytes32 callbackId = twin.makeCall(
            exchange,
            abi.encodeCall(MockExchange.swap, (tokenA, tokenB, amountIn))
        ).thenScript(afterLocalSwapScript, AfterLocalSwapScript.run.selector).build();

        twin.execute(
            recorder,
            abi.encodeCall(WorkflowRecorder.noteAfterLocalSwapCallbackId, (callbackId))
        );
    }
}

contract AfterLocalSwapScript {
    using TwinChain for TwinChain.Chain;

    address public immutable tokenB;
    address public immutable bridge;
    address public immutable recorder;
    address public immutable destinationSwapScript;
    uint256 public immutable destinationChainId;

    constructor(
        address _tokenB,
        address _bridge,
        address _recorder,
        address _destinationSwapScript,
        uint256 _destinationChainId
    ) {
        tokenB = _tokenB;
        bridge = _bridge;
        recorder = _recorder;
        destinationSwapScript = _destinationSwapScript;
        destinationChainId = _destinationChainId;
    }

    function run(bytes memory parentReturnData) external {
        Twin twin = Twin(address(this));
        uint256 amountOut = abi.decode(parentReturnData, (uint256));

        twin.execute(
            tokenB,
            abi.encodeCall(IERC20.approve, (bridge, amountOut))
        );

        bytes memory bridgeResult = twin.execute(
            bridge,
            abi.encodeCall(
                PromiseBridge.bridgeTokens,
                (tokenB, amountOut, destinationChainId, address(this))
            )
        );

        (, bytes32 bridgeMintCallbackId) = abi.decode(bridgeResult, (bytes32, bytes32));
        twin.execute(
            recorder,
            abi.encodeCall(WorkflowRecorder.noteBridgeMintCallbackId, (bridgeMintCallbackId))
        );

        bytes32 secondSwapCallbackId = TwinChain.from(twin, bridgeMintCallbackId)
            .thenScriptOn(
                destinationChainId,
                destinationSwapScript,
                DestinationSwapScript.run.selector
            )
            .build();

        twin.execute(
            recorder,
            abi.encodeCall(WorkflowRecorder.noteSecondSwapCallbackId, (secondSwapCallbackId))
        );
    }
}

contract DestinationSwapScript {
    using TwinChain for TwinChain.Chain;

    address public immutable tokenB;
    address public immutable tokenC;
    address public immutable exchange;
    address public immutable recorder;
    address public immutable rollbackScript;

    constructor(
        address _tokenB,
        address _tokenC,
        address _exchange,
        address _recorder,
        address _rollbackScript
    ) {
        tokenB = _tokenB;
        tokenC = _tokenC;
        exchange = _exchange;
        recorder = _recorder;
        rollbackScript = _rollbackScript;
    }

    function run(bytes memory) external {
        Twin twin = Twin(address(this));
        uint256 amountIn = IERC20(tokenB).balanceOf(address(this));

        twin.execute(
            tokenB,
            abi.encodeCall(IERC20.approve, (exchange, amountIn))
        );

        bytes32 rollbackCallbackId = twin.makeCall(
            exchange,
            abi.encodeCall(MockExchange.swap, (tokenB, tokenC, amountIn))
        ).fork().catchErrorScript(rollbackScript, RollbackBridgeBackScript.run.selector).build();

        twin.execute(
            recorder,
            abi.encodeCall(WorkflowRecorder.noteRollbackCallbackId, (rollbackCallbackId))
        );
    }
}

contract RollbackBridgeBackScript {
    address public immutable tokenB;
    address public immutable bridge;
    address public immutable recorder;
    uint256 public immutable returnChainId;

    constructor(address _tokenB, address _bridge, address _recorder, uint256 _returnChainId) {
        tokenB = _tokenB;
        bridge = _bridge;
        recorder = _recorder;
        returnChainId = _returnChainId;
    }

    function run(bytes memory) external {
        Twin twin = Twin(address(this));
        uint256 amountToReturn = IERC20(tokenB).balanceOf(address(this));

        twin.execute(
            tokenB,
            abi.encodeCall(IERC20.approve, (bridge, amountToReturn))
        );

        bytes memory bridgeResult = twin.execute(
            bridge,
            abi.encodeCall(
                PromiseBridge.bridgeTokens,
                (tokenB, amountToReturn, returnChainId, address(this))
            )
        );

        (, bytes32 bridgeBackMintCallbackId) = abi.decode(bridgeResult, (bytes32, bytes32));
        twin.execute(
            recorder,
            abi.encodeCall(WorkflowRecorder.noteBridgeBackMintCallbackId, (bridgeBackMintCallbackId))
        );
    }
}
