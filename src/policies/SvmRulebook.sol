// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { UniversalRulesPolicyErrors } from "../libraries/Errors.sol";

import { VALIDATION_SUCCESS } from "erc7579/interfaces/IERC7579Module.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";

import { IUniversalRulesPolicy } from "../interfaces/IUniversalRulesPolicy.sol";
import { RulesLib } from "../libraries/RulesLib.sol";
import {
    AllowedProgram,
    ANY_ACCOUNT_COUNT,
    AssetCapState,
    MIN_OUTBOUND_BODY_LEN,
    SEND_OUTBOUND_SELECTOR,
    SvmAccountPin,
    SvmConfig,
    SvmDataPin,
    SvmDataPinMode,
    SvmTerms,
    UniversalOutboundTxRequest
} from "../libraries/Types.sol";

// Cluster-independent Solana program ids, never targets. Decoded from their base58 ids by tooling and
// pinned by `test_svm_forbiddenProgramConstantsMatchBase58` — do not hand-edit a hex word. FILE-LEVEL,
// not inside the library, so that test can import them without inheriting all of the rulebook: a
// harness that did so grew past the 24,576-byte limit and failed `make sizes`. Inlined either way; no
// runtime cost.
/// @dev `11111111111111111111111111111111` — a system transfer with the CEA as funder drains it.
bytes32 constant SYSTEM_PROGRAM = bytes32(0);
/// @dev `TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA` — transfer/approve/close with CEA authority.
bytes32 constant SPL_TOKEN_PROGRAM = 0x06ddf6e1d765a193d9cbe146ceeb79ac1cb485ed5f5b37913a8cf5857eff00a9;
/// @dev `TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb` — the same surface on Token-2022.
bytes32 constant TOKEN_2022_PROGRAM = 0x06ddf6e1ee758fde18425dbce46ccddab61afc4d83b90d27febdf928d8a18bfc;
/// @dev `Stake11111111111111111111111111111111111111` — withdraw with the CEA as authority.
bytes32 constant STAKE_PROGRAM = 0x06a1d8179137542a983437bdfe2a7ab2557f535c8a78722b68a49dc000000000;
/// @dev `BPFLoaderUpgradeab1e11111111111111111111111` — never a CEA action; refused outright.
bytes32 constant BPF_LOADER_UPGRADEABLE = 0x02a8f6914e88a1b0e210153ef763ae2b00c2b93d16c124d2c0537a1004800000;
/// @dev `AddressLookupTab1e1111111111111111111111111` — rent drain with the CEA as payer.
bytes32 constant ADDRESS_LOOKUP_TABLE = 0x0277a6af97339b7ac88d1892c90446f50002309266f62e53c118244982000000;

/**
 * @title  SvmRulebook — the Solana (`solana:*`) rulebook, extracted from `UniversalRulesPolicy`.
 *
 * @notice EXTERNAL library, linked into URP at deploy time and reached with `DELEGATECALL`. It holds
 *         the whole SVM surface: the grant guards (`init`), the S1-S18 gauntlet (`check`) and the
 *         config read (`read`).
 *
 * @dev    WHY THIS FILE EXISTS. URP was 24,326 B against EIP-170's 24,576 B — 250 B of headroom,
 *         with no room for the EVM-pin feature. The Solana rulebook is about 7.9 KB of that, and it
 *         is the one rulebook that shares no runtime path with the other two: a request is EVM,
 *         native or Solana, never a mixture. Moving it out buys the headroom without touching a
 *         single gate.
 *
 *         THE DELEGATECALL MODEL, and why the behaviour is identical:
 *         - It runs in the PROXY's context. `address(this)` is the proxy, so storage pointers URP
 *           passes in address the proxy's own slots and every write lands exactly where it did.
 *         - `msg.sender` SURVIVES `DELEGATECALL`. Inside `check` it is still the engine, which is
 *           what `OutboundMetered`'s `multiplexer` field records.
 *         - EVENTS ARE EMITTED FROM THE PROXY'S ADDRESS, not the library's, and the declaration is
 *           REUSED from `IUniversalRulesPolicy` rather than redeclared, so the topic cannot drift.
 *         - REVERT DATA BUBBLES UNCHANGED. Errors stay `UniversalRulesPolicyErrors.*`, with their
 *           arguments, exactly as a caller saw them before the split.
 *         - DIRECT CALLS ARE REFUSED. Solidity's library call protection makes a non-view external
 *           library function revert when called directly instead of delegatecalled.
 *         - IT DECLARES NO STORAGE. A library cannot, and a test pins that.
 *
 *         THE `checkAction` INVARIANT, RESTATED (decision S-3). URP's `checkAction` makes no
 *         external call EXCEPT the `DELEGATECALL` into this linked rulebook library: stateless code
 *         fixed at deploy, never a token, a wallet, the engine or any address supplied at runtime.
 *         The old wording ("makes no external call") was absolute; this one is exact. What it
 *         protects is unchanged — nothing an attacker controls is ever called from the check path.
 *         `check` itself makes NO external call of any kind.
 *
 *         `gateway` IS PASSED IN, not read from storage: a library has no state of its own, and
 *         URP's `UNIVERSAL_GATEWAY_PC` lives in the proxy's slot 0. Passing it keeps this file free
 *         of any assumption about URP's layout.
 */
library SvmRulebook {
    // ───────────────────────────── svm rulebook bounds ─────────────────────────────

    /// @dev Maximum allow-list entries per SVM config. Mirrors MAX_ALLOWED_CALLS.
    uint256 internal constant MAX_ALLOWED_PROGRAMS = 32;
    /// @dev Maximum account pins per SVM config. Bounds the S17 and S18 loops.
    uint256 internal constant MAX_SVM_PINS = 16;
    /// @dev Maximum ix_data pins per SVM config.
    uint256 internal constant MAX_SVM_DATA_PINS = 8;
    /// @dev Maximum CEA-controlled accounts an owner may list. Bounds the S18 loop. 16 = the CEA, one
    ///      token account per listed asset (MAX_ASSETS = 8) and up to 7 swap-output accounts. S18 gas
    ///      grows with the number actually listed, never with this bound.
    uint256 internal constant MAX_CEA_ACCOUNTS = 16;
    /// @dev Loop bound on a request's account list. Solana's transaction size limit bites first.
    uint256 internal constant MAX_SVM_ACCOUNTS = 64;
    /// @dev Loop bound on a request's instruction data.
    uint256 internal constant MAX_SVM_IX_DATA = 1024;

    // The SVM payload grammar — the node's `decodePayload`, byte for byte:
    //   [u32 BE count][count × (pubkey32 ‖ is_writable u8)][u32 BE len][ix_data][u8 id][target32]
    uint256 internal constant SVM_HEADER_LEN = 4;
    uint256 internal constant SVM_ACCOUNT_LEN = 33;
    uint256 internal constant SVM_LEN_FIELD = 4;
    uint256 internal constant SVM_TRAILER_LEN = 33;
    uint8 internal constant SVM_INSTRUCTION_EXECUTE = 2;

    /// @dev The parsed shape of an execute payload. Memory only; never stored.
    struct SvmPayloadView {
        uint256 count;
        uint256 ixOff;
        uint256 ixLen;
        bytes32 target;
    }

    // ──────────────────────────────── grant path ────────────────────────────────

    /**
     * @dev The SVM init guards — the `solana:*` counterpart of `_initUniversal`.
     *      - Shape bounds first, then expiry and the three identity fields, then the allow-list
     *        rules, then the pins, then the teeth. Same discipline as the universal branch: every
     *        decode and guard before any write.
     *      - The teeth are IDENTICAL to the universal branch and for the same reason: each listed
     *        asset's `SOURCE_CHAIN_NAMESPACE()` is what the gateway routes on, so binding the declared
     *        chain to every one of them here is what makes a `solana:` grant with an EVM asset impossible.
     * @param cfg        Storage slot to write.
     * @param body       `abi.encode(SvmTerms)`.
     * @param chainHash  keccak256 of the declared chain string, verified against every listed asset.
     */
    function init(SvmConfig storage cfg, bytes memory body, bytes32 chainHash) external {
        SvmTerms memory incoming = abi.decode(body, (SvmTerms));

        uint256 ruleCount = incoming.programs.length;
        if (ruleCount == 0 || ruleCount > MAX_ALLOWED_PROGRAMS) {
            revert UniversalRulesPolicyErrors.ProgramListOutOfRange(ruleCount);
        }
        if (incoming.pins.length > MAX_SVM_PINS) {
            revert UniversalRulesPolicyErrors.TooManySvmPins(incoming.pins.length);
        }
        if (incoming.dataPins.length > MAX_SVM_DATA_PINS) {
            revert UniversalRulesPolicyErrors.TooManySvmDataPins(incoming.dataPins.length);
        }
        if (incoming.ceaAccounts.length > MAX_CEA_ACCOUNTS) {
            revert UniversalRulesPolicyErrors.TooManyCeaAccounts(incoming.ceaAccounts.length);
        }

        if (incoming.validUntil == 0 || incoming.validUntil <= block.timestamp) {
            revert UniversalRulesPolicyErrors.InvalidExpiry(incoming.validUntil);
        }
        if (incoming.expectedCEA == bytes32(0) || incoming.gatewayProgram == bytes32(0)) {
            revert UniversalRulesPolicyErrors.InvalidSvmConfigField();
        }

        _checkSvmRules(incoming);
        _checkSvmPinShapes(incoming);
        _checkCeaAccountList(incoming);

        RulesLib.requireAssets(incoming.assets, chainHash);

        _storeSvm(cfg, incoming);
        cfg.initialized = true;
    }

    /**
     * @dev Allow-list rule guards: tag shape, forbidden programs, and pairwise exactness.
     *      - A rule is `dataless` XOR has a 1..8-byte tag.
     *      - `maxAccounts` is `ANY_ACCOUNT_COUNT` (any count) or an exact count of 1..MAX_SVM_ACCOUNTS;
     *        0 and anything above the S13 bound are refused.
     *      - A program the check path forbids as a target is refused here too; S15 is then defence
     *        in depth against state this guard makes unreachable.
     *      - Two rules on one program must not both match one request, or first-match makes the
     *        later rule dead and its pins never run. O(n^2) at n <= 32.
     */
    function _checkSvmRules(SvmTerms memory t) private pure {
        uint256 n = t.programs.length;
        for (uint256 i; i < n;) {
            AllowedProgram memory r = t.programs[i];
            bool badLen = r.dataless ? r.discriminatorLen != 0 : (r.discriminatorLen == 0 || r.discriminatorLen > 8);
            if (badLen) revert UniversalRulesPolicyErrors.DiscriminatorLenOutOfRange(i, r.discriminatorLen);
            // Z-2: ANY_ACCOUNT_COUNT = any count; 1..MAX_SVM_ACCOUNTS = exact count; 0 and 65..254 refused.
            // 0 is "nothing": a rule that must carry zero accounts can own no account pin (every rule must),
            // and is refused here, named, instead of failing later as a confusing pin-index error.
            // A count above the S13 loop bound can never be met: every request would fail S13 or S16.
            if (r.maxAccounts != ANY_ACCOUNT_COUNT && (r.maxAccounts == 0 || r.maxAccounts > MAX_SVM_ACCOUNTS)) {
                revert UniversalRulesPolicyErrors.SvmMaxAccountsOutOfRange(i, r.maxAccounts);
            }
            if (_isForbiddenProgram(r.program, t.gatewayProgram, t.expectedCEA)) {
                revert UniversalRulesPolicyErrors.ForbiddenProgramInAllowList(i, r.program);
            }
            for (uint256 j; j < i;) {
                if (_rulesCollide(t.programs[j], r)) revert UniversalRulesPolicyErrors.AmbiguousRule(j, i);
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Two rules collide when a single request could match both: same program and either both
    ///      dataless, or neither dataless with one tag a prefix of the other. A dataless rule and a
    ///      tagged rule never collide — one needs empty ix_data, the other needs at least the tag.
    function _rulesCollide(AllowedProgram memory a, AllowedProgram memory b) private pure returns (bool) {
        if (a.program != b.program) return false;
        if (a.dataless || b.dataless) return a.dataless && b.dataless;
        uint256 shorter = a.discriminatorLen < b.discriminatorLen ? a.discriminatorLen : b.discriminatorLen;
        bytes8 mask = _prefixMask8(shorter);
        return (a.discriminator & mask) == (b.discriminator & mask);
    }

    /**
     * @dev Pin shape guards, both kinds.
     *      - Account pins: rule in range; index below the loop bound and, unless the rule is
     *        `ANY_ACCOUNT_COUNT`, below its exact account count too. Every rule must own at least one — HYGIENE: an
     *        authority-only pin always passes, and which positions must be pinned is the compiler's
     *        responsibility, not this contract's.
     *        One pin per (rule, index).
     *      - Data pins: rule in range and not dataless; `len` 1..32 for EQ, 1..8 otherwise; from-end
     *        offsets must reach at least `len` back; every offset stays inside the ix_data bound;
     *        the comparison value must be one the field can actually be compared against
     *        (`_dataPinValueValid`).
     */
    function _checkSvmPinShapes(SvmTerms memory t) private pure {
        uint256 ruleCount = t.programs.length;
        bool[] memory covered = new bool[](ruleCount); // rule i has at least one account pin

        uint256 n = t.pins.length;
        for (uint256 i; i < n;) {
            SvmAccountPin memory pin = t.pins[i];
            if (pin.ruleIndex >= ruleCount) revert UniversalRulesPolicyErrors.SvmPinRuleOutOfRange(i, pin.ruleIndex);
            uint8 cap = t.programs[pin.ruleIndex].maxAccounts;
            if (pin.accountIndex >= MAX_SVM_ACCOUNTS || (cap != ANY_ACCOUNT_COUNT && pin.accountIndex >= cap)) {
                revert UniversalRulesPolicyErrors.SvmPinIndexOutOfRange(i, pin.accountIndex);
            }
            // One position, one pin. Two pins on a (rule, index) are either redundant or
            // contradictory, and a contradictory pair makes the rule unsatisfiable. O(n^2), n <= 16.
            for (uint256 j; j < i;) {
                if (t.pins[j].ruleIndex == pin.ruleIndex && t.pins[j].accountIndex == pin.accountIndex) {
                    revert UniversalRulesPolicyErrors.DuplicateSvmPin(j, i);
                }
                unchecked {
                    ++j;
                }
            }
            covered[pin.ruleIndex] = true;
            unchecked {
                ++i;
            }
        }
        for (uint256 r; r < ruleCount;) {
            if (!covered[r]) revert UniversalRulesPolicyErrors.RuleWithoutPin(r);
            unchecked {
                ++r;
            }
        }

        n = t.dataPins.length;
        for (uint256 i; i < n;) {
            SvmDataPin memory dp = t.dataPins[i];
            if (dp.ruleIndex >= ruleCount || t.programs[dp.ruleIndex].dataless) {
                revert UniversalRulesPolicyErrors.SvmDataPinInvalid(i);
            }
            uint256 maxLen = dp.mode == SvmDataPinMode.EQ ? 32 : 8;
            if (dp.len == 0 || dp.len > maxLen) revert UniversalRulesPolicyErrors.SvmDataPinInvalid(i);
            if (!_offsetValid(dp.fromEnd, dp.offset, dp.len)) revert UniversalRulesPolicyErrors.SvmDataPinInvalid(i);
            if (!_dataPinValueValid(dp)) revert UniversalRulesPolicyErrors.SvmDataPinInvalid(i);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev A from-start field must end inside the bound; a from-end field must start at least `len`
    ///      back and no further back than the bound.
    function _offsetValid(bool fromEnd, uint16 offset, uint8 len) private pure returns (bool) {
        if (fromEnd) return uint256(offset) >= len && uint256(offset) <= MAX_SVM_IX_DATA;
        return uint256(offset) + len <= MAX_SVM_IX_DATA;
    }

    /**
     * @dev Refuses a data pin whose comparison is vacuous or impossible, and the encoding mistake that
     *      would make it so. The two value encodings differ by mode — EQ compares LEFT-ALIGNED raw
     *      bytes, the integer modes compare a RIGHT-ALIGNED integer — and each mis-encoding of one
     *      as the other is caught here, at grant, instead of producing a pin that silently never
     *      fails (a ceiling above the field's range) or never passes.
     *      - EQ: every byte of `expected` past `len` must be zero (a right-aligned integer would
     *        leave its value there).
     *      - GTE / LTE: `expected` must fit in `len` bytes, i.e. `< 2^(8·len)`.
     *      - RATIO: `num` and `den` non-zero (`num == 0` makes `a·den >= 0` always true), and the
     *        second field's offset valid.
     */
    function _dataPinValueValid(SvmDataPin memory dp) private pure returns (bool) {
        if (dp.mode == SvmDataPinMode.EQ) return dp.expected & ~_prefixMask32(dp.len) == bytes32(0);
        if (dp.mode == SvmDataPinMode.RATIO_GTE_LE) {
            return dp.num != 0 && dp.den != 0 && _offsetValid(dp.fromEnd, dp.offsetB, dp.len);
        }
        return uint256(dp.expected) >> (8 * uint256(dp.len)) == 0;
    }

    /**
     * @dev The CEA-controlled account list that S18 enforces.
     *      - Must contain `expectedCEA`. The CEA always holds value (it is the signer, and pSOL lands
     *        on it), so an empty or CEA-less list would silently switch the aliasing defence off.
     *      - No zero entry: `bytes32(0)` is the System program's id, present in most account lists,
     *        and would make every request fail.
     *      - No entry equal to an allow-listed program: Anchor passes the program's own account in
     *        many instructions, and listing it would make every such request fail.
     *      - No duplicates.
     *      All four fail closed at check time anyway; refusing them here means an owner never grants
     *      a rules set that can never be used.
     */
    function _checkCeaAccountList(SvmTerms memory t) private pure {
        uint256 n = t.ceaAccounts.length;
        bool hasCea;
        for (uint256 i; i < n;) {
            bytes32 key = t.ceaAccounts[i];
            if (key == bytes32(0)) revert UniversalRulesPolicyErrors.InvalidCeaAccount(i);
            if (key == t.expectedCEA) hasCea = true;
            for (uint256 j; j < i;) {
                if (t.ceaAccounts[j] == key) revert UniversalRulesPolicyErrors.InvalidCeaAccount(i);
                unchecked {
                    ++j;
                }
            }
            uint256 rules = t.programs.length;
            for (uint256 r; r < rules;) {
                if (t.programs[r].program == key) revert UniversalRulesPolicyErrors.InvalidCeaAccount(i);
                unchecked {
                    ++r;
                }
            }
            unchecked {
                ++i;
            }
        }
        if (!hasCea) revert UniversalRulesPolicyErrors.CeaAccountsMissExpectedCEA();
    }

    /// @dev The programs an SVM rules set may never target, directly. Inner CPIs are the allow-listed
    ///      program's own business — this set guards the top level only.
    function _isForbiddenProgram(bytes32 program, bytes32 gatewayProgram, bytes32 cea) private pure returns (bool) {
        return program == SYSTEM_PROGRAM || program == SPL_TOKEN_PROGRAM || program == TOKEN_2022_PROGRAM
            || program == STAKE_PROGRAM || program == BPF_LOADER_UPGRADEABLE || program == ADDRESS_LOOKUP_TABLE
            || program == gatewayProgram || program == cea;
    }

    /**
     * @dev Copies decoded SVM wire terms into storage. The SVM counterpart of `_store`.
     *      - Forces every asset's `spent` to zero; URP owns it.
     *      - Every dynamic member is copied ELEMENT BY ELEMENT, same shape and same reason as
     *        `allowedCalls` and `pins`.
     *      - Does not set `initialized`; the caller does, immediately after this returns.
     */
    function _storeSvm(SvmConfig storage cfg, SvmTerms memory incoming) private {
        cfg.validUntil = incoming.validUntil;
        cfg.expectedCEA = incoming.expectedCEA;
        cfg.gatewayProgram = incoming.gatewayProgram;
        cfg.maxGasPerCall = incoming.maxGasPerCall;
        delete cfg.assets;
        RulesLib.storeAssets(cfg.assets, incoming.assets);

        delete cfg.ceaAccounts;
        uint256 len = incoming.ceaAccounts.length;
        for (uint256 i; i < len;) {
            cfg.ceaAccounts.push(incoming.ceaAccounts[i]);
            unchecked {
                ++i;
            }
        }

        delete cfg.programs;
        len = incoming.programs.length;
        for (uint256 i; i < len;) {
            cfg.programs.push(incoming.programs[i]);
            unchecked {
                ++i;
            }
        }

        delete cfg.pins;
        len = incoming.pins.length;
        for (uint256 i; i < len;) {
            cfg.pins.push(incoming.pins[i]);
            unchecked {
                ++i;
            }
        }

        delete cfg.dataPins;
        len = incoming.dataPins.length;
        for (uint256 i; i < len;) {
            cfg.dataPins.push(incoming.dataPins[i]);
            unchecked {
                ++i;
            }
        }
    }

    // ──────────────────────────────── check path ────────────────────────────────

    /**
     * @dev The SVM gauntlet — S1 to S18, then effects. Same discipline as the other two: it runs
     *      BEFORE the session signature is verified, on unauthenticated calldata from an arbitrary
     *      caller, so it makes no external call, applies all effects last, and reverts on every
     *      failure.
     *
     *      S1-S10 are the universal gates 1-10 restated against `SvmConfig` — they are chain-
     *      independent. S6b is Solana's u64 amount. S11 onwards replace gates 11-16:
     *
     *      S11  the recipient is a 32-byte, non-zero pubkey (the target program)
     *      S12  the payload is non-empty and parses as the node's execute grammar, exactly
     *      S13  instruction_id is 2 (execute); account count and ix_data length are within bounds
     *      S14  the payload's target program equals the recipient
     *      S15  the target is not a forbidden program
     *      S16  a rule matches (program, tag) — first match — and its account count, if fixed, holds
     *      S17  every account pin and every data pin of that rule holds
     *      S18  every CEA-controlled account in the list sits only where that rule pins it
     *
     *      - A zero amount passes S6/S7 and writes nothing: on SVM that is a payload-only call
     *        acting on capital already at the destination, the analogue of the EVM redeploy path.
     *      - The forbidden-program check runs before the allow-list, as gate 14 runs before 15.
     *
     * @param cfg      The SVM config slice, addressed in the PROXY's storage by the caller.
     * @param id       Config id identifying the rules set.
     * @param account  The wallet.
     * @param target   Push-side call target, as the engine supplied it; must be the gateway (S3).
     * @param gateway  URP's `UNIVERSAL_GATEWAY_PC`, passed in because a library holds no state.
     *                 DISTINCT FROM `target`: S3 exists to compare the two, so collapsing them into
     *                 one parameter would delete the gate. This parameter is the addition the PRD's
     *                 §3.2 surface allows where compilation requires it.
     * @param value    Push-native value attached to the call.
     * @param data     The gateway calldata.
     * @return The engine's success sentinel.
     */
    function check(
        SvmConfig storage cfg,
        ConfigId id,
        address account,
        address target,
        address gateway,
        uint256 value,
        bytes calldata data
    ) external returns (uint256) {
        if (!cfg.initialized) revert UniversalRulesPolicyErrors.NotInitialized(id, account);

        if (block.timestamp > cfg.validUntil) revert UniversalRulesPolicyErrors.RulesExpired(cfg.validUntil);

        if (target != gateway) revert UniversalRulesPolicyErrors.InvalidTarget(target);

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

        if (req.amount > type(uint64).max) revert UniversalRulesPolicyErrors.AmountExceedsU64(req.amount);

        uint256 newSpent = cap.spent + req.amount;
        if (newSpent > cap.maxTotal) revert UniversalRulesPolicyErrors.TotalSpendCapExceeded(newSpent, cap.maxTotal);

        if (value > cfg.maxGasPerCall) revert UniversalRulesPolicyErrors.PCValueExceedsCap(value, cfg.maxGasPerCall);

        if (req.maxPCForGas == 0) revert UniversalRulesPolicyErrors.UncappedGasSwapRejected();

        if (req.revertRecipient != account) {
            revert UniversalRulesPolicyErrors.InvalidRevertRecipient(account, req.revertRecipient);
        }

        // S11 — a zero pubkey is reported with the length it has (32): the shape is right, the value
        // is not, and both are "not a pubkey".
        if (req.recipient.length != 32) revert UniversalRulesPolicyErrors.RecipientNotPubkey(req.recipient.length);
        bytes32 recipient = _loadWord(req.recipient, 0);
        if (recipient == bytes32(0)) revert UniversalRulesPolicyErrors.RecipientNotPubkey(32);

        _checkSvmPayload(cfg, recipient, req.payload);

        if (req.amount > 0) {
            cap.spent = newSpent;
            emit IUniversalRulesPolicy.OutboundMetered(id, msg.sender, account, req.token, req.amount);
        }

        return VALIDATION_SUCCESS;
    }

    /**
     * @dev S12 to S18. Split out for stack depth; makes no external call, writes no storage.
     * @param cfg        Config to validate against.
     * @param recipient  The request's recipient, already proven to be a non-zero pubkey.
     * @param payload    The execute payload carried by the outbound request.
     */
    function _checkSvmPayload(SvmConfig storage cfg, bytes32 recipient, bytes memory payload) private view {
        SvmPayloadView memory v = _parseSvmPayload(payload);

        if (v.target != recipient) revert UniversalRulesPolicyErrors.RecipientTargetMismatch(recipient, v.target);

        if (_isForbiddenProgram(v.target, cfg.gatewayProgram, cfg.expectedCEA)) {
            revert UniversalRulesPolicyErrors.ForbiddenTargetProgram(v.target);
        }

        uint256 rule = _matchSvmRule(cfg, payload, v);

        _checkSvmAccountPins(cfg, payload, v, rule);
        _checkSvmDataPins(cfg, payload, v, rule);
        _checkCeaAccounts(cfg, payload, v, rule);
    }

    /**
     * @dev S12/S13 — the node's `decodePayload` grammar, byte for byte, including "consumed exactly":
     *      `[u32 BE count][count × (pubkey32 ‖ writable u8)][u32 BE len][ix_data][u8 id][target32]`.
     *      Every length is checked before the read it guards. `is_writable` bytes are read past,
     *      never judged — a wrong flag fails on Solana, not here.
     */
    function _parseSvmPayload(bytes memory p) private pure returns (SvmPayloadView memory v) {
        if (p.length == 0) revert UniversalRulesPolicyErrors.SvmPayloadEmpty();
        if (p.length < SVM_HEADER_LEN + SVM_LEN_FIELD + SVM_TRAILER_LEN) {
            revert UniversalRulesPolicyErrors.MalformedSvmPayload(1);
        }

        v.count = _u32be(p, 0);
        if (v.count > MAX_SVM_ACCOUNTS) revert UniversalRulesPolicyErrors.SvmAccountsOutOfRange(v.count);

        uint256 lenOff = SVM_HEADER_LEN + v.count * SVM_ACCOUNT_LEN;
        if (p.length < lenOff + SVM_LEN_FIELD) revert UniversalRulesPolicyErrors.MalformedSvmPayload(2);

        v.ixLen = _u32be(p, lenOff);
        if (v.ixLen > MAX_SVM_IX_DATA) revert UniversalRulesPolicyErrors.SvmIxDataTooLong(v.ixLen);
        v.ixOff = lenOff + SVM_LEN_FIELD;

        uint256 expected = v.ixOff + v.ixLen + SVM_TRAILER_LEN;
        if (p.length < expected) revert UniversalRulesPolicyErrors.MalformedSvmPayload(3);
        if (p.length > expected) revert UniversalRulesPolicyErrors.MalformedSvmPayload(4);

        uint8 id = uint8(p[v.ixOff + v.ixLen]);
        if (id != SVM_INSTRUCTION_EXECUTE) revert UniversalRulesPolicyErrors.SvmInstructionNotExecute(id);

        v.target = _loadWord(p, v.ixOff + v.ixLen + 1);
    }

    /**
     * @dev S16 — first rule whose program equals the target and whose tag matches: a dataless rule
     *      matches only empty ix_data; a tagged rule needs at least `discriminatorLen` bytes and a
     *      prefix-equal tag. Init guarantees at most one rule can match, so first-match is exact.
     *      Then the rule's account count: unless it is `ANY_ACCOUNT_COUNT`, the request must carry
     *      exactly that many accounts.
     */
    function _matchSvmRule(SvmConfig storage cfg, bytes memory p, SvmPayloadView memory v)
        private
        view
        returns (uint256)
    {
        uint256 n = cfg.programs.length;
        for (uint256 i; i < n;) {
            AllowedProgram storage r = cfg.programs[i];
            if (r.program == v.target && _tagMatches(r, p, v)) {
                uint8 cap = r.maxAccounts;
                if (cap != ANY_ACCOUNT_COUNT && v.count != cap) {
                    revert UniversalRulesPolicyErrors.SvmAccountCountMismatch(v.count, cap);
                }
                return i;
            }
            unchecked {
                ++i;
            }
        }
        uint256 shown = v.ixLen < 8 ? v.ixLen : 8;
        revert UniversalRulesPolicyErrors.ProgramNotAllowed(
            v.target, bytes8(_loadWord(p, v.ixOff)) & _prefixMask8(shown)
        );
    }

    function _tagMatches(AllowedProgram storage r, bytes memory p, SvmPayloadView memory v)
        private
        view
        returns (bool)
    {
        if (r.dataless) return v.ixLen == 0;
        uint8 len = r.discriminatorLen;
        if (v.ixLen < len) return false;
        bytes8 mask = _prefixMask8(len);
        return (bytes8(_loadWord(p, v.ixOff)) & mask) == (r.discriminator & mask);
    }

    /// @dev S17, account half: every pin of the matched rule names an index that exists and holds
    ///      the expected key.
    function _checkSvmAccountPins(SvmConfig storage cfg, bytes memory p, SvmPayloadView memory v, uint256 rule)
        private
        view
    {
        uint256 n = cfg.pins.length;
        for (uint256 i; i < n;) {
            SvmAccountPin storage pin = cfg.pins[i];
            if (pin.ruleIndex == rule) {
                if (v.count <= pin.accountIndex) {
                    revert UniversalRulesPolicyErrors.SvmAccountCountBelowPin(i, v.count, pin.accountIndex);
                }
                bytes32 actual = _svmAccount(p, pin.accountIndex);
                if (actual != pin.expected) {
                    revert UniversalRulesPolicyErrors.SvmAccountPinMismatch(i, pin.accountIndex, pin.expected, actual);
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev S17, data half. Offsets resolve from the start or the end of ix_data; init proved the
    ///      from-end shape reaches at least `len` back, so only the length floor is checked here.
    ///      Integer reads are little-endian, `len` bytes; the ratio is computed in uint256 and cannot
    ///      overflow (both operands are at most 64 bits wide).
    function _checkSvmDataPins(SvmConfig storage cfg, bytes memory p, SvmPayloadView memory v, uint256 rule)
        private
        view
    {
        uint256 n = cfg.dataPins.length;
        for (uint256 i; i < n;) {
            SvmDataPin storage dp = cfg.dataPins[i];
            if (dp.ruleIndex == rule) _checkOneDataPin(dp, p, v, i);
            unchecked {
                ++i;
            }
        }
    }

    function _checkOneDataPin(SvmDataPin storage dp, bytes memory p, SvmPayloadView memory v, uint256 i) private view {
        uint256 off = _resolveOffset(dp.fromEnd, dp.offset, dp.len, v.ixLen, i);
        uint256 at = v.ixOff + off;
        SvmDataPinMode mode = dp.mode;

        if (mode == SvmDataPinMode.EQ) {
            bytes32 mask = _prefixMask32(dp.len);
            bytes32 actual = _loadWord(p, at) & mask;
            bytes32 want = dp.expected & mask;
            if (actual != want) revert UniversalRulesPolicyErrors.SvmDataPinMismatch(i, want, actual);
            return;
        }

        uint256 a = _uintLE(p, at, dp.len);
        if (mode == SvmDataPinMode.GTE_LE) {
            if (a < uint256(dp.expected)) {
                revert UniversalRulesPolicyErrors.SvmDataFloorNotMet(i, a, uint256(dp.expected));
            }
        } else if (mode == SvmDataPinMode.LTE_LE) {
            if (a > uint256(dp.expected)) {
                revert UniversalRulesPolicyErrors.SvmDataCeilingExceeded(i, a, uint256(dp.expected));
            }
        } else {
            uint256 offB = _resolveOffset(dp.fromEnd, dp.offsetB, dp.len, v.ixLen, i);
            uint256 b = _uintLE(p, v.ixOff + offB, dp.len);
            if (a * dp.den < b * dp.num) revert UniversalRulesPolicyErrors.SvmDataRatioNotMet(i, a, b, dp.num, dp.den);
        }
    }

    /// @dev The field's start relative to ix_data, or `SvmDataTooShortForPin` if ix_data cannot hold it.
    function _resolveOffset(bool fromEnd, uint16 offset, uint8 len, uint256 ixLen, uint256 pin)
        private
        pure
        returns (uint256)
    {
        if (fromEnd) {
            if (ixLen < offset) revert UniversalRulesPolicyErrors.SvmDataTooShortForPin(pin, ixLen);
            return ixLen - offset;
        }
        if (ixLen < uint256(offset) + len) revert UniversalRulesPolicyErrors.SvmDataTooShortForPin(pin, ixLen);
        return offset;
    }

    /**
     * @dev S18 — a CEA-controlled account may appear only where the matched rule pins it. Any other
     *      occurrence hands a program, running with the CEA's signature, an account it was not
     *      granted. Accounts absent from `ceaAccounts` are not judged: the list is the owner's
     *      statement of what holds value. O(count × |ceaAccounts| × |pins|), all bounded.
     */
    function _checkCeaAccounts(SvmConfig storage cfg, bytes memory p, SvmPayloadView memory v, uint256 rule)
        private
        view
    {
        // Never empty: init requires `expectedCEA` in the list (`_checkCeaAccountList`).
        uint256 listed = cfg.ceaAccounts.length;
        for (uint256 i; i < v.count;) {
            bytes32 key = _svmAccount(p, i);
            for (uint256 c; c < listed;) {
                if (cfg.ceaAccounts[c] == key && !_pinnedAt(cfg, rule, i)) {
                    revert UniversalRulesPolicyErrors.CeaAccountAtUnpinnedIndex(i, key);
                }
                unchecked {
                    ++c;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Whether the matched rule pins `index` at all. S17 has already proved that every pinned
    ///      position holds its expected key, so "pinned" and "pinned to this key" are the same fact
    ///      here and the key is not re-compared.
    function _pinnedAt(SvmConfig storage cfg, uint256 rule, uint256 index) private view returns (bool) {
        uint256 n = cfg.pins.length;
        for (uint256 i; i < n;) {
            SvmAccountPin storage pin = cfg.pins[i];
            if (pin.ruleIndex == rule && pin.accountIndex == index) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    // ────────────────────────────────── the read ──────────────────────────────────

    /**
     * @dev Backs `UniversalRulesPolicy.getSvmConfig`. The mode and family guards stay in URP; this
     *      only copies the struct out of the proxy's storage.
     *
     *      `pure`, not `view`, and that reads wrongly at first glance: it returns the CONTENTS of a
     *      storage slot. Solidity classes a function taking a `storage` POINTER and returning its
     *      copy as `pure` because the pointer itself is the argument — the compiler accounts for the
     *      reads at the caller, which is URP, which is already `view`. solc emits warning 2018
     *      ("can be restricted to pure") if this is marked `view`, and the repo runs a zero-warning
     *      policy, so `pure` is the only spelling that builds clean. No state can be written through
     *      it either way.
     * @param cfg  The SVM config slice, addressed in the PROXY's storage by the caller.
     * @return The stored SVM config.
     */
    function read(SvmConfig storage cfg) external pure returns (SvmConfig memory) {
        return cfg;
    }

    // ───────────────────────── svm byte helpers (pure, memory only) ─────────────────────────

    /// @dev The pubkey of account `i` in a parsed payload. Callers bound `i` by the parsed count.
    function _svmAccount(bytes memory p, uint256 i) private pure returns (bytes32) {
        return _loadWord(p, SVM_HEADER_LEN + i * SVM_ACCOUNT_LEN);
    }

    /// @dev Loads 32 bytes at `off`. Every caller has already proved the bytes it USES are inside
    ///      `b`; bytes past the end are masked away by the caller, never compared.
    function _loadWord(bytes memory b, uint256 off) private pure returns (bytes32 w) {
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            w := mload(add(add(b, 0x20), off))
        }
    }

    function _u32be(bytes memory b, uint256 off) private pure returns (uint256) {
        return uint256(uint32(bytes4(_loadWord(b, off))));
    }

    /// @dev Little-endian unsigned integer of `len` bytes (1..8) starting at `off`.
    function _uintLE(bytes memory b, uint256 off, uint256 len) private pure returns (uint256 v) {
        bytes32 w = _loadWord(b, off);
        for (uint256 i; i < len;) {
            v |= uint256(uint8(w[i])) << (8 * i);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Keeps the top `len` bytes of a bytes8. `len` 8 keeps all (a shift by >= 64 is zero).
    function _prefixMask8(uint256 len) private pure returns (bytes8) {
        return bytes8(~(type(uint64).max >> (8 * len)));
    }

    /// @dev Keeps the top `len` bytes of a bytes32. `len` 32 keeps all.
    function _prefixMask32(uint256 len) private pure returns (bytes32) {
        return bytes32(~(type(uint256).max >> (8 * len)));
    }
}
