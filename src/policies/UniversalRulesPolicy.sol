// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { UniversalRulesPolicyErrors } from "../libraries/Errors.sol";

import { VALIDATION_SUCCESS } from "erc7579/interfaces/IERC7579Module.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";
import { IActionPolicy, IPolicy } from "smartsessions/interfaces/IPolicy.sol";
import { IERC165 } from "forge-std/interfaces/IERC165.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import { IUniversalRulesPolicy } from "../interfaces/IUniversalRulesPolicy.sol";
import { PushChainLib } from "../libraries/PushChainLib.sol";
import { RulesLib } from "../libraries/RulesLib.sol";
import { SvmRulebook } from "./SvmRulebook.sol";
import {
    AllowedCall,
    ArgPin,
    AssetCapState,
    Config,
    ENVELOPE_VERSION,
    MAX_ALLOWED_CALL_PINS,
    MAX_PINS,
    MIN_OUTBOUND_BODY_LEN,
    ModeSlot,
    Multicall,
    MULTICALL_SELECTOR,
    NativeConfig,
    NativeTerms,
    PinOp,
    RulesType,
    SEND_OUTBOUND_SELECTOR as GATEWAY_SEND_OUTBOUND_SELECTOR,
    SvmConfig,
    UniversalOutboundTxRequest,
    UniversalTerms,
    UNLIMITED_CALLS,
    VALUE_SELECTOR,
    VmFamily
} from "../libraries/Types.sol";

/**
 * @title  UniversalRulesPolicy (URP)
 * @notice The security boundary of the whole system: the only contract that ever inspects what an
 *         agent really does on the far chain. Everything else routes, stores, or signs.
 *
 * @dev    - The engine identifies actions by hashing the Push-side target and selector, and every
 *           agent action is the same Push-side call, so to the engine a trade, a deposit and a theft
 *           are identical. What the user actually authorised lives two decode levels down, inside
 *           the payload. This policy opens it.
 *         - It is the fail-closed anchor: the engine requires at least one action policy per action
 *           (`PolicyLib.check`), so removing this one does not weaken a rules set, it kills every
 *           request under it.
 *         - No owner, no setters, no pause. Its three trust anchors are written once, at
 *           initialisation, and there is no function that can change them afterwards.
 *         - At validation it calls nothing anyone can choose — its only callee is `SvmRulebook`, the
 *           linked library holding the Solana rulebook, which is stateless code fixed at deploy —
 *           and it writes only after every gate has passed. The grant path additionally staticcalls
 *           each listed asset's `SOURCE_CHAIN_NAMESPACE()`; see THE TEETH in `_initUniversal`.
 *
 *         UPGRADEABLE, BEHIND A TRANSPARENT PROXY, AND THAT IS A DELIBERATE TRADE. This contract
 *         used to hold its trust anchors in immutables and describe itself as needing no trust at
 *         all. Immutables live in the implementation's bytecode, which a `delegatecall` never
 *         executes the constructor of, so upgradeability and immutables are mutually exclusive —
 *         they had to become storage. The consequence is worth stating plainly rather than
 *         discovering later: **URP's guarantees now hold subject to the proxy admin not being
 *         malicious.** An admin able to install new logic can rewrite every gate in this file.
 *
 *         What that means in practice, and what it does NOT mean:
 *         - No function here can move `SESSION_ENGINE`, the gateway or the executor module. The
 *           only route to changing them is a full implementation swap by the admin.
 *         - The admin cannot reach `_configs` or `_credited` directly; it can only replace the code
 *           that reads them. Existing rules sets keep their caps until an upgrade says otherwise.
 *         - Storage layout is therefore load-bearing FOREVER. See the layout note on `__gap`.
 *
 *         THE IMPLEMENTATION MUST NEVER BE INITIALISED DIRECTLY. Its constructor disables the
 *         initialiser for exactly that reason; an initialised implementation is a contract with a
 *         live config that the proxy does not know about.
 */
contract UniversalRulesPolicy is IUniversalRulesPolicy, Initializable {
    /// @dev Maximum inner calls in one request. Bounds the gate-13 loop.
    uint256 internal constant MAX_ACTIONS_PER_REQUEST = 10;

    /// @dev Maximum allow-list entries per config. Bounds the allow-list scan.
    uint256 internal constant MAX_ALLOWED_CALLS = 32;

    /// @notice The gateway selector every agent action must carry.
    /// @dev    Part of this contract's ABI, so it stays a public constant. The value comes from the
    ///         shared gateway constant, so this policy and the wallet's grant-shape check cannot
    ///         disagree.
    bytes4 public constant SEND_OUTBOUND_SELECTOR = GATEWAY_SEND_OUTBOUND_SELECTOR;

    // `MIN_OUTBOUND_BODY_LEN` moved to `Types.sol` in the URP size shrink: gate 4c reads it here and
    // S4c reads it in the linked `SvmRulebook`, so a single file-level owner outside both is the only
    // way the two cannot drift. The SVM rulebook's own bounds and payload-grammar constants moved
    // with it, into that library.

    // ───────────────────────────────── storage ─────────────────────────────────
    //
    // THE LAYOUT BELOW IS FROZEN. Behind a proxy, storage belongs to the proxy and outlives every
    // implementation, so a new version may only APPEND — never reorder, never remove, never change
    // a type. Doing so does not fail the build: it silently reinterprets live rules sets, which is
    // the worst failure mode this system has.
    //
    // slot 0  UNIVERSAL_GATEWAY_PC
    // slot 1  UNIVERSAL_EXECUTOR_MODULE
    // slot 2  SESSION_ENGINE
    // slot 3  _configs
    // slot 4  _credited
    // slot 5  _mode      APPENDED 2026-09-09 (native mode)
    // slot 6  _native    APPENDED 2026-09-09 (native mode)
    // slot 7  _svm       APPENDED 2026-09-30 (svm rulebook)
    // slots 8..49  __gap (uint256[42])
    //
    // THE 2026-09-09 APPEND, AND WHY IT IS SAFE. `_mode` and `_native` were added AFTER `_credited`
    // and `__gap` was shrunk 45 -> 43 in the same commit, so slots 0-4 are byte-identical to the
    // deployed layout and `__gap` still ends at slot 49. Nothing that holds data moved. The
    // alternative that was rejected — renaming `_configs` to `_universal` and inserting `_native`
    // beside it — would have shifted `_credited` and silently reinterpreted the live idempotency
    // set. Measured with `forge inspect` before the change, not assumed.
    //
    // `Initializable` adds nothing here: OZ 5.x keeps its initialisation flags in an ERC-7201
    // namespaced slot, not slot 0. A test pins this exact layout against solc's own output.

    /// @notice The one Push-side target any agent action may reach.
    /// @dev    Written once by `initialize`. No setter exists, here or anywhere.
    address public UNIVERSAL_GATEWAY_PC;

    /// @notice The sole caller permitted to credit a failed outbound.
    /// @dev    Address unconfirmed against a live deployment; confirm before mainnet. It is an
    ///         initialiser argument, so nothing about building or testing depends on the real one.
    address public UNIVERSAL_EXECUTOR_MODULE;

    /// @notice The multiplexer this contract trusts on every non-engine-driven path.
    /// @dev    Never accepted as a call argument: a wrong value would silently address an empty
    ///         slice. It is set once at initialisation and read from storage thereafter.
    address public SESSION_ENGINE;

    /// @dev configId => multiplexer (the engine) => account (the wallet) => config.
    /// @dev The configId already binds the account and the permission, so the middle level isolates
    ///      callers, not permissions.
    /// @dev On the two engine-driven entry points the multiplexer is msg.sender; every other
    ///      function keys on SESSION_ENGINE.
    mapping(ConfigId => mapping(address => mapping(address => Config))) internal _configs;

    /// @dev outbound tx id => credited already; idempotency for the refund path.
    mapping(bytes32 => bool) internal _credited;

    /// @dev configId => multiplexer => account => which rulebook this config uses.
    /// @dev THE MODE DISCRIMINATOR. Stored rather than derived from `_native[...].initialized`,
    ///      because a one-bit derived mode cannot grow: URP is upgradeable behind a proxy, and the
    ///      register's extensibility item points at MORE MODES. `ModeSlot.initialized` is
    ///      authoritative for emptiness; `mode` is meaningless when it is false.
    mapping(ConfigId => mapping(address => mapping(address => ModeSlot))) internal _mode;

    /// @dev configId => multiplexer => account => the native rulebook.
    /// @dev One entry per ACTION, not per rules set: a native rules set with eight actions writes eight
    ///      of these under eight distinct config ids.
    mapping(ConfigId => mapping(address => mapping(address => NativeConfig))) internal _native;

    /// @dev configId => multiplexer => account => the SVM rulebook.
    /// @dev APPENDED 2026-09-30 after `_native`; `__gap` shrunk 43 -> 42 in the same commit so it
    ///      still ends at slot 49. Slots 0-6 are byte-identical to the deployed layout. `ModeSlot`
    ///      gained a packed byte in the same change (see `ModeSlot.vm`); no member of any live
    ///      struct moved. Measured with the layout tests, not assumed.
    mapping(ConfigId => mapping(address => mapping(address => SvmConfig))) internal _svm;

    /**
     * @dev Reserved so a later version can add state without shifting anything above.
     *
     *      Adding a variable means DECREMENTING this by exactly the number of slots consumed, in
     *      the same commit. A mapping or dynamic array costs one slot; a struct costs its packed
     *      size. `Config` itself lives inside a mapping, so APPENDING a field to that struct is
     *      safe and costs nothing here — reordering or removing one is not.
     *
     *      Was `uint256[45]` before the 2026-09-09 native-mode append; `_mode` and `_native` took
     *      two slots, so it became 43. `_svm` took one more on 2026-09-30, so it is 42. `__gap`
     *      still ends at slot 49.
     */
    uint256[42] private __gap;

    /**
     * @notice Locks the implementation so it can never be initialised in its own context.
     *
     * @dev    An implementation left initialisable is a live contract holding a config the proxy
     *         has no knowledge of. This is the standard guard and it is not optional.
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Pins the three addresses this policy trusts for its whole lifetime.
     *
     * @dev    Runs once, in the PROXY's context, immediately after deployment. Reverts with
     *         `ZeroAddress` if any argument is zero, and with `InvalidInitialization` on any
     *         second call.
     *
     *         Deploy and initialise atomically — pass this call as the TransparentUpgradeableProxy
     *         constructor's `_data`. A proxy deployed uninitialised is front-runnable: whoever
     *         calls `initialize` first chooses the engine this policy trusts.
     *
     * @param  universalGatewayPC        The one Push-side target agent actions may reach.
     * @param  universalExecutorModule   The only caller permitted to credit a failed outbound.
     * @param  sessionEngine             The multiplexer trusted on non-engine-driven paths.
     */
    function initialize(address universalGatewayPC, address universalExecutorModule, address sessionEngine)
        external
        initializer
    {
        if (universalGatewayPC == address(0)) revert UniversalRulesPolicyErrors.ZeroAddress();
        if (universalExecutorModule == address(0)) revert UniversalRulesPolicyErrors.ZeroAddress();
        if (sessionEngine == address(0)) revert UniversalRulesPolicyErrors.ZeroAddress();

        UNIVERSAL_GATEWAY_PC = universalGatewayPC;
        UNIVERSAL_EXECUTOR_MODULE = universalExecutorModule;
        SESSION_ENGINE = sessionEngine;
    }

    /**
     * @dev The mode of a config, from its `ModeSlot`, which every init writes. Read by every
     *      mode-sensitive entry point that is not `checkAction`.
     *
     * @return initialized  true once any rulebook has been written for this config
     * @return mode         the rulebook; meaningless when `initialized` is false
     */
    function _modeOf(ConfigId id, address mux, address account)
        internal
        view
        returns (bool initialized, RulesType mode)
    {
        ModeSlot storage slot = _mode[id][mux][account];
        return (slot.initialized, slot.mode);
    }

    /// @dev The family of a UNIVERSAL config. Meaningless for NATIVE and for empty slots; callers check
    ///      the mode first.
    function _vmOf(ConfigId id, address mux, address account) internal view returns (VmFamily) {
        return _mode[id][mux][account].vm;
    }

    /**
     * @notice Writes one permission's configuration. Reached inside `enableSessions` during the
     *         wallet's `grantRules`, where `msg.sender` becomes the multiplexer key.
     *
     * @dev    - Refuses re-initialisation, a deliberate deviation from the upstream policy
     *           interface, which says a repeat call must overwrite. Do not restore overwrite
     *           semantics for interface fidelity.
     *         - This cannot break a legitimate regrant: the wallet supplies a fresh salt on every
     *           grant, so a regranted rules set has a new permission id and therefore an untouched
     *           config slot. The refusal only ever fires on a path this system does not use.
     *         - Rejects an allow-list that is empty or longer than the cap, an expiry that is zero
     *           or already past, a zero expected destination account, and an asset list that is
     *           empty, longer than MAX_ASSETS, repeats a token, or names a token whose source chain
     *           is not the declared chain. An owner consent term has no meaningful silence, so
     *           "never expires" is written as the maximum value.
     *         - Deliberately does not validate cap values (zero and max are both legal, a zero
     *           per-call cap being a valid move-nothing entry), `beneficiaryOffset`, or
     *           allow-list contents. A wrong offset fails closed at validation time; it cannot widen
     *           a rules set, only break it. Offsets must be generated from each protocol's ABI by
     *           tooling rather than hand-typed, and each newly supported protocol must ship a test
     *           rejecting a wrong beneficiary and an oversized amount.
     *         - Anyone may call this with themselves as the multiplexer; that writes into their own
     *           keyed slice and the engine never reads it.
     *         - Writes the config, sets the initialised flag, and emits `RulesConfigured` and
     *           `PolicySet`.
     *
     *         - THE ENVELOPE. `initData` is `abi.encode(uint16 version, string chain, bytes body)` —
     *           IDENTICAL IN SHAPE FOR EVERY MODE, which is what lets the chain be read before the
     *           mode is known. Nobody declares the mode: URP derives it from the chain with
     *           `PushChainLib.deriveMode`, and the wallet derived the same value from the same bytes
     *           at grant. There is no mode byte and therefore no `InvalidPolicyMode`.
     *         - THE VERSION is read from the first word BEFORE anything else is decoded, and anything
     *           but `ENVELOPE_VERSION` is refused `UnsupportedEnvelopeVersion`. So a body layout can
     *           change later under a new version, and almost every malformed or pre-version blob is
     *           refused NAMED: a two-field `(string, bytes)` envelope reports version 64 (its string
     *           offset), a bare struct 32, a zeroed blob 0. Blobs shorter than one word, and a
     *           version-1 envelope whose body is the wrong `Terms` type, revert unnamed. Nothing
     *           mis-decodes into a live config — measured, one test per shape.
     *         - Re-initialisation is refused ACROSS MODES, and the guard runs BEFORE the decode, so
     *           a malformed blob aimed at a live config still gets a named `AlreadyInitialized`.
     *
     * @param  account   The wallet this config belongs to.
     * @param  configId  Engine-derived id binding the account and the permission.
     * @param  initData  `abi.encode(uint16 version, string chain, bytes body)`, body being
     *                   `abi.encode(UniversalTerms)`, `abi.encode(SvmTerms)` or `abi.encode(NativeTerms)`
     *                   according to the DERIVED mode and family.
     */
    function initializeWithMultiplexer(address account, ConfigId configId, bytes calldata initData) external {
        ModeSlot storage slot = _mode[configId][msg.sender][account];

        // Re-initialisation would let the owner door reset a spend counter or flip a mode.
        if (slot.initialized) revert UniversalRulesPolicyErrors.AlreadyInitialized(configId);

        // THE VERSION, from the first word, before anything else is decoded.
        uint256 envelopeVersion = uint256(bytes32(initData[0:32]));
        if (envelopeVersion != ENVELOPE_VERSION) {
            revert UniversalRulesPolicyErrors.UnsupportedEnvelopeVersion(envelopeVersion);
        }

        // THE ENVELOPE, decoded exactly as the wallet decoded it at grant — same expression, same
        // bytes. That identity is the whole consistency argument: there is no second author of the
        // discriminator, so there is nothing for the two contracts to disagree about.
        (, string memory chainNamespace, bytes memory body) = abi.decode(initData, (uint16, string, bytes));
        if (bytes(chainNamespace).length == 0) revert UniversalRulesPolicyErrors.EmptyChain();

        bytes32 chainHash = keccak256(bytes(chainNamespace));
        RulesType mode = PushChainLib.deriveMode(chainHash);

        // THE FAMILY, derived only for UNIVERSAL. A native string is `eip155:` too and would classify
        // EVM, but NATIVE has no family and must not carry a meaningless one. `deriveVm` refuses any
        // namespace without a rulebook, so a `cosmos:` grant fails here, named, instead of producing
        // a rules set that passes init and rejects every request.
        VmFamily vm = VmFamily.EVM;
        if (mode == RulesType.UNIVERSAL) {
            vm = PushChainLib.deriveVm(chainNamespace);
            if (vm == VmFamily.EVM) {
                _initUniversal(_configs[configId][msg.sender][account], body, chainHash);
            } else {
                SvmRulebook.init(_svm[configId][msg.sender][account], body, chainHash);
            }
        } else {
            _initNative(_native[configId][msg.sender][account], body);
        }

        slot.initialized = true;
        slot.mode = mode;
        slot.vm = vm;
        slot.chainHash = chainHash;

        emit RulesConfigured(configId, msg.sender, account, mode, vm, chainHash);
        emit PolicySet(configId, msg.sender, account);
    }

    /// @inheritdoc IUniversalRulesPolicy
    function pushChainHash() external view returns (bytes32) {
        return PushChainLib.selfChainHash();
    }

    /**
     * @dev The universal init guards — unchanged from the single-mode contract, only relocated.
     * @param cfg   Storage slot to write.
     * @param body  `abi.encode(Config)`.
     */
    function _initUniversal(Config storage cfg, bytes memory body, bytes32 chainHash) internal {
        UniversalTerms memory incoming = abi.decode(body, (UniversalTerms));

        uint256 listLength = incoming.allowedCalls.length;
        if (listLength == 0 || listLength > MAX_ALLOWED_CALLS) {
            revert UniversalRulesPolicyErrors.AllowListOutOfRange(listLength);
        }

        if (incoming.validUntil == 0 || incoming.validUntil <= block.timestamp) {
            revert UniversalRulesPolicyErrors.InvalidExpiry(incoming.validUntil);
        }
        if (incoming.expectedCEA == address(0)) revert UniversalRulesPolicyErrors.InvalidConfigField();

        // ─── THE PIN COUNTS ───
        //
        // BOTH bounds, and they are not the same bound. `MAX_PINS` caps ONE entry; a rules set can
        // satisfy that for all 32 entries and still ask for 256 pins, which is why the aggregate
        // exists. Placed HERE — after every cheap structural guard, before the asset staticcalls and
        // before any write — so a malformed allow-list is refused without ever calling out.
        //
        // NOTHING ELSE IS REFUSED (decision P-11). Duplicate entries, duplicate pins and pins at
        // offsets 0-3 (inside the selector) are owner misconfigurations: each either fails closed on
        // every request or is redundant, and none of them widens a rules set. Refusing them would cost
        // URP bytes to defend against a mistake the SDK is better placed to catch.
        uint256 totalPins;
        for (uint256 i; i < listLength;) {
            uint256 n = incoming.allowedCalls[i].pins.length;
            if (n > MAX_PINS) revert UniversalRulesPolicyErrors.TooManyPins(n);
            totalPins += n;
            unchecked {
                ++i;
            }
        }
        if (totalPins > MAX_ALLOWED_CALL_PINS) {
            revert UniversalRulesPolicyErrors.TooManyAllowedCallPins(totalPins);
        }

        // ─── THE TEETH ───
        //
        // After every decode and guard, before every write. Effects last, as everywhere else here.
        //
        // WHY THIS MAKES THE DECLARED CHAIN TRUE AT RUNTIME. `SOURCE_CHAIN_NAMESPACE()` is the exact
        // view the gateway reads on every outbound, through `UniversalCore.getOutboundTxGasAndFees`,
        // to decide where to route. Gate 5 pins `req.token` to a LISTED asset on every request, zero
        // amount included. So asserting it here, for EVERY listed asset, binds the owner's declared
        // chain to the chain the gateway will actually use — with no runtime change and no external
        // call in `checkAction`. It is also why the list may never be empty: an empty list would pin
        // no token, and the agent would choose the chain.
        //
        // WHY AN EXTERNAL CALL IS SAFE HERE AND NOWHERE ELSE: this runs at INIT, inside the owner's
        // own grant transaction, never in `checkAction` and never on a removal path. A failure
        // blocks a grant; it can never block a revocation or an execution. The `try/catch` is
        // permitted because the external call ALREADY EXISTS — do not extend that reasoning to
        // `checkAction`'s decode, which has no external call to hide behind.
        //
        // A `view` call compiles to STATICCALL, so the callee cannot write state: reentrancy from a
        // hostile asset is structurally impossible, not merely unreachable.
        //
        // ⚠️ THE `code.length` GUARD IS NOT REDUNDANT WITH THE `catch`. MEASURED:
        //      callee reverts                 -> catch fires     -> named InvalidAsset
        //      no code at the address, or EOA -> catch does NOT  -> UNNAMED, empty revert
        //      answers with a non-string      -> catch does NOT  -> UNNAMED, empty revert
        //    Since solc 0.8.10 the compiler omits the extcodesize check when return data is
        //    expected; the call to a codeless address then SUCCEEDS with empty returndata and the
        //    failure happens when THIS frame tries to ABI-decode it — outside the try/catch. Without
        //    this line a typo'd asset address, the likeliest real mistake, reverts unnamed.
        RulesLib.requireAssets(incoming.assets, chainHash);

        _store(cfg, incoming);
        cfg.initialized = true;
    }

    /**
     * @dev The native init guards.
     *
     *      - Refuses a zero target, and the GATEWAY as a target: the mirror of gate 3, and half of
     *        the consistency lock. A native config can never be written against the gateway.
     *      - Refuses a value-only config carrying pins or an amount rule. That combination can never
     *        authorise anything — every request under it would die at N7/N8 — so it is a
     *        misconfiguration the owner believes they granted, not a valid ascetic config. Same
     *        reasoning as the empty-allow-list refusal in universal mode.
     *      - Refuses `maxCalls == 0`. A rule that can make no call authorises nothing; no limit is
     *        written `UNLIMITED_CALLS`. This is the ONE count the guards judge.
     *      - Deliberately does NOT validate the other cap values (zero and max are both legal), pin offsets or
     *        `amount.offset` — they cannot be checked against calldata that does not exist yet, and a
     *        wrong offset fails closed at N7/N8 rather than widening anything. Nor the selector
     *        against the engine's fallback flags: the wallet refuses those at grant, and a
     *        stranger-slice config the engine never reads is harmless.
     *
     *      - MAKES NO EXTERNAL CALL. A native rules set has no asset, so there is nothing to verify the
     *        chain against — and nothing to verify: the chain IS this chain, which is what made the
     *        mode NATIVE in the first place. The universal branch's teeth have no native counterpart
     *        and must not acquire one.
     *
     * @param cfg   Storage slot to write.
     * @param body  `abi.encode(NativeTerms)`.
     */
    function _initNative(NativeConfig storage cfg, bytes memory body) internal {
        NativeTerms memory incoming = abi.decode(body, (NativeTerms));

        if (incoming.validUntil == 0 || incoming.validUntil <= block.timestamp) {
            revert UniversalRulesPolicyErrors.InvalidExpiry(incoming.validUntil);
        }
        if (incoming.target == address(0)) revert UniversalRulesPolicyErrors.NativeTargetZero();
        if (incoming.target == UNIVERSAL_GATEWAY_PC) {
            revert UniversalRulesPolicyErrors.NativeTargetIsGateway(incoming.target);
        }
        if (incoming.maxCalls == 0) revert UniversalRulesPolicyErrors.ZeroMaxCalls();
        if (incoming.pins.length > MAX_PINS) revert UniversalRulesPolicyErrors.TooManyPins(incoming.pins.length);

        if (incoming.selector == VALUE_SELECTOR) {
            if (incoming.pins.length != 0) revert UniversalRulesPolicyErrors.ValueOnlyWithPins();
            if (incoming.amount.enabled) revert UniversalRulesPolicyErrors.ValueOnlyWithAmountRule();
        }

        _storeNative(cfg, incoming);
        cfg.initialized = true;
    }

    /**
     * @notice Runs every gate a cross-chain agent request must pass. Order is fixed; any failure
     *         reverts with nothing written.
     *
     * @dev    - Not `view`: gate 7 accumulates spend, and the engine invokes this with a real call
     *           so the write persists.
     *         - Runs before the session signature is verified, on unauthenticated calldata from an
     *           arbitrary caller. It is safe because it makes NO EXTERNAL CALL EXCEPT the
     *           `DELEGATECALL` into its own linked rulebook library (`SvmRulebook`, on the SVM
     *           branch only) — stateless code fixed at deploy, never a token, a wallet, the engine
     *           or any address supplied at runtime — applies all effects last, and reverts on every
     *           failure. DO NOT INTRODUCE ANY OTHER EXTERNAL CALL HERE. The linked-library exception
     *           is not a precedent for calling anything whose address comes from config or calldata.
     *         - Replayed signatures cannot burn budget through this door; they die at the wallet's
     *           nonce gate first.
     *
     *         The gates, in order:
     *         1.  the config is initialised
     *         2.  the rules set has not expired
     *         3.  the target is the gateway
     *         4.  calldata is at least four bytes; the selector is the outbound send; the body is at
     *             least the minimum encoded length
     *         5.  the token is one of the listed assets — on EVERY request, zero amount included,
     *             because the token is what the gateway routes by
     *         6.  the amount is within THAT asset's per-call cap
     *         7.  THAT asset's running total is within its lifetime cap
     *         8.  the Push-native value is within the per-call ceiling (`maxGasPerCall`)
     *         9.  the request does not ask for an uncapped gas swap
     *         10. the revert recipient is the wallet
     *         11. the recipient field is empty
     *         12. the payload is a multicall
     *         13. the inner call count is between one and the maximum
     *         14. no inner call targets the wallet, this policy, the gateway or the destination
     *             account
     *         15. each inner target and selector is allow-listed, and the entry that allows it passes
     *             IN FULL: its beneficiary (where declared), its value cap and every one of its
     *             argument pins. SEVERAL ENTRIES MAY SHARE ONE `(target, selector)` and the call
     *             passes if ANY of them passes; if none does, the FIRST matching entry's failure is
     *             what reverts
     *         16. each inner value is within that entry's allowance (evaluated inside 15)
     *
     *         - A zero amount passes gate 6 and writes nothing: zero-amount is the redeployment
     *           path, acting on capital already at the destination. There is no zero-amount gate and
     *           one must not be added.
     *         - `abi.decode` ignores trailing bytes, so gate 4c is a length floor and not a
     *           canonical-encoding check. There is no exploit: the whole execution calldata is bound
     *           into the wallet's operation hash, and the signature is verified last.
     *         - A body of correct length carrying malformed internal offsets reverts with a compiler
     *           panic rather than a named error. It cannot be given a named error without wrapping
     *           the decode in an external call, which this function must not have.
     *         - Spend accumulation is optimistic but atomic: it is written during validation and
     *           survives only because validation and dispatch share one transaction. Splitting them
     *           breaks the accounting silently.
     *         - Gate 14 runs before gate 15 on purpose, so a forbidden destination beats the
     *           allow-list: an owner who allow-listed their own destination account still cannot
     *           hand the agent direct control of it.
     *
     * @param  id       Config id identifying the rules set.
     * @param  account  The wallet. The engine passes its own caller through as this parameter, so it
     *                  is never the engine itself.
     * @param  target   Push-side call target; must be the gateway.
     * @param  value    Push-native value attached to the call.
     * @param  data     The gateway calldata, opened and walked by the gates above.
     * @return The engine's success sentinel.
     */
    function checkAction(ConfigId id, address account, address target, uint256 value, bytes calldata data)
        external
        returns (uint256)
    {
        // MODE ROUTING. An EMPTY slot falls through to the universal path, whose gate 1 reverts
        // `NotInitialized` — fail-closed either way. The `initialized &&` conjunction is what makes
        // that safe: `RulesType.UNIVERSAL` is the zero value, so testing `mode` alone could not
        // tell an empty slot from a real universal one.
        ModeSlot storage slot = _mode[id][msg.sender][account];
        if (slot.initialized) {
            if (slot.mode == RulesType.NATIVE) return _checkNative(id, account, target, value, data);
            // The family byte was never written by earlier implementations, so it reads 0 = EVM on
            // every pre-existing universal slot — those keep routing exactly where they always did.
            if (slot.vm == VmFamily.SVM) {
                return SvmRulebook.check(
                    _svm[id][msg.sender][account], id, account, target, UNIVERSAL_GATEWAY_PC, value, data
                );
            }
        }
        return _checkUniversal(id, account, target, value, data);
    }

    /**
     * @dev The universal gauntlet — gates 1 to 16, unchanged from the single-mode contract. Only the
     *      function name and visibility changed; the body is byte-for-byte what `checkAction` was.
     *
     * @param  id       Config id identifying the rules set.
     * @param  account  The wallet.
     * @param  target   Push-side call target; must be the gateway.
     * @param  value    Push-native value attached to the call.
     * @param  data     The gateway calldata.
     * @return The engine's success sentinel.
     */
    function _checkUniversal(ConfigId id, address account, address target, uint256 value, bytes calldata data)
        internal
        returns (uint256)
    {
        Config storage cfg = _configs[id][msg.sender][account];

        if (!cfg.initialized) revert UniversalRulesPolicyErrors.NotInitialized(id, account);

        if (block.timestamp > cfg.validUntil) revert UniversalRulesPolicyErrors.RulesExpired(cfg.validUntil);

        if (target != UNIVERSAL_GATEWAY_PC) revert UniversalRulesPolicyErrors.InvalidTarget(target);

        if (data.length < 4) revert UniversalRulesPolicyErrors.CalldataTooShort(data.length);

        if (bytes4(data[0:4]) != SEND_OUTBOUND_SELECTOR) {
            revert UniversalRulesPolicyErrors.InvalidSelector(bytes4(data[0:4]));
        }

        if (data.length < 4 + MIN_OUTBOUND_BODY_LEN) {
            revert UniversalRulesPolicyErrors.MalformedOutboundRequest(data.length);
        }
        UniversalOutboundTxRequest memory req = abi.decode(data[4:], (UniversalOutboundTxRequest));

        AssetCapState storage cap = RulesLib.assetFor(cfg.assets, req.token);

        if (req.amount > cap.maxPerCall) {
            revert UniversalRulesPolicyErrors.AmountExceedsCap(req.amount, cap.maxPerCall);
        }

        uint256 newSpent = cap.spent + req.amount;
        if (newSpent > cap.maxTotal) revert UniversalRulesPolicyErrors.TotalSpendCapExceeded(newSpent, cap.maxTotal);

        if (value > cfg.maxGasPerCall) revert UniversalRulesPolicyErrors.PCValueExceedsCap(value, cfg.maxGasPerCall);

        if (req.maxPCForGas == 0) revert UniversalRulesPolicyErrors.UncappedGasSwapRejected();

        if (req.revertRecipient != account) {
            revert UniversalRulesPolicyErrors.InvalidRevertRecipient(account, req.revertRecipient);
        }

        if (req.recipient.length != 0) revert UniversalRulesPolicyErrors.RecipientMustBeEmpty();

        _checkInnerCalls(cfg, account, req.payload);

        if (req.amount > 0) {
            cap.spent = newSpent;
            emit OutboundMetered(id, msg.sender, account, req.token, req.amount);
        }

        return VALIDATION_SUCCESS;
    }

    /**
     * @dev The native gauntlet — gates N1 to N9, then effects. The same discipline as the universal
     *      path and for the same reason: this runs BEFORE the session signature is verified, on
     *      unauthenticated calldata from an arbitrary caller.
     *
     *      - NO EXTERNAL CALLS. Pins and the metered amount are read by slicing `data` directly,
     *        never through `_slice` into memory and never through a helper that calls out.
     *      - ALL EFFECTS LAST. `newValueSpent` and `newAmountSpent` are computed at N6/N8 and
     *        assigned only after N9 passes, exactly as `_checkUniversal` handles `newSpent`. A
     *        request that fails at N7 leaves every counter untouched.
     *      - BOUNDS ARITHMETIC IS DONE IN `uint256`. `pin.offset` is `uint16`, so
     *        `uint256(offset) + 32` cannot wrap — but written as `uint16` arithmetic it would, and
     *        the check would pass on a crafted offset. Do not "simplify" the cast away.
     *      - `callsUsed` ALWAYS increments on success, including on a zero-value zero-amount call.
     *        A call is a use; mirroring universal's zero-amount rule (which writes nothing) would
     *        make `maxCalls` bypassable by zero-value calls, i.e. advisory. This is the one
     *        deliberate divergence between the two rulebooks.
     *      - N9 treats `maxCalls == UNLIMITED_CALLS` as "no limit" — exactly that value, not a range;
     *        every other value is the lifetime ceiling. Init refused 0, so 0 never reaches here.
     *      - Value-only configs carry no pins and no amount rule — init refuses that combination —
     *        so with `data.length == 0` the N7 loop does not execute and N8 is skipped.
     *
     * @param  id       Config id identifying the rules set.
     * @param  account  The wallet.
     * @param  target   Push-side call target; must be the configured native target.
     * @param  value    Push-native value attached to the call.
     * @param  data     The native calldata, read but never decoded as a structure.
     * @return The engine's success sentinel.
     */
    function _checkNative(ConfigId id, address account, address target, uint256 value, bytes calldata data)
        internal
        returns (uint256)
    {
        NativeConfig storage cfg = _native[id][msg.sender][account];

        // N1
        if (!cfg.initialized) revert UniversalRulesPolicyErrors.NotInitialized(id, account);

        // N2
        if (block.timestamp > cfg.validUntil) revert UniversalRulesPolicyErrors.RulesExpired(cfg.validUntil);

        // N3 — the consistency lock, mirror of universal gate 3. Init refuses a gateway target, so
        // this can only fire on state the wallet's grant check makes unreachable. It is defence in
        // depth against a mis-wired grant, not dead code.
        if (target == UNIVERSAL_GATEWAY_PC) revert UniversalRulesPolicyErrors.NativeTargetIsGateway(target);

        // N4
        if (target != cfg.target) revert UniversalRulesPolicyErrors.TargetMismatch(target, cfg.target);

        // N5 — under four bytes is the engine's value-only selector; four or more is a real one.
        bytes4 sel = data.length < 4 ? VALUE_SELECTOR : bytes4(data[0:4]);
        if (sel != cfg.selector) revert UniversalRulesPolicyErrors.SelectorMismatch(sel, cfg.selector);
        // Value-only means EMPTY calldata (register N-46). The engine buckets 1..3 bytes under the
        // same actionId, so URP is the layer that makes the documented meaning true.
        if (sel == VALUE_SELECTOR && data.length != 0) {
            revert UniversalRulesPolicyErrors.ValueOnlyCalldataNotEmpty(data.length);
        }

        // N6
        if (value > cfg.maxValuePerCall) revert UniversalRulesPolicyErrors.ValueExceedsCap(value, cfg.maxValuePerCall);
        uint256 newValueSpent = cfg.valueSpent + value;
        if (newValueSpent > cfg.maxValueTotal) {
            revert UniversalRulesPolicyErrors.TotalValueExceeded(newValueSpent, cfg.maxValueTotal);
        }

        // N7 — EQ and MAX. EQ is unchanged in meaning and in error; MAX is new, and bounds ONE call.
        // It is NOT a lifetime cap: `AmountRule` (N8) remains the only lifetime metering on a native
        // call, so a MAX pin on an amount argument limits each call and not the total.
        uint256 pinCount = cfg.pins.length;
        for (uint256 i; i < pinCount;) {
            ArgPin storage pin = cfg.pins[i];
            uint256 needed = uint256(pin.offset) + 32;
            if (data.length < needed) revert UniversalRulesPolicyErrors.CalldataTooShortForPin(data.length, i, needed);

            bytes32 actual = bytes32(data[pin.offset:needed]);
            // Named `pinned`, not `value`: `value` is this function's Push-native value parameter.
            bytes32 pinned = pin.value;

            if (pin.op == PinOp.EQ) {
                if (actual != pinned) revert UniversalRulesPolicyErrors.ArgPinMismatch(actual, i, pinned);
            } else if (uint256(actual) > uint256(pinned)) {
                revert UniversalRulesPolicyErrors.ArgPinAboveMax(uint256(actual), i, uint256(pinned));
            }

            unchecked {
                ++i;
            }
        }

        // N8
        uint256 amt;
        uint256 newAmountSpent = cfg.amountSpent;
        if (cfg.amount.enabled) {
            uint256 neededAmt = uint256(cfg.amount.offset) + 32;
            if (data.length < neededAmt) {
                revert UniversalRulesPolicyErrors.CalldataTooShortForAmount(data.length, neededAmt);
            }

            amt = uint256(bytes32(data[cfg.amount.offset:neededAmt]));
            if (amt > cfg.amount.maxPerCall) {
                revert UniversalRulesPolicyErrors.NativeAmountExceedsCap(amt, cfg.amount.maxPerCall);
            }

            newAmountSpent = cfg.amountSpent + amt;
            if (newAmountSpent > cfg.amount.maxTotal) {
                revert UniversalRulesPolicyErrors.TotalNativeAmountExceeded(newAmountSpent, cfg.amount.maxTotal);
            }
        }

        // N9 — UNLIMITED_CALLS is the only "no limit" value; init refused 0.
        if (cfg.maxCalls != UNLIMITED_CALLS && cfg.callsUsed >= cfg.maxCalls) {
            revert UniversalRulesPolicyErrors.CallLimitReached(cfg.callsUsed, cfg.maxCalls);
        }

        // Effects, last.
        cfg.valueSpent = newValueSpent;
        cfg.amountSpent = newAmountSpent;
        unchecked {
            // Bounded by N9 unless `maxCalls == UNLIMITED_CALLS`. Then the counter is informational,
            // and a uint32 wrap is unreachable at any realistic call volume and, being unchecked,
            // harmless.
            cfg.callsUsed = cfg.callsUsed + 1;
        }
        emit NativeCallMetered(id, msg.sender, account, value, amt);

        return VALIDATION_SUCCESS;
    }

    /**
     * @dev Implements gates 12 to 16 of `checkAction`'s list.
     *
     *      - Split out for stack depth only. It makes no external call and writes no storage, so the
     *        caller's effects-last property holds.
     *      - Gate 12 is not merely a format check: the destination account dispatches on the payload
     *        prefix, and only the multicall branch has entries that gates 13 to 16 can walk. Its
     *        other branches re-target the account itself or call an arbitrary target with the raw
     *        payload, bypassing the allow-list, the beneficiary pin and the per-entry value cap.
     *        Do not weaken this gate, or the agent picks its own branch.
     *      - A payload that is exactly the multicall selector, or the selector followed by malformed
     *        bytes, reverts inside the ABI decoder rather than with a named error. No minimum-length
     *        pre-check is added: unlike gate 4c, this decode sits behind eleven gates on an already
     *        constrained request, so a second hand-derived constant would be more surface than the
     *        named error is worth. It fails closed either way.
     *
     * @param cfg      Config to validate against.
     * @param account  The wallet, used as the forbidden self-target and the refund destination.
     * @param payload  The multicall payload carried by the outbound request.
     */
    function _checkInnerCalls(Config storage cfg, address account, bytes memory payload) internal view {
        if (payload.length < 4 || bytes4(_slice(payload, 0, 4)) != MULTICALL_SELECTOR) {
            revert UniversalRulesPolicyErrors.PayloadNotMulticall();
        }

        Multicall[] memory calls = abi.decode(_slice(payload, 4, payload.length - 4), (Multicall[]));

        uint256 count = calls.length;
        if (count == 0 || count > MAX_ACTIONS_PER_REQUEST) {
            revert UniversalRulesPolicyErrors.BatchSizeOutOfRange(count);
        }

        address expectedCEA = cfg.expectedCEA;

        for (uint256 i; i < count;) {
            Multicall memory entry = calls[i];

            if (
                entry.to == account || entry.to == address(this) || entry.to == UNIVERSAL_GATEWAY_PC
                    || entry.to == expectedCEA
            ) {
                revert UniversalRulesPolicyErrors.ForbiddenInnerTarget(entry.to);
            }
            if (entry.data.length < 4) revert UniversalRulesPolicyErrors.MalformedInnerCalldata();

            _requireAllowed(cfg, entry, bytes4(_slice(entry.data, 0, 4)), expectedCEA, i);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Gates 15 and 16 for ONE inner call: the allow-list, the beneficiary, the value cap and the
     *      pins. Reverts if the call is permitted by no entry; returns silently if it is.
     *
     *      ANY-MATCH, NOT FIRST-MATCH (decision P-4). Several entries may share one
     *      `(target, selector)`, and the call passes if ANY of them passes IN FULL. That is what lets
     *      one token be approved to Aave *or* to Uniswap — two entries, one pinned spender each —
     *      which a single entry cannot express, because a pin is an equality and a call has one
     *      spender. The previous behaviour returned the FIRST `(target, selector)` match and ignored
     *      every later entry, so a second entry was dead weight.
     *
     *      WHICH ERROR SURFACES WHEN NOTHING PASSES: the FIRST matching entry's failure, verbatim.
     *      Reporting the last would mean an owner who appended a loose entry sees a complaint about
     *      that one rather than about the rule they meant to use, and reporting a synthesised
     *      "nothing matched" error would throw away the argument that tells them *why*.
     *
     *      THE SINGLE-ENTRY PATH IS BYTE-IDENTICAL TO BEFORE. With one entry per
     *      `(target, selector)` and no pins, the loop matches once, `_entryFailure` evaluates the same
     *      beneficiary and value checks in the same order, and the same error bytes come back. The
     *      pre-existing suite is the proof, and it passes unedited.
     *
     * @param cfg          Config whose allow-list is scanned.
     * @param entry        The inner call under test.
     * @param selector     Its selector, already sliced by the caller.
     * @param expectedCEA  The committed destination account.
     * @param index        The inner call's index, for `InnerValueExceedsAllowance`.
     */
    function _requireAllowed(
        Config storage cfg,
        Multicall memory entry,
        bytes4 selector,
        address expectedCEA,
        uint256 index
    ) internal view {
        uint256 len = cfg.allowedCalls.length;
        bytes memory firstErr;
        bool matched;

        for (uint256 i; i < len;) {
            // STORAGE REFERENCE, never a memory copy: an entry now carries a dynamic pin array, and
            // copying one per candidate would allocate on every miss.
            AllowedCall storage rule = cfg.allowedCalls[i];

            if (rule.target == entry.to && rule.selector == selector) {
                matched = true;
                bytes memory err = _entryFailure(rule, entry, expectedCEA, index);
                if (err.length == 0) return; // this entry permits the call, in full
                if (firstErr.length == 0) firstErr = err;
            }

            unchecked {
                ++i;
            }
        }

        if (!matched) revert UniversalRulesPolicyErrors.CallNotAllowed(entry.to, selector);

        // The first matching entry's failure, byte for byte, so the engine's
        // `PolicyCheckReverted(bytes32)` wrapping sees exactly what a direct revert would have
        // produced. Assembly because Solidity has no "revert with these bytes" statement.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            revert(add(firstErr, 32), mload(firstErr))
        }
    }

    /**
     * @dev Whether ONE allow-list entry permits ONE inner call. Returns the ABI-encoded custom error
     *      of the first failure, or EMPTY BYTES if the entry permits the call in full.
     *
     *      IT RETURNS RATHER THAN REVERTS because any-match needs to try the next entry after a
     *      failure, and a revert cannot be caught without an external call — which `checkAction` must
     *      not have. The bytes it builds are byte-identical to what
     *      `abi.encodeWithSelector(<error>.selector, args...)` produces.
     *
     *      ORDER IS FIXED (decision P-5): beneficiary, then value, then pins in array order. Pins run
     *      LAST so the two pre-existing checks keep reporting their own errors on a call that fails
     *      both — which is what makes the single-entry path byte-identical to the old code.
     *
     * @param rule         The candidate entry.
     * @param entry        The inner call under test.
     * @param expectedCEA  The committed destination account.
     * @param index        The inner call's index, for `InnerValueExceedsAllowance`.
     * @return Empty if the entry permits the call; otherwise the encoded error.
     */
    function _entryFailure(AllowedCall storage rule, Multicall memory entry, address expectedCEA, uint256 index)
        internal
        view
        returns (bytes memory)
    {
        // 1 · the beneficiary, with today's semantics exactly: the LOW 160 BITS are compared, so an
        //     argument with dirty high bytes still matches. An EQ pin is stricter (full word) and is
        //     the recommended replacement, but this check's meaning is deliberately unchanged.
        if (rule.hasBeneficiary) {
            uint256 offset = uint256(rule.beneficiaryOffset);
            if (offset + 32 > entry.data.length) {
                return abi.encodeWithSelector(UniversalRulesPolicyErrors.MalformedInnerCalldata.selector);
            }
            address beneficiary = _extractBeneficiary(entry.data, rule.beneficiaryOffset);
            if (beneficiary != expectedCEA) {
                return abi.encodeWithSelector(
                    UniversalRulesPolicyErrors.BeneficiaryMismatch.selector, expectedCEA, beneficiary
                );
            }
        }

        // 2 · the value cap. Destination-chain native units, never the Push-side value: two assets on
        //     two chains.
        if (entry.value > rule.maxValue) {
            return abi.encodeWithSelector(
                UniversalRulesPolicyErrors.InnerValueExceedsAllowance.selector, index, entry.value, rule.maxValue
            );
        }

        // 3 · the pins, in array order.
        uint256 pinCount = rule.pins.length;
        for (uint256 k; k < pinCount;) {
            ArgPin storage pin = rule.pins[k];
            uint256 needed = uint256(pin.offset) + 32;
            if (entry.data.length < needed) {
                return abi.encodeWithSelector(
                    UniversalRulesPolicyErrors.CalldataTooShortForPin.selector, entry.data.length, k, needed
                );
            }

            bytes32 word = _loadWord(entry.data, pin.offset);
            bytes32 pinned = pin.value;

            if (pin.op == PinOp.EQ) {
                if (word != pinned) {
                    return abi.encodeWithSelector(UniversalRulesPolicyErrors.ArgPinMismatch.selector, word, k, pinned);
                }
            } else if (uint256(word) > uint256(pinned)) {
                return abi.encodeWithSelector(
                    UniversalRulesPolicyErrors.ArgPinAboveMax.selector, uint256(word), k, uint256(pinned)
                );
            }

            unchecked {
                ++k;
            }
        }

        return "";
    }

    /**
     * @dev Loads the 32-byte word at `offset` from a memory blob. The caller has already proved the
     *      word is inside `b`; this helper does not re-check, exactly as the native N7 read does not.
     *
     *      Added for the EVM pins. `_extractBeneficiary` cannot serve both: it masks to 160 bits,
     *      which is precisely the behaviour an EQ pin must NOT have.
     */
    function _loadWord(bytes memory b, uint256 offset) internal pure returns (bytes32 w) {
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            w := mload(add(add(b, 0x20), offset))
        }
    }

    // ───────────────────────── svm byte helpers (pure, memory only) ─────────────────────────

    /**
     * @notice Exact-equality assertion on every per-asset spend counter; the change-flow race guard.
     *
     * @dev    - Intended as the first entry of the owner's atomic change batch: assert, revoke,
     *           grant. A mismatch reverts the whole change.
     *         - Reverts if the config is not initialised. Reading zero from a ghost config is
     *           indistinguishable from reading zero from a real unused rules set, and this function
     *           exists to catch stale belief, so it must not have a silent-pass mode.
     *         - One expected value per listed asset, in list order; a different count reverts
     *           `SpentLengthMismatch` rather than checking a prefix.
     *         - Exact equality in both directions, so a credit landing between read and submit also
     *           forces recomposition.
     *         - Callable by anyone; it is a pure read.
     *
     * @param  id             Config id identifying the rules set.
     * @param  account        The wallet the rules set belongs to.
     * @param  expectedSpent  The per-asset spend totals the caller composed its change against.
     */
    function assertSpent(ConfigId id, address account, uint256[] calldata expectedSpent) external view {
        (bool init, RulesType mode) = _modeOf(id, SESSION_ENGINE, account);
        if (init && mode == RulesType.NATIVE) revert UniversalRulesPolicyErrors.WrongModeForCall(RulesType.NATIVE);

        AssetCapState[] storage assets = _universalAssets(id, account);

        uint256 n = assets.length;
        if (expectedSpent.length != n) revert UniversalRulesPolicyErrors.SpentLengthMismatch(n, expectedSpent.length);
        for (uint256 i; i < n;) {
            AssetCapState storage a = assets[i];
            if (a.spent != expectedSpent[i]) {
                revert UniversalRulesPolicyErrors.AssetSpentMismatch(a.token, expectedSpent[i], a.spent);
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice The native change-flow race guard: exact equality on all three counters.
     *
     * @dev    - The native counterpart of the universal `assertSpent`, and the same intent: the
     *           first entry of the owner's atomic change batch — assert, revoke, grant.
     *         - Reverts `WrongModeForCall(UNIVERSAL)` on a universal config and `NotInitialized` on
     *           a ghost. It must not have a silent-pass mode: reading zero from a ghost config is
     *           indistinguishable from reading zero from a real unused rules set, and this function
     *           exists to catch stale belief.
     *         - Exact equality on every counter, in both directions.
     *         - Callable by anyone; it is a pure read.
     *
     * @param  id                   Config id identifying the rules set.
     * @param  account              The wallet the rules set belongs to.
     * @param  expectedValueSpent   Native value total the caller composed against.
     * @param  expectedAmountSpent  Metered calldata-amount total the caller composed against.
     * @param  expectedCalls        Call count the caller composed against.
     */
    function assertSpent(
        ConfigId id,
        address account,
        uint256 expectedValueSpent,
        uint256 expectedAmountSpent,
        uint32 expectedCalls
    ) external view {
        (bool init, RulesType mode) = _modeOf(id, SESSION_ENGINE, account);

        if (!init) revert UniversalRulesPolicyErrors.NotInitialized(id, account);
        if (mode != RulesType.NATIVE) revert UniversalRulesPolicyErrors.WrongModeForCall(RulesType.UNIVERSAL);

        NativeConfig storage cfg = _native[id][SESSION_ENGINE][account];

        if (cfg.valueSpent != expectedValueSpent) {
            revert UniversalRulesPolicyErrors.SpentMismatch(expectedValueSpent, cfg.valueSpent);
        }
        if (cfg.amountSpent != expectedAmountSpent) {
            revert UniversalRulesPolicyErrors.SpentMismatch(expectedAmountSpent, cfg.amountSpent);
        }
        if (cfg.callsUsed != expectedCalls) {
            revert UniversalRulesPolicyErrors.SpentMismatch(expectedCalls, cfg.callsUsed);
        }
    }

    /**
     * @notice Credits a confirmed far-side failure back to one asset's spend counter.
     *
     * @dev    - Callable only by the executor module; nobody else can fabricate a failure.
     *         - A ghost config reverts `NotInitialized` and an unlisted token `AssetNotAllowed`; the
     *           revert rolls the idempotency flag back, so a misrouted credit stays retryable. Both are
     *           resolved BEFORE the flag is checked, so an already-credited id sent with an unlisted
     *           token reports the token, the actionable mistake.
     *         - Reverts if the id was already credited.
     *         - Subtracts saturating, since the amount is trusted from Push core and cannot be
     *           verified here. Idempotency and saturation bound a wrong value, PER ASSET: a credit
     *           can never lower another token's counter.
     *         - `token` is trusted from the caller as much as `amount` is: URP never learns the
     *           outbound id at check time, so it cannot map an id to the token it metered.
     *         - Emits the amount actually applied, not the amount claimed, so monitoring can detect
     *           divergence between the two.
     *         - Not yet functional: the executor module does not yet call this on outbound failure,
     *           so until that lands a failed far leg leaves `spent` inflated and the remedy is
     *           revoke-and-regrant.
     *         - There is no gas counter and this path must never introduce one, because gas consumed
     *           on a failed outbound was genuinely consumed.
     *
     * @param  id            Config id identifying the rules set.
     * @param  account       The wallet the rules set belongs to.
     * @param  outboundTxId  Push-core transaction id, the idempotency key.
     * @param  token         The listed asset whose counter is credited.
     * @param  amount        Amount claimed as failed, credited saturating.
     */
    function creditRevert(ConfigId id, address account, bytes32 outboundTxId, address token, uint256 amount) external {
        if (msg.sender != UNIVERSAL_EXECUTOR_MODULE) revert UniversalRulesPolicyErrors.CallerIsNotUEModule(msg.sender);

        AssetCapState storage cap = RulesLib.assetFor(_universalAssets(id, account), token);

        if (_credited[outboundTxId]) revert UniversalRulesPolicyErrors.AlreadyCredited(outboundTxId);
        _credited[outboundTxId] = true;

        uint256 applied = cap.spent > amount ? amount : cap.spent;
        cap.spent -= applied;

        emit RevertCredited(outboundTxId, id, account, token, applied);
    }

    /**
     * @dev The engine-keyed asset list of a UNIVERSAL config, either family. Reverts `NotInitialized`
     *      on an empty EVM slot; an SVM family byte is only ever written together with an initialised
     *      `SvmConfig`, so that branch needs no check. Shared by `assertSpent` and `creditRevert`.
     */
    function _universalAssets(ConfigId id, address account) internal view returns (AssetCapState[] storage) {
        if (_vmOf(id, SESSION_ENGINE, account) == VmFamily.SVM) return _svm[id][SESSION_ENGINE][account].assets;

        Config storage cfg = _configs[id][SESSION_ENGINE][account];
        if (!cfg.initialized) revert UniversalRulesPolicyErrors.NotInitialized(id, account);
        return cfg.assets;
    }

    /**
     * @notice The full universal config including the allow-list, keyed on the session engine.
     *
     * @dev    Reverts `WrongModeForCall(NATIVE)` on a native slot. An EMPTY slot returns the zeroed
     *         struct exactly as it always has — an empty slot is a STATE, a wrong-mode read is a
     *         CALLER BUG, and only the second is worth a revert. `getMode` is the documented first
     *         call for anything that does not already know a rules set's mode.
     *
     * @param  id       Config id identifying the rules set.
     * @param  account  The wallet the rules set belongs to.
     * @return The stored config.
     */
    function getConfig(ConfigId id, address account) external view returns (Config memory) {
        (bool init, RulesType mode) = _modeOf(id, SESSION_ENGINE, account);
        if (init && mode == RulesType.NATIVE) revert UniversalRulesPolicyErrors.WrongModeForCall(RulesType.NATIVE);
        if (init && _vmOf(id, SESSION_ENGINE, account) == VmFamily.SVM) {
            revert UniversalRulesPolicyErrors.WrongVmForCall(VmFamily.SVM);
        }

        return _configs[id][SESSION_ENGINE][account];
    }

    /**
     * @notice The full SVM config including its rules and pins, keyed on the session engine.
     * @dev    Reverts `WrongModeForCall(NATIVE)` on a native slot and `WrongVmForCall(EVM)` on an EVM
     *         universal slot; an empty slot returns the zeroed struct. See `getConfig`.
     * @param  id       Config id identifying the rules set.
     * @param  account  The wallet the rules set belongs to.
     * @return The stored SVM config.
     */
    function getSvmConfig(ConfigId id, address account) external view returns (SvmConfig memory) {
        (bool init, RulesType mode) = _modeOf(id, SESSION_ENGINE, account);
        if (init && mode == RulesType.NATIVE) revert UniversalRulesPolicyErrors.WrongModeForCall(RulesType.NATIVE);
        if (init && _vmOf(id, SESSION_ENGINE, account) == VmFamily.EVM) {
            revert UniversalRulesPolicyErrors.WrongVmForCall(VmFamily.EVM);
        }

        return SvmRulebook.read(_svm[id][SESSION_ENGINE][account]);
    }

    /**
     * @notice The full native config including its pins, keyed on the session engine.
     * @dev    Reverts `WrongModeForCall(UNIVERSAL)` on a universal slot; an empty slot returns the
     *         zeroed struct. See `getConfig`.
     * @param  id       Config id identifying the rules set.
     * @param  account  The wallet the rules set belongs to.
     * @return The stored native config.
     */
    function getNativeConfig(ConfigId id, address account) external view returns (NativeConfig memory) {
        (bool init, RulesType mode) = _modeOf(id, SESSION_ENGINE, account);
        if (init && mode == RulesType.UNIVERSAL) {
            revert UniversalRulesPolicyErrors.WrongModeForCall(RulesType.UNIVERSAL);
        }

        return _native[id][SESSION_ENGINE][account];
    }

    /**
     * @notice Which rulebook a config uses, and which chain it was granted for. NEVER REVERTS.
     * @dev    The documented first call for any integrator that does not already know a rules set's
     *         mode. An empty slot returns `(initialized: false, mode: UNIVERSAL, chainHash: 0)` — and
     *         the mode value is MEANINGLESS when `initialized` is false, because `UNIVERSAL` is the
     *         enum's zero value. Read `initialized` first, always.
     *
     *         `chainHash` is the rules set's chain, recorded at init (and, for a universal rules set,
     *         verified against every listed asset). It is THE chain record; there is no other.
     * @param  id       Config id identifying the rules set.
     * @param  account  The wallet the rules set belongs to.
     * @return The stored mode record.
     */
    function getMode(ConfigId id, address account) external view returns (ModeSlot memory) {
        return _mode[id][SESSION_ENGINE][account];
    }

    /**
     * @notice Exposes the idempotency set for monitoring.
     * @param  outboundTxId  Push-core transaction id to query.
     * @return Whether that id has already been credited.
     */
    function isCredited(bytes32 outboundTxId) external view returns (bool) {
        return _credited[outboundTxId];
    }

    /**
     * @notice The implementation's version, readable THROUGH the proxy.
     *
     * @dev    The proxy has no version of its own — it delegates, so this answers with whichever
     *         implementation is currently installed. That makes it the cheapest possible check that
     *         an upgrade actually took effect: read it before, upgrade, read it again.
     *
     *         A `constant` in bytecode, deliberately not storage: it must change with the CODE, and
     *         a storage value could drift from the logic it claims to describe.
     *
     *         BUMP THIS IN THE SAME COMMIT AS ANY LOGIC CHANGE.
     */
    function version() external pure returns (string memory) {
        return "3.1.0";
    }

    /**
     * @notice ERC-165 support check.
     * @param  iid  Interface id to query.
     * @return True for the action-policy, policy and ERC-165 interfaces.
     */
    function supportsInterface(bytes4 iid) external pure returns (bool) {
        return
            iid == type(IActionPolicy).interfaceId || iid == type(IPolicy).interfaceId
                || iid == type(IERC165).interfaceId;
    }

    /**
     * @dev Reads the 32-byte word at `offset` and returns its low 20 bytes. Bounds-checked because
     *      reading past the end of a short blob would return adjacent memory, which could be
     *      manipulated to pass the beneficiary check.
     *
     * @param  data    Inner call calldata to read from.
     * @param  offset  Byte offset of the beneficiary word, taken from config and never the request.
     * @return The address encoded at that offset.
     */
    function _extractBeneficiary(bytes memory data, uint16 offset) internal pure returns (address) {
        if (uint256(offset) + 32 > data.length) revert UniversalRulesPolicyErrors.MalformedInnerCalldata();
        bytes32 word;
        assembly {
            word := mload(add(add(data, 0x20), offset))
        }
        return address(uint160(uint256(word)));
    }

    /**
     * @dev Memory slice helper. The bounds branch is unreachable from the three call sites, which
     *      are all length-guarded by gates 12 and 14, and is expected to show as uncovered. It stays
     *      because this is a `pure` helper whose safety must not depend on every future caller.
     *
     * @param  data   Blob to slice.
     * @param  start  Byte offset to start at.
     * @param  len    Number of bytes to copy.
     * @return out    The requested slice.
     */
    function _slice(bytes memory data, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        if (start + len > data.length) revert UniversalRulesPolicyErrors.MalformedInnerCalldata();
        out = new bytes(len);
        // MCOPY requires evm_version = "cancun"; lowering the EVM target breaks this silently at
        // deploy time rather than loudly at compile time.
        assembly ("memory-safe") {
            mcopy(add(out, 0x20), add(add(data, 0x20), start), len)
        }
    }

    /**
     * @dev Copies decoded WIRE terms into the STORAGE config. The two are deliberately different
     *      types: the wire shape is free to change, the storage layout is frozen forever
     *      (see the layout note on `__gap`).
     *
     *      - Forces every asset's `spent` to zero. It is not a wire field at all — URP owns it.
     *      - Stores no chain: the chain of every rules set lives on `ModeSlot.chainHash`, where it has
     *        been verified against every listed asset.
     *      - Clears and repopulates the allow-list.
     *      - Does not set `initialized`; the caller does, immediately after this returns.
     *
     * @param cfg       Storage slot to write into.
     * @param incoming  Decoded wire terms to copy from.
     */
    function _store(Config storage cfg, UniversalTerms memory incoming) internal {
        cfg.validUntil = incoming.validUntil;
        cfg.expectedCEA = incoming.expectedCEA;
        cfg.maxGasPerCall = incoming.maxGasPerCall;
        delete cfg.assets;
        RulesLib.storeAssets(cfg.assets, incoming.assets);

        // Re-initialisation is refused, so in production this array is always empty here. The
        // delete is kept for the stranger-slice path and for tests.
        delete cfg.allowedCalls;
        uint256 len = incoming.allowedCalls.length;
        for (uint256 i; i < len;) {
            AllowedCall memory src = incoming.allowedCalls[i];

            // MEMBER BY MEMBER, NOT `push(src)`. Since `AllowedCall` gained `ArgPin[] pins`, Solidity
            // cannot copy a memory struct holding a dynamic array into a storage array in one
            // assignment — the same restriction that already forced the element-by-element loops in
            // `_storeNative` and `_storeSvm`. `push()` with no argument appends a zeroed entry and
            // returns the storage reference to fill in.
            AllowedCall storage dst = cfg.allowedCalls.push();
            dst.target = src.target;
            dst.selector = src.selector;
            dst.beneficiaryOffset = src.beneficiaryOffset;
            dst.hasBeneficiary = src.hasBeneficiary;
            dst.maxValue = src.maxValue;

            uint256 pinCount = src.pins.length;
            for (uint256 p; p < pinCount;) {
                // `ArgPin` has no dynamic member, so this one still assigns wholesale.
                dst.pins.push(src.pins[p]);
                unchecked {
                    ++p;
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Copies a decoded native config into storage. The native counterpart of `_store`.
     *
     *      - Forces `valueSpent`, `amountSpent` and `callsUsed` to zero, ignoring anything the
     *        caller supplied. A caller-set counter would be a granted head start on every cap.
     *      - `amount` is a value struct with no dynamic members, so it assigns wholesale.
     *      - `pins` must be copied ELEMENT BY ELEMENT: Solidity cannot assign a memory dynamic array
     *        into a storage struct field. Same shape as `allowedCalls` above, same reason.
     *      - Does not set `initialized`; the caller does, immediately after this returns.
     *
     * @param cfg       Storage slot to write into.
     * @param incoming  Decoded native wire terms to copy from.
     */
    function _storeNative(NativeConfig storage cfg, NativeTerms memory incoming) internal {
        cfg.validUntil = incoming.validUntil;
        cfg.target = incoming.target;
        cfg.selector = incoming.selector;
        cfg.maxValuePerCall = incoming.maxValuePerCall;
        cfg.maxValueTotal = incoming.maxValueTotal;
        cfg.valueSpent = 0;
        cfg.amount = incoming.amount;
        cfg.amountSpent = 0;
        cfg.maxCalls = incoming.maxCalls;
        cfg.callsUsed = 0;

        // Re-initialisation is refused, so in production this array is always empty here. The
        // delete is kept for the stranger-slice path and for tests.
        delete cfg.pins;
        uint256 len = incoming.pins.length;
        for (uint256 i; i < len;) {
            cfg.pins.push(incoming.pins[i]);
            unchecked {
                ++i;
            }
        }
    }
}
