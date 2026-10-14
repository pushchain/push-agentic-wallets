# AGW for the SDK — owner side

What the SDK needs to create agentic wallets, grant and revoke rules, act as the owner, and read state, against the
**v6 deployment on Donut**. Owner side only: the agent side (`executeAsAgent`, building outbound requests) is out of
scope here.

Everything below is taken from the deployed contracts (commit `ffd567d`). ABIs: use the verified contracts on
[donut.push.network](https://donut.push.network), or the build artifacts in this repo (`out/<Contract>.sol/<Contract>.json`).
Full address book: [`docs/addresses/donut.md`](addresses/donut.md).

**What changed from v5:**
- **Every address is new** (factory, wallet implementation, URP, SmartSession, AgentValidator). The factory
  `0xFBBEB6a365178fAaA81A9789a5f64b300c37e5bc` is also the EIP-712 `verifyingContract`, so every `OwnerIntent` must be
  signed for the new address (§7).
- **No approve step** before an outbound: the wallet approves the gateway for exactly the request amount and clears it.
- **`createWallet` / `createWalletWithSig`** deploy a wallet and grant up to 8 rules in one transaction.
- **Rule encoding changed:** EVM allow-list entries carry `ArgPin[] pins`; native `maxCalls = 0` is refused (unlimited is
  `type(uint32).max`); Solana `maxAccounts` is `1`–`64` or `255` for any.
- Wallets from the v5 factory (`0x8137…Ccc5`) still work against the old URP and engine, without any of the above.
  Deploy new wallets only through the v6 factory.

---

## 1. The contracts the SDK talks to

| Contract | Address (Donut, chain id `42101`) | What the SDK does with it |
|---|---|---|
| **AGWFactory** (proxy) | `0xFBBEB6a365178fAaA81A9789a5f64b300c37e5bc` | Predict, deploy and look up wallets |
| **AGW** (one per user) | address from `predictWallet` | Grant / revoke rules, owner actions, reads |
| **URP** (proxy) | `0xBA32e7A1500cb34311a31127bcD40CA52C8CFd36` | Named inside every rule; read rule terms and spend |
| **SmartSession** (engine) | `0xf63DC0628fe1B25049FE3E3a3585Ef051CB98c1d` | Read only: list a wallet's rules |
| **AgentValidator** | `0xBf08d8335c1cE41a577DB70666816027814737dD` | Named inside every rule; never called |
| UniversalGatewayPC (Push core) | `0x00000000000000000000000000000000000000C1` | Named as the target of every cross-chain rule |
| UniversalCore (Push core) | `0x00000000000000000000000000000000000000C0` | Look up a chain's gas token (`gasTokenPRC20ByChainNamespace`) |

`AGW.SESSION_ENGINE()`, `AGW.RULES_POLICY()`, `AGW.SESSION_VALIDATOR()` and `AGW.UNIVERSAL_GATEWAY_PC()` return the
engine, URP, validator and gateway a wallet expects. Prefer reading them from the wallet over hard-coding.

## 2. Five terms

- **Owner**: the Push address that owns a wallet (an EOA, or the UEA of an external key). Fixed at deploy.
- **Wallet (AGW)**: a small contract account. It holds the funds the agent may use; its balance is the hard ceiling.
- **Rule**: what one agent may do from one wallet. Granted by the owner, stored in the engine and URP, immutable once
  granted. Identified by a `rulesId` (`bytes32`).
- **Agent**: the Push address a rule names (an EOA, or the UEA of an external key). Never the owner.
- **Checkpoint**: a counter on the wallet that moves on every owner-side action (owner calls, grants, revokes), never
  on agent actions. Evaluators compare it before and after a job.

---

## 3. Wallets: predict, fund, deploy

### Predict

```solidity
function walletCount(address owner) external view returns (uint256);            // also the next index
function predictWallet(address owner, uint256 index) external view returns (address wallet, bool deployed);
```

The address depends only on `(owner, index)` and never changes, so it can be shown and **funded before deployment**
(PC and PRC20s sent to it are there when it deploys). The next wallet is `predictWallet(owner, walletCount(owner))`.
`index` may be at most `walletCount(owner)`: predicting further ahead reverts `IndexOutOfRange(index, next)`.

### Deploy

```solidity
function deployWallet(string calldata label) external returns (address wallet);  // caller = owner
function deployWalletWithSig(OwnerIntent calldata intent, bytes calldata sig, string calldata label)
    external returns (address wallet);                                             // relayed, see §7
```

- `deployWallet` makes **the caller** the owner; there is no owner parameter.
- `label` is optional (`""` for the default) and is **stored on the wallet** (see [Label](#label)). It is also
  emitted in `WalletDeployed`. Over 64 bytes, the deploy reverts `LabelTooLong(length)`.
- Deploys revert while the factory is paused (`EnforcedPause`).

### Deploy with rules, in one call

```solidity
function createWallet(string calldata label, Session[] calldata rules)
    external returns (address wallet, bytes32[] memory rulesIds);                  // caller = owner
function createWalletWithSig(OwnerIntent calldata intent, bytes calldata sig, string calldata label,
    Session[] calldata rules) external returns (address wallet, bytes32[] memory rulesIds);  // relayed, see §7
```

- Deploys the owner's next wallet at `predictWallet(owner, walletCount(owner))` and grants every rule in order,
  **atomically**: if any rule is refused (shape, agent config, URP terms), nothing is deployed and the error bubbles.
- `rules` holds 0 to `MAX_INITIAL_RULES` (8, file-level in `Types.sol`); more reverts `TooManyInitialRules(count)`
  before anything is deployed. Empty `rules` is exactly `deployWallet`. More rules can be added later with `grantRules`.
- `rulesIds[i]` is the id `grantRules(rules[i])` would have returned at grant nonce `i` (§4.6); the wallet's
  `grantNonce()` is `rules.length` afterwards. Each rule emits the usual `Checkpointed` and `RulesGranted`.
- Both revert while paused (`EnforcedPause`).

### Look up

```solidity
function isWallet(address account) external view returns (bool);
function ownerOf(address wallet) external view returns (address);    // address(0) if not a factory wallet
function indexOf(address wallet) external view returns (uint256);    // reverts NotAWallet for a non-wallet
```

To list an owner's wallets: indices `0 .. walletCount(owner)-1` through `predictWallet`, or the `WalletDeployed`
events filtered by `owner`.

### Label

> Wallets from the retired v4 factory (`0xaF88…1aaF`) have no `label()` / `setLabel`; calling them reverts.

```solidity
function label() external view returns (string memory);   // on the wallet
function setLabel(string calldata label) external;         // on the wallet; owner (or the wallet itself)
event LabelSet(string label);
```

- **Every wallet has a label.** With none set, `label()` returns `"AGW <index + 1>"`, using the owner's own index:
  an owner's wallets read `AGW 1`, `AGW 2`, … and another owner's first wallet is also `AGW 1`.
- `setLabel` renames; `setLabel("")` resets to the default. At most **64 bytes** (bytes, not characters: 16
  four-byte emoji fit), else `LabelTooLong(length)`. Anyone but the owner gets `CallerIsNotOwner`.
- **Not a checkpoint.** A direct `setLabel` moves no counter. Sent through `execute` / `executeWithSig` (how a UEA
  owner renames: an execute whose single call targets the wallet's own `setLabel`), only the owner-door call ticks.
- `LabelSet` carries the label as passed (`""` on a reset). The deploy-time label is in `WalletDeployed`.
- **The label is not signed in `deployWalletWithSig`**: the relayer passes it, so it can differ from what the owner
  chose. It is cosmetic; the owner can fix it with `setLabel`.
- `list()` / `info()` need one `eth_call` per wallet: `label()`. No event scan.

---

## 4. Granting a rule

```solidity
function grantRules(Session calldata session) external returns (bytes32 rulesId);   // owner, or the wallet itself
```

One call grants one rule. A rule is a **`Session`** (the engine's struct) whose one policy is URP, carrying the terms
in an **envelope**.

### 4.1 The Session, field by field

```solidity
struct Session {
    address      sessionValidator;          // AgentValidator 0xBf08…37dD (must equal wallet.SESSION_VALIDATOR())
    bytes        sessionValidatorInitData;  // abi.encode(address agent), agent != address(0)
    bytes32      salt;                      // anything; the wallet overwrites it with its grant nonce
    PolicyData[] userOpPolicies;            // MUST be empty
    ERC7739Data  erc7739Policies;           // MUST be empty: { allowedERC7739Content: [], erc1271Policies: [] }
    ActionData[] actions;                   // see below
    bool         permitERC4337Paymaster;    // MUST be false
}
struct PolicyData   { address policy; bytes initData; }
struct ActionData   { bytes4 actionTargetSelector; address actionTarget; PolicyData[] actionPolicies; }
struct ERC7739Data  { ERC7739Context[] allowedERC7739Content; PolicyData[] erc1271Policies; }
struct ERC7739Context { bytes32 appDomainSeparator; string[] contentNames; }
```

Every action has **exactly one** policy: `{ policy: URP, initData: <envelope> }`. Anything else reverts
`MalformedSessionShape`.

Actions by rule kind:

| Kind | `actions` |
|---|---|
| **Cross-chain** (EVM or Solana destination) | Exactly 1 action: `actionTarget = UniversalGatewayPC`, `actionTargetSelector = 0x77b86bec` (the gateway's `sendUniversalTxOutbound`) |
| **Native** (Push-side calls) | 1 to 8 actions, one per `(target, selector)` the agent may call; no duplicates; every action's envelope names the same chain |

The **kind is never declared**: it is derived from the envelope's chain string. This chain (`"eip155:42101"`) means
native; any other `eip155:` or `solana:` chain means cross-chain.

### 4.2 The envelope (`initData` of the URP policy)

```solidity
initData = abi.encode(uint16 version, string chainNamespace, bytes body)
```

- `version` = **1** (`ENVELOPE_VERSION`). Anything else is refused (`UnsupportedEnvelopeVersion`).
- `chainNamespace`: CAIP-2 string, byte-exact. Destination chain for cross-chain rules (e.g. `"eip155:11155111"`,
  `"solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1"`); `"eip155:42101"` for native rules on Donut.
  (`URP.pushChainHash()` returns `keccak256("eip155:42101")` if you want to confirm.)
- `body`: `abi.encode(UniversalTerms)`, `abi.encode(SvmTerms)` or `abi.encode(NativeTerms)`, by kind.

### 4.3 Cross-chain rule, EVM destination: `UniversalTerms`

```solidity
struct UniversalTerms {
    uint48        validUntil;     // unix seconds, in the future; "never" = type(uint48).max
    address       expectedCEA;    // the wallet's account on the destination chain
    AssetCap[]    assets;         // 1..8 tokens the agent may move
    uint256       maxGasPerCall;  // PC (wei) the wallet may spend per outbound (protocol fee + gas)
    AllowedCall[] allowedCalls;   // 1..32 destination-chain calls the agent may make
}
struct AssetCap {
    address token;       // PRC20 ON PUSH (e.g. USDC.eth), never the destination chain's address
    uint256 maxPerCall;  // per request; 0 = this token can never move
    uint256 maxTotal;    // lifetime amount sent out; type(uint256).max = unlimited; 0 = nothing
}
struct AllowedCall {
    address target;            // destination-chain contract
    bytes4  selector;          // destination-chain function
    uint16  beneficiaryOffset; // byte offset of the beneficiary argument: 4 + 32 * argIndex
    bool    hasBeneficiary;    // if true, that argument must equal expectedCEA
    uint256 maxValue;          // native value per call, in DESTINATION-chain units; 0 = non-payable
    ArgPin[] pins;             // 0..8 argument words this call must satisfy; 32 across the whole rule
}
struct ArgPin { uint16 offset; PinOp op; bytes32 value; }  // offset from byte 0, selector included: 4 = first argument
enum PinOp { EQ, MAX }   // EQ: the word equals `value`. MAX: the word, as uint256, is <= uint256(value)
```

ABI tuple: `(uint48,address,(address,uint256,uint256)[],uint256,(address,bytes4,uint16,bool,uint256,(uint16,uint8,bytes32)[])[])`

**Pins are how you bound an argument the beneficiary field cannot describe.** `approve(address,uint256)` has no
beneficiary — demanding "spender == expectedCEA" would make it useless — so without a pin an allow-listed `approve`
permits `approve(anyone, type(uint256).max)`, after which that party drains the destination account directly, where
no gate can reach it. Pin the spender and cap the amount:

```ts
// USDC.approve(spender, amount) — spender fixed to Aave, allowance capped at 1000 USDC
pins: [
  { offset: 4,  op: 0 /* EQ  */, value: pad(AAVE_POOL) },      // argument 1
  { offset: 36, op: 1 /* MAX */, value: toHex(1_000_000000n) } // argument 2, inclusive ceiling
]
```

- **Only static arguments are pinnable.** `bytes`, `string` and arrays hold an offset at their head position, so a pin
  there pins a pointer. Derive offsets from the ABI; never hand-type them.
- **`EQ` is full-word.** An address must be left-padded clean, as the ABI encodes it. (The beneficiary check compares
  only the low 160 bits, so an `EQ` pin is strictly stricter.)
- **`MAX` bounds one call, not a lifetime.** Ten calls at the ceiling are ten times the ceiling.
- **Several entries may share one `(target, selector)`** and the call passes if **any** entry passes in full — that is
  how one token is approved to Aave *or* to Uniswap. An entry with **no** pins beside a pinned one makes the pinned one
  pointless; **the SDK must refuse that shape**, because URP does not. When no entry passes, the **first** matching
  entry's error is what reverts.

Rules the contracts enforce at grant (each with a named error, §10):

- **At least one token, at most 8, no duplicates.** A rule with no token is refused (`AssetListOutOfRange(0)`): the
  gateway picks the destination chain from the request's token, so a rule without a token has no chain.
- **Every token's chain must equal the rule's chain**: URP calls `token.SOURCE_CHAIN_NAMESPACE()` and compares
  (`ChainMismatch`, `InvalidAsset`). It checks the chain, **not which token**, so picking the right PRC20 is the SDK's job.
- `expectedCEA` non-zero; `allowedCalls` 1..32; `validUntil` non-zero and in the future.
- **Pins: at most 8 per allowed call (`TooManyPins`), and at most 32 across the whole rule
  (`TooManyAllowedCallPins`).** An `op` ordinal other than 0 or 1 is refused by the ABI decoder, with no named error.

What the SDK has to resolve:

- **Token → PRC20**: users give the destination chain's token (e.g. `MOVEABLE.TOKEN.ETHEREUM_SEPOLIA.USDC`); convert
  with `PushChain.utils.tokens.getPRC20Address(...)` and confirm `SOURCE_CHAIN_NAMESPACE()` equals the rule's chain.
- **A rule that moves no tokens**: the contracts refuse an empty list, so the SDK adds the destination chain's gas
  token with both limits at 0: `UniversalCore.gasTokenPRC20ByChainNamespace(chain)` (Sepolia: pETH
  `0x2971824Db68229D087931155C2b8bB820B275809`). Add it only when the user lists no token, or it would duplicate.
- **"No total limit"**: encode `maxTotal = type(uint256).max`. Do not encode 0; 0 means nothing may move.
- **`expectedCEA`**: the wallet's CEA on the destination chain, from that chain's CEA factory:
  `getCEAForPushAccount(walletAddress) returns (address cea, bool isDeployed)`.
- **`beneficiaryOffset`**: from the function ABI, `4 + 32 * argIndex` (e.g. Aave `supply(address,uint256,address,uint16)`,
  `onBehalfOf` is argument 2, offset 68).

One rule may list several tokens and several protocols. Limits are **per token**; there is no combined limit across
tokens, and every listed token may be used with every allowed call. Different scopes need separate rules.

### 4.4 Cross-chain rule, Solana destination: `SvmTerms`

```solidity
struct SvmTerms {
    uint48           validUntil;
    bytes32          expectedCEA;     // PDA(["push_identity", wallet], gatewayProgram)
    bytes32          gatewayProgram;  // the Push gateway program on that cluster (from the chain registry)
    AssetCap[]       assets;          // 1..8, same as §4.3; request amounts must fit u64
    uint256          maxGasPerCall;
    bytes32[]        ceaAccounts;     // the CEA's value-holding accounts, max 16, MUST include expectedCEA
    AllowedProgram[] programs;        // 1..32 allowed (program, instruction) pairs
    SvmAccountPin[]  pins;            // max 16 account pins
    SvmDataPin[]     dataPins;        // max 8 instruction-data pins
}
struct AllowedProgram { bytes32 program; bytes8 discriminator; uint8 discriminatorLen; bool dataless;
                        uint8 maxAccounts; /* 255 (ANY_ACCOUNT_COUNT) = any count; 1..64 = exact count; 0 refused */ }
struct SvmAccountPin  { uint8 ruleIndex; uint8 accountIndex; bytes32 expected; }
struct SvmDataPin     { uint8 ruleIndex; bool fromEnd; uint16 offset; uint16 offsetB; uint8 len;
                        uint8 mode /* 0 EQ, 1 GTE_LE, 2 LTE_LE, 3 RATIO_GTE_LE */; bytes32 expected; uint64 num; uint64 den; }
```

What the SDK must get right (all checked at grant, named errors):

- `ceaAccounts`: the CEA plus **the CEA's token account for every listed token** and any swap-output accounts. URP
  cannot derive Solana token accounts, so it cannot check this; an unlisted account is unprotected.
- **One rule per (program, instruction).** Each position takes one pinned key, so if a swap rule pins its input to the
  USDC account, USDT cannot be that instruction's input. Plan Solana rules so different tokens use different instructions.
- Every program rule needs at least one account pin; `discriminatorLen` is 1..8, or 0 exactly when `dataless`.
- `maxAccounts` is `ANY_ACCOUNT_COUNT` (255) for any account count, or 1..64 for the exact count the instruction must
  carry (use the IDL count for fixed-layout instructions). 0 and 65..254 are refused (`SvmMaxAccountsOutOfRange`).
- System, SPL Token, Token-2022, Stake, the upgradeable loader, the lookup-table program, the gateway program and the
  CEA itself can never be allowed programs.

Field-level detail: `docs/2_UniversalRulesPolicy.md` §1.2c.

### 4.5 Native rule (Push-side calls): `NativeTerms`, one per action

```solidity
struct NativeTerms {
    uint48     validUntil;
    address    target;           // MUST equal this action's actionTarget
    bytes4     selector;         // MUST equal this action's actionTargetSelector; 0xFFFFFFFF = plain PC transfer
    uint256    maxValuePerCall;  // PC (wei) per call
    uint256    maxValueTotal;    // lifetime PC; type(uint256).max = unlimited
    AmountRule amount;           // optional metering of one uint256 argument
    uint32     maxCalls;         // lifetime calls; type(uint32).max (UNLIMITED_CALLS) = unlimited; 0 refused
    ArgPin[]   pins;             // 0..8 argument words: EQ (equals) or MAX (ceiling)
}
struct AmountRule { bool enabled; uint16 offset; uint256 maxPerCall; uint256 maxTotal; }
struct ArgPin     { uint16 offset; PinOp op; bytes32 value; }  // offset from byte 0, selector included: 4 = first argument
enum   PinOp      { EQ, MAX }                                  // same meaning as on the EVM side (§4.3)
```

ABI tuple: `(uint48,address,bytes4,uint256,uint256,(bool,uint16,uint256,uint256),uint32,(uint16,uint8,bytes32)[])`

`ArgPin` is the SAME type the EVM allow-list uses, with the same two operations — one encoder serves both. The field
was named `expected` before `MAX` existed; it is now `value`, because under `MAX` it is a ceiling.

- `target`/`selector` must match the action they sit in. The contracts do not cross-check at grant, and a mismatch
  makes the rule unusable.
- Targets that can never be granted: the gateway (use a cross-chain rule), the wallet, the factory, the engine, URP,
  the validator, `address(0)`, `address(1)`.
- A plain PC transfer (`0xFFFFFFFF`) carries no pins and no amount rule.

### 4.6 The `rulesId`

`grantRules` returns it, and `RulesGranted(rulesId, …)` carries it. It is also predictable before sending:

```
rulesId = keccak256(abi.encode(address sessionValidator, bytes sessionValidatorInitData, bytes32(grantNonce)))
        // grantNonce = wallet.grantNonce() at the moment of the grant; it advances by 1 on every grant
```

Equivalently, call `SmartSession.getPermissionId(session)` with `salt = bytes32(grantNonce)`. Ids never repeat, even
for byte-identical rules granted twice.

### 4.7 Encoding a cross-chain rule (viem)

```ts
import { encodeAbiParameters, parseAbiParameters, parseEther, maxUint256, zeroHash } from 'viem';

const terms = encodeAbiParameters(
  parseAbiParameters(
    '(uint48,address,(address,uint256,uint256)[],uint256,(address,bytes4,uint16,bool,uint256,(uint16,uint8,bytes32)[])[])',
  ),
  [[validUntil, expectedCEA,
    [[USDC_ETH, 100_000000n, 1000_000000n], [USDT_ETH, 50_000000n, maxUint256]],
    parseEther('1'),
    [
      // Aave supply(): beneficiary pinned by the beneficiary field, asset pinned by an EQ pin
      [aavePool, '0x617ba037', 68, true, 0n, [[4, 0, pad(usdcSepolia)]]],
      // USDC approve(): no beneficiary argument exists, so BOTH bounds are pins
      [usdcSepolia, '0x095ea7b3', 0, false, 0n, [
        [4,  0, pad(aavePool)],              // EQ  — the spender
        [36, 1, toHex(1_000_000000n, { size: 32 })], // MAX — the allowance ceiling
      ]],
    ]]],
);
const initData = encodeAbiParameters(parseAbiParameters('uint16, string, bytes'), [1, 'eip155:11155111', terms]);

const session = {
  sessionValidator: wallet.SESSION_VALIDATOR,                      // 0xBf08…37dD
  sessionValidatorInitData: encodeAbiParameters([{ type: 'address' }], [agent]),
  salt: zeroHash,
  userOpPolicies: [],
  erc7739Policies: { allowedERC7739Content: [], erc1271Policies: [] },
  actions: [{
    actionTargetSelector: '0x77b86bec',                            // gateway sendUniversalTxOutbound
    actionTarget: '0x00000000000000000000000000000000000000C1',    // UniversalGatewayPC
    actionPolicies: [{ policy: URP, initData }],
  }],
  permitERC4337Paymaster: false,
};
// wallet.grantRules(session), from the owner
```

---

## 5. Revoking and replacing rules

```solidity
function revokeRules(bytes32 rulesId) external;   // owner, or the wallet itself; UnknownPermission if not live
function revokeAllRules() external;               // owner, or the wallet itself
```

Revocation is immediate on Push and cannot be blocked. An outbound already sent across the bridge still completes.

**Rules are immutable.** To "update" one, the owner sends **one batch through the owner door** (§6):

1. `URP.assertSpent(configId, wallet, expectedSpent)` — reverts if the agent spent since the SDK read the counters;
2. `wallet.revokeRules(oldRulesId)`;
3. `wallet.grantRules(newSession)`.

If step 1 reverts, nothing changes. Counters start at zero on the new rule. `assertSpent` forms:

```solidity
// cross-chain (EVM or Solana): one expected value per listed token, IN THE ORDER THE RULE LISTED THEM
function assertSpent(ConfigId id, address account, uint256[] calldata expectedSpent) external view;
// native: per action
function assertSpent(ConfigId id, address account, uint256 expectedValueSpent, uint256 expectedAmountSpent, uint32 expectedCalls)
    external view;
```

---

## 6. The owner door: `execute`

```solidity
function execute(bytes32 mode, bytes calldata executionCalldata) external payable;   // owner only
```

The owner acts as the wallet with **no rule checked**: withdraw, approve, call anything, or call the wallet's own
`grantRules` / `revokeRules` in a batch.

| | `mode` | `executionCalldata` |
|---|---|---|
| Single call | `0x0000…00` (32 zero bytes) | `abi.encodePacked(address target, uint256 value, bytes callData)` |
| Batch | `0x01` followed by 31 zero bytes | `abi.encode(Execution[])`, `Execution = (address target, uint256 value, bytes callData)` |

Other modes (delegatecall, try) revert `UnsupportedExecutionMode`. Every call in an owner action records one
checkpoint. **A token outbound through `execute` needs no separate approve:** for any call to the gateway's
`sendUniversalTxOutbound` the wallet approves the request's token for exactly the request's amount just before the
call and leaves the allowance at 0 just after (both doors, `executeWithSig` too). Withdraw PC: single call to the destination address with `value = amount, callData = 0x`. Withdraw a
token: single call to the token with `transfer(to, amount)`.

---

## 7. Relayed owner actions: `OwnerIntent`

For owners who sign but do not send (a Push EOA without gas, or a relayer-driven flow). The owner signs one EIP-712
`OwnerIntent`; the named `executor` submits it.

```solidity
struct OwnerIntent {
    address owner;            // the wallet owner
    address wallet;           // the wallet (its predicted address if not deployed yet)
    address executor;         // the ONLY address allowed to submit this intent
    uint96  index;            // deploy: must equal factory.walletCount(owner)
    bytes32 sessionHash;      // grant: keccak256(abi.encode(session)) of the session AS SUBMITTED; 0 = no grant
    bytes32 mode;             // execute: the mode word
    bytes32 execCalldataHash; // execute: keccak256(executionCalldata); 0 = no execute
    uint192 nonceKey;         // execute: lane key; the top bit (1 << 191) MUST be set
    uint64  nonceSeq;         // execute: must equal wallet.getNonce(nonceKey)
    uint64  grantNonce;       // grant: must equal wallet.grantNonce()
    uint48  deadline;         // unix seconds; every door rejects after it
    uint256 signerChainId;    // the chain id the owner's wallet signs under (their home chain)
}
```

EIP-712 type string (fields in this order):

```
OwnerIntent(address owner,address wallet,address executor,uint96 index,bytes32 sessionHash,bytes32 mode,bytes32 execCalldataHash,uint192 nonceKey,uint64 nonceSeq,uint64 grantNonce,uint48 deadline,uint256 signerChainId)
```

Domain: `name "AGWFactory"`, `version "1"`, `chainId = signerChainId`, `verifyingContract = factory proxy`
(`0xFBBEB6a365178fAaA81A9789a5f64b300c37e5bc`, also for wallet doors), `salt = bytes32(uint256(42101))`. Check the local derivation against
`factory.domainSeparator(signerChainId)` (or `wallet.domainSeparator(...)`, identical) before prompting.

| Door | Contract | Fields it checks |
|---|---|---|
| `deployWalletWithSig(intent, sig, label)` | factory | `owner`, `index`, `wallet` (= predicted), `executor`, `deadline` |
| `createWalletWithSig(intent, sig, label, rules)` | factory | `owner`, `index`, `wallet` (= predicted), `executor`, `deadline`, `sessionHash` **= `keccak256(abi.encode(rules))`** (the whole `Session[]`), `grantNonce` **= 0** |
| `grantRulesWithSig(session, intent, sig)` | wallet | `wallet`, `owner`, `executor`, `deadline`, `sessionHash`, `grantNonce` |
| `executeWithSig(mode, executionCalldata, intent, sig)` | wallet | `wallet`, `owner`, `executor`, `deadline`, `mode`, `execCalldataHash`, `nonceKey`, `nonceSeq` |

- **One signature can cover all three doors**: each door checks only its own fields, and each is single-use (deploy:
  the index advances; grant: the grant nonce advances; execute: the lane sequence advances).
- **Several rules in one signature**: put a batch of the wallet's own `grantRules` calls in `executeWithSig`
  (`grantRulesWithSig` grants exactly one).
- `executeWithSig` is **not payable**; value comes from the wallet's balance.
- Signature check: an owner with no code is verified by ECDSA; a contract owner by its UEA method
  (`verifyUniversalPayloadSignature`), then ERC-1271. A **Solana-key owner's UEA must already exist on Push** before
  its first signed intent.
- If the owner calls `deployWalletWithSig` or `createWalletWithSig` directly, no signature is needed.
- At `createWalletWithSig`, `sessionHash` commits to the **whole rules array**, so every byte, the order and the count
  are signed. That value never matches a single-session hash, so the same intent cannot be replayed at the wallet's
  `grantRulesWithSig`. Presenting it at `deployWalletWithSig` deploys the wallet **without** rules (that door ignores
  `sessionHash`); the create then fails `IndexMismatch`. Only an executor the owner chose can do that.

---

## 8. "Create a wallet with rules" in practice

**One call for every owner kind**, up to 8 rules:

| Owner | How |
|---|---|
| **UEA** (external key) | One transaction: `factory.createWallet(label, rules)`. |
| **Push EOA**, sends its own txs | One transaction: `factory.createWallet(label, rules)`. |
| **Via a relayer or the marketplace** | One signature: an `OwnerIntent` with the deploy fields, `sessionHash = keccak256(abi.encode(rules))` and `grantNonce = 0`. The relayer sends `createWalletWithSig(intent, sig, label, rules)`. |

Either the wallet exists with every rule, or nothing happened.

Fund the wallet with PC (for the agent's per-call fees) and the tokens the rules allow, at its address, before or after
deployment.

**No gateway approval is ever needed, and the SDK must not set one.** Every outbound, on the agent door and the owner
doors alike, approves exactly its own amount and leaves the wallet's allowance to the gateway at 0. A standing approval
would be cleared by the next outbound in that token anyway, so setting one only costs the owner a transaction and an
owner-side checkpoint.

---

## 9. Reading state

| To get | Call |
|---|---|
| A wallet's live rules | `SmartSession.getPermissionIDs(wallet)` → `bytes32[]` |
| Is a rule live | `SmartSession.isPermissionEnabled(rulesId, wallet)` |
| The rule's agent | `wallet.agentOf(rulesId)` (zero if revoked or unknown) |
| Kind, VM family, chain | `URP.getMode(configId, wallet)` → `{initialized, mode (0 cross-chain, 1 native), vm (0 EVM, 1 Solana), chainHash}` |
| Cross-chain EVM terms + spend | `URP.getConfig(configId, wallet)` → `{initialized, validUntil, expectedCEA, maxGasPerCall, assets[], allowedCalls[]}`, each asset `{token, maxPerCall, maxTotal, spent}` |
| Solana terms + spend | `URP.getSvmConfig(configId, wallet)` (same `assets[]` with `spent`) |
| Native terms + spend | `URP.getNativeConfig(configId, wallet)` → `{…, valueSpent, amountSpent, callsUsed, …}` |
| Checkpoints | `wallet.checkpointCount()`, `wallet.lastCheckpointBlock()`, `Checkpointed` events |
| Owner / factory | `wallet.owner()`, `wallet.factory()` |
| Label | `wallet.label()` (the default `AGW <index + 1>` when none is set) |
| Next grant nonce | `wallet.grantNonce()` |
| Owner lane position | `wallet.getNonce(nonceKey)` |

**`configId`** (the key URP reads take), per action:

```
actionId       = keccak256(abi.encodePacked(address target, bytes4 selector))
actionPolicyId = keccak256(abi.encodePacked(bytes32 rulesId, actionId))
configId       = keccak256(abi.encodePacked(address wallet, actionPolicyId))
```

- Cross-chain rule: one action, `target = UniversalGatewayPC`, `selector = 0x77b86bec`, so the `configId` follows from
  `rulesId` alone.
- Native rule: one `configId` per action; use each action's `(target, selector)` from the session the SDK built (or
  decode the grant transaction's input).
- `getConfig` reverts `WrongModeForCall` / `WrongVmForCall` if called on the wrong kind; call `getMode` first when
  unsure. An empty slot returns a zeroed struct.
- `spent` counts what was **sent out**. Money coming back to the wallet does not lower it.

The contracts do not enforce one rule per agent per chain. A wallet can hold several rules for the same agent and
chain, so a lookup by `(agent, chain)` can return more than one.

---

## 10. Events

| Contract | Event | Notes |
|---|---|---|
| Factory | `WalletDeployed(address indexed owner, uint256 indexed index, address indexed wallet, string label)` | The label as passed at deploy (`""` = default) |
| Wallet | `AccountInitialized(address indexed owner, address indexed engine)` | Emitted once at deploy |
| Wallet | `LabelSet(string label)` | `setLabel`; `""` = reset to the default |
| Wallet | `RulesGranted(bytes32 indexed rulesId, uint8 mode, bytes32 indexed chainHash, string chainNamespace)` | `mode`: 0 cross-chain, 1 native |
| Wallet | `RulesRevoked(bytes32 indexed rulesId)` | Once per revoked id |
| Wallet | `OwnerExecuted(bytes32 indexed mode, bytes32 executionCalldataHash)` | `execute` |
| Wallet | `OwnerExecutedWithSig(bytes32 indexed mode, bytes32 executionCalldataHash, uint192 nonceKey, uint64 nonceSeq)` | `executeWithSig` |
| Wallet | `Checkpointed(uint64 indexed seq, uint8 kind, bytes32 ref, uint64 blockNumber)` | `kind`: 0 owner action (`ref` = `keccak256(abi.encode(target, value, callData))`), 1 rules granted, 2 rules revoked (`ref` = `rulesId`) |
| Wallet | `RulesActionAuthorized(bytes32 indexed rulesId, address indexed agent, bytes32 callsHash)` | An agent action passed (agent side) |
| URP | `OutboundMetered(bytes32 indexed id, address indexed multiplexer, address indexed account, address token, uint256 amount)` | A cross-chain spend was counted |
| URP | `NativeCallMetered(bytes32 indexed id, address indexed multiplexer, address indexed account, uint256 value, uint256 amount)` | A native call was counted |

---

## 11. Errors the owner side can hit

All are custom errors with arguments; decode with the contract ABIs. URP errors raised during a grant reach the caller
in full (they come through the wallet).

| When | Errors |
|---|---|
| **Deploy** | `IndexMismatch(expected, provided)`, `IntentWalletMismatch`, `ExecutorMismatch`, `SignatureExpired`, `InvalidOwnerSignature`, `EnforcedPause`, `LabelTooLong(length)` |
| **Create with rules** | the deploy errors, `TooManyInitialRules(count)`, `IntentRulesMismatch(actual)` (`sessionHash` is not the hash of the rules presented, carried as `actual`), `IntentGrantNonceNotZero(provided)`, and any grant error below for the refused rule |
| **Label** | `LabelTooLong(length)`, `CallerIsNotOwner` |
| **Grant: session shape** (wallet) | `MalformedSessionShape`, `TooManyActions(n)`, `DuplicateAction(target, selector)`, `ForbiddenActionTarget(target)`, `ForbiddenActionSelector(selector)`, `RulesTypeMismatch(mode, actionIndex, target)`, `EmptyChain`, `InconsistentChain(actionIndex)`, `CallerIsNotOwner` |
| **Grant: envelope** (URP) | `UnsupportedEnvelopeVersion(firstWord)`, `EmptyChain`, `UnsupportedNamespace(chainHash)` (chain is neither `eip155:` nor `solana:`; declared in `PushChainLib`) |
| **Grant: cross-chain terms** (URP) | `AssetListOutOfRange(length)`, `DuplicateAsset(token)`, `InvalidAsset(token)`, `ChainMismatch(declared, assetChain)`, `InvalidConfigField`, `AllowListOutOfRange(length)`, `InvalidExpiry(validUntil)`, `TooManyPins(count)` (one allowed call over 8), `TooManyAllowedCallPins(total)` (over 32 across the rule) |
| **Grant: Solana terms** (URP) | `InvalidSvmConfigField`, `ProgramListOutOfRange`, `TooManySvmPins`, `TooManySvmDataPins`, `TooManyCeaAccounts`, `DiscriminatorLenOutOfRange`, `AmbiguousRule`, `ForbiddenProgramInAllowList`, `SvmPinRuleOutOfRange`, `SvmPinIndexOutOfRange`, `SvmMaxAccountsOutOfRange`, `DuplicateSvmPin`, `InvalidCeaAccount`, `CeaAccountsMissExpectedCEA`, `SvmDataPinInvalid`, `RuleWithoutPin` |
| **Grant: native terms** (URP) | `NativeTargetZero`, `NativeTargetIsGateway`, `ZeroMaxCalls`, `TooManyPins`, `ValueOnlyWithPins`, `ValueOnlyWithAmountRule`, `InvalidExpiry` |
| **Revoke** | `UnknownPermission(rulesId)`, `CallerIsNotOwner` |
| **Update batch** | `AssetSpentMismatch(token, expected, actual)`, `SpentLengthMismatch(expected, actual)`, `SpentMismatch(expected, actual)` (native), `NotInitialized`, `WrongModeForCall` |
| **Owner door / signed doors** | `CallerIsNotOwner`, `UnsupportedExecutionMode`, `MalformedBatchCalldata`, `OwnerSigExpired`, `IntentWalletMismatch`, `ExecutorMismatch`, `InvalidOwnerSignature`, `IntentSessionMismatch`, `IntentGrantNonceMismatch`, `IntentExecMismatch`, `OwnerLaneRequired`, `InvalidNonce` |
| **Reads** | `WrongModeForCall(actual)`, `WrongVmForCall(actual)`, `NotAWallet(account)`, `IndexOutOfRange(index, next)` |

A call made inside an owner action that reverts bubbles its own revert data up unchanged.

---

## 12. Limits

| Limit | Value |
|---|---|
| Tokens per cross-chain rule | 1 to 8 |
| Allowed calls per EVM rule | 1 to 32 |
| Actions per native rule | 1 to 8 |
| Argument pins per native action | 0 to 8 |
| Solana: programs / account pins / data pins / value-holding accounts | 1–32 / ≤16 / ≤8 / ≤16 |
| `validUntil` | non-zero, in the future; `type(uint48).max` = never |
| Unlimited total | `type(uint256).max` (0 means nothing) |
| Unlimited calls / any account count | Unlimited calls: `type(uint32).max`; any account count: 255; 0 is refused for both |
| Envelope version | 1 |
| Wallet label | 0 to 64 bytes (`""` = the default `AGW <index + 1>`) |
| Rules per `createWallet*` | 0 to 8 (`MAX_INITIAL_RULES`) |

## 13. Checklist before sending a grant

- [ ] `sessionValidator` is the wallet's `SESSION_VALIDATOR()`; `sessionValidatorInitData = abi.encode(agent)`; agent ≠ owner.
- [ ] Every action has exactly one policy, URP, with a version-1 envelope.
- [ ] Cross-chain: one action, gateway + `0x77b86bec`; 1–8 PRC20 tokens, each on the rule's chain; a gas-token entry
      at 0/0 if the user listed none; `maxTotal` is `type(uint256).max` when the user set no total.
- [ ] `expectedCEA` is the wallet's CEA on that chain; beneficiary offsets are `4 + 32 * argIndex`.
- [ ] Native: each `NativeTerms.target/selector` equals its action's.
- [ ] Solana: `ceaAccounts` includes the CEA and the CEA's account for every listed token.
- [ ] Record the `rulesId` from the receipt (or predict it from `grantNonce`) and keep the token order for `assertSpent`.
