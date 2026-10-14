# Push Agentic Wallet — deployed addresses (Donut)

**Generation `v6` (SDK review fixes)** · Chain ID `42101` · explorer [donut.push.network](https://donut.push.network) ·
full suite deployed in blocks `24229957`–`24229971` · commit `ffd567d` (branch `deploy-agw`) · `script/Deploy.s.sol` ·
`forge 1.5.1-stable`

v6 is a **fresh full deployment**: nine contracts, including the linked `SvmRulebook` library, at new addresses. Nothing
from v5 was upgraded in place. A new URP means a new wallet implementation, because the wallet fixes its policy at
construction, and the factory's implementation cannot change, so the factory is new too.

## The two addresses you need

|                                                  | Address                                                                                                                       |
| ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| **Factory**: deploy and look up wallets          | [`0xFBBEB6a365178fAaA81A9789a5f64b300c37e5bc`](https://donut.push.network/address/0xFBBEB6a365178fAaA81A9789a5f64b300c37e5bc) |
| **URP**: name this as every rule's action policy | [`0xBA32e7A1500cb34311a31127bcD40CA52C8CFd36`](https://donut.push.network/address/0xBA32e7A1500cb34311a31127bcD40CA52C8CFd36) |

Both are **proxies**. Point integrations at these, never at an implementation.

## Everything

| Contract                                             | Address                                                                                                                       | Size (B) | Verified |
| ---------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | -------: | :------: |
| `factoryProxy` (ERC-1967, UUPS)                      | [`0xFBBEB6a365178fAaA81A9789a5f64b300c37e5bc`](https://donut.push.network/address/0xFBBEB6a365178fAaA81A9789a5f64b300c37e5bc) |      141 |    ✅     |
| `factoryLogic` (`AGWFactory`)                        | [`0x64893c611920604a9247530673071D46ac9174c9`](https://donut.push.network/address/0x64893c611920604a9247530673071D46ac9174c9) |   14,313 |    ✅     |
| `walletImplementation` (`AGW`)                       | [`0x536D3EA48219ff743ac663C6c224920e9eB476A5`](https://donut.push.network/address/0x536D3EA48219ff743ac663C6c224920e9eB476A5) |   18,818 |    ✅     |
| `urp` (Transparent proxy)                            | [`0xBA32e7A1500cb34311a31127bcD40CA52C8CFd36`](https://donut.push.network/address/0xBA32e7A1500cb34311a31127bcD40CA52C8CFd36) |      830 |    ✅     |
| `urpImplementation` (`UniversalRulesPolicy`)         | [`0xa176b1424018D52711EDCb9d3D8757dc6e174463`](https://donut.push.network/address/0xa176b1424018D52711EDCb9d3D8757dc6e174463) |   18,538 |    ✅     |
| `svmRulebook` (`SvmRulebook`, linked library)        | [`0x15c3259490f0625C75b5a00731e4231b2B529c1E`](https://donut.push.network/address/0x15c3259490f0625C75b5a00731e4231b2B529c1E) |   10,612 |    ❌ see below |
| `urpProxyAdmin` (`ProxyAdmin`)                       | [`0x5abC6Ae78EfE01c0F3d6b67389f88952Bf31A805`](https://donut.push.network/address/0x5abC6Ae78EfE01c0F3d6b67389f88952Bf31A805) |      926 |    ✅     |
| `sessionValidator` (`AgentValidator`)                | [`0xBf08d8335c1cE41a577DB70666816027814737dD`](https://donut.push.network/address/0xBf08d8335c1cE41a577DB70666816027814737dD) |      806 |    ✅     |
| `sessionEngine` (`SmartSession`, fork `7dc20e4`)     | [`0xf63DC0628fe1B25049FE3E3a3585Ef051CB98c1d`](https://donut.push.network/address/0xf63DC0628fe1B25049FE3E3a3585Ef051CB98c1d) |   22,581 |    ✅     |

**Eight of nine are verified** on Blockscout. `urpImplementation` was verified with
`--libraries src/policies/SvmRulebook.sol:SvmRulebook:0x15c3259490f0625C75b5a00731e4231b2B529c1E`, which proves
that this is the library URP calls.

**`svmRulebook` is not verified.** Forge deploys linked libraries through the CREATE2 deployer
(`0x4e59…956C`). Donut's Blockscout does not index contracts created inside another call, so it reports this address as
"not a smart contract" and refuses verification. The code is on chain: `cast code` returns all 10,612 bytes. Keep
`urpProxyAdmin`: without it URP can never be upgraded.

Check the wiring yourself:

- `cast call <factoryProxy> 'walletImplementation()(address)'` returns the `walletImplementation` above.
- That implementation's `SESSION_ENGINE()`, `RULES_POLICY()`, `SESSION_VALIDATOR()` and `UNIVERSAL_GATEWAY_PC()`
  return the engine, URP, validator and gateway in this file.
- `cast call <urp> 'SESSION_ENGINE()(address)'` returns the same engine.

All of these were checked after deployment.

### Push core contracts this deployment points at (not deployed by this repo)

|                             | Address                                                                                                                      |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `UniversalGatewayPC`        | `0x00000000000000000000000000000000000000C1` (implementation `0x1e41…a659`, 8-field outbound request, selector `0x77b86bec`) |
| `UniversalCore`             | `0x00000000000000000000000000000000000000C0`                                                                                 |
| `UEAFactory`                | `0x00000000000000000000000000000000000000eA`                                                                                 |
| `UNIVERSAL_EXECUTOR_MODULE` | `0x14191Ea54B4c176fCf86f51b0FAc7CB1E71Df7d7` (the address core's UniversalCore and PRC20s use; an account with no code)      |

## What changed from v5

|                            | v5                                                       | v6                                                                                                                                       |
| -------------------------- | -------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Every address              | see [Previous generations](#previous-generations)        | **new**, including the engine and validator (their bytecode is unchanged)                                                               |
| Token approval for outbound | owner or agent had to `approve(gateway, amount)` first   | **none**: on both doors the wallet approves the gateway for exactly the request amount, makes the call, then clears any leftover allowance |
| Create a wallet with rules | `deployWallet` then `grantRules`: two transactions        | **`createWallet(label, rules)`**, or the signed **`createWalletWithSig(intent, sig, label, rules)`** (`0x0a8f332b`): up to 8 rules in one transaction |
| EVM allow-list entry       | `(target, selector, beneficiaryOffset, hasBeneficiary, maxValue)` | **adds `ArgPin[] pins`** (`EQ` / `MAX` on static arguments, up to 32). An argument check passes if **any** matching entry passes in full |
| Native `maxCalls`          | `0` = unlimited                                          | **`0` is refused** (`ZeroMaxCalls`); unlimited is `type(uint32).max`                                                                    |
| Solana `maxAccounts`       | `0` = any                                                | **`1`–`64` exact, `255` = any**; `0` and `65`–`254` refused (`SvmMaxAccountsOutOfRange`)                                                  |
| URP implementation         | 24,326 B, Solana rulebook inside                         | **18,538 B**; the Solana rulebook is the linked library `svmRulebook`, with no behaviour change                                          |
| `OwnerIntent` signatures   | domain `verifyingContract` = `0x8137…Ccc5`               | domain `verifyingContract` = **`0xFBBE…e5bc`**: intents must be signed for the new factory                                              |
| Wallet label               | stored; `label()`, `setLabel(string)`                     | **unchanged**                                                                                                                           |

## How to grant a rule (current encoding)

Policy `initData` is `abi.encode(uint16 version, string chainNamespace, bytes body)`, with `version = 1`.

Cross-chain body (EVM destination):

```solidity
enum PinOp { EQ, MAX }
struct ArgPin { uint16 offset; PinOp op; bytes32 value; }          // offset includes the selector: 4 = first argument
struct AssetCap { address token; uint256 maxPerCall; uint256 maxTotal; }   // token = PRC20 on Push
struct AllowedCall {
    address target; bytes4 selector; uint16 beneficiaryOffset; bool hasBeneficiary; uint256 maxValue; ArgPin[] pins;
}
struct UniversalTerms {
    uint48 validUntil; address expectedCEA; AssetCap[] assets; uint256 maxGasPerCall; AllowedCall[] allowedCalls;
}
// ABI tuple:
// (uint48,address,(address,uint256,uint256)[],uint256,(address,bytes4,uint16,bool,uint256,(uint16,uint8,bytes32)[])[])
```

Push-side body (native):

```solidity
struct AmountRule { bool enabled; uint16 offset; uint256 maxPerCall; uint256 maxTotal; }
struct NativeTerms {
    uint48 validUntil; address target; bytes4 selector; uint256 maxValuePerCall; uint256 maxValueTotal;
    AmountRule amount; uint32 maxCalls; ArgPin[] pins;           // maxCalls: 0 refused, type(uint32).max = unlimited
}
// ABI tuple: (uint48,address,bytes4,uint256,uint256,(bool,uint16,uint256,uint256),uint32,(uint16,uint8,bytes32)[])
```

Limits: in token and value caps, `type(uint256).max` means unlimited and `0` means nothing.

```
cast call 0xBA32e7A1500cb34311a31127bcD40CA52C8CFd36 'pushChainHash()(bytes32)' --rpc-url <donut>
# -> 0x3d6bc1f1d3fb03065860265a8e93840b586e57075d956cd41b4319d040be87f9 == keccak256("eip155:42101")
```

Full design notes: `docs/1_AGW.md`, `docs/2_UniversalRulesPolicy.md`, `docs/multi-asset-review.md`.

## Admin

| Authority                                       | Holder                                                    | How to change it                                                                                                      |
| ----------------------------------------------- | --------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Factory `DEFAULT_ADMIN_ROLE` (factory upgrades) | deployer EOA `0xa89523351BE1e2De64937AA9AF61Ae06eAd199C7` | `beginDefaultAdminTransfer(new)`, then the new admin calls `acceptDefaultAdminTransfer()` after the **48-hour** delay |
| URP `ProxyAdmin` owner (URP upgrades)           | deployer EOA `0xa89523351BE1e2De64937AA9AF61Ae06eAd199C7` | `transferOwnership(new)` on `0x5abC…A805`, immediate                                                                  |
| Factory `PAUSER_ROLE` / `OPERATOR_ROLE`         | **nobody yet**                                            | the default admin must `grantRole` before the factory can be paused or unpaused                                       |

These are different powers, and for production they belong in different multisigs: the factory admin can strand
counterfactually funded addresses; the URP ProxyAdmin owner can rewrite every gate in the security boundary.

## Previous generations

Earlier generations stay on chain, and their wallets keep working against their own URP and engine. They do **not** get
v6 behaviour. Deploy new wallets only through the v6 factory.

### v5 (wallet label) — retired

Book: `deployments/address-book-v5/`. Blocks `23989983`–`23989987`, commit `2e61e13`. v5 deployed a new factory and
wallet implementation over the v4 engine, URP and validator.

| Contract                                           | Address                                      |
| -------------------------------------------------- | -------------------------------------------- |
| `factoryProxy`                                     | `0x8137F96A50EBF41d904e3678c84c391a0D1BCcc5` |
| `factoryLogic` (`AGWFactory`)                      | `0xe549d3D4e85cB16F687448D7acA21D9d13A7cD0f` |
| `walletImplementation` (`AGW`)                     | `0x4D459Da499C14548aa16c46c57fD92880A88EBb4` |
| `urp` (from v4)                                    | `0x603E7f0aF6e1aAFf46DDfb28b1e99364f8BC59af` |
| `urpImplementation` (`UniversalRulesPolicy` 3.1.0, from v4) | `0xA2391eee4C9EA1B32AEB3A460B77296EA709F02F` |
| `urpProxyAdmin` (from v4)                          | `0x0b7a31ec85117892aEA90AA5cB6514e2F97c2295` |
| `sessionValidator` (from v4)                       | `0x068EE2388475A98EE1f5a434C58bFF3444fffFe6` |
| `sessionEngine` (from v4)                          | `0x165A5E6782f39D30B38c7D97e1303e4CB2aD102a` |

### Older

- **`v4`** (factory `0xaF88D0FD947afAe7bBb8F34e8417DCfc165e1aaF`, wallet implementation
  `0x96D69ec7e6cDdaD414e656B5c9DCA24587DF713c`; shared the URP and engine above with v5). Its wallets have no
  `label()` / `setLabel`.
- **`v3.2`** (factory `0x2578041963f692f8b51A137A1c7ddc0c84a8226A`, URP `0xeAd99E254ACD64219d057400cdC2A2390bC74372`).
  Its wallets and rules do not carry over; owners withdraw through the owner door.

The v6 and v5 books are kept in `deployments/`. Earlier books are in git history.
