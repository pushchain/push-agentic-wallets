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
import { Keys } from "../../lib/Keys.sol";

/**
 * @title  G6_Impostor
 * @notice ACT 3 · G6 · Someone else sends the agent's exact request.
 *
 * @dev    THE ATTEMPT: Act 2's call, byte for byte, against live rules — from a different address.
 *
 *         THE POINT: possessing the agent's request is worthless. The agent door accepts exactly
 *         one sender, the address the rules name, and that check is the wallet's FIRST: it runs
 *         before the engine and before any policy. Copying calldata out of a block explorer gives
 *         an attacker nothing to submit.
 *
 *         REFUSED BY THE WALLET, UNWRAPPED. G1 and G2 die in the engine, G3-G5 and G7 die in URP
 *         and come back wrapped. This one never gets that far: `CallerIsNotAgent(rulesId, caller)`
 *         arrives bare, carrying the rules id and the address that tried.
 *
 *         WHAT ABOUT THE AGENT REPLAYING ITS OWN TRANSACTION? That is stopped by the agent
 *         account's transaction nonce, which belongs to the chain, not to these contracts. The
 *         wallet keeps no agent nonce at all.
 */
contract G6_Impostor is Script {
    function run() external {
        address impostor = Keys.addressOf("PC_RELAYER_KEY", "the impostor: a funded account the rules do not name");
        address agw = Ledger.addr("agw", "10_DeployWallet");
        bytes32 rulesId = Ledger.word("rulesId", "13_GrantRules");
        address stake = AddressBook.native("StakeDummy");

        // Act 2's request, rebuilt exactly as `20_Stake` builds it.
        NativeRequest.Built memory req = NativeRequest.build(
            agw, rulesId, stake, abi.encodeCall(StakeDummy.stakeFor, (agw, Amounts.ACT2)), Amounts.ACT2
        );

        DemoLog.header("G6", "Someone else sends the agent's request");

        NativeGauntlet.refuseAtWallet(
            "Act 2's exact call, sent from another account",
            impostor,
            "The impostor has the agent's exact request, byte for byte. Only the address the rules name may act.",
            req
        );
        DemoLog.note("Replaying the agent's own transaction is stopped by the agent account's nonce.");

        DemoLog.footer();
    }
}
