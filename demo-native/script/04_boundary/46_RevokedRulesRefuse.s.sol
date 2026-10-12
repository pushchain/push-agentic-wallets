// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";

import { StakeDummy } from "../../contracts/StakeDummy.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeGauntlet } from "../../lib/NativeGauntlet.sol";
import { NativeRequest } from "../../lib/NativeRequest.sol";

/**
 * @title  RevokedRulesRefuse
 * @notice ACT 4e · THE CLOSING BEAT · SIMULATION ONLY. A flawless request, against revoked rules.
 *
 * @dev    NOTHING IS WRONG WITH THIS REQUEST. The right contract, the right function, the right
 *         beneficiary, an amount inside every cap, sent by the agent's own account. One act ago it
 *         would have been judged on its merits.
 *
 *         IT IS REFUSED BY THE WALLET, BEFORE ANY POLICY RUNS. Revoking removes the rules from
 *         the engine, and `agentOf(rulesId)` then returns the zero address: revoked rules name
 *         nobody. The agent door's first check compares the sender against that, so the agent's
 *         own address is refused with `CallerIsNotAgent(rulesId, agent)` — the engine and URP are
 *         never reached.
 *
 *         Revocation needs no cooperation from the agent and leaves nothing to expire: there is
 *         no outstanding authority anywhere for the agent to present.
 */
contract RevokedRulesRefuse is Script {
    function run() external {
        address agent = Keys.addressOf("AGENT_KEY", "the agent, acting against revoked rules");
        address agw = Ledger.addr("agw", "10_DeployWallet");
        bytes32 rulesId = Ledger.word("rulesId", "13_GrantRules");
        address stake = AddressBook.native("StakeDummy");

        NativeRequest.Built memory req = NativeRequest.build(
            agw,
            rulesId,
            stake,
            abi.encodeCall(StakeDummy.stakeFor, (agw, Amounts.G7_OVER_TOTAL)),
            Amounts.G7_OVER_TOTAL
        );

        DemoLog.header("ACT 4e", "The agent tries again, after revocation");
        DemoLog.line(DemoLog.bold("Nothing is wrong with this request."));
        DemoLog.addrPlain("  target", stake);
        DemoLog.addrPlain("  beneficiary", agw);
        DemoLog.money("  amount", Amounts.G7_OVER_TOTAL, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.note("    Right contract, right function, right beneficiary, within every cap.");
        DemoLog.blank();

        NativeGauntlet.refuseAtWallet(
            "a flawless request, against rules revoked one act ago",
            agent,
            "Revocation is immediate: the agent's own key, a perfect request, refused by the wallet before any policy runs.",
            req
        );

        DemoLog.footer();
    }
}
