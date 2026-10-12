// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";

import { StakeDummy } from "../../contracts/StakeDummy.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeGauntlet } from "../../lib/NativeGauntlet.sol";
import { NativeRequest } from "../../lib/NativeRequest.sol";

/**
 * @title  G2_WrongFunction
 * @notice ACT 3 · G2 · The RIGHT contract, the WRONG function.
 *
 * @dev    The mirror of G1, and the pair is worth running together: G1 changes the target, G2
 *         changes the selector, and BOTH die at the engine — because the action id is derived from
 *         the two together.
 *
 *         `unstake()` is a real function on the right contract, and at this point in the demo the
 *         wallet genuinely has a stake to withdraw. It is still refused, because THIS rules set does
 *         not name it. Act 4a grants a separate rules that does — which is the cleanest way to
 *         show that a rules set is a list of permissions, not a relationship of trust.
 */
contract G2_WrongFunction is Script {
    bytes4 internal constant NO_POLICIES_SET = bytes4(keccak256("NoPoliciesSet(bytes32)"));

    function run() external {
        address agw = Ledger.addr("agw", "10_DeployWallet");
        bytes32 rulesId = Ledger.word("rulesId", "13_GrantRules");
        address stake = AddressBook.native("StakeDummy");

        NativeRequest.Built memory req =
            NativeRequest.build(agw, rulesId, stake, abi.encodeCall(StakeDummy.unstake, ()), 0);

        DemoLog.header("G2", "A different function");

        NativeGauntlet.refuseRaw(
            "unstake() on StakeDummy - the right contract, the wrong function",
            NO_POLICIES_SET,
            "the engine",
            "The wallet really does have a stake to withdraw. The rules simply never authorised withdrawing it.",
            req
        );

        DemoLog.footer();
    }
}
