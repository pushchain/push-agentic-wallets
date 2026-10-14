// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";

import { StakeDummy } from "../../contracts/StakeDummy.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeGauntlet } from "../../lib/NativeGauntlet.sol";
import { NativeRequest } from "../../lib/NativeRequest.sol";

/**
 * @title  G1_WrongContract
 * @notice ACT 3 · G1 · The agent names a DIFFERENT contract.
 *
 * @dev    REFUSED BY THE ENGINE, NOT BY URP — and the script says so rather than implying a policy
 *         gate fired.
 *
 *         A native rules set binds `(target, selector)` into the engine's ACTION ID. Changing the
 *         target changes the id, the engine finds no action matching it, and the request dies with
 *         `NoPoliciesSet` before URP is ever called. That is a STRONGER guarantee than a policy
 *         check, not a weaker one: the policy never even has to have an opinion.
 *
 *         The simulated call is sent AS THE AGENT, under live rules, so the wallet's sender check
 *         passes and the request fails at the layer it claims to demonstrate.
 */
contract G1_WrongContract is Script {
    /// @dev The engine's own error. DERIVED from its signature, never pasted as a literal.
    bytes4 internal constant NO_POLICIES_SET = bytes4(keccak256("NoPoliciesSet(bytes32)"));

    function run() external {
        address agw = Ledger.addr("agw", "10_DeployWallet");
        bytes32 rulesId = Ledger.word("rulesId", "13_GrantRules");

        // DemoUSDC: a real contract the wallet has a legitimate relationship with — and not the
        // one the rules name.
        address wrongTarget = AddressBook.native("DemoUSDC");

        NativeRequest.Built memory req = NativeRequest.build(
            agw, rulesId, wrongTarget, abi.encodeCall(StakeDummy.stakeFor, (agw, Amounts.ACT2)), Amounts.ACT2
        );

        DemoLog.header("G1", "A different contract");

        NativeGauntlet.refuseRaw(
            "stakeFor() on DemoUSDC instead of StakeDummy",
            NO_POLICIES_SET,
            "the engine",
            "The rules name one contract. A different one is not a different permission - it is no permission at all.",
            req
        );

        DemoLog.footer();
    }
}
