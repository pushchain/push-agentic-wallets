// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";

import { BaseTest } from "../Base.t.sol";

import { AGW } from "../../src/AGW.sol";
import { AGWFactory } from "../../src/AGWFactory.sol";
import { IAGW } from "../../src/interfaces/IAGW.sol";
import { IAGWFactory } from "../../src/interfaces/IAGWFactory.sol";
import { AGWErrors, AGWFactoryErrors, UniversalRulesPolicyErrors } from "../../src/libraries/Errors.sol";
import {
    AllowedCall,
    AmountRule,
    CheckpointKind,
    Config,
    MAX_INITIAL_RULES,
    NativeConfig,
    OwnerIntent,
    RulesType
} from "../../src/libraries/Types.sol";
import { ModeLib, ModeCode } from "../../src/libraries/ModeLib.sol";
import { ExecutionLib, Execution } from "../../src/libraries/ExecutionLib.sol";

import { MockPRC20 } from "../mocks/MockUniversalGateway.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockUEA } from "../mocks/MockUEA.sol";
import { StakeDummy } from "../mocks/StakeDummy.sol";

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {
    Session,
    ActionData,
    PolicyData,
    ERC7739Data,
    ERC7739Context,
    PermissionId
} from "smartsessions/DataTypes.sol";
import { ISessionValidator } from "smartsessions/interfaces/ISessionValidator.sol";

/**
 * @title  AGWFactory — `createWallet` / `createWalletWithSig` (AGW_CREATE_WALLET PRD §8.2).
 * @notice One factory call deploys the wallet and grants every rule, atomically, for any owner kind;
 *         the signed variant binds the exact rules through `intent.sessionHash`.
 *
 * @dev    Everything is real: the factory proxy, the wallet implementation, the engine, URP and the
 *         validator. Init-path errors bubble with full data (`initializeWithMultiplexer` is a plain
 *         call), so they are asserted with every argument, never through `expectUrpGate`.
 */
contract CreateWalletTest is BaseTest {
    MockPRC20 internal pUSDC;
    StakeDummy internal stake;

    address internal ownerAddr;
    uint256 internal ownerPk;
    uint256 internal otherPk;

    address internal agentU;
    address internal agentN;
    address internal stranger;
    address internal cea;
    address internal morpho;

    address internal PAUSER;
    address internal OPERATOR;

    bytes4 internal constant SUPPLY_SELECTOR = bytes4(keccak256("supply(address,uint256,address,uint16)"));
    uint16 internal constant BENEFICIARY_OFFSET = 68;
    bytes4 internal constant DEPOSIT_FOR = StakeDummy.depositFor.selector;

    /// @dev `createWallet(label, [universal, native])`: measured 1,252,067 with `forge test` (1.5.1-stable),
    ///      plus ~10%.
    uint256 internal constant CREATE_TWO_RULES_GAS_BUDGET = 1_377_000;
    /// @dev The same call under `--isolate` (which `--gas-report` switches on): measured 1,319,935, plus ~10%.
    uint256 internal constant CREATE_TWO_RULES_GAS_BUDGET_ISOLATED = 1_452_000;

    /// @dev The refused 9-rule `createWallet`: measured 28,686 with `forge test` and 126,574 under `--isolate`
    ///      (intrinsic and calldata included). One ceiling covers both; a refusal after `_deploy` would cost the
    ///      clone plus nine grants (~5M).
    uint256 internal constant TOO_MANY_RULES_REFUSAL_GAS_BUDGET = 150_000;

    function setUp() public override {
        super.setUp();
        vm.warp(1_700_000_000);

        (ownerAddr, ownerPk) = ecdsaKey("createOwner");
        (, otherPk) = ecdsaKey("notTheOwner");
        agentU = makeAddr("universalAgent");
        agentN = makeAddr("nativeAgent");
        stranger = makeAddr("stranger");
        cea = makeAddr("walletCea");
        morpho = makeAddr("morphoBlue");

        pUSDC = new MockPRC20();
        stake = new StakeDummy(new MockERC20());

        PAUSER = makeAddr("pauser");
        OPERATOR = makeAddr("operator");
        vm.startPrank(FACTORY_ADMIN);
        factory.grantRole(factory.PAUSER_ROLE(), PAUSER);
        factory.grantRole(factory.OPERATOR_ROLE(), OPERATOR);
        vm.stopPrank();
    }

    // ───────────────────────────── rule fixtures ─────────────────────────────

    function _universalRule(address agent) internal view returns (Session memory) {
        AllowedCall[] memory calls = new AllowedCall[](1);
        calls[0] = AllowedCall({
            target: morpho,
            selector: SUPPLY_SELECTOR,
            beneficiaryOffset: BENEFICIARY_OFFSET,
            hasBeneficiary: true,
            maxValue: 0,
            pins: noPins()
        });
        Config memory cfg = Config({
            initialized: false,
            validUntil: uint48(block.timestamp + 30 days),
            expectedCEA: cea,
            maxGasPerCall: 1 ether,
            assets: oneAsset(address(pUSDC), 100e6, 100e6),
            allowedCalls: calls
        });
        return canonicalSession(agentConfig(agent), universalInitData(cfg));
    }

    /// @dev `depositFor` on `target`, value capped at 1 PC per call and 10 PC in total, 100 calls.
    function _nativeCfg(address target) internal view returns (NativeConfig memory) {
        return NativeConfig({
            initialized: false,
            validUntil: uint48(block.timestamp + 7 days),
            target: target,
            selector: DEPOSIT_FOR,
            maxValuePerCall: 1 ether,
            maxValueTotal: 10 ether,
            valueSpent: 0,
            amount: AmountRule({ enabled: false, offset: 0, maxPerCall: 0, maxTotal: 0 }),
            amountSpent: 0,
            maxCalls: 100,
            callsUsed: 0,
            pins: noPins()
        });
    }

    function _nativeRuleFrom(address agent, NativeConfig memory cfg) internal view returns (Session memory) {
        PolicyData[] memory ps = new PolicyData[](1);
        ps[0] = PolicyData({ policy: address(urp), initData: nativeInitData(cfg) });
        ActionData[] memory actions = new ActionData[](1);
        actions[0] = ActionData({ actionTargetSelector: cfg.selector, actionTarget: cfg.target, actionPolicies: ps });
        return Session({
            sessionValidator: ISessionValidator(address(validator)),
            sessionValidatorInitData: agentConfig(agent),
            salt: bytes32(0),
            userOpPolicies: new PolicyData[](0),
            erc7739Policies: ERC7739Data({
                allowedERC7739Content: new ERC7739Context[](0), erc1271Policies: new PolicyData[](0)
            }),
            actions: actions,
            permitERC4337Paymaster: false
        });
    }

    function _nativeRule(address agent, address target) internal view returns (Session memory) {
        return _nativeRuleFrom(agent, _nativeCfg(target));
    }

    /// @dev A distinct, grantable native target per index.
    function _target(uint256 i) internal pure returns (address) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(0x7a46e700 + i)); // i <= MAX_INITIAL_RULES + 1, so the value fits; no truncation
    }

    function _nativeRules(uint256 n) internal view returns (Session[] memory rules) {
        rules = new Session[](n);
        for (uint256 i; i < n; ++i) {
            rules[i] = _nativeRule(agentN, _target(i));
        }
    }

    /// @dev §1's example: a universal rule (Aave-shaped, Sepolia) and a native rule (staking on Push).
    function _twoRules() internal view returns (Session[] memory rules) {
        rules = new Session[](2);
        rules[0] = _universalRule(agentU);
        rules[1] = _nativeRule(agentN, address(stake));
    }

    function _one(Session memory s) internal pure returns (Session[] memory rules) {
        rules = new Session[](1);
        rules[0] = s;
    }

    /// @dev The id `grantRules` returns at grant nonce `nonce`: the engine's own derivation, by hand.
    function _expectedId(address agent, uint256 nonce) internal view returns (bytes32) {
        return keccak256(abi.encode(address(validator), agentConfig(agent), bytes32(nonce)));
    }

    function _predicted(address owner_) internal view returns (address wallet_) {
        (wallet_,) = factory.predictWallet(owner_, factory.walletCount(owner_));
    }

    /// @dev A relayed create intent for `owner_`'s next wallet, committing to `rules`.
    function _createIntent(address owner_, Session[] memory rules) internal view returns (OwnerIntent memory i) {
        (address w, uint96 idx) = nextWallet(owner_);
        i = blankIntent(owner_, w, RELAYER);
        i.index = idx;
        i.sessionHash = keccak256(abi.encode(rules));
        i.grantNonce = 0;
    }

    function _relayCreate(OwnerIntent memory i, bytes memory sig, string memory label, Session[] memory rules)
        internal
        returns (address wallet, bytes32[] memory rulesIds)
    {
        vm.prank(RELAYER);
        return factory.createWalletWithSig(i, sig, label, rules);
    }

    // ───────────────────────────── shared assertions ─────────────────────────────

    /**
     * @dev Everything C01 asserts about a wallet created with `_twoRules()` for `owner_`: registry,
     *      label, both rules live and naming their agents, ids derived from grant nonces 0 and 1, the
     *      counters, and the exact event sequence of C-7 with the derived modes.
     */
    function _assertTwoRuleWallet(address owner_, address wallet, bytes32[] memory rulesIds, Vm.Log[] memory logs)
        internal
        view
    {
        AGW w = AGW(payable(wallet));
        assertTrue(factory.isWallet(wallet), "registered");
        assertEq(factory.ownerOf(wallet), owner_, "owner recorded");
        assertEq(w.owner(), owner_, "owner in immutable args");
        assertEq(w.label(), "aave-bot", "label stored");

        assertEq(rulesIds.length, 2, "two ids");
        assertEq(rulesIds[0], _expectedId(agentU, 0), "id 0 from grant nonce 0");
        assertEq(rulesIds[1], _expectedId(agentN, 1), "id 1 from grant nonce 1");
        assertTrue(engine.isPermissionEnabled(PermissionId.wrap(rulesIds[0]), wallet), "universal rule live");
        assertTrue(engine.isPermissionEnabled(PermissionId.wrap(rulesIds[1]), wallet), "native rule live");
        assertEq(w.agentOf(rulesIds[0]), agentU, "universal agent");
        assertEq(w.agentOf(rulesIds[1]), agentN, "native agent");

        assertEq(w.grantNonce(), 2, "grant nonce");
        assertEq(w.checkpointCount(), 2, "two RULES_GRANTED checkpoints");

        _assertCreateEvents(owner_, wallet, rulesIds, logs);
    }

    /// @dev The wallet's and factory's events, in order, ignoring the engine's and URP's own.
    function _assertCreateEvents(address owner_, address wallet, bytes32[] memory rulesIds, Vm.Log[] memory logs)
        internal
        view
    {
        bytes32[7] memory want = [
            IAGW.ModuleInstalled.selector,
            IAGW.AccountInitialized.selector,
            IAGW.Checkpointed.selector,
            IAGW.RulesGranted.selector,
            IAGW.Checkpointed.selector,
            IAGW.RulesGranted.selector,
            IAGWFactory.WalletDeployed.selector
        ];
        RulesType[2] memory modes = [RulesType.UNIVERSAL, RulesType.NATIVE];
        string[2] memory chains = [CHAIN_SEPOLIA, nativeChain()];

        uint256 k;
        for (uint256 j; j < logs.length; ++j) {
            Vm.Log memory l = logs[j];
            if (l.emitter != wallet && l.emitter != FACTORY) continue;
            assertLt(k, want.length, "no extra wallet or factory events");
            assertEq(l.topics[0], want[k], "event order");

            if (want[k] == IAGW.Checkpointed.selector) {
                uint256 r = (k - 2) / 2;
                assertEq(uint256(l.topics[1]), r + 1, "checkpoint seq");
                (CheckpointKind kind, bytes32 ref, uint64 blockNumber) =
                    abi.decode(l.data, (CheckpointKind, bytes32, uint64));
                assertEq(uint8(kind), uint8(CheckpointKind.RULES_GRANTED), "checkpoint kind");
                assertEq(ref, rulesIds[r], "checkpoint ref");
                assertEq(blockNumber, block.number, "checkpoint block");
            } else if (want[k] == IAGW.RulesGranted.selector) {
                uint256 r = (k - 3) / 2;
                assertEq(l.topics[1], rulesIds[r], "granted id");
                assertEq(l.topics[2], keccak256(bytes(chains[r])), "granted chain hash");
                (RulesType mode, string memory chain) = abi.decode(l.data, (RulesType, string));
                assertEq(uint8(mode), uint8(modes[r]), "derived mode");
                assertEq(chain, chains[r], "granted chain");
            } else if (want[k] == IAGWFactory.WalletDeployed.selector) {
                assertEq(l.topics[1], bytes32(uint256(uint160(owner_))), "deployed owner");
                assertEq(l.topics[3], bytes32(uint256(uint160(wallet))), "deployed wallet");
            }
            ++k;
        }
        assertEq(k, want.length, "every expected event fired");
    }

    // ═══════════════════════════════ unsigned: createWallet ═══════════════════════════════

    /// ⚠️ NEVER-DELETE. §6.2's purpose: one factory call deploys the wallet and grants both rules.
    function test_C01_CreateWithTwoRules() public {
        address predicted = _predicted(ownerAddr);

        vm.recordLogs();
        vm.prank(ownerAddr);
        (address wallet, bytes32[] memory rulesIds) = factory.createWallet("aave-bot", _twoRules());
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(wallet, predicted, "deployed at predictWallet(owner, 0)");
        _assertTwoRuleWallet(ownerAddr, wallet, rulesIds, logs);
    }

    function test_C02_EmptyRulesEqualsDeployWallet() public {
        address predicted = _predicted(ownerAddr);

        vm.prank(ownerAddr);
        (address wallet, bytes32[] memory rulesIds) = factory.createWallet("x", new Session[](0));

        assertEq(wallet, predicted, "the address deployWallet would use");
        assertEq(rulesIds.length, 0, "no ids");
        assertEq(AGW(payable(wallet)).grantNonce(), 0, "no grants");
        assertEq(AGW(payable(wallet)).checkpointCount(), 0, "no checkpoints");
        assertEq(AGW(payable(wallet)).label(), "x", "label stored");
        assertTrue(AGW(payable(wallet)).isModuleInstalled(1, address(engine), ""), "engine installed");
    }

    function test_C03_BadRuleRevertsWholeCreate() public {
        address predicted = _predicted(ownerAddr);
        Session[] memory rules = _twoRules();
        rules[1] = sessionWithPolicy(makeAddr("foreignPolicy"), agentConfig(agentN), "");

        vm.prank(ownerAddr);
        vm.expectRevert(AGWErrors.MalformedSessionShape.selector);
        factory.createWallet("x", rules);

        assertEq(factory.walletCount(ownerAddr), 0, "count unchanged");
        assertEq(predicted.code.length, 0, "nothing deployed");
    }

    function test_C04_UrpInitErrorBubblesInFull() public {
        address predicted = _predicted(ownerAddr);
        NativeConfig memory cfg = _nativeCfg(address(stake));
        cfg.validUntil = uint48(block.timestamp - 1);

        Session[] memory rules = _twoRules();
        rules[1] = _nativeRuleFrom(agentN, cfg);

        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.InvalidExpiry.selector, cfg.validUntil));
        factory.createWallet("x", rules);

        assertEq(factory.walletCount(ownerAddr), 0, "count unchanged");
        assertEq(predicted.code.length, 0, "nothing deployed");
    }

    function test_C05_RulesCountLimit() public {
        assertEq(MAX_INITIAL_RULES, 8, "the PRD's limit");

        address predicted = _predicted(ownerAddr);
        Session[] memory tooMany = _nativeRules(MAX_INITIAL_RULES + 1);
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSelector(AGWFactoryErrors.TooManyInitialRules.selector, MAX_INITIAL_RULES + 1));
        uint256 before = gasleft();
        factory.createWallet("x", tooMany);
        uint256 usedRefused = before - gasleft();
        emit log_named_uint("createWallet with 9 rules, refused, gas", usedRefused);
        // BEFORE deployment, not merely reverted: a revert after `_deploy` also leaves nothing behind, so
        // only the cost tells the two apart. A clone plus nine grants is ~5M gas.
        assertLt(usedRefused, TOO_MANY_RULES_REFUSAL_GAS_BUDGET, "refused before any deployment work");
        assertEq(predicted.code.length, 0, "nothing deployed");
        assertEq(factory.walletCount(ownerAddr), 0, "count unchanged");

        vm.prank(ownerAddr);
        (address wallet, bytes32[] memory rulesIds) = factory.createWallet("x", _nativeRules(MAX_INITIAL_RULES));
        assertEq(wallet, predicted, "deployed at the predicted address");
        assertEq(rulesIds.length, MAX_INITIAL_RULES, "every id returned");
        assertEq(AGW(payable(wallet)).grantNonce(), MAX_INITIAL_RULES, "grant nonce == 8");
    }

    function test_C06_PausedRefusesBoth() public {
        vm.prank(PAUSER);
        factory.pause();

        vm.prank(ownerAddr);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        factory.createWallet("x", _twoRules());

        Session[] memory rules = _twoRules();
        OwnerIntent memory i = _createIntent(ownerAddr, rules);
        bytes memory sig = signIntent(ownerPk, i);
        vm.prank(RELAYER);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        factory.createWalletWithSig(i, sig, "x", rules);

        vm.prank(OPERATOR);
        factory.unpause();

        vm.prank(ownerAddr);
        (address w0,) = factory.createWallet("x", _twoRules());
        assertTrue(factory.isWallet(w0), "createWallet works after unpause");

        i = _createIntent(ownerAddr, rules);
        sig = signIntent(ownerPk, i);
        (address w1,) = _relayCreate(i, sig, "y", rules);
        assertTrue(factory.isWallet(w1), "createWalletWithSig works after unpause");
        assertEq(factory.indexOf(w1), 1, "second wallet");
    }

    /// The initial rules are real rules: the agent acts at once, and a refused call is refused by URP.
    function test_C07_AgentActsImmediately() public {
        vm.prank(ownerAddr);
        (address wallet, bytes32[] memory rulesIds) =
            factory.createWallet("x", _one(_nativeRule(agentN, address(stake))));
        vm.deal(wallet, 5 ether);
        AGW w = AGW(payable(wallet));
        bytes32 single = ModeCode.unwrap(ModeLib.encodeSimpleSingle());

        vm.prank(agentN);
        w.executeAsAgent(
            rulesIds[0],
            single,
            ExecutionLib.encodeSingle(address(stake), 0.5 ether, abi.encodeCall(StakeDummy.depositFor, (wallet)))
        );
        assertEq(stake.pcBalance(wallet), 0.5 ether, "the agent's deposit landed");

        bytes memory overCap =
            ExecutionLib.encodeSingle(address(stake), 2 ether, abi.encodeCall(StakeDummy.depositFor, (wallet)));
        vm.prank(agentN);
        expectUrpGate(abi.encodeWithSelector(UniversalRulesPolicyErrors.ValueExceedsCap.selector, 2 ether, 1 ether));
        w.executeAsAgent(rulesIds[0], single, overCap);
    }

    function test_C08_CounterfactualFundingKept() public {
        address predicted = _predicted(ownerAddr);
        pUSDC.mint(predicted, 50e6);
        vm.deal(predicted, 1 ether);

        vm.prank(ownerAddr);
        (address wallet,) = factory.createWallet("x", _twoRules());

        assertEq(wallet, predicted, "the funded address");
        assertEq(pUSDC.balanceOf(wallet), 50e6, "tokens kept");
        assertEq(wallet.balance, 1 ether, "PC kept");
    }

    function test_C09_NoRuleInjectionAfterDeploy() public {
        vm.prank(ownerAddr);
        (address wallet,) = factory.createWallet("x", _one(_nativeRule(agentN, address(stake))));
        AGW w = AGW(payable(wallet));
        Session[] memory injected = _one(_nativeRule(stranger, _target(1)));

        vm.prank(FACTORY);
        vm.expectRevert(AGWErrors.AlreadyInitialized.selector);
        w.initializeAccount("y", injected);

        vm.prank(stranger);
        vm.expectRevert(AGWErrors.CallerIsNotFactory.selector);
        w.initializeAccount("y", injected);

        assertEq(w.grantNonce(), 1, "grant nonce unchanged");
        assertEq(w.label(), "x", "label unchanged");
    }

    function test_C10_OldDeployDoorsUnchanged() public {
        vm.prank(ownerAddr);
        AGW w0 = AGW(payable(factory.deployWallet("x")));
        assertEq(w0.grantNonce(), 0, "deployWallet: no rules");
        assertEq(w0.checkpointCount(), 0, "deployWallet: no checkpoints");

        (address predicted, uint96 idx) = nextWallet(ownerAddr);
        OwnerIntent memory i = blankIntent(ownerAddr, predicted, RELAYER);
        i.index = idx;
        bytes memory sig = signIntent(ownerPk, i);
        vm.prank(RELAYER);
        AGW w1 = AGW(payable(factory.deployWalletWithSig(i, sig, "y")));
        assertEq(w1.grantNonce(), 0, "deployWalletWithSig: no rules");
        assertEq(w1.checkpointCount(), 0, "deployWalletWithSig: no checkpoints");

        assertEq(AGWFactory.deployWallet.selector, bytes4(keccak256("deployWallet(string)")), "deployWallet selector");
        assertEq(
            AGWFactory.deployWalletWithSig.selector,
            bytes4(
                keccak256(
                    "deployWalletWithSig((address,address,address,uint96,bytes32,bytes32,bytes32,uint192,uint64,uint64,uint48,uint256),bytes,string)"
                )
            ),
            "deployWalletWithSig selector"
        );
    }

    function test_C11_RulesGrantedInOrder() public {
        vm.recordLogs();
        vm.prank(ownerAddr);
        (address wallet, bytes32[] memory rulesIds) = factory.createWallet("x", _nativeRules(3));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 r; r < 3; ++r) {
            assertEq(rulesIds[r], _expectedId(agentN, r), "ids in input order");
        }

        uint256 seen;
        for (uint256 j; j < logs.length; ++j) {
            if (logs[j].emitter != wallet || logs[j].topics[0] != IAGW.Checkpointed.selector) continue;
            assertEq(uint256(logs[j].topics[1]), seen + 1, "seq 1, 2, 3");
            (, bytes32 ref,) = abi.decode(logs[j].data, (CheckpointKind, bytes32, uint64));
            assertEq(ref, rulesIds[seen], "checkpoint follows input order");
            ++seen;
        }
        assertEq(seen, 3, "three checkpoints");
    }

    function test_C12_SecondWalletSameOwner() public {
        vm.prank(ownerAddr);
        (address w0,) = factory.createWallet("first", _one(_nativeRule(agentN, address(stake))));

        (address predicted1,) = factory.predictWallet(ownerAddr, 1);
        vm.prank(ownerAddr);
        (address w1, bytes32[] memory ids1) = factory.createWallet("second", _twoRules());

        assertEq(w1, predicted1, "wallet 1 at predictWallet(owner, 1)");
        assertEq(factory.indexOf(w1), 1, "index 1");
        assertEq(ids1[0], _expectedId(agentU, 0), "wallet 1's grant nonce starts at 0");
        assertEq(AGW(payable(w1)).grantNonce(), 2, "wallet 1 grant nonce");
        assertEq(AGW(payable(w0)).grantNonce(), 1, "wallet 0 untouched");
    }

    // ═══════════════════════════════ signed: createWalletWithSig ═══════════════════════════════

    /// ⚠️ NEVER-DELETE. The marketplace's `startJob` shape: one owner signature, one relayed call.
    function test_S01_RelayedCreateWithRules() public {
        Session[] memory rules = _twoRules();
        OwnerIntent memory i = _createIntent(ownerAddr, rules);
        bytes memory sig = signIntent(ownerPk, i);

        vm.recordLogs();
        (address wallet, bytes32[] memory rulesIds) = _relayCreate(i, sig, "aave-bot", rules);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(wallet, i.wallet, "deployed at the signed, predicted address");
        _assertTwoRuleWallet(ownerAddr, wallet, rulesIds, logs);
    }

    function test_S02_TamperedRulesRefused() public {
        Session[] memory signed = _twoRules();
        OwnerIntent memory i = _createIntent(ownerAddr, signed);
        bytes memory sig = signIntent(ownerPk, i);

        // one byte of one initData
        Session[] memory flipped = _twoRules();
        bytes memory d = flipped[1].actions[0].actionPolicies[0].initData;
        d[d.length - 1] ^= 0x01;
        _expectRulesMismatch(i, sig, flipped);

        // swapped order
        Session[] memory swapped = new Session[](2);
        swapped[0] = signed[1];
        swapped[1] = signed[0];
        _expectRulesMismatch(i, sig, swapped);

        // one rule dropped
        _expectRulesMismatch(i, sig, _one(signed[0]));

        // one rule appended
        Session[] memory appended = new Session[](3);
        appended[0] = signed[0];
        appended[1] = signed[1];
        appended[2] = _nativeRule(agentN, _target(9));
        _expectRulesMismatch(i, sig, appended);

        assertEq(factory.walletCount(ownerAddr), 0, "nothing deployed");
    }

    function _expectRulesMismatch(OwnerIntent memory i, bytes memory sig, Session[] memory presented) internal {
        vm.prank(RELAYER);
        vm.expectRevert(
            abi.encodeWithSelector(AGWFactoryErrors.IntentRulesMismatch.selector, keccak256(abi.encode(presented)))
        );
        factory.createWalletWithSig(i, sig, "x", presented);
    }

    function test_S03_NonZeroGrantNonceRefused() public {
        Session[] memory rules = _twoRules();
        OwnerIntent memory i = _createIntent(ownerAddr, rules);
        i.grantNonce = 1;
        bytes memory sig = signIntent(ownerPk, i);

        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(AGWFactoryErrors.IntentGrantNonceNotZero.selector, uint64(1)));
        factory.createWalletWithSig(i, sig, "x", rules);
    }

    function test_S04_ExecutorChecks() public {
        Session[] memory rules = _twoRules();
        OwnerIntent memory i = _createIntent(ownerAddr, rules);
        bytes memory sig = signIntent(ownerPk, i);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AGWFactoryErrors.ExecutorMismatch.selector, RELAYER, stranger));
        factory.createWalletWithSig(i, sig, "x", rules);

        i.executor = address(0);
        sig = signIntent(ownerPk, i);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AGWFactoryErrors.ExecutorMismatch.selector, address(0), stranger));
        factory.createWalletWithSig(i, sig, "x", rules);
    }

    function test_S05_Expired() public {
        Session[] memory rules = _twoRules();
        OwnerIntent memory i = _createIntent(ownerAddr, rules);
        bytes memory sig = signIntent(ownerPk, i);

        vm.warp(uint256(i.deadline) + 1);
        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(AGWFactoryErrors.SignatureExpired.selector, i.deadline));
        factory.createWalletWithSig(i, sig, "x", rules);
    }

    function test_S06_BadSignature() public {
        Session[] memory rules = _twoRules();
        OwnerIntent memory i = _createIntent(ownerAddr, rules);

        bytes memory wrongKey = signIntent(otherPk, i);
        vm.prank(RELAYER);
        vm.expectRevert(AGWFactoryErrors.InvalidOwnerSignature.selector);
        factory.createWalletWithSig(i, wrongKey, "x", rules);

        OwnerIntent memory otherDomain = _createIntent(ownerAddr, rules);
        otherDomain.signerChainId = 137;
        bytes memory wrongDomain = signIntent(ownerPk, otherDomain);
        vm.prank(RELAYER);
        vm.expectRevert(AGWFactoryErrors.InvalidOwnerSignature.selector);
        factory.createWalletWithSig(i, wrongDomain, "x", rules);
    }

    function test_S07_IndexAndWalletChecks() public {
        Session[] memory rules = _twoRules();
        OwnerIntent memory i = _createIntent(ownerAddr, rules);
        i.index = 1;
        bytes memory sig = signIntent(ownerPk, i);
        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(AGWFactoryErrors.IndexMismatch.selector, uint96(0), uint96(1)));
        factory.createWalletWithSig(i, sig, "x", rules);

        i = _createIntent(ownerAddr, rules);
        address predicted = i.wallet;
        address wrong = makeAddr("wrongWallet");
        i.wallet = wrong;
        sig = signIntent(ownerPk, i);
        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(AGWFactoryErrors.IntentWalletMismatch.selector, predicted, wrong));
        factory.createWalletWithSig(i, sig, "x", rules);
    }

    function test_S08_NoReplay() public {
        Session[] memory rules = _twoRules();
        OwnerIntent memory i = _createIntent(ownerAddr, rules);
        bytes memory sig = signIntent(ownerPk, i);
        _relayCreate(i, sig, "aave-bot", rules);

        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(AGWFactoryErrors.IndexMismatch.selector, uint96(1), uint96(0)));
        factory.createWalletWithSig(i, sig, "aave-bot", rules);
    }

    function test_S09_OwnerCallsDirectlyWithoutSignature() public {
        Session[] memory rules = _twoRules();
        OwnerIntent memory i = _createIntent(ownerAddr, rules);
        i.sessionHash = bytes32(0);

        vm.prank(ownerAddr);
        (address wallet, bytes32[] memory rulesIds) = factory.createWalletWithSig(i, "", "x", rules);

        assertEq(wallet, i.wallet, "deployed");
        assertEq(factory.ownerOf(wallet), ownerAddr, "owned by the caller");
        assertEq(rulesIds.length, 2, "both rules granted");
        assertEq(AGW(payable(wallet)).grantNonce(), 2, "grant nonce");
    }

    function test_S10_IntentNotReusableAtGrantDoor() public {
        Session[] memory rules = _twoRules();
        OwnerIntent memory i = _createIntent(ownerAddr, rules);
        bytes memory sig = signIntent(ownerPk, i);
        (address wallet,) = _relayCreate(i, sig, "aave-bot", rules);

        vm.prank(RELAYER);
        vm.expectRevert(
            abi.encodeWithSelector(AGWErrors.IntentSessionMismatch.selector, keccak256(abi.encode(rules[0])))
        );
        AGW(payable(wallet)).grantRulesWithSig(rules[0], i, sig);
    }

    /// Known and accepted (PRD §6.4): `deployWalletWithSig` ignores `sessionHash`, so the executor can
    /// deploy the wallet WITHOUT its rules; the create then fails `IndexMismatch`. The owner chose the
    /// executor, and the result is a harmless, rules-less wallet the owner can grant into later.
    function test_S11_DeployDoorIgnoresRules_KnownLimitation() public {
        Session[] memory rules = _twoRules();
        OwnerIntent memory i = _createIntent(ownerAddr, rules);
        bytes memory sig = signIntent(ownerPk, i);

        vm.prank(RELAYER);
        AGW w = AGW(payable(factory.deployWalletWithSig(i, sig, "x")));
        assertEq(address(w), i.wallet, "the signed address");
        assertEq(w.grantNonce(), 0, "deployed with no rules");

        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(AGWFactoryErrors.IndexMismatch.selector, uint96(1), uint96(0)));
        factory.createWalletWithSig(i, sig, "x", rules);
    }

    function test_S12_UeaOwnerSignature() public {
        MockUEA uea = new MockUEA(ownerAddr);
        Session[] memory rules = _twoRules();
        OwnerIntent memory i = _createIntent(address(uea), rules);
        bytes memory sig = signIntent(ownerPk, i);

        (address wallet, bytes32[] memory rulesIds) = _relayCreate(i, sig, "x", rules);

        assertEq(factory.ownerOf(wallet), address(uea), "the UEA owns it");
        assertEq(rulesIds.length, 2, "both rules granted");
        assertTrue(engine.isPermissionEnabled(PermissionId.wrap(rulesIds[1]), wallet), "rules live");
    }

    /// Pins §3.4's order: deadline before the rules hash, the rules hash before the signature.
    function test_S13_CheckOrder() public {
        Session[] memory rules = _twoRules();
        Session[] memory tampered = _one(rules[0]);
        OwnerIntent memory i = _createIntent(ownerAddr, rules);

        bytes memory badSig = signIntent(otherPk, i);
        vm.prank(RELAYER);
        vm.expectRevert(
            abi.encodeWithSelector(AGWFactoryErrors.IntentRulesMismatch.selector, keccak256(abi.encode(tampered)))
        );
        factory.createWalletWithSig(i, badSig, "x", tampered);

        bytes memory sig = signIntent(ownerPk, i);
        vm.warp(uint256(i.deadline) + 1);
        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(AGWFactoryErrors.SignatureExpired.selector, i.deadline));
        factory.createWalletWithSig(i, sig, "x", tampered);
    }

    // ═══════════════════════════════ fuzz ═══════════════════════════════

    function testFuzz_F01_RuleCount(uint8 n) public {
        uint256 count = bound(n, 0, MAX_INITIAL_RULES);

        vm.prank(ownerAddr);
        (address wallet, bytes32[] memory rulesIds) = factory.createWallet("x", _nativeRules(count));
        AGW w = AGW(payable(wallet));

        assertEq(rulesIds.length, count, "one id per rule");
        assertEq(w.grantNonce(), count, "grant nonce");
        assertEq(w.checkpointCount(), count, "one checkpoint per rule");
        for (uint256 r; r < count; ++r) {
            assertTrue(engine.isPermissionEnabled(PermissionId.wrap(rulesIds[r]), wallet), "live");
        }
    }

    /// Every signed byte is bound, including the `salt` the wallet later overwrites with its grant nonce.
    function testFuzz_F02_RulesHashBinding(bytes32 salt) public {
        Session[] memory signed = _twoRules();
        signed[0].salt = salt;
        OwnerIntent memory i = _createIntent(ownerAddr, signed);
        bytes memory sig = signIntent(ownerPk, i);

        Session[] memory presented = _twoRules();
        presented[0].salt = bytes32(uint256(salt) ^ 1);
        _expectRulesMismatch(i, sig, presented);

        (, bytes32[] memory rulesIds) = _relayCreate(i, sig, "x", signed);
        assertEq(rulesIds[0], _expectedId(agentU, 0), "the wallet's own salt, not the signed one");
    }

    // ═══════════════════════════════ gas ═══════════════════════════════

    /// `createWallet(label, [r1, r2])` against `deployWallet(label)` plus the owner's batched grant.
    function test_G01_CreateVsDeployThenGrant() public {
        // Warm the shared contracts (engine, URP, validator, factory, implementation) for both paths.
        vm.prank(makeAddr("warmup"));
        factory.createWallet("warm", _twoRules());

        Session[] memory rules = _twoRules();
        address a = makeAddr("createOwnerGas");
        address b = makeAddr("deployOwnerGas");

        vm.prank(a);
        uint256 before = gasleft();
        factory.createWallet("bot", rules);
        uint256 usedCreate = before - gasleft();

        vm.prank(b);
        before = gasleft();
        address w = factory.deployWallet("bot");
        uint256 usedDeploy = before - gasleft();

        Execution[] memory execs = new Execution[](2);
        execs[0] = Execution({ target: w, value: 0, callData: abi.encodeCall(AGW.grantRules, (rules[0])) });
        execs[1] = Execution({ target: w, value: 0, callData: abi.encodeCall(AGW.grantRules, (rules[1])) });
        bytes memory batch = ExecutionLib.encodeBatch(execs);
        bytes32 batchMode = ModeCode.unwrap(ModeLib.encodeSimpleBatch());

        vm.prank(b);
        before = gasleft();
        AGW(payable(w)).execute(batchMode, batch);
        uint256 usedGrant = before - gasleft();

        emit log_named_uint("createWallet(label, [universal, native]) gas", usedCreate);
        emit log_named_uint("deployWallet(label) gas", usedDeploy);
        emit log_named_uint("execute(batch [grantRules x2]) gas", usedGrant);
        emit log_named_uint("deploy + grant total gas (excluding the second tx's 21,000)", usedDeploy + usedGrant);

        assertEq(AGW(payable(w)).grantNonce(), 2, "the two-step path granted both");
        assertLe(usedCreate, usedDeploy + usedGrant, "one call costs no more than the two-step path");
        assertLt(
            usedCreate,
            isolatedCalls() ? CREATE_TWO_RULES_GAS_BUDGET_ISOLATED : CREATE_TWO_RULES_GAS_BUDGET,
            "createWallet with two rules within its measured budget"
        );
    }
}
