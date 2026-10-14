// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { Session } from "smartsessions/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Grant } from "../../lib/Grant.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeRules } from "../../lib/NativeRules.sol";

/**
 * @title  GrantUnpinnedApprove
 * @notice ACT 4f (2 of 5) · A rules set with a hole in it. GRANTED SUCCESSFULLY.
 *
 * @dev    NOTHING REFUSES THIS, AND THAT IS THE POINT. It is a well-formed rules set: canonical
 *         shape, the real validator, the deployed URP, a legitimate target, a legitimate selector.
 *         `grantRules` accepts it. URP initialises it. It looks exactly like the stake rules set
 *         from Act 1d.
 *
 *         THE DIFFERENCE IS ONE ABSENT FIELD: `pins` is empty. The stake rules set pinned the
 *         beneficiary word; this one pins nothing, so `approve(anyone, anything)` is authorised.
 *
 *         THE CONTRACT CANNOT TELL. There is no heuristic in URP that could distinguish "these
 *         rules omitted a pin because the argument is safe" from "these rules omitted a pin by
 *         mistake" — a rules set without pins is a perfectly valid rules set that simply permits more.
 *         PINNING IS THE SDK'S OBLIGATION, NOT THE CONTRACT'S. That sentence is the whole act.
 *
 *         ⚠️ THE TARGET IS `DemoUSDC`, NOT `StakeDummy`. This is the only place in the demo where
 *         the action target is not the staking contract, so the config id is derived against the
 *         token. Deriving it against `StakeDummy` out of habit yields an id addressing an empty
 *         slot, and every read fails at gate N1 with `NotInitialized`.
 */
contract GrantUnpinnedApprove is Script {
    error PinsShouldBeEmpty(uint256 count);

    function run() external {
        uint256 bobPk = Keys.load("BOB_KEY", "Bob grants rules with a hole in them");
        address agent = Keys.addressOf("AGENT_KEY", "the agent these over-broad rules authorise");

        address wallet = Ledger.addr("throwawayAgw", "47_Throwaway_DeployAndFund");
        address token = AddressBook.native("DemoUSDC");
        bytes4 selector = IERC20.approve.selector;

        // `address(0)` = NO PIN. This single argument is the whole difference from 4A.
        Session memory session = NativeRules.approveSession(agent, token, selector, address(0));
        Grant.Result memory r = Grant.asOwner(bobPk, wallet, session, agent, token, selector);

        // The act is only honest if the rules really have no pin.
        if (r.cfg.pins.length != 0) revert PinsShouldBeEmpty(r.cfg.pins.length);

        Ledger.setWord("unpinnedApproveRulesId", r.granted.rulesId);

        DemoLog.header("ACT 4f", "Rules with a hole in them");
        DemoLog.line(DemoLog.bold("This agent may:"));
        DemoLog.line(string.concat(unicode"  · call ", DemoLog.bold("approve()"), " on dUSDC"));
        DemoLog.blank();
        DemoLog.kv("Pinned arguments", "NONE");
        DemoLog.note("    So: approve WHOM, for HOW MUCH? The rules do not say.");
        DemoLog.blank();
        DemoLog.ok("granted", "nothing refused it - these are well-formed rules");
        DemoLog.note("    Canonical shape, the real validator, the deployed policy, a");
        DemoLog.note("    legitimate target. They look exactly like Act 1d's rules.");
        DemoLog.blank();
        DemoLog.line(DemoLog.dim("Rules without pins are not malformed rules."));
        DemoLog.line(DemoLog.dim("They are valid rules that simply permit more."));
        DemoLog.blank();
        Grant.printRecord(r, wallet);
        DemoLog.footer();
    }
}
