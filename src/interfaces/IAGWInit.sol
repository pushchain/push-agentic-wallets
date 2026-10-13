// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title  IAGWInit — the ONE function the factory compiles against.
 * @notice The factory deliberately does NOT import `AGW`. Its obligation ends at
 *         "call this once, bubble its revert"; everything inside is the wallet's own concern.
 *         Importing the wallet would couple the factory's build to the wallet's whole dependency
 *         graph for a single zero-argument call.
 */
interface IAGWInit {
    /// @notice One-shot. Callable only by the factory recorded in the clone's immutable args.
    /// @dev    Stores `label` when it is non-empty (empty means the default `AGW <index + 1>`), then
    ///         installs the default permission engine with empty install data. If it reverts — an
    ///         over-long label included — the factory's whole deployment reverts with it, so a wallet
    ///         can never exist un-initialised.
    /// @param  label  The owner's label for the wallet; empty for the default.
    function initializeAccount(string calldata label) external;
}
