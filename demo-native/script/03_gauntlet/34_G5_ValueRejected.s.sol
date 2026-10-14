// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";

import { UniversalRulesPolicyErrors } from "../../../src/libraries/Errors.sol";
import { StakeDummy } from "../../contracts/StakeDummy.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeGauntlet } from "../../lib/NativeGauntlet.sol";
import { NativeRequest } from "../../lib/NativeRequest.sol";

/**
 * @title  G5_ValueRejected
 * @notice ACT 3 · G5 · A request carrying native PC, against a cap of ZERO.
 *
 * @dev    ONE WEI. The rules' `maxValuePerCall` is 0, so any non-zero value is refused, and one
 *         wei makes that unmistakable.
 *
 *         WHY THE CAP IS ZERO AND NOT "SOMETHING SAFE". `stakeFor` is not payable and this rules
 *         never needs to move native PC, so zero is the HONEST ceiling. Setting it to some small
 *         non-zero value "just in case" would make this gauntlet entry contrived — it would prove
 *         only that a made-up limit works. A cap of zero proves the rules carry no value at
 *         all, which is a property of the grant rather than a number someone picked.
 *
 *         Gate N6. Note that value is checked BEFORE the argument pins (N7) and the amount (N8),
 *         so this request never gets as far as having its beneficiary inspected.
 */
contract G5_ValueRejected is Script {
    function run() external {
        address agw = Ledger.addr("agw", "10_DeployWallet");
        bytes32 rulesId = Ledger.word("rulesId", "13_GrantRules");
        address stake = AddressBook.native("StakeDummy");

        // Act 2's request, plus one wei of native value. The value travels inside the execution
        // calldata and would come from the WALLET; the agent door itself is not payable.
        NativeRequest.Built memory req = NativeRequest.buildWithValue(
            agw,
            rulesId,
            stake,
            abi.encodeCall(StakeDummy.stakeFor, (agw, Amounts.ACT2)),
            Amounts.ACT2,
            Amounts.G5_VALUE
        );

        DemoLog.header("G5", "Native value, where none is allowed");
        DemoLog.kv("Cap", "0 wei");
        DemoLog.kv("Requested", "1 wei");
        DemoLog.note("    The rules authorise no native value at all - not 'a little'.");
        DemoLog.blank();

        NativeGauntlet.refuseGate(
            "a request carrying 1 wei of PC",
            UniversalRulesPolicyErrors.ValueExceedsCap.selector,
            "URP gate N6 (the native-value cap)",
            "Rules that never need to move native value should permit none. Zero is a real ceiling, not a placeholder.",
            req
        );

        DemoLog.footer();
    }
}
