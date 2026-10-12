// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { AddressBook } from "./AddressBook.sol";
import { DemoLog } from "./DemoLog.sol";
import { Keys } from "./Keys.sol";
import { Ledger } from "./Ledger.sol";
import { RulesRead } from "./RulesRead.sol";
import { IAGW } from "../../src/interfaces/IAGW.sol";
import { IUniversalRulesPolicy } from "../../src/interfaces/IUniversalRulesPolicy.sol";
import { Config, AssetCapState, AllowedCall, ModeSlot } from "../../src/libraries/Types.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";

interface IEngineState {
    function isPermissionEnabled(bytes32 rulesId, address account) external view returns (bool);
}

interface IStakeState {
    function totalBalance(address) external view returns (uint256);
}

/**
 * @title  Inspect
 * @notice Shared state reads for the three `05_inspect` scripts.
 *
 * @dev    RUN BETWEEN EVERY ACT. These are what make a terminal demo legible: without them the
 *         audience sees transactions succeed and has to take the consequences on trust.
 *
 *         THE REMAINING-BUDGET LINE IS THE ONE THAT MATTERS. Watching `spent 5.00 / 6.00 · 1.00
 *         remaining` move is how the rules stop being an abstraction — it is the moment the
 *         audience feels a limit being consumed rather than hearing one described.
 *
 *         Everything here is a pure read. Nothing broadcasts, nothing writes the ledger.
 */
library Inspect {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // ────────────────────────────────── Push side ──────────────────────────────────

    /// @dev The chain every rules set in this demo is granted with. Printed only after its hash
    ///      is checked against what URP stored.
    string internal constant RULES_CHAIN = "eip155:11155111";

    /// @notice The wallet: its label, what it holds, and how often its owner has acted on it.
    function pushState() internal view {
        address agw = Ledger.addr("agw", "10_Arrive");
        address uea = Ledger.addr("uea", "10_Arrive");
        address agent = Keys.addressOf("AGENT_KEY", "the agent");
        IERC20 prc20 = IERC20(AddressBook.donut("PRC20_USDC"));

        DemoLog.line(DemoLog.bold("Push Chain"));
        DemoLog.addrPlain("Wallet", agw);
        if (agw.code.length == 0) {
            DemoLog.kv("  status", DemoLog.dim("not deployed yet - act1b deploys it"));
        } else {
            DemoLog.kv("  label", IAGW(agw).label());
            DemoLog.kv("  owner", vm.toString(IAGW(agw).owner()));
            DemoLog.money("  holds", prc20.balanceOf(agw), 6, "pUSDC");
            DemoLog.money("  gas", agw.balance, 18, "PC");
            DemoLog.kv(
                "  checkpoints",
                string.concat(
                    vm.toString(uint256(IAGW(agw).checkpointCount())),
                    "  (last at block ",
                    vm.toString(uint256(IAGW(agw).lastCheckpointBlock())),
                    ")"
                )
            );
            DemoLog.note("    Moves on every owner action, never on an agent action.");
        }
        DemoLog.blank();
        DemoLog.addrPlain("Bob (UEA)", uea);
        DemoLog.money("  holds", prc20.balanceOf(uea), 6, "pUSDC");
        DemoLog.blank();
        DemoLog.addrPlain("Agent", agent);
        DemoLog.money("  holds", prc20.balanceOf(agent), 6, "pUSDC");
        DemoLog.money("  gas", agent.balance, 18, "PC");
        DemoLog.note("    A little PC for its own transactions. Never tokens.");
    }

    /// @notice The rules, rendered readably — kind, agent, per-asset caps and spend, allow-list.
    function rules() internal view {
        if (!Ledger.has("rulesId")) {
            DemoLog.kv("Rules", DemoLog.dim("not granted yet"));
            return;
        }

        address agw = Ledger.addr("agw", "10_Arrive");
        bytes32 rulesId = Ledger.word("rulesId", "14_GrantRules");
        ConfigId id = RulesRead.universalConfigId(agw, rulesId);
        IUniversalRulesPolicy urp = IUniversalRulesPolicy(IAGW(agw).RULES_POLICY());

        bool live = IEngineState(IAGW(agw).SESSION_ENGINE()).isPermissionEnabled(rulesId, agw);

        DemoLog.line(DemoLog.bold("The rules"));
        DemoLog.kv("Rules id", vm.toString(rulesId));
        DemoLog.kv("Status", live ? DemoLog.green("live") : DemoLog.red("revoked"));
        DemoLog.kv("Agent", vm.toString(IAGW(agw).agentOf(rulesId)));
        if (!live) {
            DemoLog.note("    Revoked rules have no agent: the wallet refuses every caller.");
            return;
        }

        ModeSlot memory slot = urp.getMode(id, agw);
        DemoLog.kv("Kind", string.concat(RulesRead.kind(slot), "  on ", _chainLabel(slot.chainHash)));
        DemoLog.note("    Derived by the contracts from the chain string. Nobody declared it.");

        Config memory cfg = urp.getConfig(id, agw);
        for (uint256 i; i < cfg.assets.length; ++i) {
            _asset(cfg.assets[i]);
        }
        DemoLog.money("PC per action", cfg.maxGasPerCall, 18, "PC");
        DemoLog.kv("Expires", string.concat("timestamp ", vm.toString(uint256(cfg.validUntil))));
        DemoLog.addrPlain("Beneficiary", cfg.expectedCEA);
        DemoLog.note("    Pinned at grant. The agent can stake for this account and no other.");
        DemoLog.kv("Allow-list", string.concat(vm.toString(cfg.allowedCalls.length), " calls"));

        for (uint256 i; i < cfg.allowedCalls.length; ++i) {
            AllowedCall memory a = cfg.allowedCalls[i];
            DemoLog.note(
                string.concat(
                    "    ",
                    vm.toString(abi.encodePacked(a.selector)),
                    " on ",
                    vm.toString(a.target),
                    a.hasBeneficiary ? "  (beneficiary pinned)" : ""
                )
            );
        }
    }

    /// @dev One listed token: its own caps and its own spend counter.
    function _asset(AssetCapState memory a) private view {
        string memory symbol = IERC20Metadata(a.token).symbol();
        DemoLog.kv("Token", string.concat(symbol, "  ", vm.toString(a.token)));
        DemoLog.money("  per action", a.maxPerCall, 6, symbol);

        // THE LINE THE AUDIENCE WATCHES MOVE.
        DemoLog.kv(
            "  spent",
            string.concat(
                DemoLog.bold(DemoLog.formatAmount(a.spent, 6, "")),
                " / ",
                DemoLog.formatAmount(a.maxTotal, 6, symbol),
                "   ",
                DemoLog.bold(DemoLog.formatAmount(a.maxTotal - a.spent, 6, symbol)),
                " remaining"
            )
        );
    }

    /// @dev URP stores only the chain string's hash. The string is printed only if it hashes to
    ///      what URP stored; otherwise the hash itself is shown.
    function _chainLabel(bytes32 chainHash) private pure returns (string memory) {
        if (keccak256(bytes(RULES_CHAIN)) == chainHash) return string.concat("\"", RULES_CHAIN, "\"");
        return string.concat("chain hash ", vm.toString(chainHash));
    }

    // ───────────────────────────────── Sepolia side ─────────────────────────────────

    /// @notice The CEA and the far-chain position. Switches fork; restores it afterwards.
    function sepoliaState() internal {
        address cea = Ledger.addr("predictedCEA", "10_Arrive");
        address agent = Keys.addressOf("AGENT_KEY", "the agent");

        uint256 startingFork = vm.activeFork();
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));

        IERC20 usdc = IERC20(AddressBook.sepolia("USDC"));
        address stake = AddressBook.sepolia("StakeDummy");

        DemoLog.line(DemoLog.bold("Ethereum Sepolia"));
        DemoLog.addrPlain("CEA", cea);

        if (cea.code.length == 0) {
            DemoLog.kv("  status", DemoLog.dim("not deployed yet - act1d deploys it"));
        } else {
            DemoLog.kv("  status", DemoLog.green("deployed at the predicted address"));
            DemoLog.money("  holds", usdc.balanceOf(cea), 6, "USDC");
            DemoLog.money("  staked", IStakeState(stake).totalBalance(cea), 6, "USDC");
        }

        DemoLog.blank();
        DemoLog.addrPlain("StakeDummy", stake);
        DemoLog.money("  reward pool", usdc.balanceOf(stake), 6, "USDC");
        DemoLog.blank();
        DemoLog.addrPlain("Agent", agent);
        DemoLog.money("  holds", usdc.balanceOf(agent), 6, "USDC");

        vm.selectFork(startingFork);
    }
}
