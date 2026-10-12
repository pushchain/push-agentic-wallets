// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";
import { DemoLog } from "./DemoLog.sol";
import { IAGW } from "../../src/interfaces/IAGW.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";
import { ModeSlot, RulesType, VmFamily, SEND_OUTBOUND_SELECTOR } from "../../src/libraries/Types.sol";

/**
 * @title  RulesRead
 * @notice Reads back what the CONTRACTS decided about a rules set: its id, and its kind.
 *
 * @dev    NOBODY DECLARES A RULES SET'S KIND. There is no mode argument and no flag. The wallet and
 *         URP each derive NATIVE or UNIVERSAL, independently, from the chain string in the
 *         envelope; for a universal rules set URP also derives the destination VM family from the
 *         string's prefix.
 *
 *         So a script never prints a kind it computed. It prints the wallet's answer (the
 *         `RulesGranted` event) and URP's answer (`getMode`), and asserts the two agree.
 */
library RulesRead {
    /// @dev What the wallet emitted at grant.
    struct Granted {
        bytes32 rulesId;
        RulesType mode;
        string chainNamespace;
    }

    error RulesNotGranted();
    error DerivationDisagrees(RulesType walletSays, RulesType urpSays);
    error ModeSlotEmpty();

    /**
     * @notice Find `RulesGranted` in recorded logs.
     *
     * @dev    The id comes from the wallet's own event, never recomputed. `rulesId` and `chainHash`
     *         are indexed; `mode` and `chainNamespace` are the two non-indexed fields, in that order.
     */
    function granted(Vm.Log[] memory logs) internal pure returns (Granted memory g) {
        bytes32 topic = IAGW.RulesGranted.selector;

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length >= 2 && logs[i].topics[0] == topic) {
                g.rulesId = logs[i].topics[1];
                (g.mode, g.chainNamespace) = abi.decode(logs[i].data, (RulesType, string));
                return g;
            }
        }
        revert RulesNotGranted();
    }

    /**
     * @notice The key for every URP read of a universal rules set.
     *
     * @dev    `configId = keccak(wallet ‖ keccak(rulesId ‖ actionId))`, where
     *         `actionId = keccak(target ‖ selector)` and a universal rules set's one action is the
     *         gateway's outbound send. THE ORDER MATTERS AT EVERY LEVEL, and every level is
     *         `encodePacked`. The gateway is read from the wallet, which is what the wallet itself
     *         compares against.
     */
    function universalConfigId(address wallet, bytes32 rulesId) internal view returns (ConfigId) {
        bytes32 actionId = keccak256(abi.encodePacked(IAGW(wallet).UNIVERSAL_GATEWAY_PC(), SEND_OUTBOUND_SELECTOR));
        return ConfigId.wrap(keccak256(abi.encodePacked(wallet, keccak256(abi.encodePacked(rulesId, actionId)))));
    }

    /// @notice The derived kind, as URP stores it: `NATIVE`, `UNIVERSAL (EVM)` or `UNIVERSAL (SVM)`.
    function kind(ModeSlot memory slot) internal pure returns (string memory) {
        if (!slot.initialized) revert ModeSlotEmpty();
        if (slot.mode == RulesType.NATIVE) return "NATIVE";
        return slot.vm == VmFamily.SVM ? "UNIVERSAL (SVM)" : "UNIVERSAL (EVM)";
    }

    /**
     * @notice Print `chain "<string>" -> derived <KIND>`, with both halves read from the contracts.
     * @param  g    The wallet's `RulesGranted` fields.
     * @param  slot URP's `getMode` for the same rules set.
     */
    function printDerivation(Granted memory g, ModeSlot memory slot) internal view {
        if (!slot.initialized) revert ModeSlotEmpty();
        if (g.mode != slot.mode) revert DerivationDisagrees(g.mode, slot.mode);

        DemoLog.kv("Kind", string.concat("chain \"", g.chainNamespace, "\" -> derived ", DemoLog.bold(kind(slot))));
        DemoLog.note("    Nobody declared that. The wallet and URP each derived it from the chain string.");
    }
}
