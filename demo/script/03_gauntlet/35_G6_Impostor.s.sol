// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { Gauntlet } from "../../lib/Gauntlet.sol";
import { AgentRequest } from "../../lib/AgentRequest.sol";
import { StakeDummy } from "../../contracts/StakeDummy.sol";

/**
 * @title  G6 — the impostor
 * @notice ACT 3 · Chain: Donut · SIMULATION ONLY. Never broadcasts, changes no state.
 *
 * @dev    THE ATTEMPT: someone else submits the agent's request. Not a variation of it — the exact
 *         Act 2 call, byte for byte, against live rules, from a different address.
 *
 *         THE POINT: possessing the agent's request is worthless. The agent door accepts exactly
 *         one sender, the address the rules name, and that check is the wallet's FIRST: it runs
 *         before the engine and before any policy. Copying calldata out of a block explorer gives
 *         an attacker nothing to submit.
 *
 *         IT IS REFUSED DIFFERENTLY FROM G1-G5 AND G7, AND THAT IS WORTH SAYING. Those die inside
 *         URP, so the engine wraps them as `PolicyCheckReverted`. This one never reaches a policy:
 *         the WALLET rejects it, unwrapped, with the rules id and the caller in the error.
 *
 *         WHAT ABOUT THE AGENT REPLAYING ITS OWN TRANSACTION? That is stopped by the agent
 *         account's transaction nonce, which belongs to the chain, not to these contracts. The
 *         wallet keeps no agent nonce at all.
 */
contract G6_Impostor is Script {
    function run() external {
        address impostor = Keys.addressOf("PC_RELAYER_KEY", "the impostor: a funded account the rules do not name");
        address cea = Ledger.addr("predictedCEA", "10_Arrive");
        address stakeDummy = AddressBook.sepolia("StakeDummy");

        uint256 amount = Amounts.perCall();

        DemoLog.header("G6", "Someone else submits the agent's request");

        // Act 2's request, rebuilt exactly as `20_Stake` builds it.
        AgentRequest.Built memory req =
            AgentRequest.single(amount, stakeDummy, abi.encodeCall(StakeDummy.stakeFor, (cea, amount)));

        Gauntlet.refuseAtWallet("the exact Act 2 request, sent from another account", impostor, req);

        DemoLog.blank();
        DemoLog.note("The relayer has the agent's exact request, byte for byte. The wallet refuses it");
        DemoLog.note("before any policy runs: only the address the rules name may act.");
        DemoLog.note("Replaying the agent's own transaction is stopped by the agent account's nonce.");
        DemoLog.footer();
    }
}
