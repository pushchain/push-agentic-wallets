// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { AgentRequest } from "../../lib/AgentRequest.sol";

/**
 * @title  FundAgentPC
 * @notice Chain: Donut · broadcasts with the relayer key. T-1-hour setup.
 *
 * @dev    THE AGENT SENDS ITS OWN TRANSACTIONS, so it needs PC for gas. This tops it up to a fixed
 *         target and never above it: the agent holds a little PC for gas and never holds tokens.
 *
 *         A SEPARATE SCRIPT FROM `03_FundAll` BECAUSE THEY RUN ON DIFFERENT CHAINS. `03_FundAll`
 *         moves USDC on Sepolia; this moves PC on Donut. One script, one chain, one key.
 *
 *         Idempotent: an agent already at or above the target is left alone.
 */
contract FundAgentPC is Script {
    error RelayerOutOfPC(uint256 have, uint256 need);

    function run() external {
        uint256 relayerPk = Keys.load("PC_RELAYER_KEY", "the relayer funds the agent's gas");
        address relayer = vm.addr(relayerPk);
        address agent = Keys.addressOf("AGENT_KEY", "the agent, which pays its own gas");
        uint256 target = AgentRequest.AGENT_PC_TARGET;

        DemoLog.header("SETUP", "The agent's gas");
        DemoLog.addr("Agent", agent, true);
        DemoLog.money("Has", agent.balance, 18, "PC");
        DemoLog.money("Target", target, 18, "PC");

        if (agent.balance >= target) {
            DemoLog.blank();
            DemoLog.ok("already funded", "nothing to send");
            DemoLog.footer();
            return;
        }

        uint256 topUp = target - agent.balance;
        if (relayer.balance < topUp) revert RelayerOutOfPC(relayer.balance, topUp);

        vm.startBroadcast(relayerPk);
        (bool sent,) = payable(agent).call{ value: topUp }("");
        vm.stopBroadcast();
        require(sent, "PC transfer failed");

        DemoLog.blank();
        DemoLog.ok("sent", DemoLog.formatAmount(topUp, 18, "PC"));
        DemoLog.money("Balance", agent.balance, 18, "PC");
        DemoLog.blank();
        DemoLog.note("The agent holds a little PC for gas and never holds tokens.");
        DemoLog.note("The PC an outbound needs comes from the wallet, not from the agent.");
        DemoLog.footer();
    }
}
