# The Push-Native Agentic Demo

**One chain. One transaction per action. No bridge, no relay, no waiting.**

A user on Push Chain funds a small wallet (an AGW), grants an agent a narrow written set of rules,
and the agent does useful work with the user's money. The contracts, not the agent's honesty,
guarantee it can do **only** what the rules say.

**Status:** updated for the v6 contracts (2026-10-14); the v6 testnet run is pending. Earlier, every act
below was broadcast on Donut against v5 on 2026-10-10, and every refusal printed the error this README
names.

> ⚠️ `DemoUSDC` and `StakeDummy` are demo fixtures and are unsafe by design: a freely mintable
> token, and a staking contract with no owner, no pause and no supply accounting. **Never deploy
> either to mainnet.**

---

## How this differs from `demo/`

`demo/` is the **cross-chain** demo: Bob is an Ethereum EOA who never touches Push, acting through a
UEA, and the agent's action is bridged to Sepolia and executed by a CEA. It proves **reach**.

This one proves the **permission system**, with nothing in the way:

| | `demo/` (cross-chain) | `demo-native/` (this) |
|---|---|---|
| Chains | Sepolia + Push Donut | **Push Donut only** |
| Bob | Ethereum EOA, never touches Push | **Push EOA, acts directly** |
| Identity chain | EOA → UEA → AGW; CEA on Sepolia | **EOA → AGW. That's it.** |
| Kind the contracts derive | `UNIVERSAL (EVM)` | `NATIVE` |
| What decides the kind | the chain string `eip155:11155111` | the chain string `eip155:<this chain>` |
| Configs per rules set | 1 | **1 per action** |
| Agent's target | the gateway, always | **the contract itself** |
| Payload nesting | 4 layers | **1** |
| Request `value` | protocol fee + gas swap, live-quoted | **0** |
| Beneficiary check | `expectedCEA`, gate 15 | **`ArgPin` at offset 4, gate N7** |
| Settlement | relayed by Push's validators | **same transaction** |
| Staked asset | PRC20 `USDC.eth` | **`dUSDC`, deployed for the demo** |

**Neither supersedes the other.** The native demo is the better opener for a technical audience; the
cross-chain demo is the better closer.

---

## Keys (in `.env`, by name)

| Key | Role here |
|---|---|
| `BOB_KEY` | the owner: a Push EOA that deploys the wallet, grants rules and withdraws |
| `AGENT_KEY` | the agent: **sends its own transactions**, so it holds a little PC for gas and never holds tokens |
| `PC_RELAYER_KEY` | the Act 4f accomplice (it sends one `transferFrom`) and the G6 impostor |
| `PRIVATE_KEY` | mints dUSDC, funds the reward pool, tops up the agent's gas |

`just fund` tops the agent up to **0.05 PC**. On Donut a native `executeAsAgent` used
130,000–190,000 gas, and the six agent transactions of one full run cost 0.00087 PC in total.
Preflight requires at least 0.01 PC, so it stays green as the agent spends.

---

## Run it

```bash
cd demo-native

just preflight        # green/red checklist: run at T-1h AND T-5min
just fund             # mint dUSDC, fill the reward pool, top up the agent's gas

just act1             # Bob deploys, funds, approves, grants. 1d is the opening beat
just state            # between every act

just act2             # THE CENTRAL BEAT: the agent stakes 2.5, sending its own transaction
just gauntlet         # g1 g2 g3 g4 g5 g6 d1: seven simulated refusals
just stake 2.5        # act 3b
just stake 1          # act 3c: lands exactly on the lifetime cap
just g7               # the budget runs out under the run's own weight

just act4a-grant      # a second rules set, for one job
just act4a            # the agent withdraws, to the WALLET
just g8               # a second unstake, refused at the call limit
just act4b            # the agent tries to take the money: refused
just act4c            # Bob takes it back, instantly
just act4d            # revoke everything
just act4e            # THE CLOSING BEAT: the agent's own request, refused after revocation
just act4f            # the unpinned-approve demonstration (optional, five steps)

just state
just reset            # after any rehearsal
```

**Every broadcasting recipe has a `-dry` twin** (`just act2-dry`, `just stake-dry 2.5`,
`just act4f-3-dry`, …). A dry run broadcasts nothing, but it does write the demo ledger exactly as
the live recipe would.

**The fixtures are live.** `DemoUSDC` and `StakeDummy` are already on Donut and recorded in
`config/native_demo.json`; preflight checks their code. `just token` and `just stakedummy` exist
only to rebuild them, after which the printed addresses go into that file.

---

## The refusals, and who refuses

Every gauntlet script is a **simulation**: nothing is broadcast. G1–G8 are sent *as the agent*
(`vm.prank`), because the wallet's first check is that the sender is the agent the rules name; a
simulation sent from anyone else would die there and hide the gate it means to show.

| Recipe | Attempt | Refused with | By |
|---|---|---|---|
| `g1` | `stakeFor` aimed at DemoUSDC | `NoPoliciesSet` | the engine, unwrapped |
| `g2` | `unstake()` under the stake rules | `NoPoliciesSet` | the engine, unwrapped |
| `g3` | `stakeFor(agent, 2.5)` | `ArgPinMismatch` | URP gate N7, wrapped |
| `g4` | `stakeFor(wallet, 2.6)` | `NativeAmountExceedsCap` | URP gate N8, wrapped |
| `g5` | the Act 2 call + 1 wei | `ValueExceedsCap` | URP gate N6, wrapped |
| `g6` | the exact Act 2 call, from another account | `CallerIsNotAgent(rulesId, caller)` | **the wallet**, before the engine |
| `g7` | `stakeFor(wallet, 0.1)` after 6 spent | `TotalNativeAmountExceeded` | URP gate N8, wrapped |
| `d1` | Bob grants the same rules with chain string `EIP155:<id>` | `RulesTypeMismatch(UNIVERSAL, 0, StakeDummy)` | **the wallet**, at grant |
| `g8` | a second `unstake()` | `CallLimitReached` | URP gate N9, wrapped |
| `act4b` | `transfer(agent, everything)` | `NoPoliciesSet` | the engine, unwrapped |
| `act4e` | a flawless stake, after revocation | `CallerIsNotAgent(rulesId, agent)` | **the wallet** |
| `act4f-5` | `approve(accomplice, 2)` under the pinned rules | `ArgPinMismatch` | URP gate N7, wrapped |

"Wrapped" means the engine rewraps URP's error as `PolicyCheckReverted(bytes32)`; only the 4-byte
selector survives, and the scripts assert it.

---

## The beats that carry the demo

**1d: the rules.** The thesis on one screen: *this agent may call one function on one contract,
only ever crediting Bob's wallet, up to 2.5 dUSDC per action and 6 in total, at most four times, for
seven days.* Every number is read back from URP. It also prints
`chain "eip155:42101" -> derived NATIVE`, read from the wallet's event and from URP: nobody declared
the kind.

**G3: the agent stakes to itself.** One word of calldata differs from Act 2. It is refused, and the
reason is worth stating in full: `StakeDummy.unstake()` pays `msg.sender`, so had this succeeded the
agent could have called `unstake()` **from its own account, under no rules at all**, and walked
away with principal plus reward. The pin is what stops it.

**D1: the chain string decides.** The same grant with one character of the chain string changed is
a cross-chain rules set, which may only target the gateway, so the wallet refuses it. There is no
mode flag to set wrong, and none to set right.

**Checkpoints.** Every wallet counts owner-side actions: +1 per owner-door call, per grant and per
revoked rules set, and never on an agent action. Each script prints the counter, and the agent
scripts assert it did not move. An evaluator uses it to tell the agent's failure from the owner's
interference.

**4f: where the guarantee ends.** `approve` rules that forget to pin the spender are *valid* rules.
The agent uses them to approve an accomplice, who drains the wallet, and nothing refuses it. Then the
same rules with the spender pinned refuse the identical request. **The system enforces the rules as
written; the SDK is what refuses to write bad ones.**

---

## What this demo deliberately does not prove

- **Not cross-chain anything.** No gateway, no CEA, no Sepolia. That is `demo/`.
- **Not that the agent is intelligent.** It is a key running a script.
- **Not that `StakeDummy` is a good staking contract.**
- **Not that URP refuses badly written rules.** It proves the opposite, on purpose, in 4f.

---

## Layout

```
config/      native_demo.json: the two demo fixtures on Donut
contracts/   DemoUSDC · StakeDummy
lib/         AddressBook · Amounts · DemoLog · Keys · Ledger · OwnerDoor
             NativeRules (session and terms builders) · NativeRequest (build and submit)
             NativeIds (config ids) · NativeGauntlet (refusal assertions)
             Grant (one owner grant, read back and asserted) · RulesRead (id and derived kind)
script/      00_setup · 01_bob · 02_agent · 03_gauntlet · 04_boundary · 05_inspect · 99_reset
test/        NativeIds · NativeRules · StakeDummy
state/       ledger.json (gitignored, per-run)
```

Our own contract addresses are read from `deployments/address-book-v6/push_agw_contracts.json` and
are never copied into this folder.

---

## Things that will bite you

**A dry run writes the ledger.** `just act1d-dry` records the rules id the grant *would* produce.
That is the same id the live grant produces if nothing else is granted in between, which is why
running each `-dry` immediately before its live recipe is safe.

**`just reset` does not clear the ledger.** It revokes every rules set and sweeps both wallets back
to Bob, and says so. Delete `state/ledger.json` to start from a fresh wallet index.

**After a full run, the throwaway wallet still has two live `approve` rules.** Act 4f ends there on
purpose. The wallet is empty, but `just reset` is what revokes them.

**Rules ids repeat across wallets.** An id is `keccak256(validator, agentConfig, grantNonce)`; the
wallet is not in it. Two wallets that grant their first rules to the same agent get the same id.
All state is keyed by wallet as well, so nothing collides, but do not treat an id as globally unique.

---

## What changed from demo-v1

The demo was rebuilt for the current contracts. The short version: the agent now sends its own
transactions and signs nothing; rules name the agent by Push address; the rules envelope carries a
version; "mandate" became "rules" everywhere; wallets have a label and a checkpoint counter. The
full list of contract changes is in
[`docs-internal/demo-rebuild/demo_context.md`](../docs-internal/demo-rebuild/demo_context.md).

---

## Tests

```bash
FOUNDRY_PROFILE=demo-native forge test
```

A **separate profile**, not a change to the default `test` path: plain `forge test` must keep
running exactly the contract suite, which is the contracts' specification.
