// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";

import { IAGW } from "../../src/interfaces/IAGW.sol";
import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";
import { ModeLib, ModeCode } from "../../src/libraries/ModeLib.sol";

/**
 * @title  NativeRequest
 * @notice Builds a complete Push-native agent request and sends it from the agent's own account.
 *
 * @dev    THE WHOLE DIFFERENCE FROM THE CROSS-CHAIN DEMO IS ONE LINE. Compare:
 *
 *           cross-chain, four layers:
 *             encodeSingle(gateway, pcValue,
 *               sendUniversalTxOutbound(UniversalOutboundTxRequest{ …,
 *                 payload: MULTICALL_SELECTOR ‖ abi.encode([Multicall{ stakeDummy, 0, stakeFor(cea, amt) }]) }))
 *
 *           native, one layer:
 *             encodeSingle(stakeDummy, 0, stakeFor(wallet, amt))
 *
 *         Everything AROUND it is identical: the same agent door, `executeAsAgent(rulesId, mode,
 *         executionCalldata)`, the same mode word, and the same first check — the sender must be
 *         the agent the rules name.
 *
 *         NOTHING IS SIGNED. The agent's authority is its own account, so `build` needs no key and
 *         `submit` broadcasts from the agent key. Replay protection is the agent account's
 *         transaction nonce, which belongs to the chain.
 *
 *         THE REQUEST NEEDS NO QUOTE. There is no protocol fee, no gas swap, no `UniversalCore`
 *         call. The agent pays ordinary transaction gas and that is the only cost — which is why
 *         there is no `GasSwap` or `PushCore` equivalent in this folder.
 */
library NativeRequest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /**
     * @dev What setup tops the agent up to.
     *
     *      MEASURED, THEN PADDED. On Donut a native `executeAsAgent` used 130,000-190,000 gas, and
     *      the six agent transactions of one full run cost 0.00087 PC in total. 0.05 PC is dozens of
     *      runs of margin, and still nothing worth taking.
     */
    uint256 internal constant AGENT_PC_TARGET = 0.05 ether;

    /**
     * @dev What Preflight requires. LOWER THAN THE TARGET ON PURPOSE: the agent spends gas with
     *      every action, so a check at exactly the target would go red after the first one. This
     *      floor is still about ten full runs.
     */
    uint256 internal constant AGENT_PC_MIN = 0.01 ether;

    /// @dev Everything a script needs to submit, and everything a gauntlet script mutates.
    struct Built {
        address wallet;
        bytes32 rulesId;
        bytes32 mode;
        bytes executionCalldata;
        // The call's value, inside `executionCalldata`. Paid by the wallet; the door is not payable.
        uint256 pcValue;
        // Informational mirror for on-screen output; not part of the encoding.
        uint256 amount;
    }

    /**
     * @notice Build a request that calls `target` with `data`, carrying no value.
     *
     * @param wallet    The wallet the request is for.
     * @param rulesId   The rules the agent acts under.
     * @param target    The contract the wallet will call — a real contract on Push, not a gateway.
     * @param data      The calldata.
     * @param amount    Informational mirror for on-screen output; not part of the encoding.
     */
    function build(address wallet, bytes32 rulesId, address target, bytes memory data, uint256 amount)
        internal
        pure
        returns (Built memory b)
    {
        return buildWithValue(wallet, rulesId, target, data, amount, 0);
    }

    /**
     * @notice Build a request carrying native value. Used ONLY by G5, which exists to be refused
     *         by gate N6 against a cap of zero.
     */
    function buildWithValue(
        address wallet,
        bytes32 rulesId,
        address target,
        bytes memory data,
        uint256 amount,
        uint256 value
    ) internal pure returns (Built memory b) {
        b.wallet = wallet;
        b.rulesId = rulesId;
        b.mode = singleMode();
        b.pcValue = value;
        b.amount = amount;
        b.executionCalldata = ExecutionLib.encodeSingle(target, value, data);
    }

    /// @notice Submit, FROM THE AGENT. The wallet refuses any other sender before a policy runs.
    function submit(uint256 agentPk, Built memory b) internal {
        vm.startBroadcast(agentPk);
        IAGW(b.wallet).executeAsAgent(b.rulesId, b.mode, b.executionCalldata);
        vm.stopBroadcast();
    }

    /// @notice The raw call, for scripts that must inspect a revert rather than let it bubble.
    function encodeSubmit(Built memory b) internal pure returns (bytes memory) {
        return abi.encodeCall(IAGW.executeAsAgent, (b.rulesId, b.mode, b.executionCalldata));
    }

    /// @notice `CALLTYPE_SINGLE` + `EXECTYPE_DEFAULT` — the only mode the agent door accepts.
    function singleMode() internal pure returns (bytes32) {
        return ModeCode.unwrap(ModeLib.encodeSimpleSingle());
    }
}
