// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { UniversalOutboundTxRequest } from "../../src/libraries/Types.sol";

interface IPullableToken {
    function allowance(address owner, address spender) external view returns (uint256);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/**
 * @title  PullingGatewayMock
 * @notice OBSERVER, NEVER ORACLE. It reproduces only what the deployed `UniversalGatewayPC`
 *         (implementation `0x1e412939780f2b834DC42C7AC58d9f99888Da659`) does with the token: on the
 *         standard path, when `req.amount > 0`, it pulls exactly `req.amount` from `msg.sender`
 *         (deployed lines 206 and 448-451, `_burnPRC20` -> `transferFrom(msg.sender, this, amount)`).
 *         It burns nothing, takes no fee in the token (fees are native PC on the real gateway) and
 *         validates nothing else.
 *
 * @dev    The wallet's behaviour is under test: whether the allowance exists at the moment of the
 *         pull, and is exactly the amount. The mock records the allowance it sees on entry, so a
 *         wallet that approved too much, too little or not at all is visible.
 *
 *         Lives AT the wallet's `UNIVERSAL_GATEWAY_PC` through `vm.etch`, so storage starts zeroed
 *         and both switches start off.
 */
contract PullingGatewayMock {
    /// @dev Pull `req.amount - 1` instead of `req.amount`, leaving one unit of allowance behind.
    bool public pullShort;

    /// @dev Revert every call with `GatewayRejected`.
    bool public shouldRevert;

    uint256 public callCount;
    uint256 public lastAmount;
    uint256 public allowanceAtEntry;

    /// @dev Every `allowanceAtEntry`, in call order, for batch assertions.
    uint256[] internal _allowancesSeen;

    error GatewayRejected();
    error PullFailed();

    function setPullShort(bool v) external {
        pullShort = v;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function allowanceSeenAt(uint256 i) external view returns (uint256) {
        return _allowancesSeen[i];
    }

    /// @dev The real signature, so the wallet reaches a matching function rather than a fallback.
    function sendUniversalTxOutbound(UniversalOutboundTxRequest calldata req) external payable {
        if (shouldRevert) revert GatewayRejected();

        uint256 seen = IPullableToken(req.token).allowance(msg.sender, address(this));
        allowanceAtEntry = seen;
        _allowancesSeen.push(seen);
        lastAmount = req.amount;
        callCount++;

        if (req.amount > 0) {
            uint256 pull = pullShort ? req.amount - 1 : req.amount;
            if (!IPullableToken(req.token).transferFrom(msg.sender, address(this), pull)) revert PullFailed();
        }
    }

    receive() external payable { }
}
