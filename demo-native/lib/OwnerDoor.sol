// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IAGW } from "../../src/interfaces/IAGW.sol";
import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";
import { NativeRequest } from "./NativeRequest.sol";

/**
 * @title  OwnerDoor
 * @notice Bob's half: one call through `execute`, encoded the one way the wallet accepts.
 *
 * @dev    DECLARED ONCE BECAUSE FOUR SCRIPTS USE IT — the approval (1c), the withdrawal (4c), and
 *         Act 4f's throwaway funding. Each would otherwise re-encode the same three layers, and an
 *         encoding mistake in one of them would look like a permission failure.
 *
 *         THE OWNER DOOR CONSULTS EXACTLY TWO THINGS: the immutable-args owner and the calldata.
 *         No module, policy, engine state or flag is read there — it must succeed with the engine
 *         uninstalled and a hostile validator installed. That is why Bob can always act, instantly,
 *         no matter what any rules set says, and it is the property Act 4c demonstrates.
 */
library OwnerDoor {
    /**
     * @notice Have the wallet call `target` with `data`, carrying no value.
     * @dev    Broadcast this from the OWNER's key; `execute` is owner-only. `execute(bytes32,bytes)`
     *         is a frozen signature the engine depends on. Every call through it records one
     *         checkpoint on the wallet.
     */
    function call(address wallet, address target, bytes memory data) internal {
        IAGW(wallet).execute(NativeRequest.singleMode(), ExecutionLib.encodeSingle(target, 0, data));
    }
}
