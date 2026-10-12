// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAGW } from "../../src/interfaces/IAGW.sol";
import { IAGWFactory } from "../../src/interfaces/IAGWFactory.sol";

import { DemoUSDC } from "../contracts/DemoUSDC.sol";
import { StakeDummy } from "../contracts/StakeDummy.sol";
import { AddressBook } from "../lib/AddressBook.sol";
import { Amounts } from "../lib/Amounts.sol";
import { DemoLog } from "../lib/DemoLog.sol";
import { Keys } from "../lib/Keys.sol";
import { Ledger } from "../lib/Ledger.sol";
import { NativeRequest } from "../lib/NativeRequest.sol";

/// @dev `version()` lives on the URP implementation, not on `IUniversalRulesPolicy`.
interface IVersioned {
    function version() external view returns (string memory);
}

/**
 * @title  Preflight
 * @notice The green/red checklist. Run at T-1 hour AND five minutes before presenting.
 *
 * @dev    EVERY CHECK IS READ LIVE. Nothing here trusts a config file, a previous run, or this
 *         document. The single most expensive failure mode in a live demo is a script that proceeds
 *         against a wrong address and fails three acts later with an opaque error, and this is the
 *         instrument that prevents it.
 *
 *         IT COUNTS FAILURES RATHER THAN REVERTING ON THE FIRST. An operator needs the WHOLE list,
 *         not the first problem — fixing them one run at a time is how a T-5-minutes check becomes
 *         a T-plus-20 scramble.
 */
contract Preflight is Script {
    /// @dev The relayer key is only the Act 4f accomplice here: it sends one `transferFrom`.
    uint256 internal constant ACCOMPLICE_MIN_PC = 0.01 ether;

    uint256 internal _failures;

    function run() external {
        DemoLog.header("PREFLIGHT", "Is this demo ready?");

        _chain();
        _contracts();
        _people();
        _pool();
        _ledger();

        DemoLog.blank();
        if (_failures == 0) {
            DemoLog.ok("READY", "every check passed");
        } else {
            DemoLog.fail("NOT READY", string.concat(vm.toString(_failures), " check(s) failed - see above"));
        }
        DemoLog.footer();

        require(_failures == 0, "preflight failed");
    }

    function _chain() private {
        _check("chain is Donut (42101)", block.chainid == 42101, vm.toString(block.chainid));
    }

    function _contracts() private {
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("Contracts"));

        address urp = AddressBook.ours("urp");
        string memory v = IVersioned(urp).version();
        _check("URP is version 3.1.0", keccak256(bytes(v)) == keccak256(bytes("3.1.0")), v);

        address factory = AddressBook.ours("factoryProxy");
        address impl = IAGWFactory(factory).walletImplementation();
        _check(
            "factory clones the address book's wallet implementation",
            impl == AddressBook.ours("walletImplementation"),
            vm.toString(impl)
        );
        _check(
            "wallet implementation is push.agw.1.0.0",
            keccak256(bytes(IAGW(impl).accountId())) == keccak256(bytes("push.agw.1.0.0")),
            IAGW(impl).accountId()
        );
        _check(
            "wallet wiring matches the address book",
            IAGW(impl).RULES_POLICY() == urp && IAGW(impl).SESSION_ENGINE() == AddressBook.ours("sessionEngine")
                && IAGW(impl).SESSION_VALIDATOR() == AddressBook.ours("sessionValidator"),
            ""
        );

        DemoUSDC token = DemoUSDC(AddressBook.native("DemoUSDC"));
        _check("dUSDC is deployed", address(token).code.length > 0, vm.toString(address(token)));
        _check("dUSDC has 6 decimals", token.decimals() == Amounts.DECIMALS, vm.toString(token.decimals()));
        _check(
            "dUSDC symbol is dUSDC (NOT 'USDC')",
            keccak256(bytes(token.symbol())) == keccak256(bytes(Amounts.SYMBOL)),
            token.symbol()
        );

        StakeDummy stake = StakeDummy(AddressBook.native("StakeDummy"));
        _check("StakeDummy is deployed", address(stake).code.length > 0, vm.toString(address(stake)));
        _check("StakeDummy stakes dUSDC", address(stake.token()) == address(token), vm.toString(address(stake.token())));
    }

    function _people() private {
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("People"));

        address bob = Keys.addressOf("BOB_KEY", "the user");
        address agent = Keys.addressOf("AGENT_KEY", "the agent");
        address relayer = Keys.addressOf("PC_RELAYER_KEY", "the Act 4f accomplice");
        address deployer = Keys.addressOf("PRIVATE_KEY", "the deployer");

        bool distinct = bob != agent && bob != relayer && bob != deployer && agent != relayer && agent != deployer
            && relayer != deployer;
        _check("bob / agent / accomplice / deployer are four distinct addresses", distinct, "");

        IERC20 token = IERC20(AddressBook.native("DemoUSDC"));

        _check("Bob has PC for ~10 transactions", bob.balance >= 0.1 ether, _pc(bob.balance));
        _check(
            "Bob has enough dUSDC for act 1",
            token.balanceOf(bob) >= Amounts.WALLET_FUND + Amounts.THROWAWAY_FUND,
            DemoLog.formatAmount(token.balanceOf(bob), Amounts.DECIMALS, Amounts.SYMBOL)
        );
        _check("Accomplice has PC for its one transaction", relayer.balance >= ACCOMPLICE_MIN_PC, _pc(relayer.balance));

        // THE AGENT SENDS ITS OWN TRANSACTIONS. A little PC for gas; never any tokens.
        _check(
            "Agent has PC for its own gas (run `just fund` if not)",
            agent.balance >= NativeRequest.AGENT_PC_MIN,
            _pc(agent.balance)
        );
        _check("Agent holds NO dUSDC", token.balanceOf(agent) == 0, vm.toString(token.balanceOf(agent)));
    }

    function _pool() private {
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("Reward pool"));

        IERC20 token = IERC20(AddressBook.native("DemoUSDC"));
        uint256 pool = token.balanceOf(AddressBook.native("StakeDummy"));
        _check(
            "pool funds at least one more unstake",
            pool >= Amounts.REWARD,
            DemoLog.formatAmount(pool, Amounts.DECIMALS, Amounts.SYMBOL)
        );
    }

    /// @dev Only checked once a wallet exists. A fresh run has nothing here to be wrong.
    function _ledger() private {
        if (!Ledger.has("agw")) {
            DemoLog.blank();
            DemoLog.note("No wallet in the ledger - this is a FRESH run. Start at act1a.");
            return;
        }

        DemoLog.blank();
        DemoLog.line(DemoLog.bold("Ledger"));

        address agw = Ledger.addr("agw", "10_DeployWallet");
        address bob = Keys.addressOf("BOB_KEY", "the user");
        IAGWFactory factory = IAGWFactory(AddressBook.ours("factoryProxy"));

        _check("the recorded wallet is a real wallet", factory.isWallet(agw), vm.toString(agw));
        _check("and Bob owns it", factory.ownerOf(agw) == bob, vm.toString(factory.ownerOf(agw)));

        if (Ledger.has("rulesId")) {
            bytes32 rulesId = Ledger.word("rulesId", "13_GrantRules");
            address named = IAGW(agw).agentOf(rulesId);
            // Zero means the rules were revoked (act 4d). That is a finished run, not a fault.
            _check(
                "the stake rules name the agent, or were revoked",
                named == address(0) || named == Keys.addressOf("AGENT_KEY", "the agent"),
                vm.toString(named)
            );
        }

        if (Ledger.has("throwawayAgw")) {
            address t = Ledger.addr("throwawayAgw", "47_Throwaway_DeployAndFund");
            uint256 held = IERC20(AddressBook.native("DemoUSDC")).balanceOf(t);
            _check(
                "the throwaway wallet holds nothing (sweep it if not)",
                held == 0,
                DemoLog.formatAmount(held, Amounts.DECIMALS, Amounts.SYMBOL)
            );
        }
    }

    function _check(string memory what, bool pass, string memory detail) private {
        if (pass) {
            DemoLog.ok(what, detail);
        } else {
            DemoLog.fail(what, detail);
            ++_failures;
        }
    }

    function _pc(uint256 wei_) private pure returns (string memory) {
        return DemoLog.formatAmount(wei_, 18, "PC");
    }
}
