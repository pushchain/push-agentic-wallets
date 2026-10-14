// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { UniversalRulesPolicyErrors } from "../../../src/libraries/Errors.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeGauntlet } from "../../lib/NativeGauntlet.sol";
import { NativeRequest } from "../../lib/NativeRequest.sol";

/**
 * @title  PinnedApproveRefuses
 * @notice ACT 4f (5 of 5) · The identical request that succeeded, now refused.
 *
 * @dev    THE CLOSING COMPARISON, AND THE POINT OF THE WHOLE ACT.
 *
 *         `49_AccompliceDrains` sent exactly this request — approve the accomplice — and it went
 *         through. Same wallet, same agent, same token, same function, same amount, same sender.
 *         The ONLY thing that changed is that the rules now name which spender is
 *         permitted.
 *
 *         WHAT THE AUDIENCE SHOULD LEAVE KNOWING:
 *
 *             The system enforces the rules exactly as written. Writing a bad rules set is
 *             possible, and the tooling that composes rules is what prevents it. A demo that
 *             implies the contract will save you from a badly written rules set is selling something
 *             the contract does not do.
 *
 *         This is not a weakness being confessed — it is the correct division of responsibility.
 *         URP cannot know which arguments matter to a user's intent; only the thing that composed
 *         the rules can. What URP guarantees is that whatever WAS written will be enforced
 *         exactly, every time, without trusting the agent.
 */
contract PinnedApproveRefuses is Script {
    function run() external {
        address accomplice = Keys.addressOf("PC_RELAYER_KEY", "the same accomplice as before");

        address wallet = Ledger.addr("throwawayAgw", "47_Throwaway_DeployAndFund");
        bytes32 rulesId = Ledger.word("pinnedApproveRulesId", "4A_GrantPinnedApprove");
        address stake = AddressBook.native("StakeDummy");
        IERC20 token = IERC20(AddressBook.native("DemoUSDC"));

        // The request that drained the wallet in `49_AccompliceDrains`, under the pinned rules.
        NativeRequest.Built memory req = NativeRequest.build(
            wallet,
            rulesId,
            address(token),
            abi.encodeCall(IERC20.approve, (accomplice, Amounts.THROWAWAY_FUND)),
            Amounts.THROWAWAY_FUND
        );

        DemoLog.header("ACT 4f", "The same request, refused");
        DemoLog.addrPlain("Rules permit", stake);
        DemoLog.addrPlain("Request names", accomplice);
        DemoLog.note("    The call that drained the wallet two steps ago.");
        DemoLog.blank();

        NativeGauntlet.refuseGate(
            _title(),
            UniversalRulesPolicyErrors.ArgPinMismatch.selector,
            "URP gate N7 (the argument pin)",
            "The contract enforces the rules as written. Pinning is the SDK's obligation - and this is what it buys.",
            req
        );

        DemoLog.header("", "What Act 4f proves");
        DemoLog.line(DemoLog.bold("The system enforces the rules exactly as written."));
        DemoLog.blank();
        DemoLog.line(DemoLog.dim("Writing bad rules is possible. The tooling that composes"));
        DemoLog.line(DemoLog.dim("rules is what prevents it - not the contract, which cannot"));
        DemoLog.line(DemoLog.dim("know which arguments matter to a user's intent."));
        DemoLog.blank();
        DemoLog.line(DemoLog.dim("What URP guarantees: whatever WAS written is enforced exactly,"));
        DemoLog.line(DemoLog.dim("every time, without ever trusting the agent."));
        DemoLog.footer();
    }

    function _title() private pure returns (string memory) {
        return string.concat(
            "approve(accomplice, ",
            DemoLog.formatAmount(Amounts.THROWAWAY_FUND, Amounts.DECIMALS, Amounts.SYMBOL),
            ") - under the rules that pin the spender"
        );
    }
}
