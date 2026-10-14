// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { Requests } from "../../lib/Requests.sol";
import { BobPayload, IUEA, UniversalPayload } from "../../lib/BobPayload.sol";
import { Multicall } from "../../../src/libraries/Types.sol";
import { IAGW } from "../../../src/interfaces/IAGW.sol";
import { IEngineState } from "../../lib/Inspect.sol";

/**
 * @title  Reset
 * @notice Chain: Donut · broadcasts with the RELAYER key, on a payload BOB signed.
 *         REHEARSAL RECOVERY ONLY. Never run this during the live demo.
 *
 * @dev    Revokes every rules set on the wallet in one call, so a rehearsal can be reset without
 *         redeploying anything. The wallet keeps its funds, its owner and its address; only the
 *         agent's authority goes.
 *
 *         WHY IT IS SAFE TO CALL AT ANY MOMENT, and this is a load-bearing property rather than a
 *         convenience: `revokeAllRules` has NOTHING ON IT THAT CAN FAIL. No guard, no probe, no
 *         extra external call. Blockable revocation would be the one regression this function must
 *         never develop — an owner who cannot revoke has no real control, whatever the caps say.
 *
 *         AFTER RUNNING IT, THE LEDGER'S RULES KEYS ARE STALE. The rules id names a rules set that
 *         no longer exists and has no agent, so every agent script would be refused at the wallet.
 *         This clears `rulesId` and `rules.maxGasPerCall` — and only those — which also resets
 *         `Preflight` to phase 2 and makes the next `just act1e` a clean grant.
 *
 *         THE DIFFERENCE FROM ACT 4e (`44_RevokeAll`): that script is a demo beat and keeps the
 *         ledger so `just state` can show the revoked rules. This one is housekeeping and clears it.
 */
contract Reset is Script {
    uint256 internal constant VALID_FOR = 1 hours;

    function run() external {
        uint256 bobPk = Keys.load("BOB_KEY", "only the owner may revoke");
        uint256 relayerPk = Keys.load("PC_RELAYER_KEY", "the relayer submits");

        address uea = Ledger.addr("uea", "10_Arrive");
        address agw = Ledger.addr("agw", "10_Arrive");
        IEngineState engine = IEngineState(IAGW(agw).SESSION_ENGINE());

        DemoLog.header("RESET", "Revoke every rules set");
        DemoLog.line(DemoLog.red("  REHEARSAL RECOVERY ONLY. Never during the live demo."));
        DemoLog.blank();
        DemoLog.addrPlain("Wallet", agw);

        bool hadRules = Ledger.has("rulesId");
        bytes32 rulesId = hadRules ? Ledger.word("rulesId", "14_GrantRules") : bytes32(0);

        if (hadRules) {
            DemoLog.kv("Before", engine.isPermissionEnabled(rulesId, agw) ? "1 rules set, live" : "0 live");
        } else {
            DemoLog.kv("Before", DemoLog.dim("no rules recorded"));
        }
        uint64 checkpointsBefore = IAGW(agw).checkpointCount();

        Multicall[] memory call = Requests.singleCall(agw, abi.encodeCall(IAGW.revokeAllRules, ()));
        (UniversalPayload memory payload, bytes memory signature) =
            BobPayload.signedMulticall(uea, call, bobPk, VALID_FOR);

        vm.startBroadcast(relayerPk);
        IUEA(uea).executeUniversalTx(payload, signature);
        vm.stopBroadcast();

        if (hadRules) {
            DemoLog.kv("After", engine.isPermissionEnabled(rulesId, agw) ? "still live" : "0 live");
            DemoLog.kv("Agent of rules", vm.toString(IAGW(agw).agentOf(rulesId)));
        }
        DemoLog.kv(
            "Checkpoints",
            string.concat(
                vm.toString(uint256(checkpointsBefore)), " -> ", vm.toString(uint256(IAGW(agw).checkpointCount()))
            )
        );

        // The ledger's rules keys now name something that does not exist. CLEARED, not zeroed:
        // a zeroed key leaves `has` true and every read reverting. No other key is touched.
        //
        // ONLY WHEN BROADCASTING. A dry run revoked nothing, so clearing the ledger then would
        // leave it without the id of rules that are still live on the chain.
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            Ledger.clear("rulesId");
            Ledger.clear("rules.maxGasPerCall");
        } else {
            DemoLog.note("Dry run: nothing was revoked, so the ledger's rules keys were left in place.");
        }

        DemoLog.blank();
        DemoLog.ok("revoked", "the agent has no authority left");
        DemoLog.note("The wallet keeps its funds, its owner and its address.");
        DemoLog.blank();
        DemoLog.note("Run `just act1e` to grant fresh rules.");
        DemoLog.footer();
    }
}
