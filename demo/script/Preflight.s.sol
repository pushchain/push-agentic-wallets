// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { AddressBook } from "../lib/AddressBook.sol";
import { DemoLog } from "../lib/DemoLog.sol";
import { Keys } from "../lib/Keys.sol";
import { Ledger } from "../lib/Ledger.sol";
import { Amounts } from "../lib/Amounts.sol";
import { AgentRequest } from "../lib/AgentRequest.sol";
import { RulesRead } from "../lib/RulesRead.sol";
import { IEngineState } from "../lib/Inspect.sol";
import { IUniversalCore } from "../lib/PushCore.sol";
import { IAGW } from "../../src/interfaces/IAGW.sol";
import { IAGWFactory } from "../../src/interfaces/IAGWFactory.sol";
import { IUniversalRulesPolicy } from "../../src/interfaces/IUniversalRulesPolicy.sol";
import { Config, AssetCapState, ModeSlot, RulesType, VmFamily } from "../../src/libraries/Types.sol";

/// @dev `version()` lives on the URP implementation, not on `IUniversalRulesPolicy`.
interface IVersioned {
    function version() external view returns (string memory);
}

/**
 * @title  Preflight
 * @notice Read only, never broadcasts. Run at T-1 hour, and again five minutes before presenting.
 *
 * @dev    ONE GREEN/RED CHECKLIST, and every line names both the specific assertion and the
 *         specific act that fails without it. "Preflight failed" with no detail is not acceptable
 *         output — the point is to convert a mid-demo failure into a pre-demo one, and that only
 *         works if the remedy is on screen.
 *
 *         THREE PHASES, DETECTED FROM THE LEDGER, NOT PASSED IN:
 *
 *           1  always checkable  — keys, RPCs, contracts, balances, the agent, token pair, pool
 *           2  after Act 1       — wallet exists, owned, funded, armed; rules live; CEA matches
 *           3  after Act 2       — per-asset spend and remaining budget
 *
 *         CHECKS OUT OF SCOPE PRINT GREY, NEVER RED. A preflight that goes red because Act 1 has
 *         not run yet is a preflight you learn to ignore, and an ignored preflight is worse than
 *         none. Phase is inferred from which ledger keys exist, so nobody has to remember a flag.
 *
 *         EXIT CODE IS THE CONTRACT. Any in-scope failure reverts, so `just preflight` fails loudly
 *         rather than printing red text into a scrollback nobody reads.
 */
contract Preflight is Script {
    error NotReady(string what, string breaks);

    /// @dev Bob needs enough for the bridge plus gas for one Sepolia transaction.
    uint256 internal constant BOB_MIN_ETH = 0.005 ether;

    /// @dev Before Act 1 the relayer must cover the wallet's 1 PC, the agent's gas and its own
    ///      transactions. Once the wallet exists it only needs gas for Bob's payloads.
    uint256 internal constant RELAYER_MIN_PC_SETUP = 2 ether;
    uint256 internal constant RELAYER_MIN_PC_RUNNING = 0.1 ether;

    /// @dev Enough for many outbounds at the current quote.
    uint256 internal constant AGW_MIN_PC = 0.1 ether;

    uint256 internal failures;
    uint256 internal phase;

    function run() external {
        phase = _detectPhase();

        DemoLog.header("PREFLIGHT", _phaseTitle());
        _phaseA();
        if (phase >= 2) _phaseB();
        else _skipped("Act 1 checks", "run act1 first");
        if (phase >= 3) _phaseC();
        else _skipped("Act 2 checks", "run act2 first");
        DemoLog.footer();

        if (failures > 0) revert NotReady("see the red lines above", "the acts they name");

        DemoLog.header("", "READY");
        DemoLog.line(DemoLog.green(DemoLog.bold("  Every check in scope passed.")));
        DemoLog.footer();
    }

    // ────────────────────────────── phase detection ──────────────────────────────

    /// @dev 1 = setup only · 2 = Act 1 done · 3 = Act 2 done. Inferred from the ledger, because a
    ///      flag someone has to set is a flag someone forgets.
    /// @dev No wallet -> 1. No rules -> 2. Rules whose first asset has been spent from -> 3.
    function _detectPhase() internal view returns (uint256) {
        if (!Ledger.has("agw")) return 1;
        if (!Ledger.has("rulesId")) return 2;
        return _firstAsset().spent > 0 ? 3 : 2;
    }

    function _phaseTitle() internal view returns (string memory) {
        if (phase == 1) return "Phase 1 - setup";
        if (phase == 2) return "Phase 2 - wallet built";
        return "Phase 3 - agent has acted";
    }

    function _phaseA() internal {
        DemoLog.line(DemoLog.bold("1  Always checkable"));

        _keys();
        _chains();
        _addressBook();
        _contracts();
        _tokenPair();
        _balances();
        _agent();
        _rewardPool();
    }

    function _keys() internal {
        // `Keys.load` reverts naming the variable if one is missing, so reaching the end is the
        // assertion. Only addresses are ever printed.
        address bob = Keys.addressOf("BOB_KEY", "Bob signs the arrival and every owner action");
        address agent = Keys.addressOf("AGENT_KEY", "the agent sends its own requests");
        address relayer = Keys.addressOf("PC_RELAYER_KEY", "the relayer submits every Push-side tx");

        _check(bob != agent, "keys distinct", "Bob and the agent MUST be different keys - that separation is the demo");
        _check(relayer != bob && relayer != agent, "relayer distinct", "the relayer must hold no role");
    }

    function _chains() internal {
        _check(block.chainid == 42101, "donut rpc", "every Push-side act; run with --rpc-url $PUSH_DONUT_RPC_URL");

        // The Sepolia endpoint is checked by reading a contract that only exists there.
        uint256 donut = vm.activeFork();
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));
        _check(block.chainid == 11155111, "sepolia rpc", "Act 1a and every far-chain assertion");
        vm.selectFork(donut);
    }

    /**
     * @dev Every address the demo reads is present AND has code, on the chain it lives on.
     */
    function _addressBook() internal {
        _hasCode(AddressBook.ours("factoryProxy"), "factory", "Act 1b cannot deploy the wallet");
        _hasCode(AddressBook.ours("urp"), "urp", "the rules have no policy to name");
        _hasCode(AddressBook.ours("sessionValidator"), "validator", "no rules can name an agent");
        _hasCode(AddressBook.ours("sessionEngine"), "engine", "the agent door has no validator");
        _hasCode(AddressBook.donut("UniversalGatewayPC"), "gatewayPC", "every outbound");
        _hasCode(AddressBook.donut("UniversalCore"), "core", "the quote, and every fee");
        _hasCode(AddressBook.donut("UEAFactory"), "ueaFactory", "Bob has no identity on Push Chain");
        _hasCode(AddressBook.ours("walletImplementation"), "wallet impl", "Act 1b clones it");
        _hasCode(AddressBook.donut("PRC20_USDC"), "pUSDC", "nothing to bridge or spend");
        _hasCode(AddressBook.donut("PRC20_PETH"), "pETH", "G7 has no unlisted token to name");

        uint256 donut = vm.activeFork();
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));
        _hasCode(AddressBook.sepolia("UniversalGateway"), "sepolia gateway", "Act 1a, the only Ethereum tx");
        _hasCode(AddressBook.sepolia("Vault"), "vault", "the far leg of every outbound");
        _hasCode(AddressBook.sepolia("CEAFactory"), "ceaFactory", "the CEA cannot be predicted or deployed");
        _hasCode(AddressBook.sepolia("USDC"), "sepolia USDC", "Bob has nothing to bridge");
        _hasCode(AddressBook.sepolia("StakeDummy"), "stakeDummy", "act1d and act1e both name it; run setup first");
        vm.selectFork(donut);
    }

    /// @dev The check that catches a wrong token before it wastes an act. A deprecated PRC20 still
    ///      quotes and still resolves to Sepolia, so the failure would otherwise be silent.
    /// @dev The book must describe the contracts actually wired together on Donut.
    function _contracts() internal {
        _check(
            keccak256(bytes(IVersioned(AddressBook.ours("urp")).version())) == keccak256("3.1.0"),
            "URP is 3.1.0",
            "the rules envelope and per-asset caps these scripts encode"
        );
        address impl = AddressBook.ours("walletImplementation");
        _check(
            IAGWFactory(AddressBook.ours("factoryProxy")).walletImplementation() == impl,
            "factory clones the book's wallet",
            "Act 1b would deploy a wallet these scripts do not match"
        );
        _check(
            keccak256(bytes(IAGW(impl).accountId())) == keccak256("push.agw.1.0.0"),
            "wallet is push.agw.1.0.0",
            "every wallet call: this is not the AGW these scripts were written for"
        );
        _check(
            IUniversalCore(AddressBook.donut("UniversalCore")).gasTokenPRC20ByChainNamespace("eip155:11155111")
                == AddressBook.donut("PRC20_PETH"),
            "pETH is Sepolia's gas token",
            "G7 names it as the unlisted token"
        );
    }

    function _tokenPair() internal {
        address prc20 = AddressBook.donut("PRC20_USDC");
        (address gasToken,,,, string memory namespace,) =
            IUniversalCore(AddressBook.donut("UniversalCore")).getOutboundTxGasAndFees(prc20, 0);

        _check(gasToken != address(0), "token registered", "every outbound; the PRC20 is unknown to core");
        _check(
            keccak256(bytes(namespace)) == keccak256("eip155:11155111"),
            "destination",
            "the outbound would land on the wrong chain"
        );
        _check(!_endsWithOld(IERC20Metadata(prc20).symbol()), "not deprecated", "a .old PRC20 fails SILENTLY");
    }

    function _balances() internal {
        address relayer = Keys.addressOf("PC_RELAYER_KEY", "the relayer");
        if (phase == 1) {
            _check(relayer.balance >= RELAYER_MIN_PC_SETUP, "relayer PC", "Act 1: the wallet's 1 PC and Bob's payloads");
        } else {
            _check(relayer.balance >= RELAYER_MIN_PC_RUNNING, "relayer PC", "every payload Bob signs needs a submitter");
        }

        // Bob's Sepolia balances only matter for Act 1a, his one Ethereum transaction. Once the
        // wallet exists that act is behind us, and Bob having bridged his USDC is not a fault.
        if (phase > 1) {
            _skipped("bob ETH / USDC", "only needed for act1a, which has run");
            return;
        }

        uint256 donut = vm.activeFork();
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));

        address bob = Keys.addressOf("BOB_KEY", "Bob");
        IERC20 usdc = IERC20(AddressBook.sepolia("USDC"));

        _check(bob.balance >= BOB_MIN_ETH, "bob ETH", "Act 1a, the bridge transaction");
        _check(usdc.balanceOf(bob) >= Amounts.bridge(), "bob USDC", "Act 1a has nothing to bridge");

        vm.selectFork(donut);
    }

    /// @dev A demo that dies at Act 4 because rehearsals drained the reward pool is the most
    ///      avoidable failure in this build, and it dies at the very last act.
    /// @dev The agent sends its own transactions: a little PC for gas, and never any tokens.
    function _agent() internal {
        address agent = Keys.addressOf("AGENT_KEY", "the agent");
        _check(
            agent.balance >= AgentRequest.AGENT_PC_MIN,
            "agent has gas",
            "Act 2 and Act 4a: the agent cannot send its own transaction; run fund-agent"
        );
        _check(
            IERC20(AddressBook.donut("PRC20_USDC")).balanceOf(agent) == 0,
            "agent holds no pUSDC",
            "the claim that the agent never holds tokens"
        );

        uint256 donut = vm.activeFork();
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));
        _check(
            IERC20(AddressBook.sepolia("USDC")).balanceOf(agent) == 0,
            "agent holds no USDC",
            "the claim that the agent never holds tokens"
        );
        vm.selectFork(donut);
    }

    function _rewardPool() internal {
        uint256 donut = vm.activeFork();
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));

        address stake = AddressBook.sepolia("StakeDummy");
        uint256 pool = IERC20(AddressBook.sepolia("USDC")).balanceOf(stake);

        _check(pool >= Amounts.REWARD, "reward pool", "Act 4a - unstake pays principal PLUS a flat 10 USDC");
        if (pool >= Amounts.REWARD && pool < 3 * Amounts.REWARD) {
            DemoLog.note(string.concat("      pool is low: ", DemoLog.formatAmount(pool, 6, "USDC"), " - top up soon"));
        }

        vm.selectFork(donut);
    }

    // ─────────────────────────────────── phase B ───────────────────────────────────

    function _phaseB() internal {
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("2  After Act 1"));

        address agw = Ledger.addr("agw", "10_Arrive");
        address uea = Ledger.addr("uea", "10_Arrive");
        address prc20 = AddressBook.donut("PRC20_USDC");

        _hasCode(agw, "wallet exists", "every act from here");
        if (agw.code.length == 0) return;

        _check(IAGW(agw).owner() == uea, "owner is the UEA", "Bob does not control the wallet");
        _check(
            IAGW(agw).RULES_POLICY() == AddressBook.ours("urp")
                && IAGW(agw).SESSION_ENGINE() == AddressBook.ours("sessionEngine")
                && IAGW(agw).SESSION_VALIDATOR() == AddressBook.ours("sessionValidator"),
            "wallet wiring matches the book",
            "rules ids and config ids would be derived against the wrong contracts"
        );
        if (phase == 2) {
            _check(IERC20(prc20).balanceOf(agw) > 0, "wallet funded", "the agent has nothing to spend");
        }
        _check(agw.balance >= AGW_MIN_PC, "wallet PC", "outbounds cannot pay the gas swap; run act1c");

        _rules(agw);
        _ceaPrediction();
    }

    function _rules(address agw) internal {
        if (!Ledger.has("rulesId")) {
            _skipped("rules", "not granted yet; run act1e");
            return;
        }

        bytes32 rulesId = Ledger.word("rulesId", "14_GrantRules");
        address agent = Keys.addressOf("AGENT_KEY", "the agent");

        if (!IEngineState(IAGW(agw).SESSION_ENGINE()).isPermissionEnabled(rulesId, agw)) {
            _skipped("rules", "revoked (act4e); run reset, then act1e, for a fresh grant");
            return;
        }
        _ok("rules live", "");
        _check(IAGW(agw).agentOf(rulesId) == agent, "rules name the agent", "the wallet refuses AGENT_KEY at the door");

        ModeSlot memory slot =
            IUniversalRulesPolicy(IAGW(agw).RULES_POLICY()).getMode(RulesRead.universalConfigId(agw, rulesId), agw);
        _check(
            slot.initialized && slot.mode == RulesType.UNIVERSAL && slot.vm == VmFamily.EVM,
            "derived UNIVERSAL (EVM)",
            "the contracts did not derive a cross-chain EVM rules set from the chain string"
        );

        if (Ledger.has("rules.maxGasPerCall")) {
            uint256 granted = Ledger.num("rules.maxGasPerCall", "14_GrantRules");
            uint256 needed = Ledger.has("quote.msgValue") ? Ledger.num("quote.msgValue", "01_Quote") : 0;
            _check(
                needed == 0 || needed <= granted,
                "PC cap covers fees",
                "URP gate 8 refuses every agent request; revoke and regrant"
            );
        }
    }

    function _ceaPrediction() internal {
        if (!Ledger.has("predictedCEA")) return;

        address predicted = Ledger.addr("predictedCEA", "10_Arrive");
        uint256 donut = vm.activeFork();
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));

        if (predicted.code.length == 0) {
            _skipped("cea deployed", "not yet; act1d deploys it");
        } else {
            _ok("cea deployed", "at the predicted address");
        }

        vm.selectFork(donut);
    }

    // ─────────────────────────────────── phase C ───────────────────────────────────

    function _phaseC() internal {
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("3  After Act 2"));

        AssetCapState memory a = _firstAsset();
        string memory symbol = IERC20Metadata(a.token).symbol();

        DemoLog.kv(
            string.concat("spend ", symbol),
            string.concat(
                DemoLog.formatAmount(a.spent, 6, ""),
                " / ",
                DemoLog.formatAmount(a.maxTotal, 6, "USDC"),
                "   ",
                DemoLog.formatAmount(a.maxTotal - a.spent, 6, "USDC"),
                " remaining"
            )
        );
        _check(a.spent <= a.maxTotal, "budget intact", "the token's lifetime cap was exceeded, which gate 7 forbids");
    }

    /// @dev The rules' first listed asset, or an empty struct if the rules are gone.
    function _firstAsset() internal view returns (AssetCapState memory a) {
        address agw = Ledger.addr("agw", "10_Arrive");
        if (agw.code.length == 0) return a;
        bytes32 rulesId = Ledger.word("rulesId", "14_GrantRules");
        Config memory cfg =
            IUniversalRulesPolicy(IAGW(agw).RULES_POLICY()).getConfig(RulesRead.universalConfigId(agw, rulesId), agw);
        if (cfg.assets.length > 0) a = cfg.assets[0];
    }

    function _check(bool passed, string memory what, string memory breaks) internal {
        if (passed) {
            DemoLog.ok(what, "");
        } else {
            DemoLog.fail(what, breaks);
            ++failures;
        }
    }

    function _hasCode(address a, string memory what, string memory breaks) internal {
        _check(a.code.length > 0, what, breaks);
    }

    function _ok(string memory what, string memory detail) internal view {
        DemoLog.ok(what, detail);
    }

    /// @dev Out of scope for the current phase. GREY, never red — see the contract docs.
    function _skipped(string memory what, string memory why) internal view {
        DemoLog.kv(string.concat("- ", what), DemoLog.dim(why));
    }

    function _endsWithOld(string memory s) private pure returns (bool) {
        bytes memory b = bytes(s);
        if (b.length < 4) return false;
        uint256 n = b.length;
        return b[n - 4] == "." && b[n - 3] == "o" && b[n - 2] == "l" && b[n - 1] == "d";
    }
}

/// @dev Minimal metadata surface for the symbol check.
