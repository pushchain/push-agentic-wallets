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
 * @title  Reset
 * @notice RESET · Revoke every rules set and sweep every wallet back to Bob.
 *
 * @dev    THE REHEARSAL'S UNDO. Run it after any run — complete or abandoned — so the next
 *         rehearsal starts from a known state.
 *
 *         IT SWEEPS THE THROWAWAY WALLET, and that is the part worth having. A run abandoned
 *         part-way through Act 4f leaves 2 dUSDC in a wallet nobody looks at again; over several
 *         rehearsals that is how a token balance quietly disappears and a later preflight fails for
 *         reasons nobody can reconstruct.
 *
 *         EVERY STEP IS OPTIONAL AND GUARDED. Reset must work on a half-finished run, which is the
 *         only kind of run that needs it.
 *
 *         IT DOES NOT CLEAR THE LEDGER. The wallets keep their addresses, and their revoked rules
 *         ids stay recorded so `just state` can still show them. The script says so on screen.
 */
contract Reset is Script {
    function run() external {
        uint256 bobPk = Keys.load("BOB_KEY", "only the owner may revoke and sweep");
        address bob = vm.addr(bobPk);
        IERC20 token = IERC20(AddressBook.native("DemoUSDC"));

        DemoLog.header("RESET", "Back to a known state");

        _sweep(bobPk, bob, token, "agw", "10_DeployWallet");
        _sweep(bobPk, bob, token, "throwawayAgw", "47_Throwaway_DeployAndFund");

        DemoLog.blank();
        DemoLog.note("THE LEDGER IS NOT CLEARED. It still names these wallets and their rules ids,");
        DemoLog.note("all now revoked. Delete demo-native/state/ledger.json to start a fresh run.");
        DemoLog.footer();
    }

    /// @dev Revoke everything on one wallet, then move its dUSDC back to Bob through the owner door.
    function _sweep(uint256 bobPk, address bob, IERC20 token, string memory key, string memory writtenBy) private {
        if (!Ledger.has(key)) return;

        address wallet = Ledger.addr(key, writtenBy);
        uint256 held = token.balanceOf(wallet);
        uint64 checkpointsBefore = IAGW(wallet).checkpointCount();

        vm.startBroadcast(bobPk);
        // `revokeAllRules` cannot fail and is a no-op when nothing is live, so it is always safe.
        IAGW(wallet).revokeAllRules();
        if (held > 0) OwnerDoor.call(wallet, address(token), abi.encodeCall(IERC20.transfer, (bob, held)));
        vm.stopBroadcast();

        DemoLog.addrPlain(key, wallet);
        DemoLog.ok("  rules", "revoked");
        DemoLog.money("  swept back", held, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.kv(
            "  checkpoints",
            string.concat(
                vm.toString(uint256(checkpointsBefore)), " -> ", vm.toString(uint256(IAGW(wallet).checkpointCount()))
            )
        );
        DemoLog.note("      one per revoked rules set, plus one for the sweep");

        require(token.balanceOf(wallet) == 0, "sweep did not empty the wallet");
    }
}
