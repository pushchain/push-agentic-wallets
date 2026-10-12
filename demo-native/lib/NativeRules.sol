// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Session, ActionData, PolicyData, ERC7739Data, ERC7739Context } from "smartsessions/DataTypes.sol";
import { ISessionValidator } from "smartsessions/interfaces/ISessionValidator.sol";

import { NativeConfig, NativeTerms, ArgPin, AmountRule, ENVELOPE_VERSION } from "../../src/libraries/Types.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

import { AddressBook } from "./AddressBook.sol";
import { Amounts } from "./Amounts.sol";

/**
 * @title  NativeRules
 * @notice Builds the `Session` and `NativeTerms` a Push-native rules set is granted with.
 *
 * @dev    DECLARED ONCE BECAUSE FOUR SCRIPTS GRANT RULES — the stake rules, the unstake rules, and
 *         Act 4f's unpinned/pinned `approve` pair. If each assembled its own shape, 4f's two
 *         halves could differ in some way other than the pin, and the act would prove nothing.
 *
 *         THE SHAPE IS ENFORCED BY THE WALLET, NOT BY CONVENTION. `grantRules` refuses anything
 *         but the canonical shape: 1..8 actions for a native rules set, the wallet's own validator,
 *         exactly one action policy per action which must be the deployed URP, no user-op policies,
 *         no ERC-7739 policies, and `permitERC4337Paymaster` false. The salt passed here is
 *         discarded — the wallet overwrites it with its own monotonic grant counter, so every grant
 *         yields a rules id that never recurs.
 *
 *         THE ENVELOPE IS `abi.encode(uint16 version, string chainNamespace, bytes body)`. The
 *         version is `ENVELOPE_VERSION`; the chain string is what makes these rules native; the
 *         body is `abi.encode(NativeTerms)`. See `_initData`.
 *
 *         THE AGENT IS A PUSH ADDRESS. The validator config is `abi.encode(agent)`: one ABI word.
 *
 *         THE PIN IS THE PRODUCT. `pins[0]` fixes the beneficiary word of `stakeFor` to the wallet
 *         itself. Without it the agent could stake the user's money naming ITSELF as beneficiary
 *         and then call `unstake()` directly from its own account — under no rules at all — and
 *         walk away with principal plus reward. See `_stakeConfig`.
 */
library NativeRules {
    /// @dev Rules lifetime. Long enough to rehearse, short enough that expiry is real.
    uint48 internal constant VALIDITY = 7 days;

    /**
     * @dev `stakeFor(address beneficiary, uint256 amount)` — ABSOLUTE calldata offsets, SELECTOR
     *      INCLUDED. 4 is the first argument word, 36 the second.
     *
     *        bytes  0.. 3  selector
     *        bytes  4..35  beneficiary   <- ArgPin.offset   (gate N7)
     *        bytes 36..67  amount        <- AmountRule.offset (gate N8)
     *
     *      Getting either wrong by four fails CLOSED — `ArgPinMismatch` or a wrong metered amount —
     *      which is safe but wastes an act.
     */
    uint16 internal constant BENEFICIARY_OFFSET = 4;
    uint16 internal constant AMOUNT_OFFSET = 36;

    /// @dev `approve(address spender, uint256 amount)` — the spender is also the first word.
    uint16 internal constant SPENDER_OFFSET = 4;

    // ──────────────────────────────── sessions ────────────────────────────────

    /**
     * @notice The stake rules set: one action, `stakeFor` on `StakeDummy`, beneficiary pinned.
     * @param  agent  The agent (a Push address) the rules authorise.
     * @param  wallet The wallet that is both caller and pinned beneficiary.
     */
    function stakeSession(address agent, address wallet, address stakeDummy, bytes4 selector)
        internal
        view
        returns (Session memory)
    {
        return stakeSessionOn(thisChain(), agent, wallet, stakeDummy, selector);
    }

    /**
     * @notice The stake rules, with an EXPLICIT chain string in the envelope.
     *
     * @dev    Everything else is byte-identical to `stakeSession`. `37_D1_ChainDecides` uses this
     *         to show that the chain string alone decides whether rules are native or cross-chain.
     */
    function stakeSessionOn(
        string memory chainNamespace,
        address agent,
        address wallet,
        address stakeDummy,
        bytes4 selector
    ) internal view returns (Session memory) {
        return _session(
            agent, stakeDummy, selector, envelope(chainNamespace, _stakeConfig(wallet, stakeDummy, selector))
        );
    }

    /**
     * @notice The unstake rules set: one action, `unstake()` on `StakeDummy`, NO pins.
     *
     * @dev    NO PIN IS CORRECT HERE, NOT AN OVERSIGHT. `unstake()` takes no arguments and credits
     *         `msg.sender`, which is the wallet — there is no argument to redirect. Do not "fix"
     *         this by adding one; a pin on a zero-argument call can never match and the rules
     *         would authorise nothing.
     */
    function unstakeSession(address agent, address stakeDummy, bytes4 selector) internal view returns (Session memory) {
        return _session(agent, stakeDummy, selector, _initData(_unstakeConfig(stakeDummy, selector)));
    }

    /**
     * @notice Act 4f's `approve` rules on `DemoUSDC`, with the spender pinned or not.
     *
     * @dev    THE ONLY PLACE IN THIS DEMO WHERE THE ACTION TARGET IS NOT `StakeDummy`. It is
     *         `DemoUSDC`, so `NativeIds.configId` must be derived with that target — deriving it
     *         against `StakeDummy` out of habit yields an id addressing an empty slot.
     *
     * @param  pinnedSpender The spender to pin, or `address(0)` for the deliberately unpinned
     *                       rules that Act 4f exists to expose.
     */
    function approveSession(address agent, address token, bytes4 selector, address pinnedSpender)
        internal
        view
        returns (Session memory)
    {
        return _session(agent, token, selector, _initData(_approveConfig(token, selector, pinnedSpender)));
    }

    // ──────────────────────────────── configs ────────────────────────────────

    /**
     * @notice The stake rulebook. Every field is a gate; see the inline map.
     *
     * @dev    `maxValuePerCall` and `maxValueTotal` are ZERO, deliberately. Native actions in this
     *         demo carry no value, and zero is the honest ceiling — it is also what makes G5 a real
     *         refusal (`ValueExceedsCap(1, 0)`) rather than a contrived one. Do not set them
     *         non-zero "just in case".
     */
    function _stakeConfig(address wallet, address stakeDummy, bytes4 selector)
        private
        view
        returns (NativeConfig memory cfg)
    {
        ArgPin[] memory pins = new ArgPin[](1);
        // THE BENEFICIARY PIN. Full-word equality: an address is left-padded by the ABI, and URP
        // compares all 32 bytes on purpose — a non-zero high half is a MISMATCH, which also proves
        // the padding is clean. Masking would silently accept a dirty word.
        pins[0] = ArgPin({ offset: BENEFICIARY_OFFSET, expected: bytes32(uint256(uint160(wallet))) });

        cfg = NativeConfig({
            initialized: false, // forced true by URP
            validUntil: uint48(block.timestamp) + VALIDITY, // N2
            target: stakeDummy, // N4
            selector: selector, // N5
            maxValuePerCall: 0, // N6 — see the note above
            maxValueTotal: 0, // N6
            valueSpent: 0,
            amount: AmountRule({
                enabled: true, // N8 — the metering that makes the budget real
                offset: AMOUNT_OFFSET,
                maxPerCall: Amounts.PER_CALL,
                maxTotal: Amounts.TOTAL
            }),
            amountSpent: 0,
            maxCalls: Amounts.MAX_CALLS, // N9
            callsUsed: 0,
            pins: pins // N7
        });
    }

    /// @dev The unstake rulebook: nothing to meter, nothing to pin, one call.
    function _unstakeConfig(address stakeDummy, bytes4 selector) private view returns (NativeConfig memory cfg) {
        // HOISTED, NOT INLINED. Both of these as struct literals inside the outer one push the
        // via_ir stack past its limit in the calling script — measured, not guessed.
        ArgPin[] memory noPins = new ArgPin[](0);
        // `unstake()` carries no amount argument, so there is nothing at any offset to meter.
        AmountRule memory noAmount = AmountRule({ enabled: false, offset: 0, maxPerCall: 0, maxTotal: 0 });

        cfg.initialized = false;
        cfg.validUntil = uint48(block.timestamp) + VALIDITY;
        cfg.target = stakeDummy;
        cfg.selector = selector;
        cfg.maxValuePerCall = 0;
        cfg.maxValueTotal = 0;
        cfg.valueSpent = 0;
        cfg.amount = noAmount;
        cfg.amountSpent = 0;
        cfg.maxCalls = Amounts.UNSTAKE_MAX_CALLS; // ONE — and this is what G8 fires on
        cfg.callsUsed = 0;
        cfg.pins = noPins; // none, and that is correct — see `unstakeSession`
    }

    /**
     * @dev Act 4f's `approve` rulebook.
     *
     *      THE TWO HALVES DIFFER IN EXACTLY ONE FIELD — `pins`. Everything else is identical, which
     *      is the entire point of the act: the contract cannot tell a good rules set from a bad one,
     *      because a rules set without a pin is a perfectly valid rules set that simply permits more.
     */
    function _approveConfig(address token, bytes4 selector, address pinnedSpender)
        private
        view
        returns (NativeConfig memory cfg)
    {
        ArgPin[] memory pins;
        if (pinnedSpender == address(0)) {
            pins = new ArgPin[](0); // <- THE HOLE
        } else {
            pins = new ArgPin[](1);
            pins[0] = ArgPin({ offset: SPENDER_OFFSET, expected: bytes32(uint256(uint160(pinnedSpender))) });
        }

        // FIELD-BY-FIELD, for the same via_ir stack reason as `_unstakeConfig`.
        // The allowance amount is not metered: 4f is about the SPENDER argument, and metering the
        // amount would give the act a second reason to refuse, muddying which gate fired.
        AmountRule memory noAmount = AmountRule({ enabled: false, offset: 0, maxPerCall: 0, maxTotal: 0 });

        cfg.initialized = false;
        cfg.validUntil = uint48(block.timestamp) + VALIDITY;
        cfg.target = token;
        cfg.selector = selector;
        cfg.maxValuePerCall = 0;
        cfg.maxValueTotal = 0;
        cfg.valueSpent = 0;
        cfg.amount = noAmount;
        cfg.amountSpent = 0;
        cfg.maxCalls = 0; // unlimited — the act needs two calls on the unpinned half
        cfg.callsUsed = 0;
        cfg.pins = pins;
    }

    // ──────────────────────────────── internals ────────────────────────────────

    /**
     * @dev The canonical one-action native session. Every field is checked by `grantRules`.
     */
    function _session(address agent, address target, bytes4 selector, bytes memory initData)
        private
        view
        returns (Session memory)
    {
        PolicyData[] memory actionPolicies = new PolicyData[](1);
        actionPolicies[0] = PolicyData({ policy: AddressBook.ours("urp"), initData: initData });

        ActionData[] memory actions = new ActionData[](1);
        // SELECTOR BEFORE TARGET — that is the declaration order in `smartsessions/DataTypes.sol`.
        // Reversed, this compiles and fails confusingly.
        actions[0] =
            ActionData({ actionTargetSelector: selector, actionTarget: target, actionPolicies: actionPolicies });

        return Session({
            sessionValidator: ISessionValidator(AddressBook.ours("sessionValidator")),
            // The agent's Push address, one ABI word. This blob is an input to the rules id, so any
            // other encoding yields a different id — and the wallet refuses a config that does not
            // decode to a non-zero address.
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

    /**
     * @dev THE POLICY ENVELOPE: `abi.encode(uint16 version, string chainNamespace, bytes body)`.
     *
     *      NOBODY DECLARES A RULES SET'S KIND. The chain string decides it — this chain means a
     *      Push-side call, so the wallet derives NATIVE and URP derives NATIVE independently from
     *      these same bytes. Changing the string is the only way to change the kind, and
     *      `37_D1_ChainDecides` shows what one changed character does.
     *
     *      THE CHAIN IS BUILT FROM `block.chainid`, NEVER A LITERAL. A hard-coded chain string
     *      would silently produce a cross-chain rules set anywhere else — on a local anvil fork,
     *      on a future testnet, on mainnet — and the failure would surface as a target mismatch
     *      rather than as the wrong chain string.
     */
    function _initData(NativeConfig memory cfg) private view returns (bytes memory) {
        return envelope(thisChain(), cfg);
    }

    /// @notice The envelope for an explicit chain string. Exposed so `37_D1_ChainDecides` can
    ///         build the SAME rules with one character of the chain string changed.
    function envelope(string memory chainNamespace, NativeConfig memory cfg) internal pure returns (bytes memory) {
        return abi.encode(ENVELOPE_VERSION, chainNamespace, abi.encode(_terms(cfg)));
    }

    /**
     * @dev SPLIT OUT FOR STACK DEPTH, not for tidiness. Building the eight-field struct literal and
     *      the chain string in one expression puts this three slots too deep under `via_ir` - the
     *      same hazard `_unstakeConfig` documents above. Two statements, two frames, no juggling.
     */
    function _terms(NativeConfig memory cfg) private pure returns (NativeTerms memory t) {
        t.validUntil = cfg.validUntil;
        t.target = cfg.target;
        t.selector = cfg.selector;
        t.maxValuePerCall = cfg.maxValuePerCall;
        t.maxValueTotal = cfg.maxValueTotal;
        t.amount = cfg.amount;
        t.maxCalls = cfg.maxCalls;
        t.pins = cfg.pins;
    }

    /// @notice This chain's CAIP-2 identifier, from `block.chainid` and never a literal.
    function thisChain() internal view returns (string memory) {
        return string.concat("eip155:", Strings.toString(block.chainid));
    }
}
