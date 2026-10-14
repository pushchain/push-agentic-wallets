// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../../test/Base.t.sol";
import { Vm } from "forge-std/Vm.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IAGW } from "../../src/interfaces/IAGW.sol";
import { AGW } from "../../src/AGW.sol";
import { AGWErrors } from "../../src/libraries/Errors.sol";
import { AllowedCall, ArgPin, Config, Multicall } from "../../src/libraries/Types.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";
import { AgentRequest } from "../lib/AgentRequest.sol";
import { Requests } from "../lib/Requests.sol";
import { RulesRead } from "../lib/RulesRead.sol";
import { MockUniversalGateway } from "../../test/mocks/MockUniversalGateway.sol";

contract MockPRC20b is ERC20 {
    constructor() ERC20("USDC.eth", "USDC.eth") { }

    /// @dev The origin chain, which URP reads at grant and compares against the chain the policy
    ///      envelope declares. The live `USDC.eth` on Donut answers exactly this.
    string public constant SOURCE_CHAIN_NAMESPACE = "eip155:11155111";

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title  AgentRequestLiveTest
 * @notice Pins what Act 2 does and reads back, against the REAL wallet, engine, validator and URP.
 *
 * @dev    WHY THIS EXISTS. `20_Stake` builds a request with the demo's own `Requests` and
 *         `AgentRequest` libraries, sends it from the agent, and then asserts three things it reads
 *         off the chain: the `RulesActionAuthorized` event, the token's spend counter, and — in the
 *         gauntlet — that any other sender is refused at the wallet. Each of those is only worth
 *         asserting if the script decodes it correctly, so each is pinned here first, where a
 *         wrong decode fails a unit test rather than an act.
 *
 *         Everything here runs against the contracts deployed by `BaseTest`; only the gateway and
 *         the PRC20 are mocks.
 */
contract AgentRequestLiveTest is BaseTest {
    MockPRC20b internal pUSDC;
    AGW internal agw;

    address internal owner = makeAddr("uea");
    address internal agent = makeAddr("agent");
    address internal impostor = makeAddr("impostor");

    address internal constant FAR_TARGET = address(0xDEAD02);
    address internal constant EXPECTED_CEA = address(0xCEA002);
    bytes4 internal constant STAKE_FOR = bytes4(keccak256("stakeFor(address,uint256)"));

    uint256 internal constant AMOUNT = 50e6;
    uint256 internal constant PC_VALUE = 0.05 ether;

    function setUp() public override {
        super.setUp();

        pUSDC = new MockPRC20b();
        MockUniversalGateway g = new MockUniversalGateway();
        vm.etch(GATEWAY, address(g).code);

        agw = newWallet(owner);
        pUSDC.mint(address(agw), 1000e6);
        vm.deal(address(agw), 10 ether);
    }

    function _initData() internal view returns (bytes memory) {
        AllowedCall[] memory allowed = new AllowedCall[](1);
        allowed[0] = AllowedCall({
            target: FAR_TARGET,
            selector: STAKE_FOR,
            beneficiaryOffset: 4,
            hasBeneficiary: true,
            maxValue: 0,
            pins: new ArgPin[](0)
        });

        return universalInitData(
            Config({
                initialized: false,
                validUntil: uint48(block.timestamp + 7 days),
                expectedCEA: EXPECTED_CEA,
                maxGasPerCall: 1 ether,
                assets: oneAsset(address(pUSDC), AMOUNT, type(uint256).max),
                allowedCalls: allowed
            })
        );
    }

    function _grant() internal returns (bytes32 rulesId) {
        vm.prank(owner);
        rulesId = agw.grantRules(canonicalSession(agentConfig(agent), _initData()));
    }

    /// @dev The request exactly as `AgentRequest.buildWithToken` assembles it, minus the ledger
    ///      and the live quote, which a unit test has no chain to read from.
    function _request(bytes32 rulesId) internal view returns (AgentRequest.Built memory b) {
        Multicall[] memory calls =
            Requests.singleCall(FAR_TARGET, abi.encodeWithSelector(STAKE_FOR, EXPECTED_CEA, AMOUNT));

        b.wallet = address(agw);
        b.rulesId = rulesId;
        b.mode = Requests.singleMode();
        b.amount = AMOUNT;
        b.pcValue = PC_VALUE;
        b.executionCalldata = Requests.execution(
            GATEWAY, PC_VALUE, Requests.outbound(address(pUSDC), AMOUNT, 0.01 ether, address(agw), calls)
        );
    }

    function _send(address from, AgentRequest.Built memory b) internal returns (bool ok, bytes memory ret) {
        vm.prank(from);
        (ok, ret) = b.wallet.call(AgentRequest.encodeSubmit(b));
    }

    /// @dev `Requests.outbound` must produce bytes URP accepts. If the struct mirror or the
    ///      multicall prefix were wrong, the request would die at a gate rather than execute — so a
    ///      successful run, sent by the agent, is itself the assertion that the encoding is right.
    function test_requestsLibraryProducesAnAcceptedOutbound() public {
        AgentRequest.Built memory b = _request(_grant());

        (bool ok,) = _send(agent, b);

        assertTrue(ok, "an outbound built by the demo lib must pass every gate when the agent sends it");
        assertEq(MockUniversalGateway(payable(GATEWAY)).callCount(), 1, "the gateway was called exactly once");
    }

    /**
     * @notice THE DECODE. Reads `RulesActionAuthorized` exactly as `20_Stake` does.
     * @dev    `rulesId` and `agent` are indexed (topics 1 and 2); `callsHash` is the single data
     *         word, and it is `keccak256(executionCalldata)`.
     */
    function test_authorizationEventNamesRulesAgentAndCalls() public {
        bytes32 rulesId = _grant();
        AgentRequest.Built memory b = _request(rulesId);

        vm.recordLogs();
        (bool ok,) = _send(agent, b);
        assertTrue(ok, "the agent's request must be accepted");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IAGW.RulesActionAuthorized.selector) {
                assertEq(logs[i].topics.length, 3, "signature + two indexed fields");
                assertEq(logs[i].topics[1], rulesId, "rulesId is indexed");
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(agent))), "agent is indexed");
                assertEq(logs[i].data.length, 32, "exactly one non-indexed word");
                assertEq(abi.decode(logs[i].data, (bytes32)), keccak256(b.executionCalldata), "callsHash = keccak(ecd)");
                return;
            }
        }
        revert("the wallet must emit RulesActionAuthorized");
    }

    /// @dev G6 and Act 4e: the same bytes from any other sender die at the wallet, unwrapped, with
    ///      the rules id and the caller in the error.
    function test_sameCallFromANonAgentIsRefusedAtTheWallet() public {
        bytes32 rulesId = _grant();
        AgentRequest.Built memory b = _request(rulesId);

        (bool ok, bytes memory ret) = _send(impostor, b);

        assertFalse(ok, "only the rules' agent may act");
        assertEq(
            ret, abi.encodeWithSelector(AGWErrors.CallerIsNotAgent.selector, rulesId, impostor), "CallerIsNotAgent"
        );
        assertEq(MockUniversalGateway(payable(GATEWAY)).callCount(), 0, "nothing reached the gateway");
    }

    /// @dev The per-asset counter `20_Stake`, `G5` and `Preflight` all read, through the demo's own
    ///      config-id derivation.
    function test_spendIsMeteredOnTheListedAsset() public {
        bytes32 rulesId = _grant();
        ConfigId id = RulesRead.universalConfigId(address(agw), rulesId);

        assertEq(urp.getConfig(id, address(agw)).assets[0].spent, 0, "nothing spent before the request");

        (bool ok,) = _send(agent, _request(rulesId));
        assertTrue(ok, "the agent's request must be accepted");

        Config memory cfg = urp.getConfig(id, address(agw));
        assertEq(cfg.assets[0].token, address(pUSDC), "the listed token");
        assertEq(cfg.assets[0].spent, AMOUNT, "spent moved by exactly the amount");
    }

    /// @dev The owner-interference counter must not move on an agent action. `20_Stake` asserts
    ///      this live; here it is pinned against the real wallet.
    function test_agentActionDoesNotMoveTheCheckpointCounter() public {
        bytes32 rulesId = _grant();
        uint64 before = agw.checkpointCount();

        (bool ok,) = _send(agent, _request(rulesId));
        assertTrue(ok, "the agent's request must be accepted");

        assertEq(agw.checkpointCount(), before, "agent actions never tick the checkpoint counter");
    }
}
