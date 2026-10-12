// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { Session } from "smartsessions/DataTypes.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

import { IAGW } from "../../../src/interfaces/IAGW.sol";
import { IUniversalRulesPolicy } from "../../../src/interfaces/IUniversalRulesPolicy.sol";
import { AGWErrors } from "../../../src/libraries/Errors.sol";
import { RulesType } from "../../../src/libraries/Types.sol";
import { StakeDummy } from "../../contracts/StakeDummy.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeRules } from "../../lib/NativeRules.sol";

/**
 * @title  D1_ChainDecides
 * @notice ACT 3 · D1 · SIMULATION ONLY, sent as Bob. The chain string, not a flag, decides the kind.
 *
 * @dev    THE ATTEMPT: Bob grants the SAME stake rules he granted in Act 1d — same agent, same
 *         contract, same function, same pin, same caps — with ONE thing changed. The chain string
 *         in the envelope is spelled `EIP155:<id>` instead of `eip155:<id>`.
 *
 *         THE POINT: nobody tells the contracts that rules are Push-native. There is no mode
 *         argument and no flag anywhere. The wallet and URP each compare the hash of the chain
 *         string against the hash of this chain's own CAIP-2 string, byte for byte:
 *
 *             equal      -> NATIVE     a Push-side call, 1..8 actions, never the gateway
 *             different  -> UNIVERSAL  a cross-chain rules set: exactly one action, the gateway
 *
 *         The string is never parsed, normalised or case-folded. So a near miss is not "almost
 *         native" — it is a cross-chain rules set, whose one action must be the gateway's outbound
 *         send. This one names StakeDummy, so the wallet refuses the grant with
 *         `RulesTypeMismatch(UNIVERSAL, 0, StakeDummy)`: derived kind, action index, offending
 *         target.
 *
 *         NOTHING IS BROADCAST AND NOTHING IS GRANTED. The call is simulated from Bob's address,
 *         because only the owner reaches the grant logic at all.
 */
contract D1_ChainDecides is Script {
    error ExpectedRefusalButSucceeded();
    error WrongRefusal(bytes4 expected, bytes4 actual);
    error WrongRefusalArguments(RulesType mode, uint256 index, address target);

    function run() external {
        address bob = Keys.addressOf("BOB_KEY", "Bob, the only account that can reach the grant logic");
        address agent = Keys.addressOf("AGENT_KEY", "the same agent as Act 1d");
        address agw = Ledger.addr("agw", "10_DeployWallet");
        address stake = AddressBook.native("StakeDummy");

        // Both strings are built from the live chain id; only the prefix's case differs.
        string memory thisChain = NativeRules.thisChain();
        string memory nearMiss = string.concat("EIP155:", Strings.toString(block.chainid));
        bytes32 pushChainHash = IUniversalRulesPolicy(IAGW(agw).RULES_POLICY()).pushChainHash();

        DemoLog.header("D1", "The chain string decides - not a flag");
        DemoLog.kv("This chain", string.concat("\"", thisChain, "\""));
        DemoLog.kv("  keccak", vm.toString(keccak256(bytes(thisChain))));
        DemoLog.kv("URP pushChainHash", vm.toString(pushChainHash));
        DemoLog.note("    Equal: this is the string Act 1d used, and the contracts derived NATIVE.");
        DemoLog.blank();
        DemoLog.kv("Near miss", string.concat("\"", nearMiss, "\""));
        DemoLog.kv("  keccak", vm.toString(keccak256(bytes(nearMiss))));
        DemoLog.note("    Not equal. One character's case differs, so the hash does.");
        DemoLog.blank();

        Session memory session = NativeRules.stakeSessionOn(nearMiss, agent, agw, stake, StakeDummy.stakeFor.selector);

        DemoLog.kv("Attempt", "grant the Act 1d stake rules, with the near-miss chain string");
        DemoLog.addrPlain("Sent by", bob);
        DemoLog.blank();

        vm.prank(bob);
        (bool ok, bytes memory ret) = agw.call(abi.encodeCall(IAGW.grantRules, (session)));
        if (ok) revert ExpectedRefusalButSucceeded();

        bytes4 sel = bytes4(ret);
        if (sel != AGWErrors.RulesTypeMismatch.selector) {
            revert WrongRefusal(AGWErrors.RulesTypeMismatch.selector, sel);
        }

        (RulesType mode, uint256 index, address target) = abi.decode(_body(ret), (RulesType, uint256, address));
        if (mode != RulesType.UNIVERSAL || index != 0 || target != stake) {
            revert WrongRefusalArguments(mode, index, target);
        }

        DemoLog.ok("the wallet", "refused the grant - nothing was stored, no policy was configured");
        DemoLog.refused("RulesTypeMismatch", "refused by the wallet, at grant");
        DemoLog.kv("  observed", string.concat(vm.toString(abi.encodePacked(sel)), "  (unwrapped)"));
        DemoLog.kv("  derived kind", "UNIVERSAL");
        DemoLog.kv("  action index", vm.toString(index));
        DemoLog.kv("  target", vm.toString(target));
        DemoLog.blank();
        DemoLog.note("Nobody tells the contracts this is a Push-native rule. The wallet and URP each");
        DemoLog.note(string.concat("work it out from the chain string. ", thisChain, " is this chain, so NATIVE."));
        DemoLog.note("One character off, and it is a cross-chain rule that may only target the");
        DemoLog.note("gateway, so this grant is refused.");
        DemoLog.footer();
    }

    function _body(bytes memory ret) private pure returns (bytes memory out) {
        out = new bytes(ret.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = ret[4 + i];
        }
    }
}
