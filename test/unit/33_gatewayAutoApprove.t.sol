// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";

import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { ConfigId } from "smartsessions/DataTypes.sol";

import { BaseTest } from "../Base.t.sol";

import { AGW } from "../../src/AGW.sol";
import { IAGW } from "../../src/interfaces/IAGW.sol";
import { UniversalRulesPolicyErrors } from "../../src/libraries/Errors.sol";
import {
    AllowedCall,
    Config,
    Multicall,
    MULTICALL_SELECTOR,
    OWNER_LANE_FLAG,
    OwnerIntent,
    UniversalOutboundTxRequest
} from "../../src/libraries/Types.sol";
import { ModeLib, ModeCode } from "../../src/libraries/ModeLib.sol";
import { ExecutionLib, Execution } from "../../src/libraries/ExecutionLib.sol";

import { MockPRC20 } from "../mocks/MockUniversalGateway.sol";
import { PullingGatewayMock } from "../mocks/PullingGatewayMock.sol";
import {
    HostileTokenBase,
    RevertingApproveToken,
    FalseApproveToken,
    ReturnBombToken,
    ReentrantApproveToken
} from "../mocks/HostileTokens.sol";

/**
 * @title  GatewayAutoApproveTest — the wallet approves the gateway itself, for the exact amount, on
 *         every door (AGW_GATEWAY_AUTO_APPROVE PRD, change §6.1).
 *
 * @notice The deployed gateway pulls exactly `req.amount` of `req.token` from `msg.sender` — the
 *         wallet. Before this change nobody approved it unless the owner did so by hand. Now `_execute`
 *         approves exactly the amount before a parseable outbound and leaves the allowance at 0 after
 *         it, on `execute`, `executeWithSig` and `executeAsAgent` alike, and can never make a call fail
 *         that would have succeeded without it.
 *
 * @dev    The gateway is `PullingGatewayMock` etched at `GATEWAY`, an OBSERVER that reproduces only the
 *         real gateway's pull; tests that need a gateway that pulls nothing etch the call recorder
 *         instead. The tokens are `MockPRC20` (with its standard `transferFrom`) and the hostile tokens
 *         in `test/mocks/HostileTokens.sol`.
 */
contract GatewayAutoApproveTest is BaseTest {
    PullingGatewayMock internal gateway;
    MockPRC20 internal token;
    AGW internal wallet;

    address internal walletOwner;
    uint256 internal walletOwnerPk;
    address internal agentAddr;
    address internal protocol;
    address internal cea;
    address internal executor;

    bytes32 internal permissionId;

    bytes4 internal constant SWAP_SELECTOR = bytes4(keccak256("swap(uint256,address)"));

    /// @dev Hand-typed witnesses of the two token selectors the wallet calls raw (A19 pins the
    ///      wallet's own constants against these).
    bytes4 internal constant APPROVE_SELECTOR = bytes4(keccak256("approve(address,uint256)"));
    bytes4 internal constant ALLOWANCE_SELECTOR = bytes4(keccak256("allowance(address,address)"));

    bytes32 internal constant APPROVAL_TOPIC = keccak256("Approval(address,address,uint256)");

    /// @dev A20's payload prefix: "PC20" in ASCII. A STAND-IN, not the gateway's PC20-export selector.
    bytes4 internal constant PC20_STAND_IN_PREFIX = 0x50433230;

    /// @dev The rules set's per-call cap on `token`. Lifetime is unlimited, so the fuzz and gas runs
    ///      never meet gate 7.
    uint256 internal constant CAP = 100_000e6;
    uint256 internal constant FUNDS = 1_000_000e6;

    /// @dev Bob's per-call move in the PRD's worked example: 50 USDC.
    uint256 internal constant FIFTY = 50e6;

    /**
     * @dev A14. Gas of one owner `execute` outbound whose token return-bombs on `approve` and on
     *      `allowance` (three 1 MiB returns: approve, allowance, the clearing approve), call-recorder
     *      gateway. Measured on forge 1.5.1-stable with the pinned toolchain at 6,631,479 (default) and
     *      6,662,631 (`--isolate`); the budget is the larger plus 20%. Nearly all of it is the TOKEN's
     *      own memory expansion. Copying even one 1 MiB return into the wallet's memory would add
     *      ~2.2M more (the quadratic expansion), so a copy breaks this budget in either mode.
     */
    uint256 internal constant RETURN_BOMB_GAS_BUDGET = 7_995_157;

    /**
     * @dev G01, default mode (one transaction for the whole test, so slots warmed by the first call
     *      stay warm and refunds are invisible to `gasleft`). The overhead of auto-approve on one agent
     *      outbound of 50 against the pulling gateway: (with the feature) minus (the pre-feature flow, a
     *      standing allowance the gateway pulls from). Measured at 23,424, plus 10%. It is essentially
     *      the approve's 0 -> amount SSTORE (20,000) plus the approve and allowance calls.
     */
    uint256 internal constant AUTO_APPROVE_OVERHEAD_BUDGET = 25_766;

    /**
     * @dev G01 under `--isolate`: every top-level call is its own transaction and the figure is that
     *      transaction's gas AFTER refunds. The approve's 0 -> amount write is refunded when the
     *      gateway's pull takes it back to 0 in the same transaction, so the net overhead is small.
     *      Measured at 824, plus 10%.
     */
    uint256 internal constant AUTO_APPROVE_OVERHEAD_BUDGET_ISOLATED = 906;

    function setUp() public override {
        super.setUp();

        // The pulling gateway lives AT the address the wallet and URP were wired to.
        vm.etch(GATEWAY, type(PullingGatewayMock).runtimeCode);
        gateway = PullingGatewayMock(payable(GATEWAY));

        (walletOwner, walletOwnerPk) = ecdsaKey("autoApproveOwner");
        agentAddr = makeAddr("autoApproveAgent");
        protocol = makeAddr("farChainProtocol");
        cea = makeAddr("destinationAccount");
        executor = makeAddr("relayer");
        token = new MockPRC20();

        vm.warp(1_000_000_000);

        wallet = newWallet(walletOwner);
        token.mint(address(wallet), FUNDS);
        vm.deal(address(wallet), 10 ether);

        vm.prank(walletOwner);
        permissionId = wallet.grantRules(canonicalSession(agentConfig(agentAddr), _urpInitData()));
    }

    // ─────────────────────────────── fixtures ───────────────────────────────

    function _urpInitData() internal view returns (bytes memory) {
        AllowedCall[] memory rules = new AllowedCall[](1);
        rules[0] = AllowedCall({
            target: protocol,
            selector: SWAP_SELECTOR,
            beneficiaryOffset: 36,
            hasBeneficiary: true,
            maxValue: 0,
            pins: noPins()
        });
        return universalInitData(
            Config({
                initialized: false,
                validUntil: uint48(block.timestamp + 365 days),
                expectedCEA: cea,
                maxGasPerCall: 1 ether,
                assets: oneAsset(address(token), CAP, type(uint256).max),
                allowedCalls: rules
            })
        );
    }

    function _calls() internal view returns (Multicall[] memory c) {
        c = new Multicall[](1);
        c[0] = Multicall({ to: protocol, value: 0, data: abi.encodeWithSelector(SWAP_SELECTOR, uint256(1), cea) });
    }

    /// @dev `sendUniversalTxOutbound(req)` calldata, the shape URP accepts.
    function _request(address tok, uint256 amount) internal view returns (bytes memory) {
        return outboundRequest(tok, amount, 0.01 ether, address(wallet), _calls());
    }

    function _agentEcd(uint256 amount) internal view returns (bytes memory) {
        return ExecutionLib.encodeSingle(GATEWAY, 0, _request(address(token), amount));
    }

    function _single() internal pure returns (bytes32) {
        return ModeCode.unwrap(ModeLib.encodeSimpleSingle());
    }

    function _batch() internal pure returns (bytes32) {
        return ModeCode.unwrap(ModeLib.encodeSimpleBatch());
    }

    function _agentOutbound(uint256 amount) internal {
        bytes memory ecd = _agentEcd(amount);
        vm.prank(agentAddr);
        wallet.executeAsAgent(permissionId, _single(), ecd);
    }

    function _ownerExecute(address target, bytes memory callData) internal {
        bytes memory ecd = ExecutionLib.encodeSingle(target, 0, callData);
        vm.prank(walletOwner);
        wallet.execute(_single(), ecd);
    }

    /// @dev The owner's hand-made approval, the step this change makes unnecessary.
    function _ownerApprove(uint256 amount) internal {
        _ownerExecute(address(token), abi.encodeWithSelector(APPROVE_SELECTOR, GATEWAY, amount));
    }

    function _allowance() internal view returns (uint256) {
        return token.allowance(address(wallet), GATEWAY);
    }

    function _configId() internal view returns (ConfigId) {
        bytes32 actionId = keccak256(abi.encodePacked(GATEWAY, SEND_OUTBOUND_SELECTOR));
        return ConfigId.wrap(
            keccak256(abi.encodePacked(address(wallet), keccak256(abi.encodePacked(permissionId, actionId))))
        );
    }

    function _spent() internal view returns (uint256) {
        return urp.getConfig(_configId(), address(wallet)).assets[0].spent;
    }

    /// @dev Copy of `b[from:]`.
    function _tail(bytes memory b, uint256 from) internal pure returns (bytes memory out) {
        out = new bytes(b.length - from);
        for (uint256 i; i < out.length; ++i) {
            out[i] = b[from + i];
        }
    }

    /// @dev Overwrite the 32-byte word at `at` in `b`.
    function _setWord(bytes memory b, uint256 at, uint256 word) internal pure {
        assembly {
            mstore(add(add(b, 0x20), at), word)
        }
    }

    /// @dev `Approval` events emitted by `emitter` in `logs`: total, and how many carried a non-zero value.
    function _approvals(Vm.Log[] memory logs, address emitter)
        internal
        pure
        returns (uint256 total, uint256 zeroValued, uint256 nonZeroValued)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != emitter || logs[i].topics.length == 0 || logs[i].topics[0] != APPROVAL_TOPIC) {
                continue;
            }
            total++;
            if (abi.decode(logs[i].data, (uint256)) == 0) zeroValued++;
            else nonZeroValued++;
        }
    }

    // ═══════════════════════════════ the problem, removed ═══════════════════════════════

    /// ⚠️ NEVER-DELETE. The problem §6.1 exists to remove: before this change, an agent outbound from a
    /// wallet whose owner never approved the gateway reverted inside the gateway's pull, and the agent's
    /// whole transaction failed. Now the wallet approves exactly the amount itself, the gateway pulls
    /// it, nothing is left behind, and the owner side is never touched.
    function test_A01_AgentOutboundWithoutAnyOwnerApproval() public {
        assertEq(_allowance(), 0, "no allowance was ever set");
        uint64 checkpointsBefore = wallet.checkpointCount();
        uint256 balanceBefore = token.balanceOf(address(wallet));

        _agentOutbound(FIFTY);

        assertEq(gateway.callCount(), 1, "the outbound reached the gateway");
        assertEq(token.balanceOf(GATEWAY), FIFTY, "the gateway pulled exactly 50");
        assertEq(balanceBefore - token.balanceOf(address(wallet)), FIFTY, "the wallet's balance dropped by 50");
        assertEq(_allowance(), 0, "no allowance survives the outbound");
        assertEq(wallet.checkpointCount(), checkpointsBefore, "the agent door never ticks a checkpoint");
    }

    function test_A02_GatewaySeesExactAllowance() public {
        _agentOutbound(FIFTY);
        assertEq(gateway.allowanceAtEntry(), FIFTY, "the gateway saw exactly the amount: not max, not more");
    }

    function test_A03_OwnerExecuteSingleOutbound() public {
        uint64 checkpointsBefore = wallet.checkpointCount();

        _ownerExecute(GATEWAY, _request(address(token), 30e6));

        assertEq(gateway.allowanceAtEntry(), 30e6, "approved exactly 30");
        assertEq(token.balanceOf(GATEWAY), 30e6, "pulled 30");
        assertEq(_allowance(), 0, "allowance 0 after");
        assertEq(wallet.checkpointCount(), checkpointsBefore + 1, "the call's own owner-door tick, unchanged");
    }

    function test_A04_OwnerBatchTwoOutbounds() public {
        uint64 checkpointsBefore = wallet.checkpointCount();

        Execution[] memory execs = new Execution[](2);
        execs[0] = Execution({ target: GATEWAY, value: 0, callData: _request(address(token), 10e6) });
        execs[1] = Execution({ target: GATEWAY, value: 0, callData: _request(address(token), 20e6) });
        bytes memory ecd = ExecutionLib.encodeBatch(execs);
        vm.prank(walletOwner);
        wallet.execute(_batch(), ecd);

        assertEq(gateway.callCount(), 2, "both outbounds ran");
        assertEq(gateway.allowanceSeenAt(0), 10e6, "the first entry saw exactly 10");
        assertEq(gateway.allowanceSeenAt(1), 20e6, "the second entry saw exactly 20");
        assertEq(token.balanceOf(GATEWAY), 30e6, "both pulled");
        assertEq(_allowance(), 0, "allowance 0 after");
        assertEq(wallet.checkpointCount(), checkpointsBefore + 2, "one tick per entry, unchanged");
    }

    function test_A05_ExecuteWithSigOutbound() public {
        uint64 checkpointsBefore = wallet.checkpointCount();
        bytes memory cd = ExecutionLib.encodeSingle(GATEWAY, 0, _request(address(token), 30e6));

        OwnerIntent memory i = blankIntent(walletOwner, address(wallet), executor);
        i.mode = _single();
        i.execCalldataHash = keccak256(cd);
        i.nonceKey = OWNER_LANE_FLAG;
        i.nonceSeq = wallet.getNonce(OWNER_LANE_FLAG);
        bytes memory sig = signIntent(walletOwnerPk, i);

        vm.expectEmit(true, false, false, true, address(wallet));
        emit IAGW.OwnerExecutedWithSig(_single(), keccak256(cd), OWNER_LANE_FLAG, 0);
        vm.prank(executor);
        wallet.executeWithSig(_single(), cd, i, sig);

        assertEq(gateway.allowanceAtEntry(), 30e6, "approved exactly 30");
        assertEq(token.balanceOf(GATEWAY), 30e6, "pulled 30");
        assertEq(_allowance(), 0, "allowance 0 after");
        assertEq(wallet.checkpointCount(), checkpointsBefore + 1, "one owner-door tick, unchanged");
    }

    /// A-5: a standing allowance the owner set deliberately does not survive the next outbound.
    function test_A06_StandingAllowanceSuperseded() public {
        _ownerApprove(type(uint256).max);
        assertEq(_allowance(), type(uint256).max, "the owner's standing allowance is in place");

        _agentOutbound(FIFTY);

        assertEq(gateway.allowanceAtEntry(), FIFTY, "the gateway saw exactly 50, not the standing max");
        assertEq(_allowance(), 0, "the standing allowance was cleared (A-5)");
    }

    /// A-1 step 3 runs even when step 1 is skipped.
    function test_A07_ZeroAmountOutbound() public {
        _ownerApprove(77);

        vm.recordLogs();
        _agentOutbound(0);
        (uint256 total, uint256 zeroValued, uint256 nonZeroValued) = _approvals(vm.getRecordedLogs(), address(token));

        assertEq(gateway.callCount(), 1, "the zero-amount outbound succeeded");
        assertEq(total, 1, "exactly one Approval");
        assertEq(zeroValued, 1, "and it is the clear, Approval(wallet, gateway, 0)");
        assertEq(nonZeroValued, 0, "no approve to a non-zero value: step 1 skipped at amount 0");
        assertEq(_allowance(), 0, "allowance 0 after");
    }

    function test_A08_ShortPullIsCleared() public {
        gateway.setPullShort(true);

        _agentOutbound(FIFTY);

        assertEq(gateway.allowanceAtEntry(), FIFTY, "approved exactly 50");
        assertEq(token.balanceOf(GATEWAY), FIFTY - 1, "the gateway pulled one short");
        assertEq(_allowance(), 0, "the leftover unit was cleared");
    }

    function test_A09_GatewayRevertRestoresEverything() public {
        _assertAgentGatewayRevertRestores(0);
        _assertAgentGatewayRevertRestores(5);
        _assertOwnerGatewayRevertRestores();
    }

    function _assertAgentGatewayRevertRestores(uint256 prior) internal {
        if (prior != 0) _ownerApprove(prior);
        assertEq(_allowance(), prior, "prior allowance in place");
        uint256 balanceBefore = token.balanceOf(address(wallet));
        uint256 spentBefore = _spent();

        gateway.setShouldRevert(true);
        bytes memory ecd = _agentEcd(FIFTY);
        vm.expectRevert(PullingGatewayMock.GatewayRejected.selector);
        vm.prank(agentAddr);
        wallet.executeAsAgent(permissionId, _single(), ecd);
        gateway.setShouldRevert(false);

        assertEq(_allowance(), prior, "the allowance is exactly what it was");
        assertEq(token.balanceOf(address(wallet)), balanceBefore, "the balance is unchanged");
        assertEq(_spent(), spentBefore, "URP's spend counter is unchanged");
    }

    function _assertOwnerGatewayRevertRestores() internal {
        _ownerApprove(5);
        gateway.setShouldRevert(true);
        bytes memory ecd = ExecutionLib.encodeSingle(GATEWAY, 0, _request(address(token), FIFTY));
        vm.expectRevert(PullingGatewayMock.GatewayRejected.selector);
        vm.prank(walletOwner);
        wallet.execute(_single(), ecd);
        gateway.setShouldRevert(false);
        assertEq(_allowance(), 5, "owner door: the allowance is exactly what it was");
    }

    // ═══════════════════════ parsing never reverts, never misfires ═══════════════════════

    function test_A10_MalformedGatewayCalldataStillForwarded() public {
        etchCallRecorder(GATEWAY);
        bytes memory good = _request(address(token), FIFTY);

        bytes[] memory cases = new bytes[](9);
        cases[0] = abi.encodePacked(SEND_OUTBOUND_SELECTOR); // (a) the W-01 shape
        cases[1] = new bytes(35); // (b) 35 bytes: a good prefix, one byte short of the offset word
        for (uint256 j; j < 35; ++j) {
            cases[1][j] = good[j];
        }
        // (c) a perfect request whose offset word is huge — a parser at a fixed offset 36 would approve
        cases[2] = bytes.concat(good);
        _setWord(cases[2], 4, type(uint256).max);
        // (d) an offset inside the calldata whose struct head would run past the end
        cases[3] = bytes.concat(good);
        _setWord(cases[3], 4, good.length - 4 - 64);
        // (e) the right token with dirty high bits in its word (head word 1 at 4 + 32 + 32)
        cases[4] = bytes.concat(good);
        _setWord(cases[4], 68, uint256(uint160(address(token))) | (uint256(1) << 200));
        cases[5] = _request(address(0), FIFTY); // (f)
        cases[6] = _request(address(wallet), FIFTY); // (g)
        cases[7] = _request(address(engine), FIFTY); // (h)
        cases[8] = _request(GATEWAY, FIFTY); // (i)

        // No approve reaches any candidate "token", and no allowance query reaches the excluded ones
        // (the token's own `allowance` is read by this test below, so it is checked through the
        // absence of `Approval` instead). A call to GATEWAY with either selector would also move the
        // recorder past the one forwarded call per case.
        address[5] memory candidates = [address(token), address(wallet), address(engine), GATEWAY, address(0)];
        for (uint256 k; k < candidates.length; ++k) {
            vm.expectCall(candidates[k], abi.encodePacked(APPROVE_SELECTOR), 0);
            if (k != 0) vm.expectCall(candidates[k], abi.encodePacked(ALLOWANCE_SELECTOR), 0);
        }

        vm.recordLogs();
        for (uint256 c; c < cases.length; ++c) {
            uint256 before = callsRecorded(GATEWAY);
            _ownerExecute(GATEWAY, cases[c]);
            assertEq(callsRecorded(GATEWAY), before + 1, string.concat("case ", vm.toString(c), ": forwarded once"));
        }
        (uint256 total,,) = _approvals(vm.getRecordedLogs(), address(token));
        assertEq(total, 0, "no Approval anywhere");
        assertEq(_allowance(), 0, "no allowance was created");
    }

    /// The helper cannot turn a token's revert into the wallet's revert.
    function test_A11_RevertingApproveIgnored() public {
        RevertingApproveToken t = new RevertingApproveToken();
        etchCallRecorder(GATEWAY);

        // The approve WAS attempted, and reverted inside the token.
        vm.expectCall(address(t), abi.encodeWithSelector(APPROVE_SELECTOR, GATEWAY, FIFTY), 1);
        _ownerExecute(GATEWAY, _request(address(t), FIFTY));

        assertEq(callsRecorded(GATEWAY), 1, "the call was forwarded and succeeded");
    }

    function test_A12_FalseApproveIgnored() public {
        FalseApproveToken t = new FalseApproveToken();
        t.mint(address(wallet), FUNDS);
        bytes memory req = _request(address(t), FIFTY);

        // A pulling gateway decides: the approve set nothing, so the pull fails in the TOKEN, named.
        bytes memory ecd = ExecutionLib.encodeSingle(GATEWAY, 0, req);
        vm.expectRevert(HostileTokenBase.InsufficientAllowance.selector);
        vm.prank(walletOwner);
        wallet.execute(_single(), ecd);

        // A gateway that pulls nothing: the wallet's helper raises nothing of its own.
        etchCallRecorder(GATEWAY);
        _ownerExecute(GATEWAY, req);
        assertEq(callsRecorded(GATEWAY), 1, "forwarded; the false return was ignored");
    }

    function test_A13_CodelessTokenIgnored() public {
        address codeless = makeAddr("codelessToken");
        assertEq(codeless.code.length, 0, "no code at the token address");
        etchCallRecorder(GATEWAY);

        _ownerExecute(GATEWAY, _request(codeless, FIFTY));

        assertEq(callsRecorded(GATEWAY), 1, "forwarded; the codeless approve and allowance were no-ops");
    }

    function test_A14_ReturnBombBounded() public {
        ReturnBombToken t = new ReturnBombToken();
        etchCallRecorder(GATEWAY);
        bytes memory ecd = ExecutionLib.encodeSingle(GATEWAY, 0, _request(address(t), FIFTY));

        // Both bombing paths run: the approve, and (allowance reads non-zero) the clearing approve.
        vm.expectCall(address(t), abi.encodeWithSelector(APPROVE_SELECTOR, GATEWAY, FIFTY), 1);
        vm.expectCall(address(t), abi.encodeWithSelector(APPROVE_SELECTOR, GATEWAY, 0), 1);

        vm.prank(walletOwner);
        uint256 before = gasleft();
        wallet.execute(_single(), ecd);
        uint256 used = before - gasleft();

        emit log_named_uint("return-bomb outbound gas", used);
        assertEq(callsRecorded(GATEWAY), 1, "forwarded");
        assertLe(used, RETURN_BOMB_GAS_BUDGET, "no return data was copied into the wallet");
    }

    function test_A15_ReentrancyBlocked() public {
        ReentrantApproveToken t = new ReentrantApproveToken();
        // The token is the wallet's OWNER, so its re-entry into `execute` passes `onlyOwner` and meets
        // the transient guard itself rather than the owner check.
        AGW w = newWallet(address(t));
        t.mint(address(w), FUNDS);

        bytes memory req = outboundRequest(address(t), FIFTY, 0.01 ether, address(w), _calls());
        bytes memory ecd = ExecutionLib.encodeSingle(GATEWAY, 0, req);
        vm.prank(address(t));
        w.execute(_single(), ecd);

        assertGt(t.approveCalls(), 0, "the wallet's approve reached the token");
        assertFalse(t.reentered(), "both re-entries failed");
        assertEq(t.executeRevert(), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector, "execute: guard");
        assertEq(
            t.agentRevert(), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector, "executeAsAgent: guard"
        );
        assertEq(t.balanceOf(GATEWAY), FIFTY, "the outer outbound proceeded and was pulled");
    }

    function test_A16_NonGatewayTargetUntouched() public {
        address notGateway = makeAddr("notTheGateway");
        etchCallRecorder(notGateway);

        vm.expectCall(address(token), abi.encodePacked(APPROVE_SELECTOR), 0);
        vm.recordLogs();
        _ownerExecute(notGateway, _request(address(token), FIFTY));
        (uint256 total,,) = _approvals(vm.getRecordedLogs(), address(token));

        assertEq(callsRecorded(notGateway), 1, "the call ran");
        assertEq(total, 0, "no Approval");
        assertEq(token.allowance(address(wallet), notGateway), 0, "nothing approved to the target");
        assertEq(_allowance(), 0, "nothing approved to the gateway");
    }

    function test_A17_GatewayOtherSelectorUntouched() public {
        etchCallRecorder(GATEWAY);
        bytes memory cd = bytes.concat(bytes4(0xdeadbeef), _tail(_request(address(token), FIFTY), 4));

        vm.expectCall(address(token), abi.encodePacked(APPROVE_SELECTOR), 0);
        _ownerExecute(GATEWAY, cd);

        assertEq(callsRecorded(GATEWAY), 1, "the call ran");
        assertEq(_allowance(), 0, "no approve for another selector");
    }

    /// A-4: on the agent door URP runs first, so a refused request never approves anything.
    function test_A18_AgentRefusedByUrpNeverApproves() public {
        bytes memory ecd = _agentEcd(CAP + 1);

        vm.expectCall(address(token), abi.encodePacked(APPROVE_SELECTOR), 0);
        expectUrpGate(abi.encodeWithSelector(UniversalRulesPolicyErrors.AmountExceedsCap.selector, CAP + 1, CAP));
        vm.prank(agentAddr);
        wallet.executeAsAgent(permissionId, _single(), ecd);

        assertEq(_allowance(), 0, "allowance unchanged");
        assertEq(gateway.callCount(), 0, "nothing dispatched");
    }

    /**
     * The constants are `private` (PRD §4.1), so a harness inheriting `AGW` cannot name them, and a
     * bytecode search is codegen-dependent: via_ir emits `allowance`'s selector as
     * `PUSH4 0x6eb1769f PUSH1 0xe1 SHL` (0xdd62ed3e has a trailing zero bit), so the literal never
     * appears. The constants are therefore pinned by what the wallet SENDS: the exact calldata of each
     * call, built here from the hand-typed signature hashes, must reach the token, and the literals
     * the PRD names must equal those hashes.
     */
    function test_A19_SelectorConstantsMirror() public {
        assertEq(bytes4(0x095ea7b3), APPROVE_SELECTOR, "approve(address,uint256)");
        assertEq(bytes4(0xdd62ed3e), ALLOWANCE_SELECTOR, "allowance(address,address)");

        gateway.setPullShort(true); // leaves 1 unit, so the clearing approve runs too
        vm.expectCall(address(token), abi.encodeWithSelector(APPROVE_SELECTOR, GATEWAY, FIFTY), 1);
        vm.expectCall(address(token), abi.encodeWithSelector(ALLOWANCE_SELECTOR, address(wallet), GATEWAY));
        vm.expectCall(address(token), abi.encodeWithSelector(APPROVE_SELECTOR, GATEWAY, 0), 1);
        _agentOutbound(FIFTY);
    }

    /**
     * The wallet reads `token` and `amount` from the request head and never the payload, so the amount
     * handling is identical whichever gateway path the payload selects (the PC20-export path pulls the
     * same `req.amount`, deployed line 191).
     *
     * DEVIATION, stated: the gateway's PC20-export payload selector is not mirrored in `Types.sol` and
     * is not readable from this repo, and CLAUDE.md forbids inventing magic values. The payload here
     * therefore starts with `PC20_STAND_IN_PREFIX`, an arbitrary non-multicall literal standing in for it.
     * It is NOT the gateway's constant; the property under test does not depend on its value.
     */
    function test_A20_Pc20ShapedPayloadSameAmount() public {
        assertTrue(PC20_STAND_IN_PREFIX != MULTICALL_SELECTOR, "not the multicall branch");

        bytes memory req = abi.encodeWithSelector(
            SEND_OUTBOUND_SELECTOR,
            UniversalOutboundTxRequest({
                recipient: abi.encodePacked(cea),
                token: address(token),
                amount: FIFTY,
                gasLimit: 0,
                gasPrice: 0,
                maxPCForGas: 0.01 ether,
                payload: abi.encodePacked(PC20_STAND_IN_PREFIX, abi.encode(cea, FIFTY)),
                revertRecipient: address(wallet)
            })
        );
        _ownerExecute(GATEWAY, req);

        assertEq(gateway.allowanceAtEntry(), FIFTY, "approved exactly the amount");
        assertEq(token.balanceOf(GATEWAY), FIFTY, "pulled the amount");
        assertEq(_allowance(), 0, "cleared after");
    }

    // ═══════════════════════════════════ fuzz ═══════════════════════════════════

    function testFuzz_F01_ExactApproveAndClear(uint96 amount) public {
        uint256 a = bound(uint256(amount), 1, CAP);

        _agentOutbound(a);

        assertEq(gateway.allowanceAtEntry(), a, "the gateway saw exactly the amount");
        assertEq(token.balanceOf(GATEWAY), a, "pulled exactly the amount");
        assertEq(_allowance(), 0, "allowance 0 after");
    }

    function testFuzz_F02_ParserNeverReverts(bytes calldata junk) public {
        etchCallRecorder(GATEWAY);

        _ownerExecute(GATEWAY, bytes.concat(SEND_OUTBOUND_SELECTOR, junk));

        assertEq(callsRecorded(GATEWAY), 1, "forwarded, never reverted in the wallet");
    }

    // ═══════════════════════════════════ gas ═══════════════════════════════════

    /**
     * The overhead of auto-approve on one agent outbound of 50 against the pulling gateway.
     *
     * The pre-feature flow (a standing allowance the gateway pulls from, left non-zero) cannot run on
     * the changed wallet, which always approves. It is reproduced by neutralising the wallet's own two
     * token calls with `vm.mockCall` (the approve returns true and changes nothing) over a standing max
     * allowance. The allowance query is mocked to return 1, not 0: the gateway mock reads the same
     * call and records it in a fresh array slot, and a zero there would make the BASELINE's gateway
     * ~20k cheaper for a reason that has nothing to do with the wallet. A 1 makes the wallet send one
     * more (mocked, no-op) approve. The baseline therefore still pays three mocked calls' bare
     * CALL/STATICCALL cost, so the overhead reported is a slight UNDER-estimate.
     */
    function test_G01_AutoApproveGasOverhead() public {
        bool isolated = isolatedCalls();
        bytes memory ecd = _agentEcd(FIFTY);

        _agentOutboundEcd(ecd); // warm the wallet, engine, URP and token rows
        uint256 withFeature = _measureAgent(ecd);

        _ownerApprove(type(uint256).max);
        vm.mockCall(address(token), abi.encodePacked(APPROVE_SELECTOR), abi.encode(true));
        vm.mockCall(address(token), abi.encodePacked(ALLOWANCE_SELECTOR), abi.encode(uint256(1)));
        _agentOutboundEcd(ecd);
        uint256 baseline = _measureAgent(ecd);
        vm.clearMockedCalls();

        uint256 overhead = withFeature - baseline;
        emit log_named_uint("agent outbound gas, with auto-approve", withFeature);
        emit log_named_uint("agent outbound gas, standing allowance (pre-feature)", baseline);
        emit log_named_uint("auto-approve overhead", overhead);

        uint256 budget = isolated ? AUTO_APPROVE_OVERHEAD_BUDGET_ISOLATED : AUTO_APPROVE_OVERHEAD_BUDGET;
        assertLe(overhead, budget, "auto-approve overhead within its measured budget");
    }

    function _agentOutboundEcd(bytes memory ecd) internal {
        vm.prank(agentAddr);
        wallet.executeAsAgent(permissionId, _single(), ecd);
    }

    function _measureAgent(bytes memory ecd) internal returns (uint256 used) {
        vm.prank(agentAddr);
        uint256 before = gasleft();
        wallet.executeAsAgent(permissionId, _single(), ecd);
        used = before - gasleft();
    }
}
