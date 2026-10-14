// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { Gauntlet } from "../../lib/Gauntlet.sol";
import { AgentRequest } from "../../lib/AgentRequest.sol";
import { Requests } from "../../lib/Requests.sol";
import { UniversalRulesPolicyErrors } from "../../../src/libraries/Errors.sol";
import { StakeDummy } from "../../contracts/StakeDummy.sol";

/**
 * @title  G7 — a token the rules do not list
 * @notice ACT 3 · Chain: Donut · SIMULATION ONLY. Never broadcasts, changes no state.
 *
 * @dev    THE ATTEMPT: the Act 2 stake call, but the outbound request names a different token —
 *         pETH, Sepolia's gas-token PRC20 — and moves NONE of it. The amount is zero.
 *
 *         THE POINT: rules list the tokens they cover, one to eight of them, each with its own
 *         caps. Gate 5 requires the request's token to be on that list ON EVERY REQUEST, a
 *         zero-amount one included. The gateway routes by the token, so the token is also what
 *         chooses the destination chain; an unlisted token is an unlisted route.
 *
 *         pETH IS A REAL, SEPOLIA-BOUND TOKEN. It would be a perfectly valid thing to list. These
 *         rules simply did not list it.
 */
contract G7_UnlistedToken is Script {
    function run() external {
        address cea = Ledger.addr("predictedCEA", "10_Arrive");
        address stakeDummy = AddressBook.sepolia("StakeDummy");
        address unlisted = AddressBook.donut("PRC20_PETH");

        DemoLog.header("G7", "A token the rules do not list");
        DemoLog.kv("Rules list", IERC20Metadata(AddressBook.donut("PRC20_USDC")).symbol());
        DemoLog.kv("Request names", IERC20Metadata(unlisted).symbol());
        DemoLog.kv("Amount", "0 - nothing would even move");
        DemoLog.blank();

        AgentRequest.Built memory req = AgentRequest.buildWithToken(
            unlisted, 0, Requests.singleCall(stakeDummy, abi.encodeCall(StakeDummy.stakeFor, (cea, Amounts.perCall())))
        );

        Gauntlet.refuse(
            "the same stake call, routed with an unlisted token",
            UniversalRulesPolicyErrors.AssetNotAllowed.selector,
            "URP gate 5 (the token list)",
            "The token picks the route. Rules that list one token cover one token, at any amount, zero included.",
            req
        );

        DemoLog.footer();
    }
}
