// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";

import { IAGW } from "../../../src/interfaces/IAGW.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";

/**
 * @title  RevokeAll
 * @notice ACT 4d · The emergency lever. Every rules set dies, immediately.
 *
 * @dev    ONE CALL, NO ARGUMENTS, NO CONDITIONS. `revokeAllRules` carries no guard, no health probe and no
 *         extra external call, and that is a deliberate architectural rule rather than an
 *         oversight: BLOCKABLE REVOCATION IS THE ONE REGRESSION THIS FUNCTION CAN DEVELOP. Anything
 *         that can fail on the revoke path is a way for an attacker to keep a rules set alive.
 *
 *         REVOCATION IS IMMEDIATE, NOT SCHEDULED. There is no timelock, no cooldown, no pending
 *         state. The next block cannot carry an agent request under these permissions — and Act 4e
 *         proves it with a request that would have been accepted moments before.
 *
 *         Both rules are read back from the ENGINE afterwards, not assumed dead because the call
 *         returned. `agentOf` goes to the zero address for each: revoked rules name nobody, so
 *         the wallet refuses every caller. And the checkpoint counter moves once per revoked id.
 */
/// @dev The engine's own answer to "is this rules set live?".
interface IEngineState {
    function isPermissionEnabled(bytes32 rulesId, address account) external view returns (bool);
}

contract RevokeAll is Script {
    function run() external {
        uint256 bobPk = Keys.load("BOB_KEY", "only the owner may revoke");
        address agw = Ledger.addr("agw", "10_DeployWallet");
        IEngineState engine = IEngineState(IAGW(agw).SESSION_ENGINE());

        bytes32 stakeId = Ledger.word("rulesId", "13_GrantRules");
        bytes32 unstakeId = Ledger.has("unstakeRulesId") ? Ledger.word("unstakeRulesId", "40_GrantUnstake") : bytes32(0);

        bool stakeBefore = engine.isPermissionEnabled(stakeId, agw);
        bool unstakeBefore = unstakeId != bytes32(0) && engine.isPermissionEnabled(unstakeId, agw);
        address stakeAgentBefore = IAGW(agw).agentOf(stakeId);
        address unstakeAgentBefore = unstakeId == bytes32(0) ? address(0) : IAGW(agw).agentOf(unstakeId);
        uint64 checkpointsBefore = IAGW(agw).checkpointCount();
        uint64 revoked = (stakeBefore ? 1 : 0) + (unstakeBefore ? 1 : 0);

        vm.startBroadcast(bobPk);
        IAGW(agw).revokeAllRules();
        vm.stopBroadcast();

        // READ BACK FROM THE ENGINE AND THE WALLET. A returning call is not proof of revocation.
        bool stakeAfter = engine.isPermissionEnabled(stakeId, agw);
        bool unstakeAfter = unstakeId != bytes32(0) && engine.isPermissionEnabled(unstakeId, agw);
        uint64 checkpointsAfter = IAGW(agw).checkpointCount();

        DemoLog.header("ACT 4d", "Stop everything");
        DemoLog.kv("Stake rules", string.concat(_state(stakeBefore), " -> ", _state(stakeAfter)));
        DemoLog.kv(
            "  agent", string.concat(vm.toString(stakeAgentBefore), " -> ", vm.toString(IAGW(agw).agentOf(stakeId)))
        );
        if (unstakeId != bytes32(0)) {
            DemoLog.kv("Unstake rules", string.concat(_state(unstakeBefore), " -> ", _state(unstakeAfter)));
            DemoLog.kv(
                "  agent",
                string.concat(vm.toString(unstakeAgentBefore), " -> ", vm.toString(IAGW(agw).agentOf(unstakeId)))
            );
        }
        DemoLog.kv(
            "Checkpoints",
            string.concat(vm.toString(uint256(checkpointsBefore)), " -> ", vm.toString(uint256(checkpointsAfter)))
        );
        DemoLog.note("    One per revoked rules set.");
        DemoLog.blank();
        DemoLog.ok("revoked", "immediately - no timelock, no cooldown, no pending state");
        DemoLog.note("    revokeAllRules carries no guard and no probe, deliberately: anything that");
        DemoLog.note("    can fail on the revoke path is a way to keep rules alive.");
        DemoLog.footer();

        require(!stakeAfter, "the stake rules survived revokeAllRules");
        require(!unstakeAfter, "the unstake rules survived revokeAllRules");
        require(IAGW(agw).agentOf(stakeId) == address(0), "revoked rules must have no agent");
        require(checkpointsAfter == checkpointsBefore + revoked, "one checkpoint per revoked rules set");
    }

    function _state(bool enabled) private pure returns (string memory) {
        return enabled ? "live" : "dead";
    }
}
