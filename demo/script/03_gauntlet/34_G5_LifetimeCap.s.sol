// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { Gauntlet } from "../../lib/Gauntlet.sol";
import { AgentRequest } from "../../lib/AgentRequest.sol";
import { RulesRead } from "../../lib/RulesRead.sol";
import { IAGW } from "../../../src/interfaces/IAGW.sol";
import { IUniversalRulesPolicy } from "../../../src/interfaces/IUniversalRulesPolicy.sol";
import { AssetCapState } from "../../../src/libraries/Types.sol";
import { UniversalRulesPolicyErrors } from "../../../src/libraries/Errors.sol";
import { StakeDummy } from "../../contracts/StakeDummy.sol";

/**
 * @title  G5 — the lifetime budget is exhausted
 * @notice ACT 3 · Chain: Donut · SIMULATION ONLY. RUN AFTER ACT 2 — it depends on Act 2 having spent.
 *
 * @dev    THE ATTEMPT: a second stake, individually under the per-action ceiling. G4 was refused
 *         for being too big; this one is exactly the size Act 2 already spent, and is refused
 *         anyway.
 *
 *         THE POINT: the budget is CUMULATIVE and survives across requests. A per-action cap alone
 *         would let an agent drain a wallet in slices. The lifetime cap is what bounds total
 *         exposure rather than per-transaction exposure. It is kept per token.
 *
 *         WHY IT MUST RUN AFTER ACT 2, AND WHY THAT IS ASSERTED. `spent` is real on-chain state; a
 *         simulation reads it but cannot create it. Run before Act 2 has broadcast, this request
 *         fits inside the budget and SUCCEEDS in simulation — so the script would report a passing
 *         attack. The precondition check below turns that into a clear message naming Act 2 rather
 *         than a confusing revert-selector mismatch.
 */
contract G5_LifetimeCap is Script {
    error ActTwoHasNotRun(uint256 spent);

    function run() external {
        address cea = Ledger.addr("predictedCEA", "10_Arrive");
        address agw = Ledger.addr("agw", "10_Arrive");
        address stakeDummy = AddressBook.sepolia("StakeDummy");

        uint256 amount = Amounts.perCall();

        DemoLog.header("G5", "The lifetime budget is spent");

        AssetCapState memory usdc = IUniversalRulesPolicy(IAGW(agw).RULES_POLICY())
        .getConfig(RulesRead.universalConfigId(agw, Ledger.word("rulesId", "14_GrantRules")), agw)
        .assets[0];

        // The precondition, named. Without Act 2's spend this request FITS and would succeed.
        if (usdc.spent == 0) revert ActTwoHasNotRun(usdc.spent);

        DemoLog.money("Already spent", usdc.spent, 6, "USDC");
        DemoLog.money("Lifetime cap", usdc.maxTotal, 6, "USDC");
        DemoLog.money("This request", amount, 6, "USDC");
        DemoLog.note("    Under the per-action cap. Over the lifetime budget.");
        DemoLog.blank();

        AgentRequest.Built memory req =
            AgentRequest.single(amount, stakeDummy, abi.encodeCall(StakeDummy.stakeFor, (cea, amount)));

        Gauntlet.refuse(
            "a second stake, within the per-action cap",
            UniversalRulesPolicyErrors.TotalSpendCapExceeded.selector,
            "URP gate 7 (this token's lifetime cap)",
            "A per-action cap alone would let an agent drain a wallet in slices. This bounds the total.",
            req
        );

        DemoLog.footer();
    }
}
