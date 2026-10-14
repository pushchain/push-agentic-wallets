// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { Requests } from "../../lib/Requests.sol";
import { Gauntlet } from "../../lib/Gauntlet.sol";
import { AgentRequest } from "../../lib/AgentRequest.sol";
import { IEngineState } from "../../lib/Inspect.sol";
import { BobPayload, IUEA, UniversalPayload } from "../../lib/BobPayload.sol";
import { IAGW } from "../../../src/interfaces/IAGW.sol";
import { Multicall } from "../../../src/libraries/Types.sol";
import { StakeDummy } from "../../contracts/StakeDummy.sol";

/**
 * @title  RevokeAll
 * @notice ACT 4e · Chain: Donut · broadcasts with the RELAYER key, on a payload BOB signed.
 *         The closing beat: Bob revokes, and the agent's own account can no longer act.
 *
 * @dev    `revokeAllRules()` removes every live rules set in one call. It has nothing on it that
 *         can fail: no guard, no probe, no external call that could be made to revert. An owner
 *         who could be blocked from revoking would have no real control, whatever the caps say.
 *
 *         WHAT REVOCATION CHANGES, READ FROM THE CHAIN:
 *
 *           · the engine no longer reports the rules as enabled;
 *           · `agentOf(rulesId)` returns the zero address — revoked rules have no agent;
 *           · the checkpoint counter moves by one per revoked rules set.
 *
 *         THEN THE AGENT TRIES AGAIN, in simulation, with the exact Act 2 request from its own
 *         address. Because the rules now name nobody, the wallet's sender check refuses it —
 *         `CallerIsNotAgent(rulesId, agent)` — before the engine and before any policy.
 *
 *         THE LEDGER KEEPS `rulesId` so `just state` can show the rules as revoked. `just reset`
 *         is what clears it for the next rehearsal.
 */
contract RevokeAll is Script {
    error NothingToRevoke(bytes32 rulesId);
    error StillLive(bytes32 rulesId);
    error AgentStillNamed(bytes32 rulesId, address agent);
    error CheckpointDidNotMove(uint64 before, uint64 afterCount);

    uint256 internal constant VALID_FOR = 1 hours;

    function run() external {
        uint256 bobPk = Keys.load("BOB_KEY", "only the owner may revoke");
        uint256 relayerPk = Keys.load("PC_RELAYER_KEY", "the relayer submits");
        address agent = Keys.addressOf("AGENT_KEY", "the agent whose authority ends here");

        address uea = Ledger.addr("uea", "10_Arrive");
        address agw = Ledger.addr("agw", "10_Arrive");
        bytes32 rulesId = Ledger.word("rulesId", "14_GrantRules");
        IEngineState engine = IEngineState(IAGW(agw).SESSION_ENGINE());

        if (!engine.isPermissionEnabled(rulesId, agw)) revert NothingToRevoke(rulesId);

        DemoLog.header("ACT 4", "Bob revokes");
        DemoLog.addrPlain("Bob signs", vm.addr(bobPk));
        DemoLog.addrPlain("Relayer submits", vm.addr(relayerPk));
        DemoLog.blank();

        address agentBefore = IAGW(agw).agentOf(rulesId);
        uint64 checkpointsBefore = IAGW(agw).checkpointCount();

        Multicall[] memory call = Requests.singleCall(agw, abi.encodeCall(IAGW.revokeAllRules, ()));
        (UniversalPayload memory payload, bytes memory signature) =
            BobPayload.signedMulticall(uea, call, bobPk, VALID_FOR);

        vm.startBroadcast(relayerPk);
        IUEA(uea).executeUniversalTx(payload, signature);
        vm.stopBroadcast();

        if (engine.isPermissionEnabled(rulesId, agw)) revert StillLive(rulesId);
        address agentAfter = IAGW(agw).agentOf(rulesId);
        if (agentAfter != address(0)) revert AgentStillNamed(rulesId, agentAfter);
        uint64 checkpointsAfter = IAGW(agw).checkpointCount();
        if (checkpointsAfter != checkpointsBefore + 1) {
            revert CheckpointDidNotMove(checkpointsBefore, checkpointsAfter);
        }

        DemoLog.kv("Rules", string.concat(DemoLog.green("live"), " -> ", DemoLog.red("revoked")));
        DemoLog.kv("Agent of rules", string.concat(vm.toString(agentBefore), " -> ", vm.toString(agentAfter)));
        DemoLog.kv(
            "Checkpoints",
            string.concat(vm.toString(uint256(checkpointsBefore)), " -> ", vm.toString(uint256(checkpointsAfter)))
        );
        DemoLog.note("    One per revoked rules set.");
        DemoLog.blank();

        _agentTriesAgain(agent);

        DemoLog.blank();
        DemoLog.line(DemoLog.bold("Revoked means revoked: the agent's own key can no longer act."));
        DemoLog.footer();
    }

    /// @dev SIMULATION ONLY. The Act 2 request, from the agent itself, against the revoked rules.
    function _agentTriesAgain(address agent) internal {
        address cea = Ledger.addr("predictedCEA", "10_Arrive");
        uint256 amount = Amounts.perCall();

        AgentRequest.Built memory req = AgentRequest.single(
            amount, AddressBook.sepolia("StakeDummy"), abi.encodeCall(StakeDummy.stakeFor, (cea, amount))
        );

        Gauntlet.refuseAtWallet("the agent's own Act 2 request, after revocation (simulated)", agent, req);
    }
}
