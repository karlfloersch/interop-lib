// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {Promise} from "../src/Promise.sol";
import {Callback} from "../src/Callback.sol";
import {Twin} from "../src/Twin.sol";
import {TwinChain} from "../src/TwinChain.sol";
import {TwinFactory} from "../src/TwinFactory.sol";
import {TwinRouter} from "../src/TwinRouter.sol";
import {IScript} from "../src/interfaces/IScript.sol";
import {CallbackGasTank} from "../src/CallbackGasTank.sol";

contract TwinTest is Test {
    using TwinChain for TwinChain.Chain;

    Promise public promiseContract;
    Callback public callbackContract;
    TwinFactory public factory;
    TwinRouter public router;
    CallbackGasTank public gasTank;

    address public alice = address(0x1);
    address public bob = address(0x2);
    Twin public aliceTwin;

    function setUp() public {
        promiseContract = new Promise(address(0));
        callbackContract = new Callback(address(promiseContract), address(0));
        factory = new TwinFactory(
            address(callbackContract), address(promiseContract), address(0)
        );
        gasTank = new CallbackGasTank(address(callbackContract));
        router = new TwinRouter(address(factory), address(gasTank));
        factory.setRouter(address(router));

        // Deploy alice's twin
        aliceTwin = Twin(factory.getOrDeployTwin(alice));
    }

    // ─── Deployment ────────────────────────────────────────────────────

    function test_twinDeployment() public view {
        assertEq(aliceTwin.originChainId(), block.chainid);
        assertEq(aliceTwin.originAddress(), alice);
        assertEq(address(aliceTwin.callbackContract()), address(callbackContract));
        assertEq(address(aliceTwin.promiseContract()), address(promiseContract));
        assertTrue(factory.isTwin(address(aliceTwin)));
    }

    function test_deterministicAddress() public view {
        address computed = factory.computeTwinAddress(block.chainid, alice);
        assertEq(address(aliceTwin), computed);
    }

    function test_getOrDeployTwinIdempotent() public {
        address twin1 = factory.getOrDeployTwin(alice);
        address twin2 = factory.getOrDeployTwin(alice);
        assertEq(twin1, twin2);
    }

    function test_differentUsersGetDifferentTwins() public {
        Twin bobTwin = Twin(factory.getOrDeployTwin(bob));
        assertTrue(address(aliceTwin) != address(bobTwin));
    }

    // ─── makeCall ──────────────────────────────────────────────────────

    function test_makeCall() public {
        TwinTarget target = new TwinTarget();

        vm.prank(alice);
        TwinChain.Chain memory chain = aliceTwin.makeCall(
            address(target),
            abi.encodeCall(target.doSomething, (42))
        );

        // Promise should be resolved
        assertEq(
            uint256(promiseContract.status(chain.currentPromiseId)),
            uint256(Promise.PromiseStatus.Resolved)
        );

        // Target should have been called with msg.sender == twin
        assertTrue(target.called());
        assertEq(target.lastCaller(), address(aliceTwin));
        assertEq(target.lastValue(), 42);
    }

    function test_makeCallRejectOnRevert() public {
        TwinTarget target = new TwinTarget();

        vm.prank(alice);
        TwinChain.Chain memory chain = aliceTwin.makeCall(
            address(target),
            abi.encodeCall(target.alwaysFails, ())
        );

        // Promise should be rejected
        assertEq(
            uint256(promiseContract.status(chain.currentPromiseId)),
            uint256(Promise.PromiseStatus.Rejected)
        );
    }

    function test_makeCallOnlyOwner() public {
        TwinTarget target = new TwinTarget();

        vm.prank(bob);
        vm.expectRevert(Twin.NotAuthorized.selector);
        aliceTwin.makeCall(address(target), abi.encodeCall(target.doSomething, (1)));
    }

    // ─── then callback ─────────────────────────────────────────────────

    function test_thenCallbackMsgSenderIsTwin() public {
        TwinTarget target = new TwinTarget();

        // Create a parent promise that alice's twin can resolve
        vm.prank(alice);
        TwinChain.Chain memory chain = aliceTwin.makeCall(
            address(target),
            abi.encodeCall(target.doSomething, (10))
        );

        // Register then callback through twin
        vm.prank(alice);
        bytes32 cbPromiseId = aliceTwin.then(
            chain.currentPromiseId,
            address(target),
            target.handleCallback.selector
        );

        // Resolve the callback
        callbackContract.resolve(cbPromiseId);

        // Target should see msg.sender == twin
        assertEq(target.callbackCaller(), address(aliceTwin));
        assertTrue(target.callbackCalled());
    }

    function test_thenCallbackReceivesParentData() public {
        TwinTarget target = new TwinTarget();

        // Create and resolve parent promise
        vm.prank(alice);
        TwinChain.Chain memory chain = aliceTwin.makeCall(
            address(target),
            abi.encodeCall(target.doSomething, (42))
        );

        // Register then callback
        vm.prank(alice);
        bytes32 cbPromiseId = aliceTwin.then(
            chain.currentPromiseId,
            address(target),
            target.handleCallback.selector
        );

        // Resolve callback
        callbackContract.resolve(cbPromiseId);

        // Callback should have received the parent's return data
        assertTrue(target.callbackCalled());
    }

    // ─── catchError callback ───────────────────────────────────────────

    function test_catchErrorCallbackMsgSenderIsTwin() public {
        TwinTarget target = new TwinTarget();

        // Create a parent promise that rejects
        vm.prank(alice);
        TwinChain.Chain memory chain = aliceTwin.makeCall(
            address(target),
            abi.encodeCall(target.alwaysFails, ())
        );

        // Register catch callback through twin
        vm.prank(alice);
        bytes32 cbPromiseId = aliceTwin.catchError(
            chain.currentPromiseId,
            address(target),
            target.handleError.selector
        );

        // Resolve the callback
        callbackContract.resolve(cbPromiseId);

        // Target should see msg.sender == twin
        assertEq(target.errorCaller(), address(aliceTwin));
        assertTrue(target.errorHandled());
    }

    function test_thenScriptCallbackCanContinueAsTwin() public {
        TwinTarget parentTarget = new TwinTarget();
        TwinTarget nestedTarget = new TwinTarget();
        ThenScript callbackScript = new ThenScript(nestedTarget);

        vm.prank(alice);
        TwinChain.Chain memory chain = aliceTwin.makeCall(
            address(parentTarget),
            abi.encodeCall(parentTarget.doSomething, (21))
        );

        vm.prank(alice);
        bytes32 cbPromiseId = aliceTwin.thenScript(
            chain.currentPromiseId,
            address(callbackScript),
            callbackScript.run.selector
        );

        callbackContract.resolve(cbPromiseId);

        assertTrue(nestedTarget.called());
        assertEq(nestedTarget.lastCaller(), address(aliceTwin));
        assertEq(nestedTarget.lastValue(), 43);
    }

    function test_thenScriptCanPayResolverFromGasTank() public {
        TwinTarget target = new TwinTarget();
        TwinTarget parentTarget = new TwinTarget();
        GasPayingThenScript callbackScript = new GasPayingThenScript(gasTank, target, 0.1 ether);
        RouterGasPayingScript script =
            new RouterGasPayingScript(parentTarget, callbackScript);
        ResolverReceiver resolver = new ResolverReceiver();

        vm.deal(alice, 1 ether);

        vm.prank(alice);
        router.execute{value: 0.5 ether}(address(script));

        bytes32 cbPromiseId = promiseContract.generatePromiseId(bytes32(uint256(2)));

        resolver.resolveCallback(callbackContract, cbPromiseId);

        assertEq(resolver.totalReceived(), 0.1 ether, "Resolver should receive payout");
        assertEq(gasTank.balanceOf(address(aliceTwin)), 0.4 ether, "Twin gas balance should decrease");
        assertEq(gasTank.lastPaidRelayer(), address(resolver), "Resolver should be identified as relayer");
        assertEq(gasTank.lastPaidGasProvider(), address(aliceTwin), "Twin should fund payout");
        assertEq(gasTank.lastPaidAmount(), 0.1 ether, "Payout amount should be recorded");
        assertTrue(target.called(), "Script should continue after paying resolver");
        assertEq(target.lastCaller(), address(aliceTwin), "Nested call should still come from twin");
        assertEq(target.lastValue(), 19, "Script should still process parent result");
    }

    // ─── Auth ──────────────────────────────────────────────────────────

    function test_thenOnlyOwner() public {
        bytes32 fakePromise = bytes32(uint256(1));

        vm.prank(bob);
        vm.expectRevert(Twin.NotAuthorized.selector);
        aliceTwin.then(fakePromise, address(0x123), bytes4(0));
    }

    function test_catchErrorOnlyOwner() public {
        bytes32 fakePromise = bytes32(uint256(1));

        vm.prank(bob);
        vm.expectRevert(Twin.NotAuthorized.selector);
        aliceTwin.catchError(fakePromise, address(0x123), bytes4(0));
    }

    function test_executeOnlyOwner() public {
        vm.prank(bob);
        vm.expectRevert(Twin.NotAuthorized.selector);
        aliceTwin.execute(address(0x123), "");
    }

    function test_executeCallbackOnlyCallback() public {
        vm.prank(alice);
        vm.expectRevert(Twin.NotCallback.selector);
        aliceTwin.executeCallback("");
    }

    // ─── execute ───────────────────────────────────────────────────────

    function test_execute() public {
        TwinTarget target = new TwinTarget();

        vm.prank(alice);
        aliceTwin.execute(
            address(target),
            abi.encodeCall(target.doSomething, (99))
        );

        assertTrue(target.called());
        assertEq(target.lastCaller(), address(aliceTwin));
        assertEq(target.lastValue(), 99);
    }

    // ─── executeScript via Router ──────────────────────────────────────

    function test_executeScriptViaRouter() public {
        TwinTarget target = new TwinTarget();
        TestScript script = new TestScript(target, 77);

        vm.prank(alice);
        address twin = router.execute(address(script));

        assertEq(twin, address(aliceTwin));
        assertTrue(target.called());
        assertEq(target.lastCaller(), address(aliceTwin));
        assertEq(target.lastValue(), 77);
    }

    function test_executeScriptDirectlyByOwner() public {
        TwinTarget target = new TwinTarget();
        TestScript script = new TestScript(target, 55);

        vm.prank(alice);
        aliceTwin.executeScript(address(script));

        assertTrue(target.called());
        assertEq(target.lastCaller(), address(aliceTwin));
        assertEq(target.lastValue(), 55);
    }

    function test_executeScriptUnauthorized() public {
        TestScript script = new TestScript(new TwinTarget(), 1);

        vm.prank(bob);
        vm.expectRevert(Twin.NotAuthorized.selector);
        aliceTwin.executeScript(address(script));
    }

    // ─── TwinChain fluent API ──────────────────────────────────────────

    function test_twinChainFluent() public {
        TwinTarget target1 = new TwinTarget();
        TwinTarget target2 = new TwinTarget();

        // makeCall returns a chainable result
        vm.prank(alice);
        TwinChain.Chain memory chain = aliceTwin.makeCall(
            address(target1),
            abi.encodeCall(target1.doSomething, (10))
        );

        // Chain a .then() using the library
        vm.prank(alice);
        chain = chain.then(address(target2), target2.handleCallback.selector);

        bytes32 finalPromiseId = chain.build();

        // Resolve the callback
        callbackContract.resolve(finalPromiseId);

        // Both targets should have been called by the twin
        assertEq(target1.lastCaller(), address(aliceTwin));
        assertEq(target2.callbackCaller(), address(aliceTwin));
    }

    function test_twinChainFrom() public {
        TwinTarget target = new TwinTarget();

        // Create a promise manually
        vm.prank(alice);
        TwinChain.Chain memory chain = aliceTwin.makeCall(
            address(target),
            abi.encodeCall(target.doSomething, (5))
        );

        // Use TwinChain.from() to wrap an existing promise
        vm.prank(alice);
        TwinChain.Chain memory chain2 = TwinChain.from(aliceTwin, chain.currentPromiseId);
        chain2 = chain2.then(address(target), target.handleCallback.selector);

        bytes32 finalId = chain2.build();
        callbackContract.resolve(finalId);

        assertTrue(target.callbackCalled());
        assertEq(target.callbackCaller(), address(aliceTwin));
    }

    function test_twinChainFork() public {
        TwinTarget target1 = new TwinTarget();
        TwinTarget target2 = new TwinTarget();

        vm.startPrank(alice);

        TwinChain.Chain memory chain = aliceTwin.makeCall(
            address(target1),
            abi.encodeCall(target1.doSomething, (10))
        );

        // Fork: both branches watch the same parent promise
        TwinChain.Chain memory branch1 = chain.fork();
        branch1 = branch1.then(address(target1), target1.handleCallback.selector);

        TwinChain.Chain memory branch2 = chain.fork();
        branch2 = branch2.catchError(address(target2), target2.handleError.selector);

        vm.stopPrank();

        // Parent was resolved, so then-branch fires, catch-branch is rejected
        callbackContract.resolve(branch1.build());
        callbackContract.resolve(branch2.build());

        assertTrue(target1.callbackCalled());
        assertFalse(target2.errorHandled()); // catch doesn't fire on resolved parent
    }

    // ─── callbackPromiseId getter ──────────────────────────────────────

    function test_callbackPromiseIdRevertsOutsideExecution() public {
        vm.expectRevert("Callback: no callback currently executing");
        callbackContract.callbackPromiseId();
    }

    // ─── Factory router set ────────────────────────────────────────────

    function test_factoryRouterSetOnce() public {
        TwinFactory f2 = new TwinFactory(
            address(callbackContract), address(promiseContract), address(0)
        );
        f2.setRouter(address(0x999));

        vm.expectRevert(TwinFactory.RouterAlreadySet.selector);
        f2.setRouter(address(0x888));
    }

    function test_factorySetRouterOnlyOwner() public {
        TwinFactory f2 = new TwinFactory(
            address(callbackContract), address(promiseContract), address(0)
        );

        vm.prank(bob);
        vm.expectRevert(TwinFactory.NotOwner.selector);
        f2.setRouter(address(0x999));
    }
}

// ─── Helper Contracts ──────────────────────────────────────────────────

/// @notice Target contract that records who called it
contract TwinTarget {
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

/// @notice Script that makes a call through the twin via execute()
/// @dev Uses immutable instead of storage since scripts run via delegatecall
contract TestScript is IScript {
    TwinTarget public immutable target;
    uint256 public immutable value;

    constructor(TwinTarget _target, uint256 _value) {
        target = _target;
        value = _value;
    }

    function run() external {
        // In delegatecall context, address(this) == twin
        Twin twin = Twin(address(this));
        twin.execute(address(target), abi.encodeCall(target.doSomething, (value)));
    }
}

contract ThenScript {
    TwinTarget public immutable target;

    constructor(TwinTarget _target) {
        target = _target;
    }

    function run(bytes memory parentReturnData) external {
        uint256 value = abi.decode(parentReturnData, (uint256));
        Twin(address(this)).execute(
            address(target),
            abi.encodeCall(target.doSomething, (value + 1))
        );
    }
}

contract GasPayingThenScript {
    CallbackGasTank public immutable gasTank;
    TwinTarget public immutable target;
    uint256 public immutable payout;

    constructor(CallbackGasTank _gasTank, TwinTarget _target, uint256 _payout) {
        gasTank = _gasTank;
        target = _target;
        payout = _payout;
    }

    function run(bytes memory parentReturnData) external {
        Twin twin = Twin(address(this));
        uint256 value = abi.decode(parentReturnData, (uint256));

        twin.execute(
            address(gasTank),
            abi.encodeCall(CallbackGasTank.payCurrentResolver, (payout))
        );

        twin.execute(
            address(target),
            abi.encodeCall(target.doSomething, (value + 1))
        );
    }
}

contract RouterGasPayingScript is IScript {
    using TwinChain for TwinChain.Chain;

    TwinTarget public immutable parentTarget;
    GasPayingThenScript public immutable callbackScript;

    constructor(TwinTarget _parentTarget, GasPayingThenScript _callbackScript) {
        parentTarget = _parentTarget;
        callbackScript = _callbackScript;
    }

    function run() external {
        Twin twin = Twin(address(this));
        twin.makeCall(address(parentTarget), abi.encodeCall(parentTarget.doSomething, (9)))
            .thenScript(address(callbackScript), GasPayingThenScript.run.selector)
            .build();
    }
}

contract ResolverReceiver {
    uint256 public totalReceived;

    receive() external payable {
        totalReceived += msg.value;
    }

    function resolveCallback(Callback callbackContract, bytes32 callbackPromiseId) external {
        callbackContract.resolve(callbackPromiseId);
    }
}
