// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { AgentRequest } from "../../lib/AgentRequest.sol";
import { RulesRead } from "../../lib/RulesRead.sol";
import { IAGW } from "../../../src/interfaces/IAGW.sol";
import { IUniversalRulesPolicy } from "../../../src/interfaces/IUniversalRulesPolicy.sol";
import { StakeDummy } from "../../contracts/StakeDummy.sol";

/**
 * @title  Stake
 * @notice ACT 2 · Chain: Donut · broadcasts with the AGENT key. No relayer, no signature.
 *         THE DEMO'S CENTRAL BEAT.
 *
 * @dev    "An account that holds no tokens just moved real money across a chain boundary and put
 *         it to work." This is the first time the whole stack runs: the wallet's sender check,
 *         URP's sixteen gates, the gateway's burn, and the relay.
 *
 *         THE AGENT SENDS ITS OWN TRANSACTION. `executeAsAgent` accepts exactly one sender: the
 *         address the rules name. Nothing is signed off-chain and nobody relays. The agent holds
 *         a little PC for its own gas and never holds tokens; the PC that pays for the swap comes
 *         from the WALLET's balance — the request itself is not payable.
 *
 *         WHAT THE ASSERTION HAS TO BE. Not "the transaction succeeded" — that only proves Push
 *         accepted it. The claim is "the money is staked", which lives on the far chain, so the
 *         proof is `StakeDummy.totalBalance(cea)` and `just watch-staked` is what confirms it.
 *
 *         THREE THINGS ARE ASSERTED ON PUSH. The wallet emitted `RulesActionAuthorized` naming
 *         these rules, this agent and the hash of exactly these calls; URP's spend counter for the
 *         token rose by the amount; and the wallet's checkpoint counter DID NOT MOVE — agent
 *         actions never tick it.
 */
contract Stake is Script {
    error WalletOutOfPC(uint256 have, uint256 need);
    error NotEnoughToStake(uint256 have, uint256 need);
    error AgentOutOfGas(address agent, uint256 have);
    error AuthorizationMismatch(bytes32 expectedCallsHash, bytes32 emitted);
    error NoAuthorizationEvent();
    error SpendDidNotMove(uint256 before, uint256 afterSpent, uint256 amount);
    error CheckpointMoved(uint64 before, uint64 afterCount);

    function run() external {
        uint256 agentPk = Keys.load("AGENT_KEY", "the agent sends its own transactions");
        address agent = vm.addr(agentPk);

        address agw = Ledger.addr("agw", "10_Arrive");
        address cea = Ledger.addr("predictedCEA", "10_Arrive");
        address stakeDummy = AddressBook.sepolia("StakeDummy");
        address prc20 = AddressBook.donut("PRC20_USDC");

        uint256 amount = Amounts.perCall();

        // The far-chain entry. `beneficiary` is the CEA — gate 15 asserts it, so the agent can only
        // ever stake for Bob's own account and never for itself.
        AgentRequest.Built memory req =
            AgentRequest.single(amount, stakeDummy, abi.encodeCall(StakeDummy.stakeFor, (cea, amount)));

        _preconditions(agw, prc20, agent, req, amount);
        _printRequest(agent, cea, amount, req);

        uint256 spentBefore = _spent(agw, req.rulesId);
        uint64 checkpointsBefore = IAGW(agw).checkpointCount();

        vm.recordLogs();
        AgentRequest.submit(agentPk, req);

        _assertAuthorized(req, agent);

        uint256 spentAfter = _spent(agw, req.rulesId);
        if (spentAfter != spentBefore + amount) revert SpendDidNotMove(spentBefore, spentAfter, amount);
        DemoLog.ok("metered", string.concat("spent +", DemoLog.formatAmount(amount, 6, "USDC"), " for this token"));

        uint64 checkpointsAfter = IAGW(agw).checkpointCount();
        if (checkpointsAfter != checkpointsBefore) revert CheckpointMoved(checkpointsBefore, checkpointsAfter);

        _report(agw, prc20, agent, amount, checkpointsAfter);
    }

    /// @dev Fail before broadcasting, with a message naming the fix, rather than reverting deep
    ///      inside the gateway where the reason is a Uniswap error string.
    function _preconditions(address agw, address prc20, address agent, AgentRequest.Built memory req, uint256 amount)
        internal
        view
    {
        if (agw.balance < req.pcValue) revert WalletOutOfPC(agw.balance, req.pcValue);
        if (agent.balance == 0) revert AgentOutOfGas(agent, agent.balance);

        uint256 held = IERC20(prc20).balanceOf(agw);
        if (held < amount) revert NotEnoughToStake(held, amount);
    }

    /// @dev This token's spend counter, straight from URP.
    function _spent(address agw, bytes32 rulesId) internal view returns (uint256) {
        return IUniversalRulesPolicy(IAGW(agw).RULES_POLICY())
        .getConfig(RulesRead.universalConfigId(agw, rulesId), agw)
        .assets[0].spent;
    }

    function _printRequest(address agent, address cea, uint256 amount, AgentRequest.Built memory req) internal view {
        DemoLog.header("ACT 2", "The agent works");
        DemoLog.addrPlain("Agent", agent);
        DemoLog.note("    Sends this transaction itself. Holds a little PC for gas, never tokens.");
        DemoLog.blank();

        DemoLog.kv(
            "Request", string.concat("stake ", DemoLog.formatAmount(amount, 6, "USDC"), " for the CEA on Sepolia")
        );
        DemoLog.addrPlain("Beneficiary", cea);
        DemoLog.note("    Pinned at grant time. Gate 15 refuses any other.");
        DemoLog.money("PC value", req.pcValue, 18, "PC");
        DemoLog.note("    From the WALLET's balance. The agent request is not payable.");
        DemoLog.blank();
    }

    /**
     * @dev The wallet's own record of what it authorised.
     *
     *      `RulesActionAuthorized(bytes32 indexed rulesId, address indexed agent, bytes32 callsHash)`:
     *      the two indexed fields are topics; `callsHash` is the one data word, and it is
     *      `keccak256(executionCalldata)`.
     */
    function _assertAuthorized(AgentRequest.Built memory req, address agent) internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = IAGW.RulesActionAuthorized.selector;
        bytes32 expected = keccak256(req.executionCalldata);

        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].topics.length == 3 && logs[i].topics[0] == topic && logs[i].topics[1] == req.rulesId
                    && logs[i].topics[2] == bytes32(uint256(uint160(agent)))
            ) {
                bytes32 emitted = abi.decode(logs[i].data, (bytes32));
                if (emitted != expected) revert AuthorizationMismatch(expected, emitted);

                DemoLog.ok("wallet", "caller is the rules' agent");
                DemoLog.ok("URP", "all 16 gates");
                DemoLog.ok("authorised", "RulesActionAuthorized - these rules, this agent, exactly these calls");
                return;
            }
        }
        revert NoAuthorizationEvent();
    }

    function _report(address agw, address prc20, address agent, uint256 amount, uint64 checkpoints) internal view {
        DemoLog.ok("gateway", string.concat("burned ", DemoLog.formatAmount(amount, 6, "pUSDC"), ", outbound emitted"));
        DemoLog.ok("checkpoints", string.concat("unchanged at ", vm.toString(uint256(checkpoints))));
        DemoLog.blank();
        DemoLog.money("Wallet now holds", IERC20(prc20).balanceOf(agw), 6, "pUSDC");
        DemoLog.money("Wallet PC", agw.balance, 18, "PC");
        DemoLog.money("Agent holds", IERC20(prc20).balanceOf(agent), 6, "pUSDC");
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("Bob signed nothing. The agent held no tokens at any point."));
        DemoLog.note("Agent actions never move the checkpoint counter; owner actions always do.");
        DemoLog.note("That is how an evaluator tells the agent's failure from the owner's interference.");
        DemoLog.blank();
        DemoLog.note("Now run `just watch-staked` - the claim is not that the transaction");
        DemoLog.note("succeeded, but that the money is STAKED on the far chain.");
        DemoLog.footer();
    }
}
