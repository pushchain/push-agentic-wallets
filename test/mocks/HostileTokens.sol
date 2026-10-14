// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title  Hostile tokens for the gateway auto-approve suite (`33_gatewayAutoApprove`).
 * @notice OBSERVERS, NEVER ORACLES. Each misbehaves in exactly one way on the calls the wallet makes
 *         (`approve`, `allowance`); the property under test is that the wallet's best-effort helpers
 *         never turn that misbehaviour into a wallet revert.
 *
 * @dev    Every token answers `SOURCE_CHAIN_NAMESPACE()` like `MockPRC20`, so it can be listed in a
 *         rules set where a test needs that, and carries a standard `transferFrom` so a pulling
 *         gateway can decide the outcome.
 */
abstract contract HostileTokenBase {
    // forge-lint: disable-next-line(mixed-case-variable)
    string public SOURCE_CHAIN_NAMESPACE = "eip155:11155111"; // the PRC20 view's exact name, which URP calls

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) internal _allowance;

    error InsufficientAllowance();
    error InsufficientBalance();

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (_allowance[from][msg.sender] < amount) revert InsufficientAllowance();
        if (balanceOf[from] < amount) revert InsufficientBalance();
        _allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev `approve` always reverts.
contract RevertingApproveToken is HostileTokenBase {
    error ApproveRefused();

    function approve(address, uint256) external pure returns (bool) {
        revert ApproveRefused();
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowance[owner][spender];
    }
}

/// @dev `approve` returns `false` and changes nothing.
contract FalseApproveToken is HostileTokenBase {
    function approve(address, uint256) external pure returns (bool) {
        return false;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowance[owner][spender];
    }
}

/**
 * @dev `approve` and `allowance` both return `BOMB_SIZE` bytes (1 MiB). `allowance`'s first word is 1,
 *      so the wallet's clear step sees a non-zero remainder and calls `approve` a second time: both
 *      bombing paths are exercised in one outbound. A caller that copied the return data into its own
 *      memory would pay the quadratic expansion again, on top of the token's own.
 */
contract ReturnBombToken is HostileTokenBase {
    uint256 internal constant BOMB_SIZE = 1 << 20;

    function approve(address, uint256) external pure returns (bool) {
        assembly {
            mstore(0, 1)
            return(0, BOMB_SIZE)
        }
    }

    function allowance(address, address) external pure returns (uint256) {
        assembly {
            mstore(0, 1)
            return(0, BOMB_SIZE)
        }
    }
}

/**
 * @dev `approve` re-enters the wallet that called it, once through each of `execute` and
 *      `executeAsAgent`, records whether each re-entry succeeded and the selector it reverted with,
 *      then sets the allowance normally.
 */
contract ReentrantApproveToken is HostileTokenBase {
    bool public reentered;
    bytes4 public executeRevert;
    bytes4 public agentRevert;
    uint256 public approveCalls;

    bytes32 internal constant SINGLE_MODE = bytes32(0);

    function approve(address spender, uint256 amount) external returns (bool) {
        approveCalls++;
        bytes memory inner = abi.encodePacked(address(this), uint256(0), bytes(""));

        (bool ok1, bytes memory r1) =
            msg.sender.call(abi.encodeWithSignature("execute(bytes32,bytes)", SINGLE_MODE, inner));
        (bool ok2, bytes memory r2) = msg.sender
            .call(abi.encodeWithSignature("executeAsAgent(bytes32,bytes32,bytes)", bytes32(0), SINGLE_MODE, inner));
        reentered = ok1 || ok2;
        // forge-lint: disable-next-line(unsafe-typecast)
        executeRevert = bytes4(r1); // the revert selector; truncation intended
        // forge-lint: disable-next-line(unsafe-typecast)
        agentRevert = bytes4(r2); // the revert selector; truncation intended

        _allowance[msg.sender][spender] = amount;
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowance[owner][spender];
    }
}
