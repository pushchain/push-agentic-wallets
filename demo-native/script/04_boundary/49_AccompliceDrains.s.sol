// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAGW } from "../../../src/interfaces/IAGW.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeRequest } from "../../lib/NativeRequest.sol";

/**
 * @title  AccompliceDrains
 * @notice ACT 4f (3 of 5) · ⚠️ THE AGENT SUCCEEDS. The money leaves, and nothing refuses it.
 *
 * @dev    THE ONLY SCRIPT IN EITHER DEMO WHERE AN AGENT REQUEST DOES SOMETHING BAD AND WORKS.
 *
 *         TWO TRANSACTIONS, TWO SENDERS, and the split is the lesson:
 *
 *           1. THE AGENT sends `executeAsAgent`: the wallet calls `approve(accomplice, everything)`.
 *              The rules permit `approve` and pin nothing, so every gate passes.
 *           2. THE ACCOMPLICE sends `transferFrom(wallet, accomplice, allowance)` as itself.
 *
 *         WHY THE ACCOMPLICE IS A SEPARATE PARTY. `ERC20.transferFrom` takes its spender from
 *         `msg.sender` and checks THAT address's allowance. Whoever was approved must send the
 *         transaction; nobody can send it on their behalf. So the approved spender is a second
 *         account, with its own key and its own gas.
 *
 *         AND IT IS THE BETTER STORY. The agent did not steal for itself — it HANDED THE USER'S
 *         MONEY TO A THIRD PARTY, and still ends the act holding no tokens. That is exactly what
 *         an unpinned spender argument permits, and it is a far more realistic failure than an
 *         agent naming its own address.
 */
contract AccompliceDrains is Script {
    function run() external {
        uint256 agentPk = Keys.load("AGENT_KEY", "the agent sends the over-broad approval");
        uint256 accomplicePk = Keys.load("PC_RELAYER_KEY", "the accomplice: approved spender, and the one who takes it");
        address accomplice = vm.addr(accomplicePk);

        address wallet = Ledger.addr("throwawayAgw", "47_Throwaway_DeployAndFund");
        bytes32 rulesId = Ledger.word("unpinnedApproveRulesId", "48_GrantUnpinnedApprove");
        IERC20 token = IERC20(AddressBook.native("DemoUSDC"));

        uint256 walletBefore = token.balanceOf(wallet);
        uint256 accompliceBefore = token.balanceOf(accomplice);
        uint64 checkpointsBefore = IAGW(wallet).checkpointCount();

        DemoLog.header("ACT 4f", "The agent hands the money to an accomplice");
        DemoLog.addrPlain("Throwaway wallet", wallet);
        DemoLog.money("  holds", walletBefore, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.addrPlain("Accomplice", accomplice);
        DemoLog.note("    A separate party, because transferFrom takes the spender from msg.sender:");
        DemoLog.note("    whoever is approved must send the transaction themselves.");
        DemoLog.blank();

        // ── 1 · THE AGENT sends the approval. Allowed: the rules pin nothing. ──
        NativeRequest.Built memory req = NativeRequest.build(
            wallet, rulesId, address(token), abi.encodeCall(IERC20.approve, (accomplice, walletBefore)), walletBefore
        );
        NativeRequest.submit(agentPk, req);

        uint256 allowance = token.allowance(wallet, accomplice);
        DemoLog.ok("approved", "the policy accepted it - no pin, no objection");
        DemoLog.money("  allowance", allowance, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.blank();

        // ── 2 · THE ACCOMPLICE takes it, as itself. ──
        vm.startBroadcast(accomplicePk);
        token.transferFrom(wallet, accomplice, allowance);
        vm.stopBroadcast();

        uint256 walletAfter = token.balanceOf(wallet);
        uint256 accompliceAfter = token.balanceOf(accomplice);

        DemoLog.fail("drained", "the money is gone, and no gate fired");
        DemoLog.money("Wallet, before", walletBefore, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("Wallet, after", walletAfter, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("Accomplice gained", accompliceAfter - accompliceBefore, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("Agent holds", token.balanceOf(vm.addr(agentPk)), Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("The system did exactly what it was told."));
        DemoLog.line(DemoLog.dim("The rules said the agent may call approve(). They did not say"));
        DemoLog.line(DemoLog.dim("whom it may approve. URP enforced the rules as written."));
        DemoLog.blank();
        DemoLog.note("Next: the same rules, with the spender pinned - and the same request refused.");
        DemoLog.footer();

        require(walletAfter == 0, "the drain did not complete - the act proves nothing");
        require(accompliceAfter == accompliceBefore + walletBefore, "the accomplice did not receive the funds");
        require(IAGW(wallet).checkpointCount() == checkpointsBefore, "an agent action must not move the checkpoint");
    }
}
