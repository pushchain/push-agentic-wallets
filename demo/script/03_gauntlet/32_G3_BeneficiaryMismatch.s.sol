// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { Gauntlet } from "../../lib/Gauntlet.sol";
import { AgentRequest } from "../../lib/AgentRequest.sol";
import { UniversalRulesPolicyErrors } from "../../../src/libraries/Errors.sol";
import { StakeDummy } from "../../contracts/StakeDummy.sol";

/**
 * @title  G3 — the agent stakes for itself
 * @notice ACT 3 · Chain: Donut · SIMULATION ONLY. Never broadcasts, changes no state.
 *
 * @dev    THE ATTEMPT: an Act 2 request — same contract, same allow-listed selector, well inside
 *         every cap — with ONE WORD changed. The beneficiary is the agent's own address instead of
 *         the CEA.
 *
 *         THE POINT, and this is the most product-defining check in the system: the beneficiary is
 *         pinned at GRANT time, one argument deep, at calldata offset 4. Gate 15 reads that word and
 *         compares it to `expectedCEA`.
 *
 *         Without it, every other gate still passes — the target is allow-listed, the selector is
 *         allow-listed, the amount is under both caps — and the agent quietly stakes Bob's capital
 *         into a position only the agent can unwind. Nothing would look wrong until Bob tried to
 *         withdraw.
 *
 *         THE AMOUNT IS TINY, ON PURPOSE. The caps (gates 6 and 7) are checked before the
 *         beneficiary pin (gate 15). After Act 2 has spent most of the lifetime budget, a full-size
 *         stake would die at gate 7 and never reach the pin. A tenth of a USDC fits the remaining budget
 *         before and after Act 2, so the beneficiary pin is the gate that fires either way.
 *
 *         THIS IS THE ONE TO SHOW IF THERE IS TIME FOR ONLY ONE.
 */
contract G3_BeneficiaryMismatch is Script {
    /// @dev A tenth of a USDC at full scale; scales with `DEMO_SCALE_PERCENT` like every other figure.
    uint256 internal constant FULL_UNIT = 0.1e6;

    function run() external {
        address agent = Keys.addressOf("AGENT_KEY", "the agent names itself as beneficiary");
        address stakeDummy = AddressBook.sepolia("StakeDummy");
        uint256 amount = (FULL_UNIT * Amounts.scale()) / 100;

        DemoLog.header("G3", "Stake for itself instead of for Bob");
        DemoLog.addrPlain("Agent names", agent);
        DemoLog.note("    ...itself as the beneficiary. Everything else is an allowed stake.");
        DemoLog.money("Amount", amount, 6, "USDC");
        DemoLog.note("    Small enough to fit every cap, so only the beneficiary can refuse it.");
        DemoLog.blank();

        AgentRequest.Built memory req =
            AgentRequest.single(amount, stakeDummy, abi.encodeCall(StakeDummy.stakeFor, (agent, amount)));

        Gauntlet.refuse(
            "stakeFor(agent) instead of stakeFor(cea)",
            UniversalRulesPolicyErrors.BeneficiaryMismatch.selector,
            "URP gate 15 (the beneficiary pin)",
            "Every other gate passes. Only the pinned beneficiary stops the agent staking Bob's capital for itself.",
            req
        );

        DemoLog.footer();
    }
}
