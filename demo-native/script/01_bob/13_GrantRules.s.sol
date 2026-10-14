// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { Session } from "smartsessions/DataTypes.sol";

import { NativeConfig } from "../../../src/libraries/Types.sol";
import { StakeDummy } from "../../contracts/StakeDummy.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Grant } from "../../lib/Grant.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeRules } from "../../lib/NativeRules.sol";

/**
 * @title  GrantRules
 * @notice ACT 1d · Chain: Donut · broadcasts with BOB's key.
 *         THE MOST IMPORTANT OUTPUT ANY SCRIPT IN THIS DEMO PRODUCES.
 *
 * @dev    The rules summary this prints is the demo's thesis on one screen, and it is where the
 *         live demo opens. Everything else exists to make it credible.
 *
 *         WHAT THE RULES SAY, in one sentence: this agent may call ONE function on ONE
 *         contract on this chain, only ever crediting Bob's own wallet, up to 2.5 dUSDC per action
 *         and 6 dUSDC in total, at most four times, for seven days. Nothing else.
 *
 *         THE PIN IS THE PRODUCT. `pins[0]` fixes the beneficiary word to the wallet. Without it
 *         the agent could stake Bob's money naming ITSELF as beneficiary and then call `unstake()`
 *         straight from its own account — under no rules at all — and walk away with principal plus
 *         reward. Act 3's G3 demonstrates exactly that attempt being refused.
 *
 *         THE SHAPE IS ENFORCED BY THE WALLET, NOT BY CONVENTION. `grantRules` refuses anything
 *         but the canonical shape, and it refuses native rules that name the gateway — the
 *         consistency lock whose runtime mirror is URP's gate N3.
 *
 *         NOBODY DECLARES THESE RULES NATIVE. The envelope carries this chain's own CAIP-2
 *         string, and the wallet and URP each derive NATIVE from it. The line this script prints
 *         is read back from the contracts, not from the script.
 */
contract GrantRules is Script {
    function run() external {
        uint256 bobPk = Keys.load("BOB_KEY", "Bob grants every rules set");
        address agent = Keys.addressOf("AGENT_KEY", "the agent the rules authorise");

        address agw = Ledger.addr("agw", "10_DeployWallet");
        address stake = AddressBook.native("StakeDummy");
        bytes4 selector = StakeDummy.stakeFor.selector;

        Session memory session = NativeRules.stakeSession(agent, agw, stake, selector);

        Grant.Result memory r = Grant.asOwner(bobPk, agw, session, agent, stake, selector);

        // Only `rulesId` is written. Nothing else in the ledger is touched.
        Ledger.setWord("rulesId", r.granted.rulesId);

        _printRules(agw, r.cfg);

        DemoLog.header("", "For the record");
        Grant.printRecord(r, agw);
        DemoLog.addrPlain("StakeDummy", stake);
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("The pinned beneficiary:"));
        DemoLog.kv("  offset", string.concat(vm.toString(uint256(r.cfg.pins[0].offset)), " (first argument word)"));
        DemoLog.kv("  must equal", vm.toString(r.cfg.pins[0].expected));
        DemoLog.note("    One word of calldata. It is what stops the agent staking to itself");
        DemoLog.note("    and then unstaking to itself from its own account.");
        DemoLog.footer();
    }

    /**
     * @dev THE DEMO'S THESIS ON ONE SCREEN. Every number is read back from URP's stored rulebook,
     *      never echoed from the constants that built the request.
     */
    function _printRules(address agw, NativeConfig memory cfg) internal view {
        DemoLog.header("ACT 1d", "The rules");
        DemoLog.line(DemoLog.bold("This agent may:"));
        DemoLog.line(string.concat(unicode"  · call ", DemoLog.bold("stakeFor()"), " on StakeDummy"));
        DemoLog.note(string.concat("      but only ever crediting ", vm.toString(agw)));
        DemoLog.blank();
        DemoLog.money("Per action", cfg.amount.maxPerCall, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("Lifetime", cfg.amount.maxTotal, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.kv("At most", string.concat(vm.toString(uint256(cfg.maxCalls)), " calls"));
        DemoLog.kv("Native value", cfg.maxValuePerCall == 0 ? "0 - these rules can carry none" : "capped");
        DemoLog.kv("Expires", string.concat("in ", vm.toString((cfg.validUntil - block.timestamp) / 1 days), " days"));
        DemoLog.blank();
        DemoLog.line(DemoLog.dim("Nothing else. No other contract, no other function,"));
        DemoLog.line(DemoLog.dim("no other beneficiary."));
        DemoLog.footer();
    }
}
