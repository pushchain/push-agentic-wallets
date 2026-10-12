// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { Gauntlet } from "../../lib/Gauntlet.sol";
import { AgentRequest } from "../../lib/AgentRequest.sol";
import { ICEA } from "../../lib/PushCore.sol";
import { UniversalRulesPolicyErrors } from "../../../src/libraries/Errors.sol";

/**
 * @title  G2 — the agent drains the CEA
 * @notice ACT 3 · Chain: Donut · SIMULATION ONLY. Never broadcasts, changes no state.
 *
 * @dev    THE ATTEMPT: the agent names the wallet's own CEA as the far-chain target and asks it to
 *         send funds back through `sendUniversalTxToUEA`.
 *
 *         THE POINT: the CEA holds the working capital on Sepolia. A request aimed at the CEA
 *         itself is a request to move that capital, so URP refuses the CEA as an inner target
 *         whatever the allow-list says (gate 14, before the allow-list is even consulted).
 *
 *         The same call is legitimate for the OWNER — Act 4c makes it and it succeeds.
 */
contract G2_ForbiddenCEA is Script {
    function run() external {
        address cea = Ledger.addr("predictedCEA", "10_Arrive");
        address agw = Ledger.addr("agw", "10_Arrive");

        DemoLog.header("G2", "Send the funds somewhere the agent chooses");

        AgentRequest.Built memory req = AgentRequest.single(
            0,
            cea, // the forbidden target
            abi.encodeCall(ICEA.sendUniversalTxToUEA, (address(0), 0, "", agw))
        );

        Gauntlet.refuse(
            "call sendUniversalTxToUEA on its own CEA",
            UniversalRulesPolicyErrors.ForbiddenInnerTarget.selector,
            "URP gate 14 (no loopbacks)",
            "The CEA holds the working capital. This call is legitimate for the OWNER (Act 4c) and never for the agent.",
            req
        );

        DemoLog.footer();
    }
}
