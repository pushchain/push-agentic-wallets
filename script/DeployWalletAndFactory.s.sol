// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import { UniversalRulesPolicy } from "../src/policies/UniversalRulesPolicy.sol";
import { AGW } from "../src/AGW.sol";
import { AGWFactory } from "../src/AGWFactory.sol";

/**
 * @title  DeployWalletAndFactory — a new wallet implementation and factory over an EXISTING engine,
 *         URP and validator.
 *
 * @dev    For a change confined to `AGW` and `AGWFactory` (the wallet label, L-wallet-label PRD).
 *         The engine, URP (proxy, implementation, ProxyAdmin) and the validator are REUSED: none of
 *         them stores a factory or wallet-implementation address, and their state is keyed per
 *         wallet, so wallets from both factories share them without touching each other.
 *
 *         Deploys, in dependency order:
 *           1 · AGW implementation (wired to the reused engine, URP, validator and the gateway)
 *           2 · AGWFactory logic
 *           3 · ERC-1967 factory proxy, INITIALISED IN THE SAME TRANSACTION with the new
 *               implementation (no initialisation front-run window)
 *
 *         A NEW FACTORY PROXY, NOT AN UPGRADE: a factory's wallet implementation is written once at
 *         `initialize` and has no setter (T-09), so an upgraded old proxy would still deploy old wallets.
 *
 * Usage:
 *   forge script script/DeployWalletAndFactory.s.sol:DeployWalletAndFactory --rpc-url $RPC --broadcast
 * Required environment: CHAIN_ID, UNIVERSAL_GATEWAY_PC, FACTORY_ADMIN,
 *                       SESSION_ENGINE, URP, SESSION_VALIDATOR (the reused contracts)
 */
contract DeployWalletAndFactory is Script {
    string internal constant ENGINE_FORK_COMMIT = "7dc20e4";

    error MissingEnv(string name);
    error ChainIdMismatch(uint256 fromEnv, uint256 fromChain);
    error NoCode(string name, address at);
    error WiringMismatch(string what, address expected, address actual);

    struct Reused {
        address engine;
        address urp;
        address validator;
        address gatewayPC;
        address executorModule;
        address urpImplementation;
        address urpProxyAdmin;
    }

    function run() external {
        uint256 chainId = vm.envUint("CHAIN_ID");
        if (chainId != block.chainid) revert ChainIdMismatch(chainId, block.chainid);

        address admin = vm.envAddress("FACTORY_ADMIN");
        if (admin == address(0)) revert MissingEnv("FACTORY_ADMIN");

        Reused memory r = _reused();

        vm.startBroadcast();

        AGW walletImplementation = new AGW(r.engine, r.urp, r.validator, r.gatewayPC);
        AGWFactory factoryLogic = new AGWFactory();
        ERC1967Proxy factoryProxy = new ERC1967Proxy(
            address(factoryLogic), abi.encodeCall(AGWFactory.initialize, (admin, address(walletImplementation)))
        );

        vm.stopBroadcast();

        _assertDeployed(r, admin, walletImplementation, factoryLogic, factoryProxy);
        _writeRecord(chainId, r, address(walletImplementation), address(factoryLogic), address(factoryProxy));
    }

    /**
     * @dev Reads and checks the reused contracts BEFORE anything is broadcast: each has code, URP is
     *      wired to this engine and gateway, and URP derives this chain's identity (the Donut pin).
     */
    function _reused() internal view returns (Reused memory r) {
        r.engine = vm.envAddress("SESSION_ENGINE");
        r.urp = vm.envAddress("URP");
        r.validator = vm.envAddress("SESSION_VALIDATOR");
        r.gatewayPC = vm.envAddress("UNIVERSAL_GATEWAY_PC");

        if (r.engine.code.length == 0) revert NoCode("SESSION_ENGINE", r.engine);
        if (r.urp.code.length == 0) revert NoCode("URP", r.urp);
        if (r.validator.code.length == 0) revert NoCode("SESSION_VALIDATOR", r.validator);
        if (r.gatewayPC.code.length == 0) revert NoCode("UNIVERSAL_GATEWAY_PC", r.gatewayPC);

        UniversalRulesPolicy urp = UniversalRulesPolicy(r.urp);
        if (urp.SESSION_ENGINE() != r.engine) {
            revert WiringMismatch("URP.SESSION_ENGINE", r.engine, urp.SESSION_ENGINE());
        }
        if (urp.UNIVERSAL_GATEWAY_PC() != r.gatewayPC) {
            revert WiringMismatch("URP.UNIVERSAL_GATEWAY_PC", r.gatewayPC, urp.UNIVERSAL_GATEWAY_PC());
        }
        r.executorModule = urp.UNIVERSAL_EXECUTOR_MODULE();

        bytes32 expected = keccak256(bytes(string.concat("eip155:", vm.toString(block.chainid))));
        require(urp.pushChainHash() == expected, "URP derives a different chain identity");
        if (block.chainid == 42_101) {
            require(
                urp.pushChainHash() == 0x3d6bc1f1d3fb03065860265a8e93840b586e57075d956cd41b4319d040be87f9,
                "Donut chain hash does not match the pin"
            );
        }

        r.urpImplementation = address(uint160(uint256(vm.load(r.urp, ERC1967Utils.IMPLEMENTATION_SLOT))));
        r.urpProxyAdmin = address(uint160(uint256(vm.load(r.urp, ERC1967Utils.ADMIN_SLOT))));
    }

    /// @dev The new factory deploys the NEW wallet implementation, and that implementation is wired to
    ///      the reused contracts. Any mismatch aborts before the record is written.
    function _assertDeployed(
        Reused memory r,
        address admin,
        AGW walletImplementation,
        AGWFactory factoryLogic,
        ERC1967Proxy factoryProxy
    ) internal view {
        AGWFactory factory = AGWFactory(address(factoryProxy));
        address impl = factory.walletImplementation();
        if (impl != address(walletImplementation)) {
            revert WiringMismatch("factory.walletImplementation", address(walletImplementation), impl);
        }
        address logic = address(uint160(uint256(vm.load(address(factoryProxy), ERC1967Utils.IMPLEMENTATION_SLOT))));
        if (logic != address(factoryLogic)) revert WiringMismatch("factory logic slot", address(factoryLogic), logic);
        require(factory.hasRole(0x00, admin), "factory admin not set");

        if (walletImplementation.SESSION_ENGINE() != r.engine) {
            revert WiringMismatch("AGW.SESSION_ENGINE", r.engine, walletImplementation.SESSION_ENGINE());
        }
        if (walletImplementation.RULES_POLICY() != r.urp) {
            revert WiringMismatch("AGW.RULES_POLICY", r.urp, walletImplementation.RULES_POLICY());
        }
        if (walletImplementation.SESSION_VALIDATOR() != r.validator) {
            revert WiringMismatch("AGW.SESSION_VALIDATOR", r.validator, walletImplementation.SESSION_VALIDATOR());
        }
        if (walletImplementation.UNIVERSAL_GATEWAY_PC() != r.gatewayPC) {
            revert WiringMismatch("AGW.UNIVERSAL_GATEWAY_PC", r.gatewayPC, walletImplementation.UNIVERSAL_GATEWAY_PC());
        }
    }

    /// @dev Writes `deployments/<chainId>.json` with the SAME keys as `Deploy.s.sol`, so S-05 reads it
    ///      unchanged, plus `reused`, naming the contracts carried over from the previous deployment.
    function _writeRecord(
        uint256 chainId,
        Reused memory r,
        address walletImplementation,
        address factoryLogic,
        address factoryProxy
    ) internal {
        string memory obj = "record";
        vm.serializeUint(obj, "chainId", chainId);
        vm.serializeString(obj, "commit", _repoCommit());
        vm.serializeString(obj, "engineForkCommit", ENGINE_FORK_COMMIT);
        vm.serializeString(obj, "reused", "sessionEngine,sessionValidator,urp,urpImplementation,urpProxyAdmin");
        vm.serializeAddress(obj, "sessionEngine", r.engine);
        vm.serializeAddress(obj, "sessionValidator", r.validator);
        vm.serializeAddress(obj, "urp", r.urp);
        vm.serializeAddress(obj, "urpImplementation", r.urpImplementation);
        vm.serializeAddress(obj, "urpProxyAdmin", r.urpProxyAdmin);
        vm.serializeAddress(obj, "universalGateway", r.gatewayPC);
        vm.serializeAddress(obj, "universalExecutorModule", r.executorModule);
        vm.serializeAddress(obj, "walletImplementation", walletImplementation);
        vm.serializeAddress(obj, "factoryLogic", factoryLogic);
        string memory json = vm.serializeAddress(obj, "factoryProxy", factoryProxy);

        string memory path = string.concat("deployments/", vm.toString(chainId), ".json");
        vm.writeJson(json, path);

        console2.log("deployment record written to", path);
        console2.log("  factoryProxy         (NEW, user-facing)", factoryProxy);
        console2.log("  factoryLogic         (NEW)", factoryLogic);
        console2.log("  walletImplementation (NEW)", walletImplementation);
        console2.log("  urp                  (reused)", r.urp);
    }

    /// @dev The repo HEAD, as in `Deploy.s.sol` (prefixed so `vm.ffi` does not hex-decode it).
    function _repoCommit() internal returns (string memory) {
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] = "printf 'git:' && git rev-parse HEAD | tr -d '\n'";
        try vm.ffi(cmd) returns (bytes memory out) {
            return string(out);
        } catch {
            return "unknown";
        }
    }
}
