// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {Relayer} from "../src/test/Relayer.sol";

import {Promise} from "../src/Promise.sol";
import {Callback} from "../src/Callback.sol";
import {Twin} from "../src/Twin.sol";
import {TwinChain} from "../src/TwinChain.sol";
import {TwinFactory} from "../src/TwinFactory.sol";
import {TwinRouter} from "../src/TwinRouter.sol";
import {IScript} from "../src/interfaces/IScript.sol";
import {PredeployAddresses} from "../src/libraries/PredeployAddresses.sol";

/// @title XChainTwinTest
/// @notice Cross-chain tests for Twin contract
contract XChainTwinTest is Test, Relayer {
    using TwinChain for TwinChain.Chain;

    Promise public promiseA;
    Promise public promiseB;
    Callback public callbackA;
    Callback public callbackB;
    TwinFactory public factoryA;
    TwinFactory public factoryB;
    TwinRouter public routerA;

    address public alice = address(0x1);
    Twin public aliceTwinA;
    Twin public aliceTwinB;

    string[] private rpcUrls = [
        vm.envOr("CHAIN_A_RPC_URL", string("http://127.0.0.1:9545")),
        vm.envOr("CHAIN_B_RPC_URL", string("http://127.0.0.1:9546"))
    ];

    constructor() Relayer(rpcUrls) {}

    function setUp() public {
        // Deploy all contracts with CREATE2 salt=0 for same addresses on both chains
        vm.selectFork(forkIds[0]);
        promiseA = new Promise{salt: bytes32(0)}(
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        callbackA = new Callback{salt: bytes32(0)}(
            address(promiseA),
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );
        factoryA = new TwinFactory{salt: bytes32(0)}(
            address(callbackA), address(promiseA),
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
            address(callbackB), address(promiseB),
            PredeployAddresses.L2_TO_L2_CROSS_DOMAIN_MESSENGER
        );

        // Verify same addresses
        require(address(promiseA) == address(promiseB), "Promise addresses differ");
        require(address(callbackA) == address(callbackB), "Callback addresses differ");
        require(address(factoryA) == address(factoryB), "Factory addresses differ");

        // Deploy Router on Chain A and wire it up
        vm.selectFork(forkIds[0]);
        routerA = new TwinRouter(address(factoryA));
        factoryA.setRouter(address(routerA));

        // Deploy alice's twin on both chains
        uint256 chainAId = chainIdByForkId[forkIds[0]];

        vm.selectFork(forkIds[0]);
        aliceTwinA = Twin(factoryA.getOrDeployTwin(alice));

        vm.selectFork(forkIds[1]);
        aliceTwinB = Twin(factoryB.deployTwin(chainAId, alice));

        // Same address on both chains
        require(address(aliceTwinA) == address(aliceTwinB), "Twin addresses differ");
    }

    /// @notice Twin has same deterministic address on both chains
    function test_twinSameAddressOnBothChains() public view {
        assertEq(address(aliceTwinA), address(aliceTwinB));
    }

    /// @notice makeCallOn: call executes on dest chain with msg.sender == twin
    function test_makeCallOnMsgSenderIsTwin() public {
        // Deploy target on Chain B
        vm.selectFork(forkIds[1]);
        XChainTarget target = new XChainTarget();

        // Make cross-chain call from Chain A
        vm.selectFork(forkIds[0]);
        uint256 chainBId = chainIdByForkId[forkIds[1]];

        vm.prank(alice);
        TwinChain.Chain memory chain = aliceTwinA.makeCallOn(
            chainBId,
            address(target),
            abi.encodeCall(target.doSomething, (42))
        );

        // Promise should be pending (waiting for cross-chain execution)
        // Actually the promise was transferred, so it's deleted locally
        assertTrue(chain.currentPromiseId != bytes32(0), "Promise ID should be non-zero");

        // Relay the message to Chain B
        relayAllMessages();

        // Verify on Chain B
        vm.selectFork(forkIds[1]);
        assertTrue(target.called(), "Target should have been called");
        assertEq(target.lastCaller(), address(aliceTwinB), "msg.sender should be twin");
        assertEq(target.lastValue(), 42, "Value should be correct");

        // Promise should be resolved on Chain B
        assertEq(
            uint256(promiseB.status(chain.currentPromiseId)),
            uint256(Promise.PromiseStatus.Resolved),
            "Promise should be resolved on Chain B"
        );
    }

    /// @notice makeCallOn shares promise back to origin chain
    function test_makeCallOnSharesBackToOrigin() public {
        vm.selectFork(forkIds[1]);
        XChainTarget target = new XChainTarget();

        vm.selectFork(forkIds[0]);
        uint256 chainBId = chainIdByForkId[forkIds[1]];

        vm.prank(alice);
        TwinChain.Chain memory chain = aliceTwinA.makeCallOn(
            chainBId,
            address(target),
            abi.encodeCall(target.doSomething, (10))
        );

        // Relay call to Chain B (Twin executes + shares promise back)
        relayAllMessages();

        // Relay share message back to Chain A
        relayAllMessages();

        // Promise should now be resolved on Chain A
        vm.selectFork(forkIds[0]);
        assertEq(
            uint256(promiseA.status(chain.currentPromiseId)),
            uint256(Promise.PromiseStatus.Resolved),
            "Promise should be resolved back on Chain A"
        );
    }

    /// @notice thenOn: callback fires on dest chain with msg.sender == twin
    function test_thenOnMsgSenderIsTwin() public {
        // Deploy targets
        vm.selectFork(forkIds[0]);
        XChainTarget targetA = new XChainTarget();

        vm.selectFork(forkIds[1]);
        XChainTarget targetB = new XChainTarget();

        vm.selectFork(forkIds[0]);
        uint256 chainBId = chainIdByForkId[forkIds[1]];

        // Create and resolve a promise on Chain A
        vm.prank(alice);
        TwinChain.Chain memory chain = aliceTwinA.makeCall(
            address(targetA),
            abi.encodeCall(targetA.doSomething, (10))
        );

        // Register cross-chain then callback
        vm.prank(alice);
        bytes32 cbPromiseId = aliceTwinA.thenOn(
            chainBId,
            chain.currentPromiseId,
            address(targetB),
            targetB.handleCallback.selector
        );

        // Relay: callback registration + dispatch info to Chain B
        relayAllMessages();

        // Verify callback exists on Chain B
        vm.selectFork(forkIds[1]);
        assertTrue(callbackB.exists(cbPromiseId), "Callback should be registered on Chain B");

        // Share parent promise to Chain B so callback can fire
        vm.selectFork(forkIds[0]);
        promiseA.shareResolvedPromise(chainBId, chain.currentPromiseId);
        relayAllMessages();

        // Execute callback on Chain B
        vm.selectFork(forkIds[1]);
        assertTrue(callbackB.canResolve(cbPromiseId), "Callback should be resolvable");
        callbackB.resolve(cbPromiseId);

        // Verify msg.sender at target is the twin
        assertTrue(targetB.callbackCalled(), "Callback should have fired");
        assertEq(targetB.callbackCaller(), address(aliceTwinB), "msg.sender should be twin");
    }

    /// @notice Dispatch info is received correctly cross-chain
    function test_dispatchInfoReceivedCrossChain() public {
        vm.selectFork(forkIds[0]);
        XChainTarget targetA = new XChainTarget();

        vm.selectFork(forkIds[1]);
        XChainTarget targetB = new XChainTarget();

        vm.selectFork(forkIds[0]);
        uint256 chainBId = chainIdByForkId[forkIds[1]];

        // Create promise and register cross-chain callback
        vm.prank(alice);
        TwinChain.Chain memory chain = aliceTwinA.makeCall(
            address(targetA),
            abi.encodeCall(targetA.doSomething, (1))
        );

        vm.prank(alice);
        bytes32 cbPromiseId = aliceTwinA.thenOn(
            chainBId,
            chain.currentPromiseId,
            address(targetB),
            targetB.handleCallback.selector
        );

        // Relay messages
        relayAllMessages();

        // Check dispatch info on Chain B
        vm.selectFork(forkIds[1]);
        (address dispTarget, bytes4 dispSelector) = aliceTwinB.dispatches(cbPromiseId);
        assertEq(dispTarget, address(targetB), "Dispatch target should match");
        assertEq(dispSelector, targetB.handleCallback.selector, "Dispatch selector should match");
    }

    /// @notice catchErrorOn works cross-chain
    function test_catchErrorOnCrossChain() public {
        vm.selectFork(forkIds[0]);
        XChainTarget targetA = new XChainTarget();

        vm.selectFork(forkIds[1]);
        XChainTarget errorHandler = new XChainTarget();

        vm.selectFork(forkIds[0]);
        uint256 chainBId = chainIdByForkId[forkIds[1]];

        // Create a promise that rejects
        vm.prank(alice);
        TwinChain.Chain memory chain = aliceTwinA.makeCall(
            address(targetA),
            abi.encodeCall(targetA.alwaysFails, ())
        );

        // Register cross-chain catch callback
        vm.prank(alice);
        bytes32 cbPromiseId = aliceTwinA.catchErrorOn(
            chainBId,
            chain.currentPromiseId,
            address(errorHandler),
            errorHandler.handleError.selector
        );

        // Relay callback registration + dispatch info
        relayAllMessages();

        // Share rejected promise to Chain B
        vm.selectFork(forkIds[0]);
        promiseA.shareResolvedPromise(chainBId, chain.currentPromiseId);
        relayAllMessages();

        // Execute catch callback on Chain B
        vm.selectFork(forkIds[1]);
        assertTrue(callbackB.canResolve(cbPromiseId), "Catch callback should be resolvable");
        callbackB.resolve(cbPromiseId);

        // msg.sender should be twin
        assertTrue(errorHandler.errorHandled(), "Error handler should have fired");
        assertEq(errorHandler.errorCaller(), address(aliceTwinB), "msg.sender should be twin");
    }

    /// @notice Full e2e: makeCallOn + thenOn chain
    function test_e2eMakeCallOnThenChainedCallback() public {
        // Deploy targets
        vm.selectFork(forkIds[1]);
        XChainTarget targetB = new XChainTarget();

        vm.selectFork(forkIds[0]);
        XChainTarget callbackTargetA = new XChainTarget();
        uint256 chainBId = chainIdByForkId[forkIds[1]];

        // makeCallOn chain B, then callback on chain A
        vm.startPrank(alice);
        TwinChain.Chain memory chain = aliceTwinA.makeCallOn(
            chainBId,
            address(targetB),
            abi.encodeCall(targetB.doSomething, (100))
        );

        // Register callback on Chain A watching the cross-chain call result
        bytes32 cbPromiseId = aliceTwinA.then(
            chain.currentPromiseId,
            address(callbackTargetA),
            callbackTargetA.handleCallback.selector
        );
        vm.stopPrank();

        // Step 1: Relay makeCallOn to Chain B
        relayAllMessages();

        // Verify call executed on Chain B
        vm.selectFork(forkIds[1]);
        assertTrue(targetB.called(), "Target on Chain B should have been called");
        assertEq(targetB.lastCaller(), address(aliceTwinB), "msg.sender should be twin on B");

        // Step 2: Relay resolved promise back to Chain A
        relayAllMessages();

        // Step 3: Execute callback on Chain A
        vm.selectFork(forkIds[0]);
        assertTrue(callbackA.canResolve(cbPromiseId), "Callback should be resolvable on A");
        callbackA.resolve(cbPromiseId);

        assertTrue(callbackTargetA.callbackCalled(), "Callback on A should have fired");
        assertEq(
            callbackTargetA.callbackCaller(),
            address(aliceTwinA),
            "msg.sender at callback target should be twin"
        );
    }

    /// @notice Full end-to-end: Router → Script → makeCallOn → relay → callback
    /// @dev Exercises the entire Twin system:
    ///   1. Alice calls router.execute(script) on Chain A
    ///   2. Router deploys twin (already deployed), calls twin.executeScript(script)
    ///   3. Script runs via delegatecall in twin's context
    ///   4. Script uses TwinChain fluent API: twin.makeCallOn(B, dex, data).then(handler, sel).build()
    ///   5. Cross-chain messages relay: call executes on Chain B, promise shares back
    ///   6. Callback fires on Chain A
    ///   7. msg.sender == twin at every target on every chain
    function test_e2eFullFlowRouterScriptMakeCallOnThen() public {
        // ── Deploy targets ─────────────────────────────────────────
        vm.selectFork(forkIds[1]);
        XChainTarget dexOnB = new XChainTarget(); // simulates a DEX on chain B

        vm.selectFork(forkIds[0]);
        XChainTarget handlerOnA = new XChainTarget(); // handles the result on chain A
        uint256 chainBId = chainIdByForkId[forkIds[1]];

        // ── Deploy the script ──────────────────────────────────────
        // The script encodes the full promise chain using TwinChain fluent API
        E2EScript script = new E2EScript(chainBId, address(dexOnB), address(handlerOnA));

        // ── Step 1: Alice calls router.execute(script) on Chain A ──
        // Router: getOrDeployTwin(alice) → twin.executeScript(script)
        // executeScript: delegatecall → script.run()
        // script.run():
        //   twin.makeCallOn(chainB, dex, swap(42))   → cross-chain call + promise P1
        //       .then(handler, handleCallback.sel)    → callback watching P1 → promise P2
        //       .build()                              → returns P2
        vm.prank(alice);
        address twinAddr = routerA.execute(address(script));
        assertEq(twinAddr, address(aliceTwinA), "Router should use alice's existing twin");

        // At this point on Chain A:
        //   - P1 was created and transferred to Chain B
        //   - A cross-chain message is pending: "twin on B, call dex.doSomething(42)"
        //   - P2 (callback) is registered on Chain A watching P1

        // ── Step 2: Relay makeCallOn message to Chain B ────────────
        relayAllMessages();

        // Verify: dex on Chain B was called, msg.sender == twin
        vm.selectFork(forkIds[1]);
        assertTrue(dexOnB.called(), "DEX on Chain B should have been called");
        assertEq(dexOnB.lastCaller(), address(aliceTwinB), "msg.sender at DEX should be twin");
        assertEq(dexOnB.lastValue(), 42, "DEX should receive correct value");
        // dex returns 42 * 2 = 84

        // Twin on Chain B also shared the resolved promise back to Chain A

        // ── Step 3: Relay resolved promise back to Chain A ─────────
        relayAllMessages();

        // ── Step 4: Callback fires on Chain A ──────────────────────
        // Find the callback promise ID — it's the promise created after P1
        // We need to resolve it via the Callback contract
        vm.selectFork(forkIds[0]);

        // The script created P1 (nonce 2, since twin creation used nonce 1 for factory)
        // then the callback created P2. We can find P2 by scanning.
        // Since makeCallOn creates a promise and then.then() creates another,
        // we know the callback promise is the one that's still resolvable.
        // Let's find it by checking which promises the callback contract has.
        //
        // Actually, the script's .then() called twin.then() which called
        // callbackContract.then(P1, twin, executeCallback.selector).
        // The callback promise ID was created by the callback contract.
        // We can find it because it's the only pending callback.
        //
        // For this test, we'll reconstruct: the promise nonce on chain A started at 1.
        // Twin deployment (via factory) doesn't create promises.
        // makeCallOn creates promise at nonce 1 → P1
        // twin.then() calls callbackContract.then() which calls promiseContract.create() → nonce 2 → P2
        bytes32 cbPromiseId = promiseA.generatePromiseId(bytes32(uint256(2)));

        assertTrue(callbackA.canResolve(cbPromiseId), "Callback should be resolvable on Chain A");
        callbackA.resolve(cbPromiseId);

        // ── Step 5: Verify msg.sender == twin at EVERY hop ─────────
        // Chain B: dex saw msg.sender == twin ✓ (verified above)
        // Chain A: handler saw msg.sender == twin
        assertTrue(handlerOnA.callbackCalled(), "Handler on Chain A should have been called");
        assertEq(
            handlerOnA.callbackCaller(),
            address(aliceTwinA),
            "msg.sender at handler on Chain A should be twin"
        );
    }

    /// @notice makeCallOn with failing call rejects promise
    function test_makeCallOnFailingCallRejectsPromise() public {
        vm.selectFork(forkIds[1]);
        XChainTarget target = new XChainTarget();

        vm.selectFork(forkIds[0]);
        uint256 chainBId = chainIdByForkId[forkIds[1]];

        vm.prank(alice);
        TwinChain.Chain memory chain = aliceTwinA.makeCallOn(
            chainBId,
            address(target),
            abi.encodeCall(target.alwaysFails, ())
        );

        // Relay to Chain B
        relayAllMessages();

        // Promise should be rejected on Chain B
        vm.selectFork(forkIds[1]);
        assertEq(
            uint256(promiseB.status(chain.currentPromiseId)),
            uint256(Promise.PromiseStatus.Rejected),
            "Promise should be rejected"
        );
    }
}

/// @notice Script that sets up a cross-chain call + callback using TwinChain fluent API
/// @dev Runs via delegatecall inside the Twin. Uses immutables (not storage) since
///      delegatecall uses the caller's storage, not the script's.
contract E2EScript is IScript {
    using TwinChain for TwinChain.Chain;

    uint256 public immutable destChainId;
    address public immutable remoteTarget;
    address public immutable localHandler;

    constructor(uint256 _destChainId, address _remoteTarget, address _localHandler) {
        destChainId = _destChainId;
        remoteTarget = _remoteTarget;
        localHandler = _localHandler;
    }

    function run() external {
        Twin twin = Twin(address(this));

        // Fluent chain: call DEX on chain B, then handle result locally
        twin.makeCallOn(
            destChainId,
            remoteTarget,
            abi.encodeCall(XChainTarget.doSomething, (42))
        )
        .then(localHandler, XChainTarget.handleCallback.selector)
        .build();
    }
}

/// @notice Target contract that records who called it
contract XChainTarget {
    bool public called;
    address public lastCaller;
    uint256 public lastValue;

    bool public callbackCalled;
    address public callbackCaller;

    bool public errorHandled;
    address public errorCaller;

    function doSomething(uint256 value) external returns (uint256) {
        called = true;
        lastCaller = msg.sender;
        lastValue = value;
        return value * 2;
    }

    function handleCallback(bytes memory) external returns (bytes memory) {
        callbackCalled = true;
        callbackCaller = msg.sender;
        return abi.encode(true);
    }

    function handleError(bytes memory) external returns (bytes memory) {
        errorHandled = true;
        errorCaller = msg.sender;
        return abi.encode(false);
    }

    function alwaysFails() external pure {
        revert("always fails");
    }
}
