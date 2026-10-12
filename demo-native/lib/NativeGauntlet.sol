// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";

import { IAGW } from "../../src/interfaces/IAGW.sol";
import { AGWErrors, UniversalRulesPolicyErrors } from "../../src/libraries/Errors.sol";

import { DemoLog } from "./DemoLog.sol";
import { NativeRequest } from "./NativeRequest.sol";

/**
 * @title  NativeGauntlet
 * @notice Submits a deliberately-broken request AS THE AGENT, asserts the NAMED refusal, and
 *         narrates it.
 *
 * @dev    EVERY SIMULATED CALL IS PRANKED. The agent door's first check is
 *         `msg.sender == agentOf(rulesId)`. A simulation sent from the script contract dies there,
 *         as `CallerIsNotAgent`, whatever the request says — and hides the refusal the script
 *         means to show. So `refuseGate` and `refuseRaw` send as the agent the rules name, read
 *         from the wallet, and `refuseAtWallet` sends as whoever the script says.
 *
 *         THE ORDER OF REFUSAL ON THE AGENT DOOR, which is the whole point of this file:
 *
 *           1. the wallet's sender check   `CallerIsNotAgent(rulesId, caller)`   unwrapped
 *           2. the engine                  `NoPoliciesSet`, `InvalidPermissionId`   unwrapped
 *           3. URP                         wrapped as `PolicyCheckReverted(bytes32)`
 *
 *         A native rules set binds `(target, selector)` into the engine's ACTION ID. So a request
 *         naming a different target or a different function does not reach URP at all — the engine
 *         finds no matching action and refuses first. Only requests that DO match an action reach
 *         the policy, and only those come back wrapped.
 *
 *           · `refuseAtWallet(caller)`    — the wallet (G6, 4e). Bare, with both arguments.
 *           · `refuseRaw(selector)`       — the engine (G1, G2, 4b). Bare.
 *           · `refuseGate(innerSelector)` — URP gates (G3, G4, G5, G7, G8, 4f). The engine
 *             truncates policy revert data to 32 bytes and rewraps it as
 *             `PolicyCheckReverted(bytes32)`, so this path asserts the outer selector is the
 *             wrapper and then compares the INNER one.
 *
 * @dev    A LOW-LEVEL CALL, NOT `vm.expectRevert`. `expectRevert` is a test cheatcode; it does not
 *         belong in a script, and this form additionally hands back the raw bytes so the selector
 *         can be READ rather than merely matched — which is what lets the amber line on screen
 *         carry values that were actually asserted.
 */
library NativeGauntlet {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev `PolicyCheckReverted(bytes32)`, the engine's wrapper. DERIVED, never pasted.
    bytes4 internal constant POLICY_CHECK_REVERTED = bytes4(keccak256("PolicyCheckReverted(bytes32)"));

    error ExpectedRefusalButSucceeded(string what);
    error WrongRefusal(bytes4 expected, bytes4 actual);
    error NotWrappedByEngine(bytes4 outer);
    error UnexpectedRawRefusal(bytes4 expected, bytes4 actual);
    error NoRevertData();
    error RulesHaveNoAgent(bytes32 rulesId);
    error WrongRefusalArguments(bytes32 rulesId, address caller);

    /**
     * @notice A refusal that comes from URP, wrapped by the engine.
     *
     * @param title    What the agent attempted, in plain language.
     * @param expected The URP error selector this attempt must produce.
     * @param gate     Which gate that is, e.g. "URP gate N7 (the argument pin)".
     * @param lesson   One sentence on what would have happened without the gate.
     * @param req      The mutated request.
     */
    function refuseGate(
        string memory title,
        bytes4 expected,
        string memory gate,
        string memory lesson,
        NativeRequest.Built memory req
    ) internal {
        DemoLog.kv("Attempt", title);
        DemoLog.blank();

        bytes memory ret = _submitExpectingFailure(expected, req);

        bytes4 outer = bytes4(ret);
        if (outer != POLICY_CHECK_REVERTED) revert NotWrappedByEngine(outer);

        bytes32 embedded = abi.decode(_slice(ret, 4), (bytes32));
        bytes4 inner = bytes4(embedded);
        if (inner != expected) revert WrongRefusal(expected, inner);

        DemoLog.ok("engine", "wrapped URP's refusal, selector intact");
        DemoLog.kv("  observed", string.concat("PolicyCheckReverted(", vm.toString(abi.encodePacked(inner)), "...)"));
        DemoLog.refused(_urpErrorName(expected), string.concat("refused by ", gate, ", before anything moved"));
        _printTruncatedArgument(expected, embedded);

        DemoLog.blank();
        DemoLog.note(lesson);
        DemoLog.note("Nothing moved. The refusal is on-chain, atomic and costs only gas.");
    }

    /**
     * @notice A refusal that comes from the ENGINE, unwrapped.
     *
     * @dev    `expected` here is one of the engine's own error selectors — `NoPoliciesSet(bytes32)`
     *         or `InvalidPermissionId(bytes32)`, derived from their signatures — not a URP gate.
     */
    function refuseRaw(
        string memory title,
        bytes4 expected,
        string memory who,
        string memory lesson,
        NativeRequest.Built memory req
    ) internal {
        DemoLog.kv("Attempt", title);
        DemoLog.blank();

        bytes memory ret = _submitExpectingFailure(expected, req);

        bytes4 outer = bytes4(ret);
        if (outer == POLICY_CHECK_REVERTED) {
            // It reached the policy. For G1/G2 that would mean the action id MATCHED, which is the
            // opposite of what the act claims — so this is a real failure, not a near miss.
            revert UnexpectedRawRefusal(expected, outer);
        }
        if (outer != expected) revert UnexpectedRawRefusal(expected, outer);

        DemoLog.ok(who, "refused it before any policy ran");
        DemoLog.kv("  observed", string.concat(vm.toString(abi.encodePacked(outer)), "  (unwrapped)"));
        DemoLog.refused(_rawErrorName(expected), string.concat("URP never executed - ", who, " stopped it first"));

        DemoLog.blank();
        DemoLog.note(lesson);
        DemoLog.note("Nothing moved. The refusal is on-chain, atomic and costs only gas.");
    }

    // ──────────────────────────────── internals ────────────────────────────────

    /// @dev Submit and require failure. Returns the raw revert data for the caller to decode.
    /**
     * @notice A refusal by the WALLET's sender check: `CallerIsNotAgent(rulesId, caller)`, bare,
     *         before the engine and before any policy.
     *
     * @param title  What was attempted, in plain language.
     * @param caller The address the simulated call is sent from.
     * @param lesson One sentence on what this protects.
     * @param req    The request, which may be flawless: the sender is what is refused.
     */
    function refuseAtWallet(string memory title, address caller, string memory lesson, NativeRequest.Built memory req)
        internal
    {
        DemoLog.kv("Attempt", title);
        DemoLog.addrPlain("Sent by", caller);
        DemoLog.blank();

        vm.prank(caller);
        (bool ok, bytes memory ret) = req.wallet.call(NativeRequest.encodeSubmit(req));
        if (ok) revert ExpectedRefusalButSucceeded("CallerIsNotAgent");
        if (ret.length < 4) revert NoRevertData();

        bytes4 outer = bytes4(ret);
        if (outer != AGWErrors.CallerIsNotAgent.selector) {
            revert UnexpectedRawRefusal(AGWErrors.CallerIsNotAgent.selector, outer);
        }
        (bytes32 rulesId, address refused) = abi.decode(_slice(ret, 4), (bytes32, address));
        if (rulesId != req.rulesId || refused != caller) revert WrongRefusalArguments(rulesId, refused);

        DemoLog.ok("the wallet", "refused it before the engine and before any policy ran");
        DemoLog.refused("CallerIsNotAgent", "the wallet's sender check - URP never executed");
        DemoLog.kv("  observed", string.concat(vm.toString(abi.encodePacked(outer)), "  (unwrapped)"));
        DemoLog.kv("  rules id", vm.toString(rulesId));
        DemoLog.kv("  caller", vm.toString(refused));
        DemoLog.kv("  rules' agent", vm.toString(IAGW(req.wallet).agentOf(req.rulesId)));
        DemoLog.blank();
        DemoLog.note(lesson);
        DemoLog.note("Nothing moved. The refusal is on-chain, atomic and costs only gas.");
    }

    /// @dev Send as the agent the rules name, so the wallet's sender check passes and the request
    ///      reaches the engine and the policy.
    function _submitExpectingFailure(bytes4 expected, NativeRequest.Built memory req) private returns (bytes memory) {
        address agent = IAGW(req.wallet).agentOf(req.rulesId);
        if (agent == address(0)) revert RulesHaveNoAgent(req.rulesId);

        vm.prank(agent);
        (bool ok, bytes memory ret) = req.wallet.call(NativeRequest.encodeSubmit(req));
        if (ok) revert ExpectedRefusalButSucceeded(_anyErrorName(expected));
        if (ret.length < 4) revert NoRevertData();
        return ret;
    }

    function _printTruncatedArgument(bytes4 expected, bytes32 embedded) private view {
        if (expected == UniversalRulesPolicyErrors.ArgPinMismatch.selector) {
            // Strip URP's selector; what remains is the first 28 bytes of the offending word.
            DemoLog.kv("  received word (partial)", vm.toString(bytes32(uint256(embedded) << 32)));
            DemoLog.note("      truncated by the engine to 32 bytes - the selector survives whole,");
            DemoLog.note("      the argument does not. The full value is in the script's own output.");
        } else {
            DemoLog.note("      the engine truncates policy reverts to 32 bytes: the GATE is named");
            DemoLog.note("      exactly, the argument is not recoverable. Requested values above.");
        }
    }

    /// @dev Names for the URP gates this demo exercises.
    function _urpErrorName(bytes4 s) private pure returns (string memory) {
        if (s == UniversalRulesPolicyErrors.ArgPinMismatch.selector) return "ArgPinMismatch";
        if (s == UniversalRulesPolicyErrors.NativeAmountExceedsCap.selector) return "NativeAmountExceedsCap";
        if (s == UniversalRulesPolicyErrors.TotalNativeAmountExceeded.selector) return "TotalNativeAmountExceeded";
        if (s == UniversalRulesPolicyErrors.ValueExceedsCap.selector) return "ValueExceedsCap";
        if (s == UniversalRulesPolicyErrors.CallLimitReached.selector) return "CallLimitReached";
        if (s == UniversalRulesPolicyErrors.RulesExpired.selector) return "RulesExpired";
        if (s == UniversalRulesPolicyErrors.TargetMismatch.selector) return "TargetMismatch";
        if (s == UniversalRulesPolicyErrors.SelectorMismatch.selector) return "SelectorMismatch";
        return "a URP gate";
    }

    /// @dev Names for engine and wallet errors. Selectors are DERIVED from their signatures so this
    ///      file does not have to import the engine's interface for a string.
    function _rawErrorName(bytes4 s) private pure returns (string memory) {
        if (s == bytes4(keccak256("NoPoliciesSet(bytes32)"))) return "NoPoliciesSet";
        if (s == bytes4(keccak256("InvalidPermissionId(bytes32)"))) return "InvalidPermissionId";
        return "a refusal";
    }

    function _anyErrorName(bytes4 s) private pure returns (string memory) {
        string memory urp = _urpErrorName(s);
        if (keccak256(bytes(urp)) != keccak256(bytes("a URP gate"))) return urp;
        return _rawErrorName(s);
    }

    /// @dev `bytes` slice from `start` to the end.
    function _slice(bytes memory data, uint256 start) private pure returns (bytes memory out) {
        out = new bytes(data.length - start);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[start + i];
        }
    }
}
