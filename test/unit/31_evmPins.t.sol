// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { UniversalRulesPolicyErrors } from "../../src/libraries/Errors.sol";

import { BaseTest } from "../Base.t.sol";
import {
    AllowedCall,
    AmountRule,
    ArgPin,
    Config,
    MAX_ALLOWED_CALL_PINS,
    MAX_PINS,
    Multicall,
    NativeConfig,
    PinOp
} from "../../src/libraries/Types.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";
import { MockPRC20 } from "../mocks/MockUniversalGateway.sol";

/**
 * @title  EvmPinsTest — argument pins on EVM destination calls, and MAX pins on Push calls.
 *
 * @notice THE FEATURE EXISTS TO STOP ONE ATTACK, and `test_P05_ApproveDrainRefused` is it: an
 *         allow-list entry for `USDC.approve` used to permit `approve(accomplice, type(uint256).max)`,
 *         after which the accomplice calls `transferFrom` directly on the destination chain, outside
 *         URP's reach entirely. The beneficiary check cannot defend it — requiring "spender == CEA"
 *         makes `approve` useless. A pinned spender can.
 *
 * @dev    WHERE TO ASSERT WHAT. Through the engine, revert data is truncated to a selector plus 28
 *         bytes, so `expectUrpGate` is the only honest assertion. Called DIRECTLY as the engine
 *         (`urp.checkAction`), the full arguments survive — that is where an error's arguments are
 *         pinned. Init errors are never truncated (they bubble from `ConfigLib`), so those use a
 *         plain `vm.expectRevert` with every argument.
 */
contract EvmPinsTest is BaseTest {
    address internal PROTOCOL;
    address internal USDC;
    address internal AAVE;
    address internal UNISWAP;
    address internal ACCOMPLICE;
    address internal CEA;
    address internal ACCOUNT;
    address internal ASSET;

    bytes4 internal constant APPROVE = bytes4(keccak256("approve(address,uint256)"));
    bytes4 internal constant SUPPLY = bytes4(keccak256("supply(address,uint256,address,uint16)"));
    bytes4 internal constant SWAP_SELECTOR = bytes4(keccak256("swap(uint256,address)"));

    /// @dev `swap(uint256,address)` — the beneficiary is argument 2, so 4 + 32.
    uint16 internal constant BENEFICIARY_OFFSET = 36;
    /// @dev `approve(address,uint256)` — spender at 4, amount at 36.
    uint16 internal constant SPENDER_OFFSET = 4;
    uint16 internal constant AMOUNT_OFFSET = 36;

    ConfigId internal constant CID = ConfigId.wrap(bytes32(uint256(0x9105)));
    uint48 internal constant VALID_UNTIL = 2_000_000_000;

    function setUp() public override {
        super.setUp();
        PROTOCOL = makeAddr("farChainProtocol");
        USDC = makeAddr("USDC on the destination chain");
        AAVE = makeAddr("AavePool");
        UNISWAP = makeAddr("UniswapRouter");
        ACCOMPLICE = makeAddr("accomplice");
        CEA = makeAddr("destinationAccount");
        ACCOUNT = makeAddr("agentWallet");
        ASSET = address(new MockPRC20());
        vm.warp(1_000_000_000);
    }

    // ───────────────────────────── builders ─────────────────────────────

    function _entry(address target, bytes4 selector, uint256 maxValue, ArgPin[] memory pins)
        internal
        pure
        returns (AllowedCall memory)
    {
        return AllowedCall({
            target: target,
            selector: selector,
            beneficiaryOffset: 0,
            hasBeneficiary: false,
            maxValue: maxValue,
            pins: pins
        });
    }

    function _one(AllowedCall memory e) internal pure returns (AllowedCall[] memory list) {
        list = new AllowedCall[](1);
        list[0] = e;
    }

    function _two(AllowedCall memory a, AllowedCall memory b) internal pure returns (AllowedCall[] memory list) {
        list = new AllowedCall[](2);
        list[0] = a;
        list[1] = b;
    }

    function _config(AllowedCall[] memory rules) internal view returns (Config memory cfg) {
        cfg = Config({
            initialized: false,
            validUntil: VALID_UNTIL,
            expectedCEA: CEA,
            maxGasPerCall: 5 ether,
            assets: oneAsset(ASSET, 100 ether, 1000 ether),
            allowedCalls: rules
        });
    }

    function _init(AllowedCall[] memory rules) internal {
        vm.prank(address(engine));
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(_config(rules)));
    }

    function _initReverts(bytes memory err, AllowedCall[] memory rules) internal {
        vm.prank(address(engine));
        vm.expectRevert(err);
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(_config(rules)));
    }

    /// @dev Grant under a CALLER-CHOSEN config id. `_init` reuses `CID`, and URP refuses
    ///      re-initialisation by design, so any test that grants more than once needs distinct ids.
    function _initAt(ConfigId id, AllowedCall[] memory rules) internal {
        vm.prank(address(engine));
        urp.initializeWithMultiplexer(ACCOUNT, id, universalInitData(_config(rules)));
    }

    function _initRevertsAt(ConfigId id, bytes memory err, AllowedCall[] memory rules) internal {
        vm.prank(address(engine));
        vm.expectRevert(err);
        urp.initializeWithMultiplexer(ACCOUNT, id, universalInitData(_config(rules)));
    }

    function _calls(Multicall memory c) internal pure returns (Multicall[] memory list) {
        list = new Multicall[](1);
        list[0] = c;
    }

    function _approveCall(address spender, uint256 amount) internal view returns (Multicall memory) {
        return Multicall({ to: USDC, value: 0, data: abi.encodeWithSelector(APPROVE, spender, amount) });
    }

    function _check(Multicall[] memory calls) internal returns (uint256) {
        vm.prank(address(engine));
        return urp.checkAction(CID, ACCOUNT, GATEWAY, 0, outboundRequest(ASSET, 1 ether, 1 ether, ACCOUNT, calls));
    }

    /// @dev Prank, THEN arm the revert, THEN call — the order Foundry requires.
    function _checkReverts(bytes memory err, Multicall[] memory calls) internal {
        vm.prank(address(engine));
        vm.expectRevert(err);
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, outboundRequest(ASSET, 1 ether, 1 ether, ACCOUNT, calls));
    }

    function _checkWithValue(uint256 innerValue, Multicall[] memory calls) internal returns (uint256) {
        calls[0].value = innerValue;
        vm.prank(address(engine));
        return urp.checkAction(CID, ACCOUNT, GATEWAY, 0, outboundRequest(ASSET, 1 ether, 1 ether, ACCOUNT, calls));
    }

    // ═══════════════════════════ P01–P04 · the comparisons ═══════════════════════════

    function test_P01_EqPinPasses() public {
        _init(_one(_entry(USDC, APPROVE, 0, eqPin(SPENDER_OFFSET, AAVE))));
        _check(_calls(_approveCall(AAVE, 1000e6)));
    }

    function test_P02_EqPinMismatchRefused() public {
        _init(_one(_entry(USDC, APPROVE, 0, eqPin(SPENDER_OFFSET, AAVE))));

        _checkReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.ArgPinMismatch.selector,
                bytes32(uint256(uint160(ACCOMPLICE))),
                uint256(0),
                bytes32(uint256(uint160(AAVE)))
            ),
            _calls(_approveCall(ACCOMPLICE, 1000e6))
        );
    }

    function test_P03_MaxPinBoundary() public {
        _init(_one(_entry(USDC, APPROVE, 0, maxPin(AMOUNT_OFFSET, 1000e6))));

        // == max passes: the bound is inclusive.
        _check(_calls(_approveCall(AAVE, 1000e6)));

        // max + 1 does not.
        _checkReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.ArgPinAboveMax.selector, uint256(1000e6 + 1), uint256(0), uint256(1000e6)
            ),
            _calls(_approveCall(AAVE, 1000e6 + 1))
        );
    }

    function test_P04_PinBeyondCalldataRefused() public {
        // `approve` calldata is 4 + 64 = 68 bytes; a pin at 100 needs 132.
        ArgPin[] memory pins = new ArgPin[](1);
        pins[0] = ArgPin({ offset: 100, op: PinOp.EQ, value: bytes32(0) });
        _init(_one(_entry(USDC, APPROVE, 0, pins)));

        _checkReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.CalldataTooShortForPin.selector, uint256(68), uint256(0), uint256(132)
            ),
            _calls(_approveCall(AAVE, 1000e6))
        );
    }

    // ═══════════════════════════ P05 · the attack ═══════════════════════════

    /**
     * @dev ⚠️ NEVER-DELETE. THE ATTACK THIS FEATURE EXISTS TO STOP.
     *
     *      Before pins, an allow-list entry for `USDC.approve` permitted
     *      `approve(accomplice, type(uint256).max)`. The accomplice then calls
     *      `USDC.transferFrom(CEA, accomplice, balance)` DIRECTLY on the destination chain — a
     *      transaction URP never sees, from an address it has no relationship with. The CEA is
     *      emptied, and no gate fired, because every gate passed: the target and selector were
     *      allow-listed, there was no beneficiary argument to pin, and `approve` carries no value.
     *
     *      Two pins close it: the spender is pinned to one protocol, and the allowance is capped.
     */
    function test_P05_ApproveDrainRefused() public {
        ArgPin[] memory pins = new ArgPin[](2);
        pins[0] = ArgPin({ offset: SPENDER_OFFSET, op: PinOp.EQ, value: bytes32(uint256(uint160(AAVE))) });
        pins[1] = ArgPin({ offset: AMOUNT_OFFSET, op: PinOp.MAX, value: bytes32(uint256(1000e6)) });
        _init(_one(_entry(USDC, APPROVE, 0, pins)));

        // (a) the drain: an unlimited approval to an accomplice. Refused on the SPENDER pin, index 0.
        _checkReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.ArgPinMismatch.selector,
                bytes32(uint256(uint160(ACCOMPLICE))),
                uint256(0),
                bytes32(uint256(uint160(AAVE)))
            ),
            _calls(_approveCall(ACCOMPLICE, type(uint256).max))
        );

        // (b) the legitimate approval still works.
        _check(_calls(_approveCall(AAVE, 1000e6)));

        // (c) the right spender, too much allowance. Refused on the AMOUNT pin, index 1.
        _checkReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.ArgPinAboveMax.selector, uint256(1000e6 + 1), uint256(1), uint256(1000e6)
            ),
            _calls(_approveCall(AAVE, 1000e6 + 1))
        );

        // (d) and the unlimited approval is refused even WITH the right spender.
        _checkReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.ArgPinAboveMax.selector, type(uint256).max, uint256(1), uint256(1000e6)
            ),
            _calls(_approveCall(AAVE, type(uint256).max))
        );
    }

    // ═══════════════════════════ P06–P09 · any-match ═══════════════════════════

    /**
     * @dev Any-match is what lets one token be approved to Aave OR to Uniswap. A single entry cannot
     *      express it: a pin is an equality, and one call has one spender.
     */
    function test_P06_AnyMatchingEntryPasses() public {
        _init(
            _two(
                _entry(USDC, APPROVE, 0, eqPin(SPENDER_OFFSET, AAVE)),
                _entry(USDC, APPROVE, 0, eqPin(SPENDER_OFFSET, UNISWAP))
            )
        );

        // Both spenders pass — the second entry is not dead weight.
        _check(_calls(_approveCall(AAVE, 1e6)));
        _check(_calls(_approveCall(UNISWAP, 1e6)));

        // A third spender fails, reported with the FIRST matching entry's expectation (Aave).
        _checkReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.ArgPinMismatch.selector,
                bytes32(uint256(uint160(ACCOMPLICE))),
                uint256(0),
                bytes32(uint256(uint160(AAVE)))
            ),
            _calls(_approveCall(ACCOMPLICE, 1e6))
        );
    }

    /// @dev Any-match applies to the VALUE cap too, not only to pins.
    function test_P07_SecondEntryMaxValue() public {
        _init(_two(_entry(PROTOCOL, SWAP_SELECTOR, 0, noPins()), _entry(PROTOCOL, SWAP_SELECTOR, 1 ether, noPins())));

        Multicall[] memory calls =
            _calls(Multicall({ to: PROTOCOL, value: 0, data: abi.encodeWithSelector(SWAP_SELECTOR, uint256(1), CEA) }));

        // 0.5 ether fails the first entry (cap 0) and passes the second.
        _checkWithValue(0.5 ether, calls);

        // 2 ether passes neither, and the FIRST entry's failure is what surfaces: cap 0.
        calls[0].value = 2 ether;
        _checkReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.InnerValueExceedsAllowance.selector, uint256(0), uint256(2 ether), uint256(0)
            ),
            calls
        );
    }

    /// @dev P-5's order, observable: the earlier check's error is the one reported.
    function test_P08_CheckOrderWithinEntry() public {
        AllowedCall[] memory rules = new AllowedCall[](1);
        rules[0] = AllowedCall({
            target: PROTOCOL,
            selector: SWAP_SELECTOR,
            beneficiaryOffset: BENEFICIARY_OFFSET,
            hasBeneficiary: true,
            maxValue: 0,
            pins: eqPin(4, AAVE) // argument 1 pinned, and it will not match
        });
        _init(rules);

        // Beneficiary wrong AND the pin wrong -> BENEFICIARY first.
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.BeneficiaryMismatch.selector, CEA, ACCOMPLICE),
            _calls(
                Multicall({
                    to: PROTOCOL, value: 0, data: abi.encodeWithSelector(SWAP_SELECTOR, uint256(1), ACCOMPLICE)
                })
            )
        );

        // Beneficiary right, value over AND the pin wrong -> VALUE before the pin.
        Multicall[] memory ok =
            _calls(Multicall({ to: PROTOCOL, value: 1, data: abi.encodeWithSelector(SWAP_SELECTOR, uint256(1), CEA) }));
        _checkReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.InnerValueExceedsAllowance.selector, uint256(0), uint256(1), uint256(0)
            ),
            ok
        );
    }

    /// @dev Pins are per inner call, and a later call's failure still stops the whole request.
    function test_P09_PinsOnSeveralInnerCalls() public {
        AllowedCall[] memory rules = new AllowedCall[](2);
        rules[0] = _entry(USDC, APPROVE, 0, eqPin(SPENDER_OFFSET, AAVE));
        rules[1] = _entry(AAVE, SUPPLY, 0, eqPin(4, USDC)); // the asset argument is pinned
        _init(rules);

        Multicall[] memory both = new Multicall[](2);
        both[0] = _approveCall(AAVE, 1000e6);

        // (a) second call names the wrong asset -> its pin fires.
        both[1] = Multicall({
            to: AAVE, value: 0, data: abi.encodeWithSelector(SUPPLY, ACCOMPLICE, uint256(1), CEA, uint16(0))
        });
        _checkReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.ArgPinMismatch.selector,
                bytes32(uint256(uint160(ACCOMPLICE))),
                uint256(0),
                bytes32(uint256(uint160(USDC)))
            ),
            both
        );

        // (b) both correct -> the request passes.
        both[1] =
            Multicall({ to: AAVE, value: 0, data: abi.encodeWithSelector(SUPPLY, USDC, uint256(1), CEA, uint16(0)) });
        _check(both);
    }

    // ═══════════════════════════ P10–P11 · grant guards ═══════════════════════════

    function test_P10_PinCountLimits() public {
        // 8 pins on one entry: the per-entry maximum, accepted.
        ArgPin[] memory eight = new ArgPin[](MAX_PINS);
        for (uint256 i; i < MAX_PINS; ++i) {
            eight[i] = ArgPin({ offset: uint16(4 + i * 32), op: PinOp.EQ, value: bytes32(i) });
        }
        _initAt(ConfigId.wrap(bytes32(uint256(0xE1))), _one(_entry(USDC, APPROVE, 0, eight)));

        // 9 on one entry: refused, per entry.
        ArgPin[] memory nine = new ArgPin[](MAX_PINS + 1);
        for (uint256 i; i < MAX_PINS + 1; ++i) {
            nine[i] = ArgPin({ offset: uint16(4 + i * 32), op: PinOp.EQ, value: bytes32(i) });
        }
        _initRevertsAt(
            ConfigId.wrap(bytes32(uint256(0xE2))),
            abi.encodeWithSelector(UniversalRulesPolicyErrors.TooManyPins.selector, MAX_PINS + 1),
            _one(_entry(USDC, APPROVE, 0, nine))
        );

        // 32 in aggregate (4 entries x 8): accepted. Each entry satisfies MAX_PINS.
        AllowedCall[] memory four = new AllowedCall[](4);
        for (uint256 e; e < 4; ++e) {
            four[e] = _entry(USDC, bytes4(uint32(0x1000 + e)), 0, eight);
        }
        _initAt(ConfigId.wrap(bytes32(uint256(0xE3))), four);

        // 33 in aggregate: refused by the AGGREGATE guard, which no per-entry check would catch.
        ArgPin[] memory oneMore = new ArgPin[](1);
        oneMore[0] = ArgPin({ offset: 4, op: PinOp.EQ, value: bytes32(0) });
        AllowedCall[] memory five = new AllowedCall[](5);
        for (uint256 e; e < 4; ++e) {
            five[e] = _entry(USDC, bytes4(uint32(0x2000 + e)), 0, eight);
        }
        five[4] = _entry(USDC, bytes4(uint32(0x2004)), 0, oneMore);
        _initRevertsAt(
            ConfigId.wrap(bytes32(uint256(0xE4))),
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.TooManyAllowedCallPins.selector, MAX_ALLOWED_CALL_PINS + 1
            ),
            five
        );
    }

    /**
     * @dev An `op` ordinal outside `PinOp` is refused by the ABI DECODER, before URP runs a line.
     *
     *      THE ONE PERMITTED BARE `vm.expectRevert()` in this file, and the justification is that the
     *      revert genuinely carries no data: solc's enum range check on a decoded value is a plain
     *      `revert(0, 0)`, not a named error, so there is nothing to assert but "it reverted".
     *      Grepped for a named form first — none exists, because no error is ever emitted here.
     *
     *      The property that matters is that it reverts RATHER THAN MIS-DECODING into `EQ` or `MAX`.
     */
    function test_P11_InvalidOpRefusedAtDecode() public {
        // The op ordinal is patched in the ENCODED bytes: Solidity's type system makes `PinOp(2)`
        // unrepresentable in source, so a valid envelope is built and the one byte is overwritten.
        AllowedCall[] memory rules = _one(_entry(USDC, APPROVE, 0, eqPin(SPENDER_OFFSET, AAVE)));
        bytes memory good = universalInitData(_config(rules));
        bytes memory bad = _patchFirstPinOp(good, 2);

        // Sanity: the only difference is the one op byte, so a failure below cannot be a mangled
        // envelope — it is the enum range check specifically.
        assertEq(bad.length, good.length, "patch must not resize the envelope");

        vm.prank(address(engine));
        // THE ONE PERMITTED BARE expectRevert IN THIS FILE. solc's enum range check on a decoded
        // value compiles to a plain `revert(0, 0)` and carries NO data at all, so there is no error
        // to name. Grepped for a named form first: none exists, and none can.
        vm.expectRevert();
        urp.initializeWithMultiplexer(ACCOUNT, CID, bad);
    }

    /**
     * @dev Overwrites the first `ArgPin.op` byte in an encoded universal envelope with `op`.
     *
     *      `op` is a `uint8` in a 32-byte ABI word, so it is the LAST byte of that word. The word is
     *      found by scanning for the only 32-byte-aligned word in the blob that equals 0 and is
     *      immediately followed by the pinned value — brittle in general, which is why the caller
     *      asserts the length is unchanged and the test's whole claim is only "it reverts".
     */
    function _patchFirstPinOp(bytes memory blob, uint8 op) internal view returns (bytes memory out) {
        out = bytes(blob); // copy
        bytes32 needle = bytes32(uint256(uint160(AAVE))); // the EQ pin's value word
        for (uint256 i = 32; i + 32 <= out.length; i += 32) {
            bytes32 w;
            bytes32 prev;
            assembly {
                w := mload(add(add(out, 0x20), i))
                prev := mload(add(add(out, 0x20), sub(i, 32)))
            }
            // the op word (0 = EQ) sits immediately before the value word
            if (w == needle && prev == bytes32(0)) {
                out[i - 1] = bytes1(op);
                return out;
            }
        }
        revert("pin op word not found");
    }

    // ═══════════════════════════ P12–P15 · round trip and shapes ═══════════════════════════

    function test_P12_PinsRoundTripThroughGetConfig() public {
        ArgPin[] memory pins = new ArgPin[](2);
        pins[0] = ArgPin({ offset: SPENDER_OFFSET, op: PinOp.EQ, value: bytes32(uint256(uint160(AAVE))) });
        pins[1] = ArgPin({ offset: AMOUNT_OFFSET, op: PinOp.MAX, value: bytes32(uint256(1000e6)) });
        _init(_two(_entry(USDC, APPROVE, 0, pins), _entry(PROTOCOL, SWAP_SELECTOR, 1 ether, noPins())));

        Config memory got = urp.getConfig(CID, ACCOUNT);

        assertEq(got.allowedCalls.length, 2, "entry count");
        assertEq(got.allowedCalls[0].pins.length, 2, "entry 0 pin count");
        assertEq(got.allowedCalls[0].pins[0].offset, SPENDER_OFFSET, "pin 0 offset");
        assertEq(uint8(got.allowedCalls[0].pins[0].op), uint8(PinOp.EQ), "pin 0 op");
        assertEq(got.allowedCalls[0].pins[0].value, bytes32(uint256(uint160(AAVE))), "pin 0 value");
        assertEq(got.allowedCalls[0].pins[1].offset, AMOUNT_OFFSET, "pin 1 offset");
        assertEq(uint8(got.allowedCalls[0].pins[1].op), uint8(PinOp.MAX), "pin 1 op");
        assertEq(got.allowedCalls[0].pins[1].value, bytes32(uint256(1000e6)), "pin 1 value");
        assertEq(got.allowedCalls[1].pins.length, 0, "entry 1 has no pins");
    }

    /// @dev The regression anchor: an unpinned entry behaves exactly as it did before the feature.
    function test_P13_EntryWithoutPinsUnchanged() public {
        AllowedCall[] memory rules = new AllowedCall[](1);
        rules[0] = AllowedCall({
            target: PROTOCOL,
            selector: SWAP_SELECTOR,
            beneficiaryOffset: BENEFICIARY_OFFSET,
            hasBeneficiary: true,
            maxValue: 1 ether,
            pins: noPins()
        });
        _init(rules);

        _check(
            _calls(Multicall({ to: PROTOCOL, value: 0, data: abi.encodeWithSelector(SWAP_SELECTOR, uint256(1), CEA) }))
        );

        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.BeneficiaryMismatch.selector, CEA, ACCOMPLICE),
            _calls(
                Multicall({
                    to: PROTOCOL, value: 0, data: abi.encodeWithSelector(SWAP_SELECTOR, uint256(1), ACCOMPLICE)
                })
            )
        );
    }

    /**
     * @dev EQ is FULL-WORD. An address argument with dirty high bytes fails against the clean
     *      address, deliberately: full-word equality also proves the ABI padding is clean.
     *
     *      CONTRAST, and it is intentional: the BENEFICIARY check reads only the low 160 bits
     *      (`_extractBeneficiary`), so the same dirty word would pass there. An EQ pin is therefore
     *      strictly stronger than a beneficiary pin. See Appendix A of the PRD.
     */
    function test_P14_EqIsFullWord() public {
        _init(_one(_entry(USDC, APPROVE, 0, eqPin(SPENDER_OFFSET, AAVE))));

        bytes32 dirty = bytes32(uint256(uint160(AAVE)) | (uint256(1) << 200));
        bytes memory data = abi.encodePacked(APPROVE, dirty, uint256(1000e6));

        _checkReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.ArgPinMismatch.selector, dirty, uint256(0), bytes32(uint256(uint160(AAVE)))
            ),
            _calls(Multicall({ to: USDC, value: 0, data: data }))
        );
    }

    /// @dev The Aave `supply` case from the PRD's attack table: asset and amount both pinned.
    function test_P15_SupplyAssetAndAmountPinned() public {
        ArgPin[] memory pins = new ArgPin[](2);
        pins[0] = ArgPin({ offset: 4, op: PinOp.EQ, value: bytes32(uint256(uint160(USDC))) });
        pins[1] = ArgPin({ offset: 36, op: PinOp.MAX, value: bytes32(uint256(500e6)) });
        _init(_one(_entry(AAVE, SUPPLY, 0, pins)));

        // wrong asset
        _checkReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.ArgPinMismatch.selector,
                bytes32(uint256(uint160(ACCOMPLICE))),
                uint256(0),
                bytes32(uint256(uint160(USDC)))
            ),
            _calls(
                Multicall({
                    to: AAVE, value: 0, data: abi.encodeWithSelector(SUPPLY, ACCOMPLICE, uint256(1), CEA, uint16(0))
                })
            )
        );

        // amount over the ceiling
        _checkReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.ArgPinAboveMax.selector, uint256(500e6 + 1), uint256(1), uint256(500e6)
            ),
            _calls(
                Multicall({
                    to: AAVE, value: 0, data: abi.encodeWithSelector(SUPPLY, USDC, uint256(500e6 + 1), CEA, uint16(0))
                })
            )
        );

        // correct
        _check(
            _calls(
                Multicall({
                    to: AAVE, value: 0, data: abi.encodeWithSelector(SUPPLY, USDC, uint256(500e6), CEA, uint16(0))
                })
            )
        );
    }

    // ═══════════════════════════ F01–F02 · fuzz ═══════════════════════════

    function testFuzz_F01_MaxPin(uint256 actual, uint256 ceiling) public {
        _init(_one(_entry(USDC, APPROVE, 0, maxPin(AMOUNT_OFFSET, ceiling))));

        Multicall[] memory calls = _calls(_approveCall(AAVE, actual));
        if (actual <= ceiling) {
            _check(calls);
        } else {
            _checkReverts(
                abi.encodeWithSelector(UniversalRulesPolicyErrors.ArgPinAboveMax.selector, actual, uint256(0), ceiling),
                calls
            );
        }
    }

    // ═══════════════════════════ N01–N02 · native MAX ═══════════════════════════

    /// @dev `stakeFor(address,uint256)` — beneficiary at 4, amount at 36.
    bytes4 internal constant STAKE_FOR = bytes4(keccak256("stakeFor(address,uint256)"));
    ConfigId internal constant NATIVE_CID = ConfigId.wrap(bytes32(uint256(0xA71BE)));

    function _nativeConfig(ArgPin[] memory pins) internal view returns (NativeConfig memory cfg) {
        cfg = NativeConfig({
            initialized: false,
            validUntil: VALID_UNTIL,
            target: PROTOCOL,
            selector: STAKE_FOR,
            maxValuePerCall: 0,
            maxValueTotal: 0,
            valueSpent: 0,
            amount: AmountRule({ enabled: false, offset: 0, maxPerCall: 0, maxTotal: 0 }),
            amountSpent: 0,
            maxCalls: 0,
            callsUsed: 0,
            pins: pins
        });
    }

    function _initNative(ArgPin[] memory pins) internal {
        vm.prank(address(engine));
        urp.initializeWithMultiplexer(ACCOUNT, NATIVE_CID, nativeInitData(_nativeConfig(pins)));
    }

    function _checkNative(bytes memory data) internal returns (uint256) {
        vm.prank(address(engine));
        return urp.checkAction(NATIVE_CID, ACCOUNT, PROTOCOL, 0, data);
    }

    function _checkNativeReverts(bytes memory err, bytes memory data) internal {
        vm.prank(address(engine));
        vm.expectRevert(err);
        urp.checkAction(NATIVE_CID, ACCOUNT, PROTOCOL, 0, data);
    }

    /// @dev N7 gains MAX. It bounds ONE call: `AmountRule` (N8) remains the only lifetime metering,
    ///      so a MAX pin is not a budget and must not be read as one.
    function test_N01_NativeMaxPin() public {
        _initNative(maxPin(36, 100e6));

        _checkNative(abi.encodeWithSelector(STAKE_FOR, CEA, uint256(100e6))); // == max passes
        _checkNativeReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.ArgPinAboveMax.selector, uint256(100e6 + 1), uint256(0), uint256(100e6)
            ),
            abi.encodeWithSelector(STAKE_FOR, CEA, uint256(100e6 + 1))
        );
    }

    /// @dev EQ and MAX side by side, each reported with its own error and its own index.
    function test_N02_NativeMixedEqAndMax() public {
        ArgPin[] memory pins = new ArgPin[](2);
        pins[0] = ArgPin({ offset: 4, op: PinOp.EQ, value: bytes32(uint256(uint160(CEA))) });
        pins[1] = ArgPin({ offset: 36, op: PinOp.MAX, value: bytes32(uint256(100e6)) });
        _initNative(pins);

        // both satisfied
        _checkNative(abi.encodeWithSelector(STAKE_FOR, CEA, uint256(50e6)));

        // the EQ pin fails, at index 0
        _checkNativeReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.ArgPinMismatch.selector,
                bytes32(uint256(uint160(ACCOMPLICE))),
                uint256(0),
                bytes32(uint256(uint160(CEA)))
            ),
            abi.encodeWithSelector(STAKE_FOR, ACCOMPLICE, uint256(50e6))
        );

        // the MAX pin fails, at index 1
        _checkNativeReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.ArgPinAboveMax.selector, uint256(100e6 + 1), uint256(1), uint256(100e6)
            ),
            abi.encodeWithSelector(STAKE_FOR, CEA, uint256(100e6 + 1))
        );
    }

    // ═══════════════════════════ G01 · gas ═══════════════════════════

    /**
     * @dev Marginal `checkAction` gas per EVM pin, measured as a DIFFERENCE between a 1-pin and an
     *      8-pin config so the fixed cost of the surrounding gauntlet cancels. Same shape as
     *      `test_gas_svm_S18CostPerListedAccount`.
     *
     *      The budget is a measured number plus headroom, per the repo's "gas assertions carry a
     *      number" rule — "within a sane budget" is not assertable.
     */
    function test_G01_GasPerEvmPin() public {
        ArgPin[] memory one = new ArgPin[](1);
        one[0] = ArgPin({ offset: 4, op: PinOp.EQ, value: bytes32(uint256(uint160(AAVE))) });

        ArgPin[] memory eight = new ArgPin[](8);
        for (uint256 i; i < 8; ++i) {
            // every pin satisfied, so all eight are actually evaluated
            eight[i] = ArgPin({ offset: 4, op: PinOp.EQ, value: bytes32(uint256(uint160(AAVE))) });
        }

        // warm-up on a third config, so the measurements below are not paying first-touch costs.
        ConfigId warm = ConfigId.wrap(bytes32(uint256(0xAB12)));
        vm.prank(address(engine));
        urp.initializeWithMultiplexer(ACCOUNT, warm, universalInitData(_config(_one(_entry(USDC, APPROVE, 0, one)))));
        vm.prank(address(engine));
        urp.checkAction(warm, ACCOUNT, GATEWAY, 0, _approveRequest(AAVE, 1e6));

        ConfigId c1 = ConfigId.wrap(bytes32(uint256(0xC1)));
        ConfigId c8 = ConfigId.wrap(bytes32(uint256(0xC8)));
        vm.prank(address(engine));
        urp.initializeWithMultiplexer(ACCOUNT, c1, universalInitData(_config(_one(_entry(USDC, APPROVE, 0, one)))));
        vm.prank(address(engine));
        urp.initializeWithMultiplexer(ACCOUNT, c8, universalInitData(_config(_one(_entry(USDC, APPROVE, 0, eight)))));

        bytes memory req = _approveRequest(AAVE, 1e6);

        vm.prank(address(engine));
        uint256 g0 = gasleft();
        urp.checkAction(c1, ACCOUNT, GATEWAY, 0, req);
        uint256 gas1 = g0 - gasleft();

        vm.prank(address(engine));
        g0 = gasleft();
        urp.checkAction(c8, ACCOUNT, GATEWAY, 0, req);
        uint256 gas8 = g0 - gasleft();

        uint256 perPin = (gas8 - gas1) / 7;
        emit log_named_uint("checkAction gas, 1 pin ", gas1);
        emit log_named_uint("checkAction gas, 8 pins", gas8);
        emit log_named_uint("marginal gas per pin   ", perPin);

        // MEASURED 753/pin on this toolchain (the pin's packed slot plus its value word, both
        // already warm in this config, plus the comparison). Budget is that +10%.
        assertLt(perPin, 830, "marginal cost per EVM pin regressed");
    }

    function _approveRequest(address spender, uint256 amount) internal view returns (bytes memory) {
        return outboundRequest(ASSET, 1 ether, 1 ether, ACCOUNT, _calls(_approveCall(spender, amount)));
    }

    function testFuzz_F02_EqPin(bytes32 actual, bytes32 expected) public {
        ArgPin[] memory pins = new ArgPin[](1);
        pins[0] = ArgPin({ offset: SPENDER_OFFSET, op: PinOp.EQ, value: expected });
        _init(_one(_entry(USDC, APPROVE, 0, pins)));

        bytes memory data = abi.encodePacked(APPROVE, actual, uint256(1));
        Multicall[] memory calls = _calls(Multicall({ to: USDC, value: 0, data: data }));

        if (actual == expected) {
            _check(calls);
        } else {
            _checkReverts(
                abi.encodeWithSelector(
                    UniversalRulesPolicyErrors.ArgPinMismatch.selector, actual, uint256(0), expected
                ),
                calls
            );
        }
    }
}
