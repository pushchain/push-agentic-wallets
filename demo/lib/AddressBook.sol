// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { VmSafe } from "forge-std/Vm.sol";

/**
 * @title  AddressBook
 * @notice Resolves every address the demo uses from two places, so that no script ever carries a
 *         hardcoded address: our own contracts from `deployments/address-book-v6/`, and Push core
 *         and Sepolia infrastructure from the demo-owned files in `demo/config/`.
 *
 * @dev    THE ONE RULE: this library never returns `address(0)`. A key that is absent, or present
 *         and zero, reverts `MissingAddress(chain, name)` naming what is missing. A demo that
 *         proceeds with a zero address fails minutes later on the far chain, in front of an
 *         audience, with nothing on screen explaining why — which is the failure mode the whole
 *         no-hardcoded-addresses rule exists to prevent.
 *
 *         TWO FILE SHAPES, TWO RESOLVERS. The files this reads were written for different purposes
 *         and are deliberately not unified:
 *
 *           · NESTED  — `push_agw_contracts.json` holds our own deployment under
 *                       `.contracts.<name>.address`, alongside sizes, tx hashes and notes. It is
 *                       the permanent record of what we shipped and is not reshaped to suit a
 *                       reader.
 *           · FLAT    — `sepolia.json` and `donut_push_core.json` are `<name>: <address>` maps of
 *                       infrastructure this repo does not deploy.
 *
 *         Both are read here rather than rewritten. If a key is in neither, that is a MissingAddress
 *         for a human to fill, not a file for a script to restructure.
 */
library AddressBook {
    VmSafe private constant vm = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Push core and Sepolia infrastructure, which this repo does not deploy. The files are
    ///      owned by the demo; `sepolia.json` carries the `CEAFactory` the Vault actually deploys
    ///      through, with the stale one recorded as deprecated.
    string internal constant DIR = "demo/config/";

    /**
     * @dev OUR OWN contracts, from the current deployment's address book.
     *
     *      READ IN PLACE, NEVER COPIED INTO A DEMO FILE. A stale duplicate is exactly how the
     *      wrong-CEAFactory bug happened: an address that resolves, has code, and is simply not
     *      the one in use. The validator's address is an input to every rules id, so a validator
     *      from one deployment mixed with an engine from another derives ids that address an
     *      empty config.
     */
    string internal constant OURS_DIR = "deployments/address-book-v6/";

    /// @dev The named failure this library exists to produce. Names the file and the key.
    error MissingAddress(string chain, string name);

    // ─────────────────────────────── Push Chain Donut ───────────────────────────────

    /**
     * @notice Resolve one of the contracts this repo deployed on Donut.
     * @param  name Key under `.contracts` — e.g. "factoryProxy", "urp", "sessionValidator".
     * @return The address. Never zero.
     */
    function ours(string memory name) internal view returns (address) {
        return _nested("push_agw_contracts.json", name);
    }

    /**
     * @notice Resolve Push core infrastructure or a PRC20 on Donut.
     * @param  name Key — e.g. "UniversalGatewayPC", "UniversalCore", "UEAFactory", "PRC20_USDC",
     *              "PRC20_PETH".
     * @return The address. Never zero.
     */
    function donut(string memory name) internal view returns (address) {
        return _flat("donut_push_core.json", name);
    }

    // ───────────────────────────────── Sepolia ─────────────────────────────────

    /**
     * @notice Resolve a contract on Ethereum Sepolia.
     * @param  name Key — e.g. "UniversalGateway", "Vault", "CEAFactory", "USDC", "StakeDummy".
     * @return The address. Never zero — an unwritten "StakeDummy" placeholder reverts.
     */
    function sepolia(string memory name) internal view returns (address) {
        return _flat("sepolia.json", name);
    }

    // ───────────────────────────────── resolvers ─────────────────────────────────

    /**
     * @dev Flat `<name>: <address>` map.
     * @param file Filename under `DIR`.
     * @param name Top-level key.
     */
    function _flat(string memory file, string memory name) private view returns (address) {
        string memory json = vm.readFile(string.concat(DIR, file));
        return _require(json, string.concat(".", name), file, name);
    }

    /**
     * @dev Nested record: the address sits at `.contracts.<name>.address`, beside metadata.
     *      Reads from `OURS_DIR`.
     * @param file Filename under `OURS_DIR`.
     * @param name Key under `.contracts`.
     */
    function _nested(string memory file, string memory name) private view returns (address) {
        string memory json = vm.readFile(string.concat(OURS_DIR, file));
        return _require(json, string.concat(".contracts.", name, ".address"), file, name);
    }

    /**
     * @dev Read one JSON path and enforce the never-zero rule.
     *
     *      Absence and zero collapse to the same error on purpose. A caller can do nothing
     *      different about them — both mean "this address is not available" — and giving them
     *      separate errors would suggest a distinction that does not exist.
     *
     * @param json Parsed file contents.
     * @param path JSON path to read.
     * @param file Filename, for the error message.
     * @param name Key, for the error message.
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
