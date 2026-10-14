// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { Session, ActionData, PolicyData, ERC7739Data, ERC7739Context, ConfigId } from "smartsessions/DataTypes.sol";
import { ISessionValidator } from "smartsessions/interfaces/ISessionValidator.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { RulesRead } from "../../lib/RulesRead.sol";
import { BobPayload, IUEA, UniversalPayload } from "../../lib/BobPayload.sol";
import { IAGW } from "../../../src/interfaces/IAGW.sol";
import { IUniversalRulesPolicy } from "../../../src/interfaces/IUniversalRulesPolicy.sol";
import {
    UniversalTerms,
    AssetCap,
    AllowedCall,
    Config,
    SEND_OUTBOUND_SELECTOR,
    ENVELOPE_VERSION
} from "../../../src/libraries/Types.sol";
import { StakeDummy } from "../../contracts/StakeDummy.sol";

/**
 * @title  GrantRules
 * @notice ACT 1e · Chain: Donut · broadcasts with the relayer key, on a payload BOB signed.
 *         THE MOST IMPORTANT OUTPUT ANY SCRIPT IN THIS DEMO PRODUCES.
 *
 * @dev    The rules summary this prints is the demo's thesis on one screen, and it is where the
 *         live demo opens. Everything else exists to make it credible.
 *
 *         WHAT THE RULES SAY, in one sentence: this agent may call two functions on one contract
 *         on one chain, only ever for Bob's own account, up to the per-action and lifetime caps of
 *         one token, for seven days. Nothing else.
 *
 *         THE SHAPE IS ENFORCED BY THE WALLET, NOT BY CONVENTION. `grantRules` refuses anything
 *         but the canonical shape: exactly one action for a cross-chain rules set, the wallet's
 *         own validator, exactly one action policy which must be the deployed URP, no user-op
 *         policies, no ERC-7739 policies, and `permitERC4337Paymaster` false. The salt passed here
 *         is discarded — the wallet overwrites it with its own monotonic grant counter, so every
 *         grant yields a rules id that never recurs.
 *
 *         THE AGENT IS A PUSH ADDRESS. The validator config is `abi.encode(agent)`: one ABI word.
 *         The agent signs nothing off-chain; it sends its own transactions, and the wallet's first
 *         check is that the sender is this address.
 *
 *         `expectedCEA` IS THE FIELD THAT MAKES THE DEMO. It is committed at grant time, before the
 *         CEA has done anything, and gates 14 and 15 measure every agent request against it. It is
 *         why the agent can stake for Bob and for nobody else.
 *
 *         `approve` IS DELIBERATELY NOT IN THE ALLOW-LIST — see `13_ApproveStakeDummyOnCEA`.
 */
contract GrantRules is Script {
    error AgentNotRecorded(address expected, address recorded);
    error PredictedIdMismatch(bytes32 predicted, bytes32 granted);
    error CheckpointDidNotMove(uint64 before, uint64 afterCount);

    uint48 internal constant VALIDITY = 7 days;
    uint256 internal constant VALID_FOR = 1 hours;

    /// @dev The chain this rules set acts on. It is the ONLY thing that makes the rules
    ///      cross-chain: the wallet and URP derive the kind from this string.
    string internal constant CHAIN = "eip155:11155111";

    /// @dev `stakeFor(address beneficiary, uint256 amount)` — the beneficiary is the FIRST argument
    ///      word, immediately after the 4-byte selector. Gate 15 reads a 32-byte word at this
    ///      offset and asserts it equals `expectedCEA`.
    uint16 internal constant BENEFICIARY_OFFSET = 4;

    function run() external {
        uint256 bobPk = Keys.load("BOB_KEY", "Bob signs every owner action");
        uint256 relayerPk = Keys.load("PC_RELAYER_KEY", "the relayer submits");
        address agent = Keys.addressOf("AGENT_KEY", "the agent the rules authorise");

        address uea = Ledger.addr("uea", "10_Arrive");
        address agw = Ledger.addr("agw", "10_Arrive");
        address cea = Ledger.addr("predictedCEA", "10_Arrive");
        address stakeDummy = AddressBook.sepolia("StakeDummy");

        uint256 maxGasPerCall = Ledger.num("quote.maxGasPerCall", "01_Quote");

        Session memory session = _session(agw, agent, cea, stakeDummy, maxGasPerCall);

        (UniversalPayload memory payload, bytes memory signature) =
            BobPayload.signedCall(uea, agw, abi.encodeCall(IAGW.grantRules, (session)), bobPk, VALID_FOR);

        bytes32 predicted = _predictId(agw, agent);
        uint64 checkpointsBefore = IAGW(agw).checkpointCount();

        vm.recordLogs();
        vm.startBroadcast(relayerPk);
        IUEA(uea).executeUniversalTx(payload, signature);
        vm.stopBroadcast();

        RulesRead.Granted memory granted = RulesRead.granted(vm.getRecordedLogs());
        bytes32 rulesId = granted.rulesId;

        if (rulesId != predicted) revert PredictedIdMismatch(predicted, rulesId);
        address recorded = IAGW(agw).agentOf(rulesId);
        if (recorded != agent) revert AgentNotRecorded(agent, recorded);
        uint64 checkpointsAfter = IAGW(agw).checkpointCount();
        if (checkpointsAfter != checkpointsBefore + 1) {
            revert CheckpointDidNotMove(checkpointsBefore, checkpointsAfter);
        }

        Ledger.setWord("rulesId", rulesId);
        Ledger.setNum("rules.maxGasPerCall", maxGasPerCall);

        _printRules(agw, granted);
        _printRecord(agw, rulesId, stakeDummy, checkpointsBefore, checkpointsAfter);
    }

    /// @dev `rulesId = keccak256(abi.encode(validator, validatorConfig, bytes32(grantNonce)))`,
    ///      computed by the engine. Predicted here only to assert it against the event.
    function _predictId(address agw, address agent) internal view returns (bytes32) {
        return keccak256(
            abi.encode(IAGW(agw).SESSION_VALIDATOR(), abi.encode(agent), bytes32(uint256(IAGW(agw).grantNonce())))
        );
    }

    /// @dev The canonical session shape. Every field is checked by `grantRules`; see the contract.
    function _session(address agw, address agent, address cea, address stakeDummy, uint256 maxGasPerCall)
        internal
        view
        returns (Session memory)
    {
        // THE POLICY ENVELOPE: `abi.encode(uint16 version, string chainNamespace, bytes body)`.
        // The chain is Sepolia, so the wallet derives UNIVERSAL and URP derives UNIVERSAL (and the
        // EVM rulebook, from the `eip155:` prefix) independently from these same bytes.
        //
        // AND THE STRING MUST BE BYTE-EXACT WHAT THE ASSET REPORTS. URP asks each listed PRC20 for
        // its own `SOURCE_CHAIN_NAMESPACE()` at grant and refuses unless the two match — which is
        // what stops rules from claiming Sepolia while spending a token bound to some other chain.
        // `USDC.eth` on Donut answers exactly this string.
        PolicyData[] memory actionPolicies = new PolicyData[](1);
        actionPolicies[0] = PolicyData({
            policy: IAGW(agw).RULES_POLICY(),
            initData: abi.encode(ENVELOPE_VERSION, CHAIN, abi.encode(_terms(cea, stakeDummy, maxGasPerCall)))
        });

        ActionData[] memory actions = new ActionData[](1);
        // Selector BEFORE target — that is the declaration order in DataTypes.sol.
        actions[0] = ActionData({
            actionTargetSelector: SEND_OUTBOUND_SELECTOR,
            actionTarget: AddressBook.donut("UniversalGatewayPC"),
            actionPolicies: actionPolicies
        });

        return Session({
            sessionValidator: ISessionValidator(IAGW(agw).SESSION_VALIDATOR()),
            // The agent's Push address, one ABI word. This blob feeds the rules id, so changing it
            // changes every id.
            sessionValidatorInitData: abi.encode(agent),
            salt: bytes32(0), // discarded; the wallet substitutes its own grant counter
            userOpPolicies: new PolicyData[](0),
            erc7739Policies: ERC7739Data({
                allowedERC7739Content: new ERC7739Context[](0), erc1271Policies: new PolicyData[](0)
            }),
            actions: actions,
            permitERC4337Paymaster: false
        });
    }

    /// @dev The terms: only what the OWNER decides. URP keeps the spend counters itself.
    function _terms(address cea, address stakeDummy, uint256 maxGasPerCall)
        internal
        view
        returns (UniversalTerms memory)
    {
        AllowedCall[] memory allowed = new AllowedCall[](2);

        // The agent may stake — but the beneficiary is pinned to the CEA, one argument deep.
        allowed[0] = AllowedCall({
            target: stakeDummy,
            selector: StakeDummy.stakeFor.selector,
            beneficiaryOffset: BENEFICIARY_OFFSET,
            hasBeneficiary: true,
            maxValue: 0 // not payable; gate 16 rejects any entry carrying value
        });

        // And unstake, which takes no arguments — the caller is the staker.
        allowed[1] = AllowedCall({
            target: stakeDummy,
            selector: StakeDummy.unstake.selector,
            beneficiaryOffset: 0,
            hasBeneficiary: false,
            maxValue: 0
        });

        // ONE LISTED TOKEN, with its own caps. The token is the PRC20 ON PUSH; the gateway routes
        // by it, so listing it is also what pins the destination chain. Gate 5 refuses any request
        // naming a token that is not in this list, even at zero amount.
        AssetCap[] memory assets = new AssetCap[](1);
        assets[0] = AssetCap({
            token: AddressBook.donut("PRC20_USDC"), maxPerCall: Amounts.perCall(), maxTotal: Amounts.total()
        });

        return UniversalTerms({
            validUntil: uint48(block.timestamp) + VALIDITY,
            expectedCEA: cea,
            assets: assets,
            maxGasPerCall: maxGasPerCall,
            allowedCalls: allowed
        });
    }

    /**
     * @dev THE DEMO'S THESIS ON ONE SCREEN. Get this right before anything else — it is where the
     *      live demo opens, and it is the block the audience reads while everything else scrolls.
     *
     *      EVERY NUMBER IS READ BACK FROM URP. Nothing here is a local variable echoed to screen.
     */
    function _printRules(address agw, RulesRead.Granted memory granted) internal view {
        ConfigId id = RulesRead.universalConfigId(agw, granted.rulesId);
        IUniversalRulesPolicy urp = IUniversalRulesPolicy(IAGW(agw).RULES_POLICY());
        Config memory cfg = urp.getConfig(id, agw);

        DemoLog.header("", "The rules");
        DemoLog.line(DemoLog.bold("This agent may:"));
        DemoLog.line(string.concat(unicode"  · call ", DemoLog.bold("stakeFor()"), " on StakeDummy"));
        DemoLog.note(string.concat("      but only ever for ", vm.toString(cfg.expectedCEA)));
        DemoLog.line(string.concat(unicode"  · call ", DemoLog.bold("unstake()"), " on StakeDummy"));
        DemoLog.blank();

        for (uint256 i; i < cfg.assets.length; ++i) {
            string memory symbol = IERC20Metadata(cfg.assets[i].token).symbol();
            DemoLog.kv("Token", symbol);
            DemoLog.money("  per action", cfg.assets[i].maxPerCall, 6, symbol);
            DemoLog.money("  lifetime", cfg.assets[i].maxTotal, 6, symbol);
        }
        DemoLog.money("PC per action", cfg.maxGasPerCall, 18, "PC");
        DemoLog.note("    The most the wallet may attach to one outbound, for the fee and gas swap.");
        DemoLog.kv("Expires", string.concat("in ", vm.toString((cfg.validUntil - block.timestamp) / 1 days), " days"));
        DemoLog.blank();
        RulesRead.printDerivation(granted, urp.getMode(id, agw));
        DemoLog.blank();
        DemoLog.line(DemoLog.dim("Nothing else. No other contract, no other function,"));
        DemoLog.line(DemoLog.dim("no other beneficiary, no other token, no other chain."));
        DemoLog.footer();
    }

    function _printRecord(address agw, bytes32 rulesId, address stakeDummy, uint64 before, uint64 afterCount)
        internal
        view
    {
        DemoLog.header("", "For the record");
        DemoLog.addrPlain("Agent", IAGW(agw).agentOf(rulesId));
        DemoLog.note("    A Push address: it sends its own transactions. It holds a little PC");
        DemoLog.note("    for gas and never holds tokens.");
        DemoLog.addrPlain("StakeDummy", stakeDummy);
        DemoLog.kv("Rules id", vm.toString(rulesId));
        DemoLog.note("    From the wallet's RulesGranted event; equals the predicted id.");
        DemoLog.kv("Checkpoints", string.concat(vm.toString(uint256(before)), " -> ", vm.toString(uint256(afterCount))));
        DemoLog.note("    A grant is an owner action, so the counter moved by one.");
        DemoLog.footer();
    }
}
