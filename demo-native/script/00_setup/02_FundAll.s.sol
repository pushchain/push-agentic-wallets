// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { DemoUSDC } from "../../contracts/DemoUSDC.sol";
import { StakeDummy } from "../../contracts/StakeDummy.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { NativeRequest } from "../../lib/NativeRequest.sol";

/**
 * @title  FundAll
 * @notice SETUP · Chain: Donut · broadcasts with the deployer key. The last setup step.
 *
 * @dev    Mints Bob's dUSDC, fills the reward pool, and tops up the two accounts that send their
 *         own transactions without being Bob: the AGENT (to `NativeRequest.AGENT_PC_TARGET`) and
 *         the Act 4f accomplice. The PC top-ups stop at their targets, so a re-run never
 *         over-funds; the mints are deliberately repeated on every run. The token numbers come
 *         from `Amounts`, and both are chosen rather than arbitrary:
 *
 *           · Bob gets 150 — 100 for the wallet (Act 1b), 20 for the throwaway wallet (Act 4f),
 *             and 30 slack so a rehearsal can repeat Act 1 without re-minting.
 *           · The pool gets 50 — `unstake` pays a flat 10 per successful call and the plan has one
 *             per run, so this funds FIVE rehearsals before this script must be run again.
 *
 *         THE POOL MUST BE FUNDED BEFORE ACT 4a. Without it `unstake` reverts inside a token
 *         transfer, which looks exactly like a permission failure and is not — the single most
 *         confusing way this demo can break. `Preflight` asserts the balance for that reason.
 */
contract FundAll is Script {
    /// @dev The accomplice sends exactly one `transferFrom` in Act 4f. This is far more than
    ///      that costs, and well above the floor Preflight asks of the relayer key.
    uint256 internal constant ACCOMPLICE_PC_TARGET = 0.05 ether;

    function run() external {
        uint256 deployerPk = Keys.load("PRIVATE_KEY", "mints and funds the reward pool");
        address bob = Keys.addressOf("BOB_KEY", "the user, who needs dUSDC to fund his wallet");
        address deployer = vm.addr(deployerPk);

        DemoUSDC token = DemoUSDC(AddressBook.native("DemoUSDC"));
        StakeDummy stake = StakeDummy(AddressBook.native("StakeDummy"));

        uint256 bobBefore = token.balanceOf(bob);
        uint256 poolBefore = token.balanceOf(address(stake));

        address agent = Keys.addressOf("AGENT_KEY", "the agent, which pays its own gas");
        address accomplice = Keys.addressOf("PC_RELAYER_KEY", "the Act 4f accomplice, who sends one transaction");
        uint256 agentTopUp = _shortfall(agent, NativeRequest.AGENT_PC_TARGET);
        uint256 accompliceTopUp = _shortfall(accomplice, ACCOMPLICE_PC_TARGET);

        vm.startBroadcast(deployerPk);
        token.mint(bob, Amounts.MINT_TO_BOB);
        // Mint to ourselves first: `fundRewards` pulls with `transferFrom`, so the deployer needs
        // both the balance AND an allowance. Minting straight to the pool would skip the contract's
        // own accounting path and its `RewardsFunded` event.
        token.mint(deployer, Amounts.REWARD_POOL);
        IERC20(address(token)).approve(address(stake), Amounts.REWARD_POOL);
        stake.fundRewards(Amounts.REWARD_POOL);
        if (agentTopUp > 0) _sendPC(agent, agentTopUp);
        if (accompliceTopUp > 0) _sendPC(accomplice, accompliceTopUp);
        vm.stopBroadcast();

        // READ BACK FROM THE CHAIN. Nothing here reports success because a call did not revert.
        uint256 bobAfter = token.balanceOf(bob);
        uint256 poolAfter = token.balanceOf(address(stake));

        DemoLog.header("SETUP", "Funding");
        DemoLog.addrPlain("Bob", bob);
        DemoLog.money("  before", bobBefore, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("  after", bobAfter, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.blank();
        DemoLog.addrPlain("Reward pool", address(stake));
        DemoLog.money("  before", poolBefore, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("  after", poolAfter, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.note(string.concat("      enough for ", vm.toString(poolAfter / Amounts.REWARD), " more unstake(s)"));
        DemoLog.blank();
        DemoLog.addrPlain("Agent", agent);
        DemoLog.money("  PC sent", agentTopUp, 18, "PC");
        DemoLog.money("  PC now", agent.balance, 18, "PC");
        DemoLog.note("      The agent sends its own transactions: a little PC for gas, never tokens.");
        DemoLog.addrPlain("Accomplice (4f)", accomplice);
        DemoLog.money("  PC sent", accompliceTopUp, 18, "PC");
        DemoLog.money("  PC now", accomplice.balance, 18, "PC");
        DemoLog.footer();

        require(agent.balance >= NativeRequest.AGENT_PC_TARGET, "the agent's gas top-up did not land");
        require(bobAfter == bobBefore + Amounts.MINT_TO_BOB, "Bob's mint did not land");
        require(poolAfter == poolBefore + Amounts.REWARD_POOL, "the reward pool did not fill");
    }

    /// @dev How much PC `who` is short of `target`. Zero when already at or above it, so a re-run
    ///      never pushes a balance past the target.
    function _shortfall(address who, uint256 target) private view returns (uint256) {
        return who.balance >= target ? 0 : target - who.balance;
    }

    function _sendPC(address to, uint256 amount) private {
        (bool sent,) = payable(to).call{ value: amount }("");
        require(sent, "PC transfer failed");
    }
}
