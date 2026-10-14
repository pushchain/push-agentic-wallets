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
 * @title  GrantPinnedApprove
 * @notice ACT 4f (4 of 5) · The SAME rules, with one field filled in.
 *
 * @dev    IDENTICAL TO `48_GrantUnpinnedApprove` IN EVERY RESPECT BUT ONE: `pins` names the
 *         spender. Same wallet, same agent, same target, same selector, same caps — so when the
 *         next script's request is refused, the pin is unambiguously the reason.
 *
 *         THE SPENDER IS PINNED TO `StakeDummy`, which is the only address these rules should ever
 *         approve: staking rules need the staking contract to be able to pull tokens, and
 *         nothing else. Any other spender — including the accomplice who succeeded one act ago —
 *         is now a gate N7 failure.
 *
 *         THE RULES ARE GRANTED ON THE SAME (NOW EMPTY) THROWAWAY WALLET. The unpinned rules stay
 *         live beside them, under their own id; the next script acts under the pinned id.
 */
contract GrantPinnedApprove is Script {
    error PinMissing();

    function run() external {
        uint256 bobPk = Keys.load("BOB_KEY", "Bob grants the corrected rules");
        address agent = Keys.addressOf("AGENT_KEY", "the same agent");

        address wallet = Ledger.addr("throwawayAgw", "47_Throwaway_DeployAndFund");
        address token = AddressBook.native("DemoUSDC");
        address stake = AddressBook.native("StakeDummy");
        bytes4 selector = IERC20.approve.selector;

        // The pinned spender. Compare with `48_GrantUnpinnedApprove`, which passes `address(0)`.
        Session memory session = NativeRules.approveSession(agent, token, selector, stake);
        Grant.Result memory r = Grant.asOwner(bobPk, wallet, session, agent, token, selector);

        if (r.cfg.pins.length != 1) revert PinMissing();

        Ledger.setWord("pinnedApproveRulesId", r.granted.rulesId);

        DemoLog.header("ACT 4f", "The same rules, with the hole closed");
        DemoLog.line(DemoLog.bold("This agent may:"));
        DemoLog.line(string.concat(unicode"  · call ", DemoLog.bold("approve()"), " on dUSDC"));
        DemoLog.note(string.concat("      but ONLY naming ", vm.toString(stake)));
        DemoLog.blank();
        DemoLog.kv("Pinned argument", string.concat("spender, at offset ", vm.toString(uint256(r.cfg.pins[0].offset))));
        DemoLog.kv("Must equal", vm.toString(r.cfg.pins[0].value));
        DemoLog.blank();
        DemoLog.line(DemoLog.dim("Same wallet, same agent, same contract, same function, same caps."));
        DemoLog.line(DemoLog.dim("One field is different."));
        DemoLog.blank();
        Grant.printRecord(r, wallet);
        DemoLog.footer();
    }
}
