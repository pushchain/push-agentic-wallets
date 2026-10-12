// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";
import { DemoLog } from "./DemoLog.sol";
import { AgentRequest } from "./AgentRequest.sol";
import { RulesRead } from "./RulesRead.sol";
import { IActionPolicy } from "smartsessions/interfaces/IPolicy.sol";
import { IAGW } from "../../src/interfaces/IAGW.sol";
import { AGWErrors, UniversalRulesPolicyErrors } from "../../src/libraries/Errors.sol";

/**
 * @title  Gauntlet
 * @notice The refusal assertions every Act 3 script uses.
 *
 * @dev    ── EVERY SIMULATED CALL COMES FROM THE AGENT'S ADDRESS ──
 *
 *         The agent door's first check is `msg.sender == agentOf(rulesId)`. A simulation sent from
 *         the script contract dies there, as `CallerIsNotAgent`, whatever the request says — and
 *         hides the gate the script means to show. So every policy refusal below is pranked as
 *         the agent the rules name, read from the wallet.
 *
 *         ── THE ORDER OF REFUSAL ON THE AGENT DOOR ──
 *
 *           1. the wallet's sender check   `CallerIsNotAgent(rulesId, caller)`   unwrapped
 *           2. the engine                  `NoPoliciesSet`, `InvalidPermissionId`   unwrapped
 *           3. URP                         wrapped as `PolicyCheckReverted(bytes32)`
 *           4. the validator               cannot fail when the sender is the agent
 *           5. the dispatch guard          `ForbiddenDispatchTarget`
 *
 *         ── WHY ONE LAYER IS NOT ENOUGH FOR A POLICY REFUSAL ──
 *
 *         The engine truncates a policy's revert data to 32 bytes (`PolicyLib.sol`, `_maxCopy: 32`)
 *         and rewraps it as `PolicyCheckReverted(bytes32)`. Those 32 bytes are URP's 4-byte
 *         selector followed by the first 28 bytes of its first argument — and that prefix is
 *         worthless: for a `uint256` like `60e6` it is the all-zero high bytes; for an `address` it
 *         is 12 bytes of zero padding plus 16 of the 20 address bytes.
 *
 *         So through the agent door ONLY THE SELECTOR SURVIVES.
 *
 *         LAYER 1, THE HONEST PATH: submit exactly as the agent would. Assert the outer error is
 *         `PolicyCheckReverted` AND that the top 4 bytes of the embedded word are the expected URP
 *         selector. This is what production actually looks like.
 *
 *         LAYER 2, THE ARGUMENT PROOF: call `URP.checkAction` directly, pranked as the engine,
 *         against live forked state. The error arrives unwrapped, with every argument intact.
 *
 *         THE ENGINE PRANK IS MANDATORY, NOT STYLISTIC. `checkAction` reads its config under
 *         `msg.sender`, so an unpranked call reads an empty slot and dies at gate 1 with
 *         `NotInitialized` — the wrong error, and a test that looks like it passed for the wrong
 *         reason.
 *
 *         AND THE NARRATION COMES FROM LAYER 2. The amber line the audience reads carries values
 *         that were actually asserted, never a string typed into a `console.log`.
 */
library Gauntlet {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev `PolicyCheckReverted(bytes32)`, the engine's wrapper. Derived, never pasted.
    bytes4 internal constant POLICY_CHECK_REVERTED = bytes4(keccak256("PolicyCheckReverted(bytes32)"));

    error ExpectedRefusalButSucceeded(string what);
    error WrongRefusal(bytes4 expected, bytes4 actual);
    error NotWrappedByEngine(bytes4 outer);
    error RulesHaveNoAgent(bytes32 rulesId);
    error WrongRefusalArguments(bytes32 rulesId, address caller);

    /**
     * @notice Run one policy refusal: submit as the agent, assert the gate, and narrate it.
     *
     * @param title     What the agent attempted, in plain language.
     * @param expected  The URP error selector this attempt must produce.
     * @param gate      Which gate that is, e.g. "URP gate 15".
     * @param lesson    One sentence on what would have happened without the gate.
     * @param req       The mutated request.
     */
    function refuse(
        string memory title,
        bytes4 expected,
        string memory gate,
        string memory lesson,
        AgentRequest.Built memory req
    ) internal {
        address agent = IAGW(req.wallet).agentOf(req.rulesId);
        if (agent == address(0)) revert RulesHaveNoAgent(req.rulesId);

        DemoLog.kv("Attempt", title);
        DemoLog.addrPlain("Sent by", agent);
        DemoLog.note("    The agent the rules name. The wallet's sender check passes.");
        DemoLog.blank();

        _layer1(agent, expected, req);
        _layer2(req);

        DemoLog.refused(_errorName(expected), string.concat("refused by ", gate));
        DemoLog.blank();
        DemoLog.note(lesson);
        DemoLog.note("Nothing reached Sepolia. The refusal is on-chain, atomic and free.");
    }

    /**
     * @notice Run one WALLET refusal: submit as `caller`, and assert `CallerIsNotAgent(rulesId, caller)`
     *         arrives unwrapped — before the engine and before any policy.
     *
     * @param title   What was attempted, in plain language.
     * @param caller  The address the simulated call is sent from.
     * @param req     The request, which may be flawless: the sender is what is refused.
     */
    function refuseAtWallet(string memory title, address caller, AgentRequest.Built memory req) internal {
        DemoLog.kv("Attempt", title);
        DemoLog.addrPlain("Sent by", caller);
        DemoLog.blank();

        vm.prank(caller);
        (bool ok, bytes memory ret) = req.wallet.call(AgentRequest.encodeSubmit(req));

        if (ok) revert ExpectedRefusalButSucceeded("CallerIsNotAgent");
        if (ret.length < 4) revert NotWrappedByEngine(bytes4(0));

        bytes4 outer = bytes4(ret);
        if (outer != AGWErrors.CallerIsNotAgent.selector) {
            revert WrongRefusal(AGWErrors.CallerIsNotAgent.selector, outer);
        }

        (bytes32 rulesId, address refusedCaller) = abi.decode(_slice(ret, 4), (bytes32, address));
        if (rulesId != req.rulesId || refusedCaller != caller) revert WrongRefusalArguments(rulesId, refusedCaller);

        DemoLog.ok("wallet", "refused it before the engine and before any policy ran");
        DemoLog.refused("CallerIsNotAgent", "refused by the wallet's sender check");
        DemoLog.kv("  observed", string.concat(vm.toString(abi.encodePacked(outer)), "  (unwrapped)"));
        DemoLog.kv("  rules id", vm.toString(rulesId));
        DemoLog.kv("  caller", vm.toString(refusedCaller));
        DemoLog.kv("  rules' agent", vm.toString(IAGW(req.wallet).agentOf(req.rulesId)));
    }

    // ─────────────────────────────────── layer 1 ───────────────────────────────────

    /**
     * @dev Submit through the agent door, as the agent, and assert the wrapped selector.
     *
     *      A LOW-LEVEL CALL, NOT `vm.expectRevert`. Outside a test context `expectRevert` is
     *      unreliable around a real RPC call, and this form additionally hands back the raw bytes
     *      so the selector can be read rather than merely matched.
     */
    function _layer1(address agent, bytes4 expected, AgentRequest.Built memory req) private {
        vm.prank(agent);
        (bool ok, bytes memory ret) = req.wallet.call(AgentRequest.encodeSubmit(req));

        if (ok) revert ExpectedRefusalButSucceeded(_errorName(expected));
        if (ret.length < 4) revert NotWrappedByEngine(bytes4(0));

        bytes4 outer = bytes4(ret);
        if (outer != POLICY_CHECK_REVERTED) revert NotWrappedByEngine(outer);

        bytes32 embedded = abi.decode(_slice(ret, 4), (bytes32));
        bytes4 innerSelector = bytes4(embedded);
        if (innerSelector != expected) revert WrongRefusal(expected, innerSelector);

        DemoLog.ok("layer 1", "engine wrapped the policy's refusal, selector intact");
        DemoLog.kv(
            "  observed", string.concat("PolicyCheckReverted(", vm.toString(abi.encodePacked(innerSelector)), "...)")
        );
    }

    // ─────────────────────────────────── layer 2 ───────────────────────────────────

    /**
     * @dev The same request, straight to `URP.checkAction`, pranked as the engine, on a Donut fork.
     *      The error arrives whole. Nothing is broadcast: this runs against forked state.
     */
    function _layer2(AgentRequest.Built memory req) private {
        vm.createSelectFork(vm.envString("PUSH_DONUT_RPC_URL"));

        (address target, uint256 value, bytes memory data) = _decodeSingle(req.executionCalldata);

        vm.prank(IAGW(req.wallet).SESSION_ENGINE()); // MANDATORY — see the contract docs.
        (bool ok, bytes memory ret) = IAGW(req.wallet).RULES_POLICY()
            .call(
                abi.encodeCall(
                    IActionPolicy.checkAction,
                    (RulesRead.universalConfigId(req.wallet, req.rulesId), req.wallet, target, value, data)
                )
            );

        if (ok) {
            DemoLog.note("    layer 2: checkAction accepted it - the refusal came from elsewhere");
            return;
        }
        DemoLog.ok("layer 2", "URP refused it directly, with arguments intact");
        _printArguments(ret);
    }

    /// @dev Decode the full, untruncated error and print its arguments. This is where the amber
    ///      line's numbers come from.
    function _printArguments(bytes memory ret) private view {
        if (ret.length < 4) return;
        bytes4 sel = bytes4(ret);
        bytes memory body = _slice(ret, 4);

        if (sel == UniversalRulesPolicyErrors.CallNotAllowed.selector && body.length >= 64) {
            (address t, bytes4 s) = abi.decode(body, (address, bytes4));
            DemoLog.kv("  target", vm.toString(t));
            DemoLog.kv("  selector", vm.toString(abi.encodePacked(s)));
        } else if (sel == UniversalRulesPolicyErrors.ForbiddenInnerTarget.selector && body.length >= 32) {
            DemoLog.kv("  forbidden", vm.toString(abi.decode(body, (address))));
        } else if (sel == UniversalRulesPolicyErrors.BeneficiaryMismatch.selector && body.length >= 64) {
            (address want, address got) = abi.decode(body, (address, address));
            DemoLog.kv("  expected", vm.toString(want));
            DemoLog.kv("  got", vm.toString(got));
        } else if (sel == UniversalRulesPolicyErrors.AmountExceedsCap.selector && body.length >= 64) {
            (uint256 amt, uint256 cap) = abi.decode(body, (uint256, uint256));
            DemoLog.kv("  requested", DemoLog.formatAmount(amt, 6, "USDC"));
            DemoLog.kv("  cap", DemoLog.formatAmount(cap, 6, "USDC"));
        } else if (sel == UniversalRulesPolicyErrors.TotalSpendCapExceeded.selector && body.length >= 64) {
            (uint256 total, uint256 cap) = abi.decode(body, (uint256, uint256));
            DemoLog.kv("  would total", DemoLog.formatAmount(total, 6, "USDC"));
            DemoLog.kv("  lifetime cap", DemoLog.formatAmount(cap, 6, "USDC"));
        } else if (sel == UniversalRulesPolicyErrors.AssetNotAllowed.selector && body.length >= 32) {
            DemoLog.kv("  token", vm.toString(abi.decode(body, (address))));
        }
    }

    // ─────────────────────────────────── helpers ───────────────────────────────────

    /// @dev `ExecutionLib.encodeSingle` is `abi.encodePacked(target, value, callData)` — 20 bytes,
    ///      then 32, then the remainder. Unpacked here so layer 2 can hand URP the same arguments
    ///      the wallet would have.
    function _decodeSingle(bytes memory ecd) private pure returns (address target, uint256 value, bytes memory data) {
        assembly {
            target := shr(96, mload(add(ecd, 0x20)))
            value := mload(add(ecd, 0x34))
        }
        data = _slice(ecd, 52);
    }

    function _slice(bytes memory b, uint256 from) private pure returns (bytes memory out) {
        if (b.length <= from) return "";
        out = new bytes(b.length - from);
        for (uint256 i; i < out.length; ++i) {
            out[i] = b[from + i];
        }
    }

    function _errorName(bytes4 sel) private pure returns (string memory) {
        if (sel == UniversalRulesPolicyErrors.CallNotAllowed.selector) return "CallNotAllowed";
        if (sel == UniversalRulesPolicyErrors.ForbiddenInnerTarget.selector) return "ForbiddenInnerTarget";
        if (sel == UniversalRulesPolicyErrors.BeneficiaryMismatch.selector) return "BeneficiaryMismatch";
        if (sel == UniversalRulesPolicyErrors.AmountExceedsCap.selector) return "AmountExceedsCap";
        if (sel == UniversalRulesPolicyErrors.TotalSpendCapExceeded.selector) return "TotalSpendCapExceeded";
        if (sel == UniversalRulesPolicyErrors.AssetNotAllowed.selector) return "AssetNotAllowed";
        if (sel == AGWErrors.CallerIsNotAgent.selector) return "CallerIsNotAgent";
        return "refused";
    }
}
