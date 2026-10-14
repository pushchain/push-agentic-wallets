// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { AgentRequest } from "../../lib/AgentRequest.sol";
import { RulesRead } from "../../lib/RulesRead.sol";
import { IAGW } from "../../../src/interfaces/IAGW.sol";
import { IUniversalRulesPolicy } from "../../../src/interfaces/IUniversalRulesPolicy.sol";
import { StakeDummy } from "../../contracts/StakeDummy.sol";

/**
 * @title  AgentUnstake
 * @notice ACT 4a · Chain: Donut · broadcasts with the AGENT key. The agent sends it itself.
 *
 * @dev    THE AGENT UNWINDS ITS OWN POSITION, and the interesting part is what it costs: nothing.
 *
 *         A ZERO-AMOUNT REQUEST. The capital is already on Sepolia — there is nothing to bridge, so
 *         `amount` is 0 and this is pure calldata. Three things still hold, and all three surprise
 *         people:
 *
 *           · `token` must STILL be a listed token — gate 5 checks it regardless of amount.
 *           · `maxPCForGas` must STILL be non-zero — gate 9 does not look at amount either.
 *           · `msg.value` must STILL be sent — the gas swap runs, and reverts on a zero swap.
 *
 *         `_burnPRC20` is skipped and URP adds nothing to the token's `spent`. So the agent can unwind
 *         without consuming budget — **the lifetime cap meters what LEAVES Push Chain, not how many
 *         times the agent acts.** That is the design working, not a gap.
 *
 *         `unstake()` TAKES NO ARGUMENTS. The caller is the staker, so there is no beneficiary to
 *         pin and the allow-list entry is trivial. The far-chain calldata is a bare four bytes.
 *
 *         AFTER THE RELAY the CEA holds principal plus the flat reward, and `spent` is unchanged —
 *         both asserted by `just watch-unstaked` and `just state`.
 */
contract AgentUnstake is Script {
    error WalletOutOfPC(uint256 have, uint256 need);
    error SpendMoved(uint256 before, uint256 afterSpent);
    error CheckpointMoved(uint64 before, uint64 afterCount);

    function run() external {
        uint256 agentPk = Keys.load("AGENT_KEY", "the agent sends its own transactions");

        address agw = Ledger.addr("agw", "10_Arrive");
        address stakeDummy = AddressBook.sepolia("StakeDummy");

        AgentRequest.Built memory req =
            AgentRequest.single(0, stakeDummy, abi.encodeWithSelector(StakeDummy.unstake.selector));

        if (agw.balance < req.pcValue) revert WalletOutOfPC(agw.balance, req.pcValue);

        DemoLog.header("ACT 4", "The agent unwinds");
        DemoLog.addrPlain("Agent", vm.addr(agentPk));
        DemoLog.note("    Sends this transaction itself, as in Act 2.");
        DemoLog.blank();
        DemoLog.kv("Request", "unstake() on StakeDummy");
        DemoLog.kv("Bridged", "0.00 USDC  (the capital is already there)");
        DemoLog.kv("Calldata", "4 bytes - unstake takes no arguments");
        DemoLog.money("PC value", req.pcValue, 18, "PC");
        DemoLog.blank();

        uint256 spentBefore = _spent(agw, req.rulesId);
        uint64 checkpointsBefore = IAGW(agw).checkpointCount();

        AgentRequest.submit(agentPk, req);

        uint256 spentAfter = _spent(agw, req.rulesId);
        if (spentAfter != spentBefore) revert SpendMoved(spentBefore, spentAfter);
        uint64 checkpointsAfter = IAGW(agw).checkpointCount();
        if (checkpointsAfter != checkpointsBefore) revert CheckpointMoved(checkpointsBefore, checkpointsAfter);

        DemoLog.ok("accepted", "all 16 gates, on a zero-amount request");
        DemoLog.ok("metered", string.concat("nothing - spent is still ", DemoLog.formatAmount(spentAfter, 6, "USDC")));
        DemoLog.ok("checkpoints", string.concat("unchanged at ", vm.toString(uint256(checkpointsAfter))));
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("The lifetime cap meters what LEAVES Push Chain,"));
        DemoLog.line(DemoLog.bold("not how many times the agent acts."));
        DemoLog.blank();
        DemoLog.note("Run `just watch-unstaked` - the CEA should end with principal plus the reward.");
        DemoLog.footer();
    }

    /// @dev The listed token's spend counter, straight from URP.
    function _spent(address agw, bytes32 rulesId) internal view returns (uint256) {
        return IUniversalRulesPolicy(IAGW(agw).RULES_POLICY())
        .getConfig(RulesRead.universalConfigId(agw, rulesId), agw)
        .assets[0].spent;
    }
}
