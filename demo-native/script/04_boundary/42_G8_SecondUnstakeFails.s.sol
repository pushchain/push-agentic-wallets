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
import { DemoLog } from "../../lib/DemoLog.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeGauntlet } from "../../lib/NativeGauntlet.sol";
import { NativeIds } from "../../lib/NativeIds.sol";
import { NativeRequest } from "../../lib/NativeRequest.sol";

/**
 * @title  G8_SecondUnstakeFails
 * @notice ACT 4 · G8 · The call ceiling. A second `unstake()` under a one-call rules set.
 *
 * @dev    WHY THIS LIVES ON THE UNSTAKE RULES RATHER THAN WITH G1-G7. Gate N8 (amount) runs
 *         before gate N9 (calls), so ONE rules cannot demonstrate both its lifetime budget and
 *         its call ceiling: reaching four calls means the budget never ran out, and exhausting the
 *         budget takes only three. The stake rules set shows the budget (G7); the unstake rules set,
 *         with `maxCalls = 1`, shows the ceiling.
 *
 *         IT ALSO FIRES BEFORE DISPATCH, WHICH IS THE POINT. The wallet's stake is already zero
 *         after Act 4a, so a second `unstake()` would revert inside `StakeDummy` with
 *         `NothingStaked()` — an error about the counterparty's state, not about permissions.
 *         `maxCalls = 1` means URP refuses it at N9 first, so the refusal is about the RULES.
 *         That distinction is the whole reason the cap is one.
 */
contract G8_SecondUnstakeFails is Script {
    error CallCeilingNotReached(uint32 used, uint32 max);

    function run() external {
        address agw = Ledger.addr("agw", "10_DeployWallet");
        bytes32 rulesId = Ledger.word("unstakeRulesId", "40_GrantUnstake");
        address stake = AddressBook.native("StakeDummy");
        bytes4 selector = StakeDummy.unstake.selector;

        ConfigId configId = NativeIds.configId(rulesId, agw, stake, selector);
        NativeConfig memory cfg = IUniversalRulesPolicy(IAGW(agw).RULES_POLICY()).getNativeConfig(configId, agw);

        // PRECONDITION, NAMED. Before Act 4a has used the one call, this request would succeed.
        if (cfg.callsUsed < cfg.maxCalls) revert CallCeilingNotReached(cfg.callsUsed, cfg.maxCalls);

        NativeRequest.Built memory req =
            NativeRequest.build(agw, rulesId, stake, abi.encodeCall(StakeDummy.unstake, ()), 0);

        DemoLog.header("G8", "One call too many");
        DemoLog.kv("Calls allowed", vm.toString(uint256(cfg.maxCalls)));
        DemoLog.kv("Calls used", vm.toString(uint256(cfg.callsUsed)));
        DemoLog.blank();

        NativeGauntlet.refuseGate(
            "a second unstake(), under one-call rules",
            UniversalRulesPolicyErrors.CallLimitReached.selector,
            "URP gate N9 (the call limit)",
            "Refused at validation - so StakeDummy's own NothingStaked() never gets the chance. The refusal is about the rules, not the counterparty.",
            req
        );

        DemoLog.footer();
    }
}
