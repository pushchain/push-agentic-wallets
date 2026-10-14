// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { UniversalRulesPolicyErrors } from "./Errors.sol";
import { IPRC20Source } from "../interfaces/IPRC20Source.sol";
import { AssetCap, AssetCapState, MAX_ASSETS } from "./Types.sol";

/**
 * @title  RulesLib — the guards and helpers both universal rulebooks share.
 *
 * @notice INTERNAL library, so every function here is INLINED into each contract that calls it.
 *         There is no deployed `RulesLib` address and no `DELEGATECALL`: the bytecode is copied
 *         into `UniversalRulesPolicy` and into `SvmRulebook` independently.
 *
 * @dev    WHY THIS FILE EXISTS. The Solana rulebook moved into its own linked library
 *         (`SvmRulebook`) to free EIP-170 headroom in URP. The asset-list guards and the gate-5
 *         lookup are needed by BOTH rulebooks, so they had to live somewhere neither owns —
 *         otherwise one side would import the other purely for a helper, or the source would be
 *         duplicated and the two copies would drift.
 *
 *         THE COST IS ACCEPTED AND DELIBERATE (decision S-2). An internal library pays its bytes
 *         in every contract that uses it, so `_requireAssets` and friends appear in both runtimes.
 *         The alternative — an external library — would add a `DELEGATECALL` to the asset scan on
 *         every single request, which is the hot path. Bytes are the cheaper currency here.
 *
 *         THE TEETH (`requireAssetOnChain`) MAKE THE ONLY EXTERNAL CALL IN THIS FILE, and only on
 *         the GRANT path. See the long note on it: a `view` call compiles to STATICCALL, it runs
 *         inside the owner's own grant transaction, and it can never block a revocation or an
 *         execution. Nothing here is reachable from `checkAction` except `assetFor`, which makes
 *         no external call at all.
 */
library RulesLib {
    /**
     * @dev The asset-list guards, shared by both universal families: 1..MAX_ASSETS entries, no token
     *      twice, and THE TEETH for every entry. A zero token fails the teeth as `InvalidAsset(0)`.
     *      O(n^2) duplicate check at n <= 8.
     */
    function requireAssets(AssetCap[] memory assets, bytes32 chainHash) internal view {
        uint256 n = assets.length;
        if (n == 0 || n > MAX_ASSETS) revert UniversalRulesPolicyErrors.AssetListOutOfRange(n);
        for (uint256 i; i < n;) {
            address token = assets[i].token;
            for (uint256 j; j < i;) {
                if (assets[j].token == token) revert UniversalRulesPolicyErrors.DuplicateAsset(token);
                unchecked {
                    ++j;
                }
            }
            requireAssetOnChain(token, chainHash);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev THE TEETH, shared by both universal families. Reverts `InvalidAsset` for a codeless
     *      address, a reverting callee or a non-string answer, and `ChainMismatch` when the asset's
     *      own `SOURCE_CHAIN_NAMESPACE()` hash differs from the declared chain. See the long note
     *      in `UniversalRulesPolicy._initUniversal` for why this external call is safe at init and
     *      nowhere else.
     */
    function requireAssetOnChain(address asset, bytes32 chainHash) internal view {
        if (asset.code.length == 0) revert UniversalRulesPolicyErrors.InvalidAsset(asset);

        try IPRC20Source(asset).SOURCE_CHAIN_NAMESPACE() returns (string memory ns) {
            bytes32 assetChain = keccak256(bytes(ns));
            if (assetChain != chainHash) revert UniversalRulesPolicyErrors.ChainMismatch(chainHash, assetChain);
        } catch {
            revert UniversalRulesPolicyErrors.InvalidAsset(asset);
        }
    }

    /// @dev Wire asset caps into storage, element by element, every `spent` forced to zero. Shared by
    ///      both universal families. The caller deletes `dst` first, as for every other array.
    function storeAssets(AssetCapState[] storage dst, AssetCap[] memory src) internal {
        uint256 len = src.length;
        for (uint256 i; i < len;) {
            dst.push(
                AssetCapState({
                    token: src[i].token, maxPerCall: src[i].maxPerCall, maxTotal: src[i].maxTotal, spent: 0
                })
            );
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Gate 5: the entry for `token` in a listed-asset array, or `AssetNotAllowed`. A linear scan
     *      at n <= MAX_ASSETS, so up to eight cold reads on a miss. Makes no external call.
     */
    function assetFor(AssetCapState[] storage assets, address token) internal view returns (AssetCapState storage) {
        uint256 n = assets.length;
        for (uint256 i; i < n;) {
            AssetCapState storage a = assets[i];
            if (a.token == token) return a;
            unchecked {
                ++i;
            }
        }
        revert UniversalRulesPolicyErrors.AssetNotAllowed(token);
    }
}
