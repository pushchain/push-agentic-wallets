// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAGW } from "../../../src/interfaces/IAGW.sol";
import { IUniversalRulesPolicy } from "../../../src/interfaces/IUniversalRulesPolicy.sol";
import { NativeConfig } from "../../../src/libraries/Types.sol";
import { StakeDummy } from "../../contracts/StakeDummy.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeIds } from "../../lib/NativeIds.sol";
import { NativeRequest } from "../../lib/NativeRequest.sol";

/**
 * @title  Stake
 * @notice ACT 2 · Chain: Donut · THE CENTRAL BEAT. Broadcasts with the AGENT key.
 *
 * @dev    ONE SCRIPT, THREE ACTS. Parameterised by `STAKE_AMOUNT` (default 2.5e6) so that Act 2,
 *         Act 3b and Act 3c are the same code with a different number — which is also the honest
 *         way to show a budget being consumed, since nothing about the request changes except the
 *         amount.
 *
 *             just act2         # 2.5 - Act 2
 *             just stake 2.5    # 2.5 - Act 3b
 *             just stake 1      # 1   - Act 3c, lands exactly on the lifetime cap
 *
 *         THE AGENT SENDS ITS OWN TRANSACTION. `executeAsAgent` accepts exactly one sender: the
 *         address the rules name. Nothing is signed off-chain and nobody relays. The agent holds a
 *         little PC for its own gas and never holds tokens.
 *
 *         FOUR THINGS ARE ASSERTED, all read back from the chain: the stake landed on the wallet;
 *         URP metered the amount and counted the call; the wallet emitted `RulesActionAuthorized`
 *         naming these rules, this agent and the hash of exactly this call; and the wallet's
 *         checkpoint counter DID NOT MOVE — agent actions never tick it.
 *
 *         THE CALLDATA IS ONE LAYER DEEP. In the cross-chain demo the same intent needed four
 *         nested layers — an execution wrapping an outbound wrapping a multicall wrapping the
 *         actual call. Here it is `encodeSingle(stakeDummy, 0, stakeFor(wallet, amount))`, and the
 *         contract the agent names is the contract that runs.
 */
contract Stake is Script {
    error NoAuthorizationEvent();
    error AuthorizationMismatch(bytes32 expectedCallsHash, bytes32 emitted);

    function run() external {
        uint256 agentPk = Keys.load("AGENT_KEY", "the agent sends its own transactions");
        address agent = vm.addr(agentPk);

        address agw = Ledger.addr("agw", "10_DeployWallet");
        bytes32 rulesId = Ledger.word("rulesId", "13_GrantRules");
        address stake = AddressBook.native("StakeDummy");
        bytes4 selector = StakeDummy.stakeFor.selector;

        uint256 amount = vm.envOr("STAKE_AMOUNT", Amounts.ACT2);

        ConfigId configId = NativeIds.configId(rulesId, agw, stake, selector);
        IUniversalRulesPolicy urp = IUniversalRulesPolicy(IAGW(agw).RULES_POLICY());

        NativeConfig memory before = urp.getNativeConfig(configId, agw);
        uint256 stakedBefore = StakeDummy(stake).totalBalance(agw);
        uint64 checkpointsBefore = IAGW(agw).checkpointCount();

        NativeRequest.Built memory req =
            NativeRequest.build(agw, rulesId, stake, abi.encodeCall(StakeDummy.stakeFor, (agw, amount)), amount);

        DemoLog.header("ACT 2", "The agent acts");
        DemoLog.line(DemoLog.bold("The agent asks to stake, crediting Bob's wallet."));
        DemoLog.addrPlain("  sent by", agent);
        DemoLog.note("      The agent itself. A little PC for gas, never tokens.");
        DemoLog.money("  amount", amount, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.addrPlain("  target", stake);
        DemoLog.addrPlain("  beneficiary", agw);
        DemoLog.kv("  value", "0");
        DemoLog.blank();

        vm.recordLogs();
        NativeRequest.submit(agentPk, req);
        _assertAuthorized(req, agent);

        // READ BACK FROM THE CHAIN. A non-reverting call proves the request was accepted; it does
        // not prove the stake landed on the right account, and it says nothing about the budget.
        uint256 stakedAfter = StakeDummy(stake).totalBalance(agw);
        NativeConfig memory afterCfg = urp.getNativeConfig(configId, agw);
        uint64 checkpointsAfter = IAGW(agw).checkpointCount();

        DemoLog.ok("landed", "in this transaction - no bridge, no relay, no waiting");
        DemoLog.ok("authorised", "RulesActionAuthorized - these rules, this agent, exactly this call");
        DemoLog.blank();
        _report(
            stakedBefore,
            stakedAfter,
            afterCfg,
            checkpointsAfter,
            IERC20(AddressBook.native("DemoUSDC")).balanceOf(agent)
        );

        require(stakedAfter == stakedBefore + amount, "the stake did not land on the wallet");
        require(afterCfg.amountSpent == before.amountSpent + amount, "URP did not meter the amount");
        require(afterCfg.callsUsed == before.callsUsed + 1, "URP did not count the call");
        require(checkpointsAfter == checkpointsBefore, "an agent action must never move the checkpoint counter");
    }

    /// @dev `RulesActionAuthorized(bytes32 indexed rulesId, address indexed agent, bytes32 callsHash)`:
    ///      two topics, and one data word that is `keccak256(executionCalldata)`.
    function _assertAuthorized(NativeRequest.Built memory req, address agent) private view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 expected = keccak256(req.executionCalldata);

        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].topics.length == 3 && logs[i].topics[0] == IAGW.RulesActionAuthorized.selector
                    && logs[i].topics[1] == req.rulesId && logs[i].topics[2] == bytes32(uint256(uint160(agent)))
            ) {
                bytes32 emitted = abi.decode(logs[i].data, (bytes32));
                if (emitted != expected) revert AuthorizationMismatch(expected, emitted);
                return;
            }
        }
        revert NoAuthorizationEvent();
    }

    function _report(
        uint256 stakedBefore,
        uint256 stakedAfter,
        NativeConfig memory cfg,
        uint64 checkpoints,
        uint256 agentTokens
    ) private view {
        DemoLog.header("", "What the chain says");
        DemoLog.money("Staked, before", stakedBefore, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("Staked, after", stakedAfter, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.blank();
        DemoLog.money("Budget spent", cfg.amountSpent, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("Budget remaining", cfg.amount.maxTotal - cfg.amountSpent, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.kv(
            "Calls used", string.concat(vm.toString(uint256(cfg.callsUsed)), " of ", vm.toString(uint256(cfg.maxCalls)))
        );
        DemoLog.money("Agent holds", agentTokens, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.blank();
        DemoLog.kv("Checkpoints", string.concat("unchanged at ", vm.toString(uint256(checkpoints))));
        DemoLog.note("    Agent actions never move the checkpoint counter; owner actions always do.");
        DemoLog.note("    That is how an evaluator tells the agent's failure from the owner's interference.");
        DemoLog.footer();
    }
}
