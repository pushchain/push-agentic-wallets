// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { Gauntlet } from "../../lib/Gauntlet.sol";
import { AgentRequest } from "../../lib/AgentRequest.sol";
import { UniversalRulesPolicyErrors } from "../../../src/libraries/Errors.sol";
import { StakeDummy } from "../../contracts/StakeDummy.sol";

/**
 * @title  G4 — over the per-action cap
 * @notice ACT 3 · Chain: Donut · SIMULATION ONLY. Never broadcasts, changes no state.
 *
 * @dev    THE ATTEMPT: a stake for the right beneficiary, through the right function, for 20% more
 *         than one action may move.
 *
 *         THE POINT: each listed token carries its own per-action ceiling, and gate 6 compares the
 *         request's amount against the ceiling of the token it names. A compromised agent's worst
 *         single action is bounded by a number the owner chose.
 */
contract G4_PerCallCap is Script {
    function run() external {
        address cea = Ledger.addr("predictedCEA", "10_Arrive");
        address stakeDummy = AddressBook.sepolia("StakeDummy");

        uint256 tooMuch = Amounts.perCall() + Amounts.perCall() / 5;

        DemoLog.header("G4", "Over the per-action cap");
        DemoLog.money("Rules allow", Amounts.perCall(), 6, "USDC");
        DemoLog.money("Agent requests", tooMuch, 6, "USDC");
        DemoLog.blank();

        AgentRequest.Built memory req =
            AgentRequest.single(tooMuch, stakeDummy, abi.encodeCall(StakeDummy.stakeFor, (cea, tooMuch)));

        Gauntlet.refuse(
            "stake more than one action permits",
            UniversalRulesPolicyErrors.AmountExceedsCap.selector,
            "URP gate 6 (this token's per-action cap)",
            "A per-action ceiling turns a compromised agent into a bounded loss.",
            req
        );

        DemoLog.footer();
    }
}
