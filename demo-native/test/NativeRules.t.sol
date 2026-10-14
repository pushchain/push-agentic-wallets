// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { Session } from "smartsessions/DataTypes.sol";

import { NativeTerms, ENVELOPE_VERSION } from "../../src/libraries/Types.sol";

import { Amounts } from "../lib/Amounts.sol";
import { NativeRules } from "../lib/NativeRules.sol";

/**
 * @title  NativeRulesTest
 * @notice The rules' SHAPE — the parts that are wrong silently rather than loudly.
 *
 * @dev    WHAT THIS FILE DOES NOT TEST, AND WHY. It does not assert that URP enforces these terms;
 *         that is URP's property, proven by the contract suite under `test/` and demonstrated
 *         live by the gauntlet. A unit test of a builder library cannot show anything about the policy.
 *
 *         WHAT IT DOES TEST is the encoding layer between the two, where a mistake produces a
 *         rules set that GRANTS SUCCESSFULLY and then behaves differently from what the operator
 *         believes they granted. Those are the failures that survive a rehearsal.
 *
 *         THE BUILDERS TAKE THEIR TARGET AS A PARAMETER rather than resolving the address book
 *         themselves. That is what lets this suite run with no deployment, no fork and no writes to
 *         a tracked file — and it keeps the never-zero rule intact, since the scripts still resolve
 *         through `AddressBook` at their call sites.
 */
contract NativeRulesTest is Test {
    address internal agent = makeAddr("agent");
    address internal wallet = makeAddr("agw");
    address internal stakeDummy = makeAddr("stakeDummy");
    address internal token = makeAddr("dUSDC");

    bytes4 internal constant STAKE_FOR = bytes4(keccak256("stakeFor(address,uint256)"));
    bytes4 internal constant UNSTAKE = bytes4(keccak256("unstake()"));
    bytes4 internal constant APPROVE = bytes4(keccak256("approve(address,uint256)"));

    /// @dev Decode a session's single policy `initData` back into the declared chain and the terms.
    ///      The envelope is `abi.encode(uint16 version, string chainNamespace, bytes body)` — there
    ///      is no kind in it, because the kind is DERIVED from the chain string by the wallet and
    ///      by URP independently.
    function _decode(bytes memory initData) internal pure returns (string memory chain, NativeTerms memory terms) {
        (, chain, terms) = _decodeVersioned(initData);
    }

    function _decodeVersioned(bytes memory initData)
        internal
        pure
        returns (uint16 version, string memory chain, NativeTerms memory terms)
    {
        bytes memory body;
        (version, chain, body) = abi.decode(initData, (uint16, string, bytes));
        terms = abi.decode(body, (NativeTerms));
    }

    /// @dev What this chain calls itself — built from `block.chainid`, never a literal, for the same
    ///      reason the library builds it that way.
    function _thisChain() internal view returns (string memory) {
        return string.concat("eip155:", vm.toString(block.chainid));
    }

    /**
     * @dev ⚠️ THE ENVELOPE, AND THE CHAIN THAT DECIDES THE KIND.
     *
     *      URP's `initData` is `abi.encode(uint16 version, string chainNamespace, bytes body)`.
     *      URP reads the first word as the version and refuses anything but 1. Nothing in the
     *      envelope states a kind: the wallet hashes the chain string, compares it to its own
     *      chain, and derives NATIVE — and URP does the same, independently, from the same bytes.
     *      So the string must be this chain's, byte-exact. A near miss in the prefix's case would
     *      derive a cross-chain rules set and the grant would be refused against the target, which
     *      is exactly what `37_D1_ChainDecides` shows on purpose.
     */
    function test_stake_envelopeIsVersionOneOnThisChain() public view {
        (uint16 version, string memory chain,) = _decodeVersioned(
            NativeRules.stakeSession(agent, wallet, stakeDummy, STAKE_FOR).actions[0].actionPolicies[0].initData
        );
        assertEq(version, 1, "the envelope's first word is the version, and it is 1");
        assertEq(version, ENVELOPE_VERSION, "and it is the contracts' own constant");
        assertEq(chain, _thisChain(), "the envelope must declare THIS chain, which is what derives NATIVE");
    }

    /// @dev D1's builder changes the chain string and NOTHING else.
    function test_stakeOn_changesOnlyTheChainString() public view {
        string memory nearMiss = string.concat("EIP155:", vm.toString(block.chainid));

        (uint16 v1, string memory c1, NativeTerms memory t1) = _decodeVersioned(
            NativeRules.stakeSession(agent, wallet, stakeDummy, STAKE_FOR).actions[0].actionPolicies[0].initData
        );
        (uint16 v2, string memory c2, NativeTerms memory t2) = _decodeVersioned(
            NativeRules.stakeSessionOn(nearMiss, agent, wallet, stakeDummy, STAKE_FOR)
            .actions[0].actionPolicies[0].initData
        );

        assertEq(c2, nearMiss, "the explicit chain string is carried verbatim");
        assertTrue(keccak256(bytes(c1)) != keccak256(bytes(c2)), "one character of case changes the hash");
        assertEq(v1, v2, "same version");
        assertEq(keccak256(abi.encode(t1)), keccak256(abi.encode(t2)), "the terms are byte-identical");
    }

    /**
     * @dev THE PIN IS THE PRODUCT. Offset 4 is the first argument word, selector included; the
     *      expected value is the wallet, left-padded to a full 32-byte word because URP compares
     *      all 32 bytes.
     */
    function test_stake_pinsTheBeneficiaryToTheWallet() public view {
        (, NativeTerms memory cfg) = _decode(
            NativeRules.stakeSession(agent, wallet, stakeDummy, STAKE_FOR).actions[0].actionPolicies[0].initData
        );

        assertEq(cfg.pins.length, 1, "exactly one pin");
        assertEq(cfg.pins[0].offset, 4, "the beneficiary is the FIRST argument word, at offset 4");
        assertEq(cfg.pins[0].value, bytes32(uint256(uint160(wallet))), "the pin must name the wallet");
    }

    /// @dev Offset 36 is the second argument word. Off by four and the meter reads the wrong bytes.
    function test_stake_metersTheAmountAtOffset36() public view {
        (, NativeTerms memory cfg) = _decode(
            NativeRules.stakeSession(agent, wallet, stakeDummy, STAKE_FOR).actions[0].actionPolicies[0].initData
        );

        assertTrue(cfg.amount.enabled, "the amount must be metered");
        assertEq(cfg.amount.offset, 36, "the amount is the SECOND argument word, at offset 36");
        assertEq(cfg.amount.maxPerCall, Amounts.PER_CALL, "per-call cap");
        assertEq(cfg.amount.maxTotal, Amounts.TOTAL, "lifetime cap");
    }

    /**
     * @dev ZERO VALUE CAPS, and this is a deliberate choice rather than an omission. `stakeFor` is
     *      not payable and these rules never move native PC, so zero is the honest ceiling — and
     *      it is what makes G5 a real refusal rather than a contrived one.
     */
    function test_stake_permitsNoNativeValue() public view {
        (, NativeTerms memory cfg) = _decode(
            NativeRules.stakeSession(agent, wallet, stakeDummy, STAKE_FOR).actions[0].actionPolicies[0].initData
        );

        assertEq(cfg.maxValuePerCall, 0, "no value per call");
        assertEq(cfg.maxValueTotal, 0, "no value ever");
    }

    /**
     * @dev THE BUDGET ARITHMETIC THE ACT PLAN DEPENDS ON: 2.5 + 2.5 + 1 exhausts 6 in three calls,
     *      leaving G7 reachable. If someone retunes the caps, this fails rather than the demo
     *      silently losing its best beat.
     */
    function test_theActPlanArithmeticHolds() public pure {
        assertEq(
            Amounts.ACT2 + Amounts.ACT3B + Amounts.ACT3C, Amounts.TOTAL, "the three stakes must land exactly on the cap"
        );
        assertLe(Amounts.ACT2, Amounts.PER_CALL, "act 2 must fit the per-call cap");
        assertLe(Amounts.ACT3B, Amounts.PER_CALL, "act 3b must fit");
        assertLe(Amounts.ACT3C, Amounts.PER_CALL, "act 3c must fit");
        assertGt(Amounts.G4_OVER_PER_CALL, Amounts.PER_CALL, "G4 must actually exceed the per-call cap");
        assertGt(Amounts.G7_OVER_TOTAL, 0, "G7 must request something, or N8 never fires");

        // G8 lives on the unstake rules set BECAUSE the stake rules set cannot reach its call ceiling:
        // the budget runs out at three calls, and `MAX_CALLS` is four.
        assertEq(Amounts.MAX_CALLS, 4, "the stake rules set's ceiling");
        assertEq(Amounts.UNSTAKE_MAX_CALLS, 1, "the unstake rules set's ceiling is what G8 fires on");
    }

    /// @dev The approval is a SECOND ceiling and must exactly match the rules' lifetime cap.
    function test_approvalEqualsTheLifetimeCap() public pure {
        assertEq(Amounts.APPROVAL, Amounts.TOTAL, "the approval must equal the lifetime budget");
        assertGt(Amounts.WALLET_FUND, Amounts.TOTAL, "the wallet must hold more than the rules permit");
    }

    /**
     * @dev NO PINS AND NO AMOUNT RULE ON `unstake()`, AND THAT IS CORRECT. It takes no arguments
     *      and credits `msg.sender`, so there is nothing to redirect and nothing to meter. A pin
     *      here could never match, and the rules would authorise nothing at all.
     */
    function test_unstake_hasNoPinsAndNoAmountRule() public view {
        (, NativeTerms memory cfg) =
            _decode(NativeRules.unstakeSession(agent, stakeDummy, UNSTAKE).actions[0].actionPolicies[0].initData);

        assertEq(cfg.pins.length, 0, "unstake() has no argument to pin");
        assertFalse(cfg.amount.enabled, "unstake() has no amount to meter");
        assertEq(cfg.maxCalls, Amounts.UNSTAKE_MAX_CALLS, "one call - which is what G8 fires on");
    }

    /**
     * @dev ⚠️ ACT 4f'S CLAIM, AS A TEST: the two approve rules differ in EXACTLY ONE FIELD.
     *
     *      If they differed in any other way, the act would prove nothing — the refusal could be
     *      attributed to the other difference. This asserts every other field matches.
     */
    function test_approve_pinnedAndUnpinnedDifferOnlyInPins() public view {
        (, NativeTerms memory unpinned) = _decode(
            NativeRules.approveSession(agent, token, APPROVE, address(0)).actions[0].actionPolicies[0].initData
        );
        (, NativeTerms memory pinned) =
            _decode(NativeRules.approveSession(agent, token, APPROVE, wallet).actions[0].actionPolicies[0].initData);

        assertEq(unpinned.pins.length, 0, "the unpinned rules set is the hole");
        assertEq(pinned.pins.length, 1, "the pinned rules set closes it");
        assertEq(pinned.pins[0].offset, 4, "the spender is the first argument word");

        // EVERY OTHER FIELD IDENTICAL.
        assertEq(unpinned.target, pinned.target, "same target");
        assertEq(unpinned.selector, pinned.selector, "same selector");
        assertEq(unpinned.maxValuePerCall, pinned.maxValuePerCall, "same value cap");
        assertEq(unpinned.maxValueTotal, pinned.maxValueTotal, "same value total");
        assertEq(unpinned.amount.enabled, pinned.amount.enabled, "same metering");
        assertEq(unpinned.maxCalls, pinned.maxCalls, "same call ceiling");
    }

    /// @dev The canonical shape `grantRules` enforces. Anything else is `MalformedSessionShape`.
    function test_session_isTheCanonicalShape() public view {
        Session memory s = NativeRules.stakeSession(agent, wallet, stakeDummy, STAKE_FOR);

        assertEq(s.actions.length, 1, "exactly one action");
        assertEq(s.actions[0].actionPolicies.length, 1, "exactly one action policy");
        assertEq(s.userOpPolicies.length, 0, "no user-op policies");
        assertEq(s.erc7739Policies.erc1271Policies.length, 0, "no ERC-7739 policies");
        assertEq(s.erc7739Policies.allowedERC7739Content.length, 0, "no ERC-7739 content");
        assertFalse(s.permitERC4337Paymaster, "no paymaster permit");
        assertEq(s.salt, bytes32(0), "the salt is discarded - the wallet substitutes its grant counter");
    }

    /// @dev The agent is a Push address, encoded as one ABI word. This blob is an input to every
    ///      rules id, and the wallet refuses a config that does not decode to a non-zero address.
    function test_session_encodesTheAgentAsOneAbiWord() public view {
        bytes memory cfg = NativeRules.stakeSession(agent, wallet, stakeDummy, STAKE_FOR).sessionValidatorInitData;

        assertEq(cfg.length, 32, "exactly one ABI word");
        assertEq(abi.decode(cfg, (address)), agent, "and it must be the agent");
        assertEq(cfg, abi.encode(agent), "byte-for-byte abi.encode(agent)");
    }
}
