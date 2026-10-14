// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAGW } from "../../../src/interfaces/IAGW.sol";
import { IUniversalRulesPolicy } from "../../../src/interfaces/IUniversalRulesPolicy.sol";
import { ModeSlot, NativeConfig, UNLIMITED_CALLS } from "../../../src/libraries/Types.sol";
import { StakeDummy } from "../../contracts/StakeDummy.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeIds } from "../../lib/NativeIds.sol";
import { NativeRules } from "../../lib/NativeRules.sol";
import { RulesRead } from "../../lib/RulesRead.sol";

/**
 * @title  State
 * @notice INSPECT · Read-only. Run between every act.
 *
 * @dev    THE OPERATOR'S INSTRUMENT, and the audience's scoreboard. Everything here is read live
 *         from the chain — nothing is remembered from a previous script, and nothing is inferred.
 *
 *         IT DEGRADES GRACEFULLY. Every section is guarded by `Ledger.has`, so this runs at any
 *         point in the demo — before the wallet exists, between acts, or after `revokeAllRules` — and
 *         reports what is true right now rather than failing on a key that has not been written
 *         yet.
 */
/// @dev The engine's own answer to "is this rules set live?".
interface IEngineState {
    function isPermissionEnabled(bytes32 rulesId, address account) external view returns (bool);
}

contract State is Script {
    function run() external view {
        DemoLog.header("STATE", "Live, from the chain");

        IERC20 token = IERC20(AddressBook.native("DemoUSDC"));
        StakeDummy staking = StakeDummy(AddressBook.native("StakeDummy"));

        _people(token);
        _mainWallet(token, staking);
        _throwawayWallet(token);
        _pool(token, staking);

        DemoLog.footer();
    }

    function _people(IERC20 token) private view {
        address bob = Keys.addressOf("BOB_KEY", "the user");
        address agent = Keys.addressOf("AGENT_KEY", "the agent");
        address accomplice = Keys.addressOf("PC_RELAYER_KEY", "the Act 4f accomplice");

        DemoLog.line(DemoLog.bold("People"));
        DemoLog.addrPlain("  Bob", bob);
        DemoLog.money("    dUSDC", token.balanceOf(bob), Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("    PC", bob.balance, 18, "PC");
        DemoLog.addrPlain("  Agent", agent);
        DemoLog.money("    dUSDC", token.balanceOf(agent), Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("    PC", agent.balance, 18, "PC");
        DemoLog.note("      dUSDC should be ZERO, always. The PC is only gas for its own transactions.");
        DemoLog.addrPlain("  Accomplice", accomplice);
        DemoLog.money("    dUSDC", token.balanceOf(accomplice), Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("    PC", accomplice.balance, 18, "PC");
        DemoLog.blank();
    }

    function _mainWallet(IERC20 token, StakeDummy staking) private view {
        if (!Ledger.has("agw")) {
            DemoLog.note("No wallet yet - run act1a.");
            DemoLog.blank();
            return;
        }
        address agw = Ledger.addr("agw", "10_DeployWallet");

        DemoLog.line(DemoLog.bold("The wallet"));
        _walletFacts(agw, token);
        DemoLog.money("  staked", staking.totalBalance(agw), Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money(
            "  approved to StakeDummy", token.allowance(agw, address(staking)), Amounts.DECIMALS, Amounts.SYMBOL
        );
        DemoLog.blank();

        _rule(agw, "stake rules", "rulesId", "13_GrantRules", address(staking), StakeDummy.stakeFor.selector);
        _rule(agw, "unstake rules", "unstakeRulesId", "40_GrantUnstake", address(staking), StakeDummy.unstake.selector);
    }

    function _throwawayWallet(IERC20 token) private view {
        if (!Ledger.has("throwawayAgw")) return;
        address t = Ledger.addr("throwawayAgw", "47_Throwaway_DeployAndFund");

        DemoLog.line(DemoLog.bold("Throwaway wallet (Act 4f)"));
        _walletFacts(t, token);
        DemoLog.note("      should hold 0 after 4f - if not, sweep it with `just reset`");
        DemoLog.blank();

        _rule(
            t,
            "unpinned approve",
            "unpinnedApproveRulesId",
            "48_GrantUnpinnedApprove",
            address(token),
            IERC20.approve.selector
        );
        _rule(
            t,
            "pinned approve",
            "pinnedApproveRulesId",
            "4A_GrantPinnedApprove",
            address(token),
            IERC20.approve.selector
        );
    }

    /// @dev What every wallet prints: label, owner, balance, and the owner-interference counter.
    function _walletFacts(address wallet, IERC20 token) private view {
        DemoLog.addrPlain("  Address", wallet);
        DemoLog.kv("  label", IAGW(wallet).label());
        DemoLog.kv("  owner", vm.toString(IAGW(wallet).owner()));
        DemoLog.money("  dUSDC held", token.balanceOf(wallet), Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.kv(
            "  checkpoints",
            string.concat(
                vm.toString(uint256(IAGW(wallet).checkpointCount())),
                "  (last at block ",
                vm.toString(uint256(IAGW(wallet).lastCheckpointBlock())),
                ")"
            )
        );
        DemoLog.note("      moves on every owner action, never on an agent action");
    }

    /**
     * @dev One rules set: live or revoked, who it names, what the contracts derived it to be, and
     *      its caps and counters. Skipped silently if the ledger has no such key yet.
     */
    function _rule(
        address wallet,
        string memory name,
        string memory key,
        string memory writtenBy,
        address target,
        bytes4 selector
    ) private view {
        if (!Ledger.has(key)) return;
        bytes32 rulesId = Ledger.word(key, writtenBy);

        bool live = IEngineState(IAGW(wallet).SESSION_ENGINE()).isPermissionEnabled(rulesId, wallet);
        DemoLog.kv(string.concat("  ", name), live ? "LIVE" : "revoked");
        DemoLog.kv("    agent", vm.toString(IAGW(wallet).agentOf(rulesId)));
        if (!live) {
            DemoLog.note("      revoked rules name nobody: the wallet refuses every caller");
            DemoLog.blank();
            return;
        }

        ConfigId id = NativeIds.configId(rulesId, wallet, target, selector);
        IUniversalRulesPolicy urp = IUniversalRulesPolicy(IAGW(wallet).RULES_POLICY());

        ModeSlot memory slot = urp.getMode(id, wallet);
        DemoLog.kv("    kind", string.concat(RulesRead.kind(slot), "  on ", _chainLabel(slot.chainHash)));

        NativeConfig memory cfg = urp.getNativeConfig(id, wallet);
        if (cfg.amount.enabled) {
            DemoLog.money("    per action", cfg.amount.maxPerCall, Amounts.DECIMALS, Amounts.SYMBOL);
            DemoLog.money("    spent", cfg.amountSpent, Amounts.DECIMALS, Amounts.SYMBOL);
            DemoLog.money("    remaining", cfg.amount.maxTotal - cfg.amountSpent, Amounts.DECIMALS, Amounts.SYMBOL);
        }
        DemoLog.kv(
            "    calls",
            cfg.maxCalls == UNLIMITED_CALLS
                ? string.concat(vm.toString(uint256(cfg.callsUsed)), " used, no limit")
                : string.concat(vm.toString(uint256(cfg.callsUsed)), " of ", vm.toString(uint256(cfg.maxCalls)))
        );
        DemoLog.kv("    pins", vm.toString(cfg.pins.length));
        DemoLog.blank();
    }

    /// @dev URP stores only the chain string's hash. This chain's string is printed only if it
    ///      hashes to what URP stored; otherwise the hash itself is shown.
    function _chainLabel(bytes32 chainHash) private view returns (string memory) {
        string memory here = NativeRules.thisChain();
        if (keccak256(bytes(here)) == chainHash) return string.concat("\"", here, "\"");
        return string.concat("chain hash ", vm.toString(chainHash));
    }

    function _pool(IERC20 token, StakeDummy staking) private view {
        uint256 pool = token.balanceOf(address(staking));
        DemoLog.line(DemoLog.bold("Reward pool"));
        DemoLog.money("  balance", pool, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.kv("  funds", string.concat(vm.toString(pool / Amounts.REWARD), " more unstake(s)"));
    }
}
