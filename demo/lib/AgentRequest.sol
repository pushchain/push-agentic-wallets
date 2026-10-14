// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";
import { AddressBook } from "./AddressBook.sol";
import { Ledger } from "./Ledger.sol";
import { Requests } from "./Requests.sol";
import { GasSwap } from "./GasSwap.sol";
import { IUniversalCore } from "./PushCore.sol";
import { IAGW } from "../../src/interfaces/IAGW.sol";
import { Multicall } from "../../src/libraries/Types.sol";

/**
 * @title  AgentRequest
 * @notice Builds a complete agent request — the far-chain multicall, the outbound and the execution
 *         calldata — and sends it from the agent's own account.
 *
 * @dev    DECLARED ONCE BECAUSE ELEVEN SCRIPTS BUILD THE SAME SHAPE. Act 2 stakes, Act 4a unstakes,
 *         and the gauntlet scripts each vary exactly one field of this structure in order to be
 *         refused. If each assembled its own request, a gauntlet script could fail for a reason
 *         other than the one it claims to demonstrate — which is the one bug that would make the
 *         whole act dishonest rather than merely broken.
 *
 *         So the gauntlet mutates a request built HERE, and every negative differs from the
 *         positive in one named way.
 *
 *         NOTHING IS SIGNED. The agent door is `executeAsAgent(rulesId, mode, executionCalldata)`
 *         and the wallet's first check is that `msg.sender` is the agent the rules name. The
 *         agent's authority is its own account, so `build` needs no key and `submit` broadcasts
 *         from the agent key. Replay protection is the agent account's transaction nonce, which
 *         belongs to the chain.
 *
 *         THE REQUEST IS NOT PAYABLE. The PC for the protocol fee and gas swap travels as `value`
 *         inside `executionCalldata` and comes from the WALLET's balance — which is why the seam
 *         in Act 1c exists at all. The agent pays only its own transaction gas.
 */
library AgentRequest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /**
     * @dev What setup tops the agent up to. MEASURED, THEN PADDED: on Donut a cross-chain
     *      `executeAsAgent` used about 405,000 gas for a stake and 357,000 for an unstake, roughly
     *      0.0004 PC each. 0.05 PC is over a hundred agent transactions of margin, and still nothing
     *      worth taking.
     */
    uint256 internal constant AGENT_PC_TARGET = 0.05 ether;

    /**
     * @dev What Preflight requires. LOWER THAN THE TARGET ON PURPOSE: the agent spends gas with
     *      every action, so a check at exactly the target would go red after the first one.
     */
    uint256 internal constant AGENT_PC_MIN = 0.01 ether;

    /// @dev Everything a script needs to submit, and everything a gauntlet script needs to mutate.
    struct Built {
        address wallet;
        bytes32 rulesId;
        bytes32 mode;
        bytes executionCalldata;
        uint256 pcValue;
        uint256 amount;
    }

    /**
     * @notice Build a request whose far-chain payload is a single call.
     *
     * @dev    The PC value is priced from the live pool every time rather than read from the
     *         ledger, because `gasFee` is recomputed from the gas price when the transaction lands.
     *         A cached figure is how the first live Act 1 run reverted `STF`.
     *
     * @param amount   PRC20 to bridge. Zero for a request that only carries calldata.
     * @param target   Far-chain contract the entry calls.
     * @param data     Far-chain calldata.
     * @return b       The built request.
     */
    function single(uint256 amount, address target, bytes memory data) internal view returns (Built memory b) {
        return build(amount, Requests.singleCall(target, data));
    }

    /// @notice Build a request from arbitrary multicall entries, bridging the demo's token.
    function build(uint256 amount, Multicall[] memory calls) internal view returns (Built memory b) {
        return buildWithToken(AddressBook.donut("PRC20_USDC"), amount, calls);
    }

    /**
     * @notice Build a request that names an explicit token. Used ONLY by G7, which exists to be
     *         refused by gate 5 for naming a token the rules do not list.
     */
    function buildWithToken(address token, uint256 amount, Multicall[] memory calls)
        internal
        view
        returns (Built memory b)
    {
        b.wallet = Ledger.addr("agw", "10_Arrive");
        b.rulesId = Ledger.word("rulesId", "14_GrantRules");
        b.mode = Requests.singleMode();
        b.amount = amount;
        b.pcValue = pcValue();

        b.executionCalldata = Requests.execution(
            AddressBook.donut("UniversalGatewayPC"),
            b.pcValue,
            Requests.outbound(token, amount, maxPCForGas(), b.wallet, calls)
        );
    }

    /// @notice Submit, FROM THE AGENT. The wallet refuses any other sender before a policy runs.
    function submit(uint256 agentPk, Built memory b) internal {
        vm.startBroadcast(agentPk);
        IAGW(b.wallet).executeAsAgent(b.rulesId, b.mode, b.executionCalldata);
        vm.stopBroadcast();
    }

    /// @notice The raw call, for scripts that must inspect the revert rather than let it bubble.
    function encodeSubmit(Built memory b) internal pure returns (bytes memory) {
        return abi.encodeCall(IAGW.executeAsAgent, (b.rulesId, b.mode, b.executionCalldata));
    }

    // ────────────────────────────────── pricing ──────────────────────────────────

    /// @dev The gas-swap budget, priced from the pool. See `GasSwap` for the unit trap.
    function maxPCForGas() internal view returns (uint256) {
        (address gasToken, uint256 gasFee,,,,) = _quote();
        return GasSwap.budget(gasToken, gasFee);
    }

    /// @dev What the request carries as `value` inside `executionCalldata`. Gate 8 compares this
    ///      against `maxGasPerCall`; it is Push-native and unrelated to gate 16's per-entry cap,
    ///      which is in destination-chain units.
    function pcValue() internal view returns (uint256) {
        (,, uint256 protocolFee,,,) = _quote();
        return protocolFee + maxPCForGas();
    }

    function _quote() private view returns (address, uint256, uint256, uint256, string memory, uint256) {
        return IUniversalCore(AddressBook.donut("UniversalCore"))
            .getOutboundTxGasAndFees(AddressBook.donut("PRC20_USDC"), Requests.FAR_GAS_LIMIT);
    }
}
