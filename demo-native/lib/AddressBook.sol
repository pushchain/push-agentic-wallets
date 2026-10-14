// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { VmSafe } from "forge-std/Vm.sol";

/**
 * @title  AddressBook
 * @notice Resolves every address the native demo uses, so that no script carries a hardcoded one.
 *
 * @dev    THE ONE RULE: this library never returns `address(0)`. A key that is absent, or present
 *         and zero, reverts `MissingAddress(file, name)` naming what is missing. A demo that
 *         proceeds with a zero address fails later, in front of an audience, with nothing on screen
 *         explaining why.
 *
 *         TWO FILES, TWO SHAPES, read rather than rewritten:
 *
 *           · NESTED — `deployments/address-book-v6/push_agw_contracts.json` holds our own
 *                      deployment under `.contracts.<name>.address`, beside sizes, tx hashes and
 *                      notes. It is the permanent record of what we shipped and is not reshaped
 *                      to suit a reader, and never copied into a demo file.
 *           · FLAT   — `demo-native/config/native_demo.json` is this demo's own two fixtures, a
 *                      `<name>: <address>` map.
 *
 *         THERE IS NO `sepolia()` AND NO `donut()` RESOLVER. This demo has no second chain and
 *         never calls the gateway; a script that needs either address is a bug, and the absence
 *         of the resolver makes it a compile error. Wiring the wallet depends on is read from
 *         the wallet itself (`SESSION_ENGINE()`, `RULES_POLICY()`, `UNIVERSAL_GATEWAY_PC()`).
 */
library AddressBook {
    VmSafe private constant vm = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev This demo's own fixtures (`DemoUSDC`, `StakeDummy`).
    string internal constant DIR = "demo-native/config/";

    /// @dev OUR OWN contracts, from the current deployment's address book. The validator's
    ///      address is an input to every rules id, so every script reads the same book.
    string internal constant OURS_DIR = "deployments/address-book-v6/";

    /// @dev The named failure this library exists to produce. Names the file and the key.
    error MissingAddress(string file, string name);

    // ─────────────────────────────── Push Chain Donut ───────────────────────────────

    /**
     * @notice Resolve one of the contracts this repo deployed on Donut.
     * @param  name Key under `.contracts` — e.g. "factoryProxy", "urp", "sessionValidator",
     *              "sessionEngine".
     * @return The address. Never zero.
     */
    function ours(string memory name) internal view returns (address) {
        return _nested("push_agw_contracts.json", name);
    }

    /**
     * @notice Resolve a contract this demo itself deployed — `DemoUSDC` or `StakeDummy`.
     *
     * @dev    A missing or zero key fails with a named `MissingAddress` rather than letting a
     *         script proceed against `address(0)`.
     *
     * @param  name "DemoUSDC" or "StakeDummy".
     * @return The address. Never zero.
     */
    function native(string memory name) internal view returns (address) {
        return _flat(DIR, "native_demo.json", name);
    }

    // ───────────────────────────────── resolvers ─────────────────────────────────

    /// @dev Flat `<name>: <address>` map.
    function _flat(string memory dir, string memory file, string memory name) private view returns (address) {
        string memory json = vm.readFile(string.concat(dir, file));
        return _require(json, string.concat(".", name), file, name);
    }

    /// @dev Nested record: the address sits at `.contracts.<name>.address`, beside metadata.
    function _nested(string memory file, string memory name) private view returns (address) {
        string memory json = vm.readFile(string.concat(OURS_DIR, file));
        return _require(json, string.concat(".contracts.", name, ".address"), file, name);
    }

    /**
     * @dev Read one JSON path and enforce the never-zero rule.
     *
     *      Absence and zero collapse to the same error on purpose. A caller can do nothing
     *      different about them — both mean "this address is not available" — and separate errors
     *      would suggest a distinction that does not exist.
     */
    function _require(string memory json, string memory path, string memory file, string memory name)
        private
        view
        returns (address)
    {
        if (!vm.keyExistsJson(json, path)) revert MissingAddress(file, name);
        address a = vm.parseJsonAddress(json, path);
        if (a == address(0)) revert MissingAddress(file, name);
        return a;
    }
}
