// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAGW } from "../../../src/interfaces/IAGW.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { OwnerDoor } from "../../lib/OwnerDoor.sol";

/**
 * @title  OwnerWithdraw
 * @notice ACT 4c · Bob takes everything back, instantly, through the owner door.
 *
 * @dev    THE ANSWER TO "WHAT IF SOMETHING GOES WRONG". Bob does not need the agent's cooperation,
 *         the engine's permission, or any rules to be in any particular state. He owns the wallet.
 *
 *         THE OWNER DOOR CONSULTS EXACTLY TWO THINGS: the immutable-args owner, and the calldata.
 *         No module, no policy, no engine state, no flag. It would work with the session engine
 *         uninstalled, with a hostile validator installed, or with ghost rules in storage. That
 *         is a deliberate, load-bearing property of the architecture — and this act is what makes
 *         it visible rather than merely documented.
 *
 *         Contrast with 4b, one act earlier: the same token, the same function, the same amount —
 *         refused for the agent, instant for Bob. The difference is not the request. It is who is
 *         asking.
 */
contract OwnerWithdraw is Script {
    function run() external {
        uint256 bobPk = Keys.load("BOB_KEY", "Bob withdraws his own funds");
        address bob = vm.addr(bobPk);
        address agw = Ledger.addr("agw", "10_DeployWallet");
        IERC20 token = IERC20(AddressBook.native("DemoUSDC"));

        uint256 walletBefore = token.balanceOf(agw);
        uint256 bobBefore = token.balanceOf(bob);
        uint64 checkpointsBefore = IAGW(agw).checkpointCount();

        vm.startBroadcast(bobPk);
        OwnerDoor.call(agw, address(token), abi.encodeCall(IERC20.transfer, (bob, walletBefore)));
        vm.stopBroadcast();

        uint256 walletAfter = token.balanceOf(agw);
        uint256 bobAfter = token.balanceOf(bob);
        uint64 checkpointsAfter = IAGW(agw).checkpointCount();

        DemoLog.header("ACT 4c", "Bob takes it back");
        DemoLog.money("Wallet, before", walletBefore, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("Wallet, after", walletAfter, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.blank();
        DemoLog.money("Bob, before", bobBefore, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("Bob, after", bobAfter, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.blank();
        DemoLog.ok("instant", "no rules consulted, no policy in the path");
        DemoLog.kv(
            "Checkpoints",
            string.concat(vm.toString(uint256(checkpointsBefore)), " -> ", vm.toString(uint256(checkpointsAfter)))
        );
        DemoLog.note("    The owner acted, so the counter moved by one.");
        DemoLog.line(DemoLog.dim("The same token, the same function, the same amount the agent"));
        DemoLog.line(DemoLog.dim("was refused one act ago. The difference is who is asking."));
        DemoLog.footer();

        require(walletAfter == 0, "the wallet was not emptied");
        require(bobAfter == bobBefore + walletBefore, "Bob did not receive the funds");
        require(checkpointsAfter == checkpointsBefore + 1, "an owner-door call must add one checkpoint");
    }
}
