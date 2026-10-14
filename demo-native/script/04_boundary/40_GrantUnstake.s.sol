// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { Session } from "smartsessions/DataTypes.sol";

import { StakeDummy } from "../../contracts/StakeDummy.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Grant } from "../../lib/Grant.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeRules } from "../../lib/NativeRules.sol";

/**
 * @title  GrantUnstake
 * @notice ACT 4a′ · Chain: Donut · broadcasts with BOB's key. A SECOND rules set, for one job.
 *
 * @dev    `unstake()` was never in the stake rules set — G2 proved it, by being refused. Bob grants a
 *         separate rules set for it now, which is a stronger story than bundling both at the start:
 *         a rules set is granted for a job, used, and then dies with `revokeAllRules`.
 *
 *         THREE THINGS ARE DELIBERATELY DIFFERENT FROM THE STAKE RULES:
 *
 *           · NO PINS. `unstake()` takes no arguments and credits `msg.sender`, which is the wallet.
 *             There is nothing to redirect, so there is nothing to pin. Do not "fix" this by adding
 *             one — a pin on a zero-argument call can never match, and the rules would authorise
 *             nothing at all.
 *           · NO AMOUNT RULE. There is no amount word in the calldata to meter.
 *           · `maxCalls = 1`. The honest shape for "unstake once" — and it is what makes G8 fire at
 *             gate N9, cleanly, BEFORE dispatch, so `StakeDummy.NothingStaked()` never gets the
 *             chance to muddy the error.
 *
 *         ONE WALLET, TWO RULES SETS, ONE AGENT. Each grant gets its own rules id from the
 *         wallet's grant counter, and each id records its own agent, rulebook and counters.
 */
contract GrantUnstake is Script {
    function run() external {
        uint256 bobPk = Keys.load("BOB_KEY", "Bob grants the unstake rules");
        address agent = Keys.addressOf("AGENT_KEY", "the same agent - a new job, not a new agent");

        address agw = Ledger.addr("agw", "10_DeployWallet");
        address stake = AddressBook.native("StakeDummy");
        bytes4 selector = StakeDummy.unstake.selector;

        Session memory session = NativeRules.unstakeSession(agent, stake, selector);
        Grant.Result memory r = Grant.asOwner(bobPk, agw, session, agent, stake, selector);

        Ledger.setWord("unstakeRulesId", r.granted.rulesId);

        DemoLog.header("ACT 4a'", "A second rules set, for one job");
        DemoLog.line(DemoLog.bold("This agent may now also:"));
        DemoLog.line(string.concat(unicode"  \u00b7 call ", DemoLog.bold("unstake()"), " on StakeDummy"));
        DemoLog.blank();
        DemoLog.kv("At most", string.concat(vm.toString(uint256(r.cfg.maxCalls)), " call"));
        DemoLog.kv("Pins", string.concat(vm.toString(r.cfg.pins.length), " - and that is correct"));
        DemoLog.note("    unstake() takes no arguments and credits msg.sender, which IS the");
        DemoLog.note("    wallet. There is no argument to redirect, so nothing to pin.");
        DemoLog.blank();
        Grant.printRecord(r, agw);
        DemoLog.footer();
    }
}
