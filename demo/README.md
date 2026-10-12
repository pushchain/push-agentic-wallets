# The cross-chain agentic demo

A user on Ethereum owns an agent wallet (an AGW) on Push Chain without ever holding a Push Chain
key, grants it rules narrow enough to fit on one screen, and watches an agent move real capital
across a chain boundary, while the attacks in the gauntlet die on-chain.

**Status:** run end to end on Donut and Sepolia against the current (v5) contracts on 2026-10-10/11,
at `DEMO_SCALE_PERCENT=4` (Bob held 4 USDC on Sepolia). Every act was broadcast and every far-chain
effect was confirmed on Sepolia.

**The operator's script is [`DEMO_MANUAL.md`](DEMO_MANUAL.md).** This file is the short version.

> ⚠️ `StakeDummy` is a demo fixture and is unsafe by design: no owner, no pause, no supply
> accounting. **Never deploy it to mainnet.**

## Keys (in `.env`, by name)

| Key | Role |
|---|---|
| `BOB_KEY` | the owner. A Sepolia EOA; signs every owner payload for his UEA on Push. Never holds a Push key |
| `AGENT_KEY` | the agent. **Sends its own transactions**, so it holds a little PC for gas and never holds tokens |
| `PC_RELAYER_KEY` | submits what Bob signs, funds the wallet's PC and the agent's gas, and plays the G6 impostor |
| `SEPOLIA_STAKE_DEPLOYER_KEY` | deployed and funded StakeDummy on Sepolia |

`just fund-agent` tops the agent up to **0.05 PC**. On Donut a cross-chain `executeAsAgent` used
about 405,000 gas for a stake and 357,000 for an unstake, roughly 0.0004 PC each. Preflight requires
at least 0.01 PC, so it stays green as the agent spends.

## Run it

```
cd demo && just            # list every recipe
```

```
just preflight             # T-1 hour, and again five minutes before presenting
just setup                 # tokens, quote, fund, stakedummy, fund-agent, preflight
just act1                  # off-camera: the only Ethereum tx, and the longest relay wait
just state                 # ← run this between every act

just act2                  # the central beat: the agent sends its own transaction
just watch-staked
just gauntlet              # g1 g2 g3 g4 g6 g7: needs no Act 2
just g5                    # the lifetime cap: needs Act 2's spend
just act4a ; just watch-unstaked
just act4b
just act4c ; just watch-returned
just act4d
just act4e                 # Bob revokes; the agent's own request is then refused
```

**Every broadcasting recipe has a `-dry` twin.** A dry run broadcasts nothing, but it does write
the demo ledger exactly as the live recipe would.

**`reset-dry` leaves the ledger alone.** The live `reset` clears `rulesId`; the dry run revokes
nothing, so it clears nothing.

**`fund` and `stakedummy` skip themselves** while the recorded StakeDummy is live and its reward
pool covers an unstake. To rebuild the fixture, zero `.StakeDummy` in `config/sepolia.json` first.

## The gauntlet

All seven are simulations, sent **as the agent** (`vm.prank`): the wallet's first check is that the
sender is the agent the rules name, so a simulation sent from anyone else would die there and hide
the gate it means to show. G6 is the deliberate exception: it is sent as someone else.

| Recipe | Attempt | Refused with | By | Needs Act 2 |
|---|---|---|---|---|
| `g1` | selector `0xdeadbeef` on StakeDummy | `CallNotAllowed(target, selector)` | URP gate 15 | no |
| `g2` | inner target = the wallet's own CEA | `ForbiddenInnerTarget(cea)` | URP gate 14 | no |
| `g3` | `stakeFor(agent, 0.1)` | `BeneficiaryMismatch(cea, agent)` | URP gate 15 | no |
| `g4` | `stakeFor(cea, 120% of the per-action cap)` | `AmountExceedsCap(amount, cap)` | URP gate 6 | no |
| `g5` | a second full-size stake | `TotalSpendCapExceeded(newTotal, cap)` | URP gate 7 | **yes** |
| `g6` | the exact Act 2 call, from the relayer's address | `CallerIsNotAgent(rulesId, caller)` | **the wallet**, before the engine | no |
| `g7` | the stake call routed with pETH, amount 0 | `AssetNotAllowed(pETH)` | URP gate 5 | no |

URP refusals arrive wrapped by the engine as `PolicyCheckReverted(bytes32)`, with only the selector
intact; each script then calls `checkAction` directly, pranked as the engine, to print the full
arguments. G6 arrives unwrapped.

**G3 stakes a tiny amount on purpose.** The caps (gates 6 and 7) run before the beneficiary pin (gate
15). After Act 2 a full-size stake would die at the lifetime cap and never reach the pin.

## What to know before running it

**`just preflight` detects its own phase.** No wallet in the ledger is phase 1; a wallet is phase 2;
rules whose token has been spent from is phase 3. Checks that are not yet applicable print grey,
never red. It exits non-zero on any real failure.

**`just quote` must run again immediately before Act 2.** `maxGasPerCall` is frozen into the rules
at grant time, at three times the quoted cost. If Sepolia's gas price moves the cost past it, every
agent request is refused by gate 8 (`PCValueExceedsCap`) and the only remedy is `just reset` and
`just act1e`. The quote warns while there is still time.

**`just g5` must run after `just act2`.** Its refusal depends on the spend counter having moved. It
asserts that and fails with a message naming Act 2 rather than a confusing selector mismatch.

**`DEMO_SCALE_PERCENT=10` runs the whole thing on a tenth of the capital.** Every ratio the gauntlet
depends on is preserved; the flat 10 USDC reward does not scale.

**Checkpoints.** The wallet counts owner-side actions: +1 per owner-door call, per grant and per
revoked rules set, never on an agent action. Owner scripts print the counter moving; agent scripts
assert it did not. That is how an evaluator tells the agent's failure from the owner's interference.

## What is where

| path | holds |
|---|---|
| `config/` | Push core and Sepolia addresses the demo reads (`donut_push_core.json`, `sepolia.json`) |
| `contracts/StakeDummy.sol` | the far-chain target. Demo only, never mainnet |
| `lib/` | address book, ledger, logging, request builders, refusal assertions, state reads |
| `script/00_setup/` | tokens, quote, StakeDummy, funding, the agent's gas, the forwarding probes |
| `script/01_bob/` | Act 1: arrival, the wallet, the PC seam, the approval, the rules |
| `script/02_agent/` | Act 2: the stake |
| `script/03_gauntlet/` | Act 3: seven refusals |
| `script/04_boundary/` | Act 4: unstake, the refusal, the owner's repatriation, the withdrawal, revocation |
| `script/05_inspect/` | state dumps |
| `script/Preflight.s.sol` · `Watch.s.sol` | the checklist, and the cross-chain wait |
| `state/ledger.json` | per-run state. Gitignored |

Our own contract addresses are read from `deployments/address-book-v5/push_agw_contracts.json` and
are never copied into this folder.

## Things that cost a debugging session each

**`gasFee` is denominated in the GAS TOKEN, not PC.** `protocolFee` is in PC. Two currencies in one
return tuple. Sizing a PC budget from `gasFee` undersizes the swap by the pETH/PC price, and it
fails as an opaque Uniswap `STF`. `lib/GasSwap.sol` prices it from the pool.

**`maxPCForGas` caps what reaches the swap; the rest is refunded.** Raising `msg.value` alone changes
nothing. A zero there means *uncapped*, which makes owner-path scripts pass while every agent-path
call fails, because gate 9 requires a non-zero cap.

**Push's default far-chain gas limit is too low for Sepolia today.** A request with `gasLimit: 0`
is relayed with 500,000 gas. The first outbound for a wallet, which deploys its CEA and runs one
`approve`, needs about 1,400,000 (`eth_estimateGas` on the relayed call). At the default the relay's
Sepolia transaction reverts, the CEA never appears, and every later outbound reverts with it. Push
refunds the bridged tokens to the wallet, **but the rules' spend counter is not credited back**, so
the budget is gone until a regrant. `lib/Requests.sol` therefore sends `FAR_GAS_LIMIT = 2,000,000`,
and every quote is priced with the same number.

**Never run Act 2 before `watch-cea` succeeds.** The stake needs the allowance that Act 1d's
outbound sets on Sepolia. If that outbound did not land, the stake reverts on Sepolia and consumes
budget as above. Recovery: `just act1d`, `just watch-cea`, `just reset`, `just act1e`.

**forge under-sizes gas for the Sepolia USDC `approve`.** It sizes a broadcast from its local
simulation times 1.3, which gave 64,784 gas where the network needs about 130,000. The approve ran
out of gas and the bridge transaction behind it failed for lack of allowance. The Sepolia recipes
therefore pass `--gas-estimate-multiplier 300`.

**A load-balanced Sepolia RPC can answer `block not found`.** `watch-*` re-forks at the latest block
every round; if one backend lags the head, the script dies with an RPC error instead of timing out.
Run it again.

## Where our responsibility ends

The Push-side transaction completing is the whole of what these contracts control. Delivery to the
far chain is Push core's validators and their TSS signer. A slow far leg is not a bug in the rules:
every Push-side decision is already final and verifiable on the explorer. `just watch-*` says
exactly that on timeout, and points at the gauntlet, which needs no relay.

## What changed from demo-v1

The demo was rebuilt for the current contracts. The short version: the agent now sends its own
transactions and signs nothing; rules name the agent by Push address; rules list one to eight tokens,
each with its own caps; the rules envelope carries a version; "mandate" became "rules" everywhere;
wallets have a label and a checkpoint counter; G6 is an impostor rather than a replay, and G7 and
Act 4e are new. The full list of contract changes is in
[`docs-internal/demo-rebuild/demo_context.md`](../docs-internal/demo-rebuild/demo_context.md).

## Tests

```
just test                  # FOUNDRY_PROFILE=demo forge test
```

The three `*Fork.t.sol` suites read live chains and need `PUSH_DONUT_RPC_URL`, `SEPOLIA_RPC_URL`
and (for `OwnerPathFork`) `PROBE_KEY`. Without them they return early: **a skipped fork test is not
a passing one.**
