// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";
import { Session, ConfigId } from "smartsessions/DataTypes.sol";

import { IAGW } from "../../src/interfaces/IAGW.sol";
import { IUniversalRulesPolicy } from "../../src/interfaces/IUniversalRulesPolicy.sol";
import { ModeSlot, NativeConfig } from "../../src/libraries/Types.sol";

import { DemoLog } from "./DemoLog.sol";
import { NativeIds } from "./NativeIds.sol";
import { RulesRead } from "./RulesRead.sol";

/**
 * @title  Grant
 * @notice One owner grant, with everything a script must read back and assert afterwards.
 *
 * @dev    DECLARED ONCE BECAUSE FOUR SCRIPTS GRANT RULES — stake (1d), unstake (4a'), and Act 4f's
 *         unpinned and pinned `approve`. Each must do the same six things, and a script that
 *         skipped one would print a rules box nobody had checked:
 *
 *           1. predict the rules id from the wallet's grant counter;
 *           2. broadcast `grantRules` from the owner;
 *           3. read the id, the derived kind and the chain string from `RulesGranted`;
 *           4. assert the id equals the prediction and `agentOf(id)` is the agent;
 *           5. assert the checkpoint counter moved by exactly one (a grant is an owner action);
 *           6. read the stored rulebook and the derived kind back from URP.
 */
library Grant {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Result {
        RulesRead.Granted granted;
        ModeSlot slot;
        NativeConfig cfg;
        uint64 checkpointsBefore;
        uint64 checkpointsAfter;
    }

    error PredictedIdMismatch(bytes32 predicted, bytes32 granted);
    error AgentNotRecorded(address expected, address recorded);
    error CheckpointDidNotMove(uint64 before, uint64 afterCount);
    error ConfigNotInitialised();

    /**
     * @param ownerPk  The wallet owner's key. Never logged.
     * @param wallet   The wallet the rules are granted on.
     * @param session  The canonical one-action session, from `NativeRules`.
     * @param agent    The Push address the rules must name.
     * @param target   The action's target, for the config id.
     * @param selector The action's selector, for the config id.
     */
    function asOwner(
        uint256 ownerPk,
        address wallet,
        Session memory session,
        address agent,
        address target,
        bytes4 selector
    ) internal returns (Result memory r) {
        // `rulesId = keccak256(abi.encode(validator, validatorConfig, bytes32(grantNonce)))`,
        // computed by the engine. Predicted only to be asserted against the event.
        bytes32 predicted = keccak256(
            abi.encode(IAGW(wallet).SESSION_VALIDATOR(), abi.encode(agent), bytes32(uint256(IAGW(wallet).grantNonce())))
        );
        r.checkpointsBefore = IAGW(wallet).checkpointCount();

        vm.recordLogs();
        vm.startBroadcast(ownerPk);
        IAGW(wallet).grantRules(session);
        vm.stopBroadcast();

        r.granted = RulesRead.granted(vm.getRecordedLogs());
        if (r.granted.rulesId != predicted) revert PredictedIdMismatch(predicted, r.granted.rulesId);

        address recorded = IAGW(wallet).agentOf(r.granted.rulesId);
        if (recorded != agent) revert AgentNotRecorded(agent, recorded);

        r.checkpointsAfter = IAGW(wallet).checkpointCount();
        if (r.checkpointsAfter != r.checkpointsBefore + 1) {
            revert CheckpointDidNotMove(r.checkpointsBefore, r.checkpointsAfter);
        }

        ConfigId id = NativeIds.configId(r.granted.rulesId, wallet, target, selector);
        IUniversalRulesPolicy urp = IUniversalRulesPolicy(IAGW(wallet).RULES_POLICY());
        r.slot = urp.getMode(id, wallet);
        r.cfg = urp.getNativeConfig(id, wallet);
        if (!r.cfg.initialized) revert ConfigNotInitialised();
    }

    /// @notice The lines every grant prints under its rules box: kind, agent, id, checkpoints.
    function printRecord(Result memory r, address wallet) internal view {
        RulesRead.printDerivation(r.granted, r.slot);
        DemoLog.addrPlain("Agent", IAGW(wallet).agentOf(r.granted.rulesId));
        DemoLog.note("    A Push address: it sends its own transactions.");
        DemoLog.kv("Rules id", vm.toString(r.granted.rulesId));
        DemoLog.kv(
            "Checkpoints",
            string.concat(vm.toString(uint256(r.checkpointsBefore)), " -> ", vm.toString(uint256(r.checkpointsAfter)))
        );
        DemoLog.note("    A grant is an owner action, so the counter moved by one.");
    }
}
