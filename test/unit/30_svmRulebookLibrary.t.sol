// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { UniversalRulesPolicyErrors } from "../../src/libraries/Errors.sol";

import { Vm } from "forge-std/Vm.sol";

import { BaseTest } from "../Base.t.sol";
import { SvmRulebook } from "../../src/policies/SvmRulebook.sol";
import { IUniversalRulesPolicy } from "../../src/interfaces/IUniversalRulesPolicy.sol";
import { AllowedProgram, SvmAccountPin, SvmConfig, SvmDataPin, SvmTerms } from "../../src/libraries/Types.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";
import { MockPRC20 } from "../mocks/MockUniversalGateway.sol";

/**
 * @title  SvmRulebookLibraryTest — the extraction itself, not the rules.
 *
 * @notice `9_svmRulebook.t.sol` owns the S1-S18 gauntlet and every grant guard; it passes UNEDITED
 *         through this change, which is the real proof that behaviour did not move. This file
 *         proves the five facts the DELEGATECALL model rests on, each of which would be invisible
 *         to a gate test:
 *
 *           L1  URP is actually linked to a deployed library (not inlined, not a stub)
 *           L2  the library declares no storage
 *           L3  a direct call to it is refused by Solidity's library call protection
 *           L4  events still come from the PROXY, with the engine as `multiplexer`
 *           L5  revert data still carries its arguments, byte for byte
 *           L6  state written through the library lands in the PROXY's storage
 *           L7  `getSvmConfig`'s ABI output is unchanged (only under trim T9; see the test)
 *
 * @dev    Fixtures are the minimum needed to make one valid SVM rules set and one valid request;
 *         they deliberately mirror `9_svmRulebook.t.sol` rather than importing its internals, so a
 *         change there cannot silently weaken an assertion here.
 */
contract SvmRulebookLibraryTest is BaseTest {
    ConfigId internal constant CID = ConfigId.wrap(bytes32(uint256(0x5B11)));
    uint48 internal constant VALID_UNTIL = 2_000_000_000;

    address internal ACCOUNT;
    address internal ASSET;

    bytes32 internal CEA = keccak256("push_identity pda for ACCOUNT");
    bytes32 internal ATA_IN = keccak256("ata(CEA, USDC)");
    bytes32 internal GATEWAY_PROG = keccak256("push svm gateway program");
    bytes32 internal PROG = keccak256("aggregator program");

    bytes8 internal constant ROUTE = 0xc1209b3341d69c81; // shared_accounts_route

    uint256 internal constant MAX_PER_CALL = 100_000_000;
    uint256 internal constant MAX_TOTAL = 1_000_000_000;
    uint256 internal constant MAX_PC = 5 ether;

    function setUp() public override {
        super.setUp();
        ACCOUNT = makeAddr("agentWallet");
        MockPRC20 asset = new MockPRC20();
        asset.setSourceChainNamespace(CHAIN_SOLANA_DEVNET);
        ASSET = address(asset);
        vm.warp(1_000_000_000);
    }

    // ───────────────────────────── fixtures ─────────────────────────────

    function _terms() internal view returns (SvmTerms memory t) {
        AllowedProgram[] memory r = new AllowedProgram[](1);
        r[0] = AllowedProgram({
            program: PROG, discriminator: ROUTE, discriminatorLen: 8, dataless: false, maxAccounts: 0
        });

        SvmAccountPin[] memory p = new SvmAccountPin[](2);
        p[0] = SvmAccountPin({ ruleIndex: 0, accountIndex: 0, expected: CEA });
        p[1] = SvmAccountPin({ ruleIndex: 0, accountIndex: 1, expected: ATA_IN });

        bytes32[] memory c = new bytes32[](2);
        c[0] = CEA;
        c[1] = ATA_IN;

        t = SvmTerms({
            validUntil: VALID_UNTIL,
            expectedCEA: CEA,
            gatewayProgram: GATEWAY_PROG,
            assets: oneCap(ASSET, MAX_PER_CALL, MAX_TOTAL),
            maxGasPerCall: MAX_PC,
            ceaAccounts: c,
            programs: r,
            pins: p,
            dataPins: new SvmDataPin[](0)
        });
    }

    function _init() internal {
        vm.prank(address(engine));
        urp.initializeWithMultiplexer(ACCOUNT, CID, svmInitData(CHAIN_SOLANA_DEVNET, _terms()));
    }

    /// @dev Two accounts, both pinned, so S17 and S18 both pass.
    function _payload() internal view returns (bytes memory) {
        bytes32[] memory a = new bytes32[](2);
        bool[] memory w = new bool[](2);
        a[0] = CEA;
        w[0] = true;
        a[1] = ATA_IN;
        w[1] = true;
        return svmExecutePayload(a, w, abi.encodePacked(ROUTE), 2, PROG);
    }

    function _request(uint256 amount) internal view returns (bytes memory) {
        return svmOutboundRequest(ASSET, amount, 1 ether, ACCOUNT, abi.encodePacked(PROG), _payload());
    }

    // ───────────────────────────── L1 ─────────────────────────────

    /**
     * @dev The link is real. An EXTERNAL library is a deployed contract whose 20-byte address is
     *      stamped into every caller's bytecode at link time; an INTERNAL one is inlined and leaves
     *      no address at all. So finding the address inside URP's runtime code, and finding code at
     *      that address, is what distinguishes "linked" from "quietly inlined" — and inlining would
     *      put the 7.9 KB straight back and silently undo this whole change.
     *
     *      `address(SvmRulebook)` is how Solidity exposes the linked address to a test.
     */
    function test_SL1_UrpIsLinkedToTheLibrary() public view {
        address lib = address(SvmRulebook);
        assertTrue(lib != address(0), "library address is zero - not linked");
        assertGt(lib.code.length, 0, "no code at the linked library address");

        bytes memory urpCode = address(urpImplementation).code;
        bytes memory needle = abi.encodePacked(bytes20(lib));

        bool found;
        // A 20-byte window scan. `urpCode.length` exceeds 17 KB, so this is the cheap direction.
        for (uint256 i; i + 20 <= urpCode.length; ++i) {
            bool same = true;
            for (uint256 j; j < 20; ++j) {
                if (urpCode[i + j] != needle[j]) {
                    same = false;
                    break;
                }
            }
            if (same) {
                found = true;
                break;
            }
        }
        assertTrue(found, "URP implementation does not embed the linked library address");
    }

    // ───────────────────────────── L2 ─────────────────────────────

    /// @dev A library cannot declare storage, and this is the artifact-level proof rather than a
    ///      `vm.load` probe that would pass on a contract that declares slots and never writes them.
    function test_SL2_LibraryDeclaresNoStorage() public view {
        assertEmptyStorageLayout("SvmRulebook");
    }

    // ───────────────────────────── L3 ─────────────────────────────

    /**
     * @dev Library call protection. A non-view external library function compiled for DELEGATECALL
     *      carries a guard that reverts when the call arrives as a plain CALL — which is what makes
     *      the deployed library useless to anyone but its linked callers, so nobody can drive
     *      `init`/`check` against a storage slot of their choosing.
     *
     *      Asserted by RAW call, not through the typed library symbol: Solidity will not emit a
     *      direct external call to a linked library, so the only way to attempt one is to hand the
     *      address encoded calldata. A bare `expectRevert` is correct here and justified: the
     *      protection reverts with NO data at all (it is a compiler-inserted guard, not a named
     *      error), so there is nothing to name. Verified by asserting the returned data is empty.
     */
    function test_SL3_DirectCallToLibraryReverts() public {
        address lib = address(SvmRulebook);

        // `check(SvmConfig storage, ConfigId, address, address, address, uint256, bytes)` — the
        // storage pointer is a plain uint256 slot number on the wire.
        bytes memory callData = abi.encodeWithSignature(
            "check(uint256,bytes32,address,address,address,uint256,bytes)",
            uint256(0),
            ConfigId.unwrap(CID),
            ACCOUNT,
            GATEWAY,
            GATEWAY,
            uint256(0),
            _request(0)
        );

        (bool ok, bytes memory ret) = lib.call(callData);
        assertFalse(ok, "a direct CALL into the library must revert");
        assertEq(ret.length, 0, "library call protection reverts with no data");

        bytes memory initData =
            abi.encodeWithSignature("init(uint256,bytes,bytes32)", uint256(0), abi.encode(_terms()), bytes32(0));
        (ok, ret) = lib.call(initData);
        assertFalse(ok, "a direct CALL to init must revert");
        assertEq(ret.length, 0, "library call protection reverts with no data");
    }

    // ───────────────────────────── L4 ─────────────────────────────

    /**
     * @dev Events survive the move. Inside a DELEGATECALL the library runs in the proxy's context,
     *      so `OutboundMetered` must be logged with the PROXY as emitter and `msg.sender` — still
     *      the engine, because DELEGATECALL does not rewrite it — as `multiplexer`. Either fact
     *      breaking would silently orphan every indexer built on this event.
     */
    function test_SL4_SvmEventsComeFromTheProxy() public {
        _init();

        vm.recordLogs();
        vm.prank(address(engine));
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _request(1_000_000));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = IUniversalRulesPolicy.OutboundMetered.selector;

        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != topic) continue;
            seen = true;
            assertEq(logs[i].emitter, address(urp), "OutboundMetered must come from the PROXY, not the library");
            // topics: [sig, id, multiplexer, account]
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(engine)))), "multiplexer must be the engine");
            assertEq(logs[i].topics[3], bytes32(uint256(uint160(ACCOUNT))), "account must be the wallet");
        }
        assertTrue(seen, "no OutboundMetered emitted");
    }

    // ───────────────────────────── L5 ─────────────────────────────

    /**
     * @dev Revert data bubbles through a library call unchanged, ARGUMENTS INCLUDED. Called directly
     *      as the engine, so nothing truncates: through the engine these same reverts are cut to 32
     *      bytes and rewrapped (`expectUrpGate`), which would hide an argument regression.
     *
     *      One init error and one check error, as §7.2 requires.
     */
    function test_SL5_SvmRevertDataUnchanged() public {
        // init: an expiry already past, which `init` reports with the offending value.
        SvmTerms memory bad = _terms();
        bad.validUntil = uint48(block.timestamp - 1);

        vm.prank(address(engine));
        vm.expectRevert(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.InvalidExpiry.selector, uint48(block.timestamp - 1))
        );
        urp.initializeWithMultiplexer(ACCOUNT, CID, svmInitData(CHAIN_SOLANA_DEVNET, bad));

        // check: S6, which names both the amount and the cap.
        _init();
        uint256 over = MAX_PER_CALL + 1;
        vm.prank(address(engine));
        vm.expectRevert(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.AmountExceedsCap.selector, over, MAX_PER_CALL)
        );
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _request(over));
    }

    // ───────────────────────────── L6 ─────────────────────────────

    /**
     * @dev The library writes the PROXY's storage, not its own. This is the single most important
     *      fact about the delegatecall model: a library that wrote its own slots would meter spend
     *      somewhere nobody reads, so every cap would be unenforceable while every test that only
     *      checks "the request passed" still went green.
     *
     *      Proved end to end — grant through the library, spend through the library, then read back
     *      through URP's own getter — so the write and the read must agree on the same slot.
     */
    function test_SL6_SvmStateWrittenToProxyStorage() public {
        _init();

        SvmConfig memory stored = urp.getSvmConfig(CID, ACCOUNT);
        assertTrue(stored.initialized, "grant did not land in the proxy's storage");
        assertEq(stored.expectedCEA, CEA, "expectedCEA not stored");
        assertEq(stored.gatewayProgram, GATEWAY_PROG, "gatewayProgram not stored");
        assertEq(stored.programs.length, 1, "programs not stored");
        assertEq(stored.pins.length, 2, "pins not stored");
        assertEq(stored.assets[0].spent, 0, "spent must start at zero");

        vm.prank(address(engine));
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _request(7_000_000));

        assertEq(
            urp.getSvmConfig(CID, ACCOUNT).assets[0].spent,
            7_000_000,
            "the library's spend write did not land in the proxy's storage"
        );

        // And the library did NOT write its own storage: its address holds code but no config.
        assertEq(
            uint256(vm.load(address(SvmRulebook), bytes32(uint256(7)))), 0, "the library must never write its own slots"
        );
    }

    // ───────────────────────────── L7 ─────────────────────────────

    /**
     * @dev `getSvmConfig`'s ABI output, pinned against an encoding rebuilt from the same terms.
     *
     *      §7.2 marks L7 "only if T9 is applied". T9 (raw-forwarding the getter with assembly) was
     *      NOT applied — URP came in at 17,465 B against the 18,500 B ceiling, so the §5 trim pass
     *      was not needed at all. The test is kept anyway and costs nothing: it is the regression
     *      guard that would catch T9, or any later getter rewrite, changing the bytes on the wire.
     */
    function test_SL7_GetSvmConfigOutputUnchanged() public {
        _init();

        SvmConfig memory got = urp.getSvmConfig(CID, ACCOUNT);
        SvmTerms memory t = _terms();

        // Field-by-field rather than one `abi.encode` comparison: a whole-struct assert that fails
        // says only "bytes differ", which is the least useful possible message here.
        assertTrue(got.initialized, "initialized");
        assertEq(got.validUntil, t.validUntil, "validUntil");
        assertEq(got.expectedCEA, t.expectedCEA, "expectedCEA");
        assertEq(got.gatewayProgram, t.gatewayProgram, "gatewayProgram");
        assertEq(got.maxGasPerCall, t.maxGasPerCall, "maxGasPerCall");

        assertEq(got.assets.length, t.assets.length, "assets length");
        assertEq(got.assets[0].token, t.assets[0].token, "asset token");
        assertEq(got.assets[0].maxPerCall, t.assets[0].maxPerCall, "asset maxPerCall");
        assertEq(got.assets[0].maxTotal, t.assets[0].maxTotal, "asset maxTotal");
        assertEq(got.assets[0].spent, 0, "asset spent");

        assertEq(got.ceaAccounts.length, t.ceaAccounts.length, "ceaAccounts length");
        assertEq(got.ceaAccounts[0], t.ceaAccounts[0], "ceaAccounts[0]");

        assertEq(got.programs.length, t.programs.length, "programs length");
        assertEq(got.programs[0].program, t.programs[0].program, "program id");
        assertEq(got.programs[0].discriminator, t.programs[0].discriminator, "discriminator");
        assertEq(got.programs[0].discriminatorLen, t.programs[0].discriminatorLen, "discriminatorLen");

        assertEq(got.pins.length, t.pins.length, "pins length");
        assertEq(got.pins[0].expected, t.pins[0].expected, "pin expected");
        assertEq(got.dataPins.length, 0, "dataPins length");
    }
}
