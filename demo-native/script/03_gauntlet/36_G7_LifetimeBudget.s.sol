// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";

import { IAGW } from "../../../src/interfaces/IAGW.sol";
import { IUniversalRulesPolicy } from "../../../src/interfaces/IUniversalRulesPolicy.sol";
import { NativeConfig } from "../../../src/libraries/Types.sol";
import { UniversalRulesPolicyErrors } from "../../../src/libraries/Errors.sol";
import { StakeDummy } from "../../contracts/StakeDummy.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeGauntlet } from "../../lib/NativeGauntlet.sol";
import { NativeRequest } from "../../lib/NativeRequest.sol";
import { NativeIds } from "../../lib/NativeIds.sol";

/**
 * @title  G7_LifetimeBudget
 * @notice ACT 3 · G7 · The budget, exhausted by the run itself.
 *
 * @dev    THE NATURAL END OF ACT 3, and the only gauntlet entry that is not a mutation. Acts 2, 3b
 *         and 3c stake 2.5 + 2.5 + 1 = 6, which is the whole lifetime budget. This asks for one
 *         more unit of anything and is refused.
 *
 *         That makes it the most honest refusal in the demo: nothing was tampered with. The agent
 *         simply ran out of what it was given.
 *
 *         IT ASSERTS ITS PRECONDITION FIRST. If the budget is not actually exhausted, this script
 *         fails with a sentence saying so, rather than submitting a request that would SUCCEED and
 *         quietly spend Bob's money mid-demo. An out-of-order rehearsal must fail on the first line,
 *         not the last.
 *
 *         WHY THE CALL CEILING (N9) IS NOT DEMONSTRATED HERE. N8 runs before N9, so a rules set
 *         cannot show both its lifetime cap and its call cap: reaching four calls means the budget
 *         never ran out, and exhausting the budget takes only three. G8 therefore lives on the
 *         unstake rules set, whose `maxCalls` is 1. See `04_boundary/42_G8_SecondUnstakeFails`.
 */
contract G7_LifetimeBudget is Script {
    error BudgetNotExhausted(uint256 spent, uint256 cap);

    function run() external {
        address agw = Ledger.addr("agw", "10_DeployWallet");
        bytes32 rulesId = Ledger.word("rulesId", "13_GrantRules");
        address stake = AddressBook.native("StakeDummy");
        bytes4 selector = StakeDummy.stakeFor.selector;

        ConfigId configId = NativeIds.configId(rulesId, agw, stake, selector);
        NativeConfig memory cfg = IUniversalRulesPolicy(IAGW(agw).RULES_POLICY()).getNativeConfig(configId, agw);

        // PRECONDITION, NAMED. Run before the budget is spent, this request FITS and would succeed
        // in simulation - so the script would report a passing attack.
        if (cfg.amountSpent + Amounts.G7_OVER_TOTAL <= cfg.amount.maxTotal) {
            revert BudgetNotExhausted(cfg.amountSpent, cfg.amount.maxTotal);
        }

        NativeRequest.Built memory req = NativeRequest.build(
            agw,
            rulesId,
            stake,
            abi.encodeCall(StakeDummy.stakeFor, (agw, Amounts.G7_OVER_TOTAL)),
            Amounts.G7_OVER_TOTAL
        );

        DemoLog.header("G7", "The budget runs out");
        DemoLog.money("Lifetime cap", cfg.amount.maxTotal, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("Already spent", cfg.amountSpent, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("Now requesting", Amounts.G7_OVER_TOTAL, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.kv(
            "Calls used", string.concat(vm.toString(uint256(cfg.callsUsed)), " of ", vm.toString(uint256(cfg.maxCalls)))
        );
        DemoLog.note("    Note: the budget ran out before the call ceiling did.");
        DemoLog.blank();

        NativeGauntlet.refuseGate(
            "one more stake, with the lifetime budget already spent",
            UniversalRulesPolicyErrors.TotalNativeAmountExceeded.selector,
            "URP gate N8 (the lifetime amount cap)",
            "Nothing was tampered with here. The agent simply ran out of what it was given - which is how rules are supposed to end.",
            req
        );

        DemoLog.footer();
    }
}
