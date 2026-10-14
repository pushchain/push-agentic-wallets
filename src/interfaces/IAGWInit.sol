// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Session } from "smartsessions/DataTypes.sol";

/**
 * @title  IAGWInit — the ONE function the factory compiles against.
 * @notice The factory deliberately does NOT import `AGW`. Its obligation ends at
 *         "call this once, bubble its revert"; everything inside is the wallet's own concern.
 *         Importing the wallet would couple the factory's build to the wallet's whole dependency
 *         graph for one call; the factory passes the deploy-time label and the owner-authorised
 *         initial rules.
 */
interface IAGWInit {
    /// @notice One-shot. Callable only by the factory recorded in the clone's immutable args.
    /// @dev    Stores `label` when it is non-empty (empty means the default `AGW <index + 1>`), then
    ///         installs the default permission engine with empty install data, then grants each of
    ///         `rules` in order through the same path `grantRules` uses. If it reverts — an over-long
    ///         label or a refused rule included — the factory's whole deployment reverts with it, so a
    ///         wallet can never exist un-initialised or with only some of its rules.
    /// @param  label     The owner's label for the wallet; empty for the default.
    /// @param  rules     The owner-authorised initial rules; empty for none.
    /// @return rulesIds  The engine's id for each granted rule, in input order.
    function initializeAccount(string calldata label, Session[] calldata rules)
        external
        returns (bytes32[] memory rulesIds);
}
