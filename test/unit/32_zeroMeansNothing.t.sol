// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { UniversalRulesPolicyErrors } from "../../src/libraries/Errors.sol";

import { BaseTest } from "../Base.t.sol";
import { AGW } from "../../src/AGW.sol";
import {
    AllowedCall,
    AllowedProgram,
    AmountRule,
    ANY_ACCOUNT_COUNT,
    ArgPin,
    Config,
    ModeSlot,
    Multicall,
    NativeConfig,
    SvmAccountPin,
    SvmDataPin,
    SvmTerms,
    UNLIMITED_CALLS
} from "../../src/libraries/Types.sol";
import { ModeLib, ModeCode } from "../../src/libraries/ModeLib.sol";
import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";
import { StakeDummy } from "../mocks/StakeDummy.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockPRC20 } from "../mocks/MockUniversalGateway.sol";
import { ActionData, ConfigId, ERC7739Context, ERC7739Data, PolicyData, Session } from "smartsessions/DataTypes.sol";
import { ISessionValidator } from "smartsessions/interfaces/ISessionValidator.sol";

/**
 * @title  ZeroMeansNothing — one rule for every limit: 0 means nothing, the type's maximum means
 *         unlimited (URP_ZERO_MEANS_NOTHING_PRD).
 * @notice The two count fields that used to read 0 as "no limit" now use a named sentinel, and refuse
 *         0 at grant because a rule with no calls, or an SVM rule with no accounts, authorises nothing:
 *         - native `maxCalls`: `UNLIMITED_CALLS` (`type(uint32).max`) = no limit; 0 → `ZeroMaxCalls`.
 *         - SVM `maxAccounts`: `ANY_ACCOUNT_COUNT` (255) = any count; 1..64 = exact count; 0 and
 *           65..254 → `SvmMaxAccountsOutOfRange`.
 *         Per-token zeros (`AssetCap` 0/0) stay legal: the token routes a no-movement request (Z12).
 *
 * @dev    Init errors bubble in full from `initializeWithMultiplexer`, so they are asserted with every
 *         argument. Check-path errors are asserted directly as the engine, and once through the real
 *         wallet with `expectUrpGate` (Z04), where the engine truncates them.
 */
contract ZeroMeansNothingTest is BaseTest {
    ConfigId internal constant CID = ConfigId.wrap(bytes32(uint256(0x2E50)));
    uint48 internal constant VALID_UNTIL = 2_000_000_000;

    bytes4 internal constant CLAIM = StakeDummy.claim.selector;

    address internal account;
    address internal nativeTarget;

    // ── svm fixtures ──
    address internal svmAsset;
    bytes32 internal constant CEA = keccak256("zero-means-nothing CEA");
    bytes32 internal constant GATEWAY_PROG = keccak256("zero-means-nothing svm gateway program");
    bytes32 internal constant PROG = keccak256("zero-means-nothing program");
    bytes8 internal constant TAG = 0xc1209b3341d69c81;

    function setUp() public override {
        super.setUp();
        account = makeAddr("agentWallet");
        nativeTarget = makeAddr("nativeTarget");
        MockPRC20 asset = new MockPRC20();
        asset.setSourceChainNamespace(CHAIN_SOLANA_DEVNET);
        svmAsset = address(asset);
        vm.warp(1_000_000_000);
    }

    // ═════════════════════════════ native builders ═════════════════════════════

    /// @dev The ascetic native shape — `claim()`: no value, no amount rule, no pins. Only N9 can bite.
    function _native(uint32 maxCalls) internal view returns (NativeConfig memory) {
        return NativeConfig({
            initialized: false,
            validUntil: VALID_UNTIL,
            target: nativeTarget,
            selector: CLAIM,
            maxValuePerCall: 0,
            maxValueTotal: 0,
            valueSpent: 0,
            amount: AmountRule({ enabled: false, offset: 0, maxPerCall: 0, maxTotal: 0 }),
            amountSpent: 0,
            maxCalls: maxCalls,
            callsUsed: 0,
            pins: new ArgPin[](0)
        });
    }

    function _initNative(uint32 maxCalls) internal {
        vm.prank(address(engine));
        urp.initializeWithMultiplexer(account, CID, nativeInitData(_native(maxCalls)));
    }

    function _checkNative() internal {
        vm.prank(address(engine));
        urp.checkAction(CID, account, nativeTarget, 0, abi.encodeWithSelector(CLAIM));
    }

    function _checkNativeReverts(bytes memory err) internal {
        vm.prank(address(engine));
        vm.expectRevert(err);
        urp.checkAction(CID, account, nativeTarget, 0, abi.encodeWithSelector(CLAIM));
    }

    function _callLimit(uint32 used, uint32 max) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(UniversalRulesPolicyErrors.CallLimitReached.selector, used, max);
    }

    function _callsUsed() internal view returns (uint32) {
        return urp.getNativeConfig(CID, account).callsUsed;
    }

    // ───────────── locating `callsUsed` through solc's storage layout ─────────────

    /// @dev The slot of `_native[CID][engine][account]` plus the `callsUsed` member, and its byte
    ///      offset — every number read from the artifact's `storageLayout`, none computed by hand.
    function _callsUsedLocation() internal view returns (bytes32 slot, uint256 offset) {
        string memory artifact = vm.readFile("out/UniversalRulesPolicy.sol/UniversalRulesPolicy.json");

        uint256 base = type(uint256).max;
        for (uint256 i; vm.keyExistsJson(artifact, _storageAt(i, ".label")); ++i) {
            if (keccak256(bytes(vm.parseJsonString(artifact, _storageAt(i, ".label")))) == keccak256("_native")) {
                base = vm.parseJsonUint(artifact, _storageAt(i, ".slot"));
                break;
            }
        }
        require(base != type(uint256).max, "no _native in the storage layout");

        string memory members = string.concat(".storageLayout.types.['", _nativeConfigTypeKey(artifact), "'].members");
        uint256 memberSlot = type(uint256).max;
        for (uint256 i; vm.keyExistsJson(artifact, string.concat(members, "[", vm.toString(i), "].label")); ++i) {
            string memory at = string.concat(members, "[", vm.toString(i), "]");
            if (keccak256(bytes(vm.parseJsonString(artifact, string.concat(at, ".label")))) == keccak256("callsUsed")) {
                memberSlot = vm.parseJsonUint(artifact, string.concat(at, ".slot"));
                offset = vm.parseJsonUint(artifact, string.concat(at, ".offset"));
                break;
            }
        }
        require(memberSlot != type(uint256).max, "no callsUsed in NativeConfig");

        // `_native` is keyed configId => multiplexer => account.
        bytes32 s = keccak256(abi.encode(ConfigId.unwrap(CID), base));
        s = keccak256(abi.encode(address(engine), s));
        s = keccak256(abi.encode(account, s));
        slot = bytes32(uint256(s) + memberSlot);
    }

    function _storageAt(uint256 i, string memory field) internal pure returns (string memory) {
        return string.concat(".storageLayout.storage[", vm.toString(i), "]", field);
    }

    function _nativeConfigTypeKey(string memory artifact) internal pure returns (string memory) {
        string[] memory keys = vm.parseJsonKeys(artifact, ".storageLayout.types");
        bytes memory prefix = bytes("t_struct(NativeConfig)");
        for (uint256 i; i < keys.length; ++i) {
            bytes memory k = bytes(keys[i]);
            if (k.length < prefix.length) continue;
            bool same = true;
            for (uint256 j; j < prefix.length; ++j) {
                if (k[j] != prefix[j]) {
                    same = false;
                    break;
                }
            }
            if (same) return keys[i];
        }
        revert("no NativeConfig type in the storage layout");
    }

    /// @dev Overwrites the four `callsUsed` bytes in place, leaving the packed neighbours intact.
    function _setCallsUsed(uint32 value) internal {
        (bytes32 slot, uint256 offset) = _callsUsedLocation();
        uint256 word = uint256(vm.load(address(urp), slot));
        uint256 shift = offset * 8;
        word = (word & ~(uint256(type(uint32).max) << shift)) | (uint256(value) << shift);
        vm.store(address(urp), slot, bytes32(word));
        assertEq(_callsUsed(), value, "callsUsed written through the artifact-located slot");
    }

    // ═════════════════════════════ native: maxCalls ═════════════════════════════

    /// Z01 — `UNLIMITED_CALLS` never trips, and the counter still counts. Replaces the retired
    /// `test_native_N9_zeroMaxCallsIsUnlimited`.
    function test_Z01_NativeUnlimitedCallsNeverTrips() public {
        _initNative(UNLIMITED_CALLS);
        for (uint256 i; i < 10; ++i) {
            _checkNative();
        }
        assertEq(_callsUsed(), 10, "callsUsed counts every call under UNLIMITED_CALLS");
    }

    /// Z02 — 0 is refused at grant, before any write.
    function test_Z02_NativeZeroMaxCallsRefusedAtGrant() public {
        bytes memory initData = nativeInitData(_native(0));
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.ZeroMaxCalls.selector));
        urp.initializeWithMultiplexer(account, CID, initData);

        ModeSlot memory slot = urp.getMode(CID, account);
        assertFalse(slot.initialized, "mode slot not written");
        NativeConfig memory cfg = urp.getNativeConfig(CID, account);
        assertFalse(cfg.initialized, "config not initialised");
        assertEq(cfg.target, address(0), "target not written");
        assertEq(cfg.selector, bytes4(0), "selector not written");
        assertEq(cfg.validUntil, 0, "validUntil not written");
        assertEq(cfg.maxCalls, 0, "maxCalls not written");
    }

    // ───────────────────────────── through the wallet ─────────────────────────────

    struct WalletRig {
        AGW wallet;
        address owner;
        address agent;
        StakeDummy stake;
    }

    function _rig() internal returns (WalletRig memory r) {
        r.owner = makeAddr("walletOwner");
        r.agent = makeAddr("nativeAgent");
        r.wallet = newWallet(r.owner);
        r.stake = new StakeDummy(new MockERC20());
    }

    function _claimSession(WalletRig memory r, uint32 maxCalls) internal view returns (Session memory) {
        NativeConfig memory c = _native(maxCalls);
        c.target = address(r.stake);
        c.validUntil = uint48(block.timestamp + 7 days);

        PolicyData[] memory ps = new PolicyData[](1);
        ps[0] = PolicyData({ policy: address(urp), initData: nativeInitData(c) });
        ActionData[] memory a = new ActionData[](1);
        a[0] = ActionData({ actionTargetSelector: CLAIM, actionTarget: address(r.stake), actionPolicies: ps });

        return Session({
            sessionValidator: ISessionValidator(address(validator)),
            sessionValidatorInitData: agentConfig(r.agent),
            salt: bytes32(0),
            userOpPolicies: new PolicyData[](0),
            erc7739Policies: ERC7739Data({
                allowedERC7739Content: new ERC7739Context[](0), erc1271Policies: new PolicyData[](0)
            }),
            actions: a,
            permitERC4337Paymaster: false
        });
    }

    function _agentClaim(WalletRig memory r, bytes32 pid) internal {
        bytes memory execCd = ExecutionLib.encodeSingle(address(r.stake), 0, abi.encodeWithSelector(CLAIM));
        bytes32 mode = ModeCode.unwrap(ModeLib.encodeSimpleSingle());
        vm.prank(r.agent);
        r.wallet.executeAsAgent(pid, mode, execCd);
    }

    /// Z03 — the same refusal through `grantRules`: bubbled in full, and the wallet's counters never move.
    function test_Z03_NativeZeroMaxCallsRefusedThroughTheWallet() public {
        WalletRig memory r = _rig();
        Session memory s = _claimSession(r, 0);
        uint64 nonceBefore = r.wallet.grantNonce();
        uint64 checkpointsBefore = r.wallet.checkpointCount();

        vm.prank(r.owner);
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.ZeroMaxCalls.selector));
        r.wallet.grantRules(s);

        assertEq(r.wallet.grantNonce(), nonceBefore, "grantNonce unchanged");
        assertEq(r.wallet.checkpointCount(), checkpointsBefore, "checkpointCount unchanged");
    }

    /// Z04 — the boundary: `maxCalls = 1` allows exactly one. Direct as the engine, then once through
    /// the real wallet, where the engine truncates the revert.
    function test_Z04_NativeMaxCallsOneAllowsExactlyOne() public {
        _initNative(1);
        _checkNative();
        assertEq(_callsUsed(), 1, "the one call counted");
        _checkNativeReverts(_callLimit(1, 1));

        WalletRig memory r = _rig();
        vm.prank(r.owner);
        bytes32 pid = r.wallet.grantRules(_claimSession(r, 1));
        _agentClaim(r, pid);
        expectUrpGate(_callLimit(1, 1));
        _agentClaim(r, pid);
    }

    /// Z05 — the sentinel is EXACTLY `type(uint32).max`, not a range: one below it is a real ceiling.
    function test_Z05_NativeMaxCallsJustBelowUnlimitedIsALimit() public {
        uint32 cap = UNLIMITED_CALLS - 1;
        _initNative(cap);
        _setCallsUsed(cap);
        _checkNativeReverts(_callLimit(cap, cap));
    }

    /// Z06 — under `UNLIMITED_CALLS` the counter is informational: at `type(uint32).max` the next call
    /// still passes and the unchecked increment wraps to 0.
    function test_Z06_NativeUnlimitedCounterNearWrapIsHarmless() public {
        _initNative(UNLIMITED_CALLS);
        _setCallsUsed(type(uint32).max);
        _checkNative();
        assertEq(_callsUsed(), 0, "callsUsed wrapped (unchecked, informational)");
    }

    // ═════════════════════════════ svm builders ═════════════════════════════

    /// @dev One tagged rule on PROG with the given account count, one account pin (the CEA at `pinIndex`),
    ///      no data pins. The smallest rules set every SVM init guard accepts.
    function _svmTerms(uint8 maxAccounts, uint8 pinIndex) internal view returns (SvmTerms memory t) {
        AllowedProgram[] memory programs = new AllowedProgram[](1);
        programs[0] = AllowedProgram({
            program: PROG, discriminator: TAG, discriminatorLen: 8, dataless: false, maxAccounts: maxAccounts
        });
        SvmAccountPin[] memory pins = new SvmAccountPin[](1);
        pins[0] = SvmAccountPin({ ruleIndex: 0, accountIndex: pinIndex, expected: CEA });
        bytes32[] memory ceaAccounts = new bytes32[](1);
        ceaAccounts[0] = CEA;

        t = SvmTerms({
            validUntil: VALID_UNTIL,
            expectedCEA: CEA,
            gatewayProgram: GATEWAY_PROG,
            assets: oneCap(svmAsset, 100e6, 1000e6),
            maxGasPerCall: 5 ether,
            ceaAccounts: ceaAccounts,
            programs: programs,
            pins: pins,
            dataPins: new SvmDataPin[](0)
        });
    }

    function _svmInitAt(ConfigId id, SvmTerms memory t) internal {
        vm.prank(address(engine));
        urp.initializeWithMultiplexer(account, id, svmInitData(CHAIN_SOLANA_DEVNET, t));
    }

    function _svmInitReverts(bytes memory err, SvmTerms memory t) internal {
        bytes memory initData = svmInitData(CHAIN_SOLANA_DEVNET, t);
        vm.prank(address(engine));
        vm.expectRevert(err);
        urp.initializeWithMultiplexer(account, CID, initData);
    }

    function _accountsOutOfRange(uint8 maxAccounts) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(UniversalRulesPolicyErrors.SvmMaxAccountsOutOfRange.selector, 0, maxAccounts);
    }

    function _pinIndexOutOfRange(uint8 index) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(UniversalRulesPolicyErrors.SvmPinIndexOutOfRange.selector, 0, index);
    }

    /// @dev A request carrying `count` accounts: the CEA at index 0 (the pinned position), distinct
    ///      fillers elsewhere, and the bare tag as ix_data.
    function _svmRequest(uint256 count) internal view returns (bytes memory) {
        bytes32[] memory a = new bytes32[](count);
        bool[] memory w = new bool[](count);
        a[0] = CEA;
        w[0] = true;
        for (uint256 i = 1; i < count; ++i) {
            a[i] = keccak256(abi.encode("filler account", i));
        }
        bytes memory payload = svmExecutePayload(a, w, abi.encodePacked(TAG), 2, PROG);
        return svmOutboundRequest(svmAsset, 1e6, 1 ether, account, abi.encodePacked(PROG), payload);
    }

    function _svmCheck(uint256 count) internal {
        bytes memory data = _svmRequest(count);
        vm.prank(address(engine));
        urp.checkAction(CID, account, GATEWAY, 0, data);
    }

    function _svmCheckReverts(bytes memory err, uint256 count) internal {
        bytes memory data = _svmRequest(count);
        vm.prank(address(engine));
        vm.expectRevert(err);
        urp.checkAction(CID, account, GATEWAY, 0, data);
    }

    // ═════════════════════════════ svm: maxAccounts ═════════════════════════════

    /// Z07 — `ANY_ACCOUNT_COUNT` accepts any count within the S13 bound.
    function test_Z07_SvmAnyAccountCountAcceptsAnyCount() public {
        _svmInitAt(CID, _svmTerms(ANY_ACCOUNT_COUNT, 0));
        _svmCheck(3);
        _svmCheck(10);
        _svmCheck(64);
        assertEq(urp.getSvmConfig(CID, account).assets[0].spent, 3e6, "all three requests passed and metered");
    }

    /// Z08 — 0 is refused as an out-of-range count, never as the pin-index error it would otherwise
    /// cause (the rule guard runs before the pin guard).
    function test_Z08_SvmZeroMaxAccountsRefusedAtGrant() public {
        _svmInitReverts(_accountsOutOfRange(0), _svmTerms(0, 0));
        assertFalse(urp.getMode(CID, account).initialized, "nothing written");
    }

    /// Z09 — the edges: 1 and 64 legal (exact), 65 and 254 refused, 255 legal (any).
    function test_Z09_SvmMaxAccountsRangeEdges() public {
        _svmInitAt(ConfigId.wrap(bytes32(uint256(0x2E51))), _svmTerms(1, 0));
        _svmInitAt(ConfigId.wrap(bytes32(uint256(0x2E52))), _svmTerms(64, 0));
        _svmInitReverts(_accountsOutOfRange(65), _svmTerms(65, 0));
        _svmInitReverts(_accountsOutOfRange(254), _svmTerms(254, 0));
        _svmInitAt(ConfigId.wrap(bytes32(uint256(0x2E53))), _svmTerms(255, 0));

        assertEq(urp.getSvmConfig(ConfigId.wrap(bytes32(uint256(0x2E51))), account).programs[0].maxAccounts, 1);
        assertEq(urp.getSvmConfig(ConfigId.wrap(bytes32(uint256(0x2E52))), account).programs[0].maxAccounts, 64);
        assertEq(urp.getSvmConfig(ConfigId.wrap(bytes32(uint256(0x2E53))), account).programs[0].maxAccounts, 255);
    }

    /// Z10 — an exact count is still exact: one fewer or one more account is refused at S16.
    function test_Z10_SvmExactCountStillExact() public {
        _svmInitAt(CID, _svmTerms(10, 0));
        _svmCheck(10);
        _svmCheckReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.SvmAccountCountMismatch.selector, 9, uint8(10)), 9
        );
        _svmCheckReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.SvmAccountCountMismatch.selector, 11, uint8(10)), 11
        );
    }

    /// Z11 — the pin-index bound: under `ANY_ACCOUNT_COUNT` only the S13 loop bound applies (63 legal,
    /// 64 refused); under an exact count the count itself bounds the index.
    function test_Z11_SvmPinIndexBoundWithAnyCount() public {
        _svmInitAt(ConfigId.wrap(bytes32(uint256(0x2E54))), _svmTerms(ANY_ACCOUNT_COUNT, 63));
        _svmInitReverts(_pinIndexOutOfRange(64), _svmTerms(ANY_ACCOUNT_COUNT, 64));
        _svmInitReverts(_pinIndexOutOfRange(5), _svmTerms(5, 5));
    }

    // ═════════════════════════════ per-token zero ═════════════════════════════

    /// Z12 — Z-3's exception: a token capped 0/0 is still granted and still routes a zero-amount
    /// request; only a non-zero amount is refused.
    function test_Z12_PerTokenZeroStillLegal() public {
        address token = address(new MockPRC20());
        address cea = makeAddr("destinationAccount");
        address protocol = makeAddr("farChainProtocol");
        bytes4 swap = bytes4(keccak256("swap(uint256,address)"));

        AllowedCall[] memory rules = new AllowedCall[](1);
        rules[0] = AllowedCall({
            target: protocol, selector: swap, beneficiaryOffset: 36, hasBeneficiary: true, maxValue: 0, pins: noPins()
        });
        Config memory cfg = Config({
            initialized: false,
            validUntil: VALID_UNTIL,
            expectedCEA: cea,
            maxGasPerCall: 5 ether,
            assets: oneAsset(token, 0, 0),
            allowedCalls: rules
        });
        vm.prank(address(engine));
        urp.initializeWithMultiplexer(account, CID, universalInitData(cfg));
        assertTrue(urp.getMode(CID, account).initialized, "a 0/0 token is granted");

        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall({ to: protocol, value: 0, data: abi.encodeWithSelector(swap, uint256(1), cea) });

        bytes memory zero = outboundRequest(token, 0, 1 ether, account, calls);
        vm.prank(address(engine));
        urp.checkAction(CID, account, GATEWAY, 0, zero);

        bytes memory one = outboundRequest(token, 1, 1 ether, account, calls);
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.AmountExceedsCap.selector, 1, 0));
        urp.checkAction(CID, account, GATEWAY, 0, one);
    }

    // ═════════════════════════════ constants ═════════════════════════════

    /// Z13 — the sentinels are the type maxima, so "unlimited" reads the same way on every field.
    function test_Z13_ConstantsAreTheTypeMaxima() public pure {
        assertEq(UNLIMITED_CALLS, type(uint32).max, "UNLIMITED_CALLS");
        assertEq(ANY_ACCOUNT_COUNT, type(uint8).max, "ANY_ACCOUNT_COUNT");
    }

    // ═════════════════════════════ fuzz ═════════════════════════════

    /// F01 — 0 refused; `UNLIMITED_CALLS` never trips; any other value admits exactly that many calls.
    function testFuzz_F01_NativeMaxCalls(uint32 maxCalls, uint8 calls) public {
        calls = uint8(bound(calls, 0, 20));

        if (maxCalls == 0) {
            bytes memory initData = nativeInitData(_native(0));
            vm.prank(address(engine));
            vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.ZeroMaxCalls.selector));
            urp.initializeWithMultiplexer(account, CID, initData);
            return;
        }

        _initNative(maxCalls);
        for (uint256 i; i < calls; ++i) {
            if (maxCalls != UNLIMITED_CALLS && i >= maxCalls) {
                _checkNativeReverts(_callLimit(maxCalls, maxCalls));
                return;
            }
            _checkNative();
        }
        assertEq(_callsUsed(), calls, "every call within the ceiling counted");
    }

    /// F02 — the grant-time domain of `maxAccounts` is exactly [1, 64] ∪ {255}. The one pin sits at
    /// index 0, so the pin guard never interferes.
    function testFuzz_F02_SvmMaxAccountsAtGrant(uint8 maxAccounts) public {
        bool legal = (maxAccounts >= 1 && maxAccounts <= 64) || maxAccounts == ANY_ACCOUNT_COUNT;
        if (legal) {
            _svmInitAt(CID, _svmTerms(maxAccounts, 0));
            assertEq(urp.getSvmConfig(CID, account).programs[0].maxAccounts, maxAccounts, "stored as granted");
        } else {
            _svmInitReverts(_accountsOutOfRange(maxAccounts), _svmTerms(maxAccounts, 0));
        }
    }
}
