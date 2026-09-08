# StoaChain v3.2.1-stoa.3 — Release Notes

**Base:** chainweb-node **3.2.1** (`kda-community`, `d89bb530`) + Pact **5.4.1** (`72f42760`)
**Image:** `ghcr.io/stoachain/stoa-node:v3.2.1-stoa.3`
**Branch:** `upgrade/chainweb-3.2.1`
**Previous:** `v3.2.1-stoa.2`

> ## ⚠️ HARD DEADLINE — BLOCK 600,000
>
> This release schedules a **consensus fork at block height 600,000 per chain**.
> **Every node must be running `v3.2.1-stoa.3` before that height or it will stall.**
>
> At the time of writing the chain was at **551,188**, giving 48,812 blocks of
> margin — about **17.4 days** at our 30-second block delay, landing around
> **2026-09-25**.
>
> Nodes below the fork height interoperate normally with upgraded nodes, so the
> rollout can be staged. The deadline is the *height*, not the restart.
>
> **Verify with `nodeLatestBehaviorHeight` on `/info`:** a node on stoa.2 reports
> **516501**; a node on stoa.3 reports **600001**. A node that is merely
> *healthy* is not necessarily *upgraded* — it will look fine right up until it
> stalls.

---

## What this release does

It turns the **Yin engine** on: StoaChain's minimum gas price stops being a
constant and becomes a function of time, enforced at consensus.

```
F(t) = min( 10,000 + floor( (t − GENESIS) / 10,800 ), 1,000,000 )   [ANU]

    GENESIS   = 2026-02-23T18:00:00Z
    interval  = 3 hours   (so +1 ANU per 3h, 8 per day)
    cap       = 1,000,000 ANU = 1 microSTOA per gas, reached 2364-12-18
```

From block 600,000, a transaction is rejected unless its gas price is at least
`F(its own creationTime)`.

**Comparing against the transaction's own creation time — not block time — is
the load-bearing design choice.** It means the floor a transaction is judged
against is frozen the moment it is signed, so a transaction waiting in a mempool
can never go stale as the floor ticks. The only thing that expires a pending
transaction is its TTL. Had this compared against block time, every queued
transaction would have begun failing every three hours with no action by the
sender.

This also completes the commitment made at launch that the gas floor would
arrive in Year 1.

### What was already live before this release

The Pact half shipped ahead of the node and needs no upgrade:

- `coin` upgraded — `MAX-GAS-PRICE` 400,000 → **1,000,000**, and `GENESIS-TIME`
  aligned to **2026-02-23T18:00:00Z** to match consensus.
- `stoa-ns.stoic-xchain` upgraded to V3 (live-floor ceiling + 10 ANU buffer);
  both cross-chain gas stations rotated onto it.
- DALOS gas station moved to a floor-relative notional cap (+100 ANU buffer).
- Ouronet UI, Stoa Wallet and stoa-js all price by the new formula already.

Because the new rule is **strictly stricter** than the old static `1e-8`
minimum, clients could adopt it early and be correct under both regimes. That is
what made shipping the wallets ahead of the protocol safe.

---

## Changes in this release

| file | change |
|---|---|
| `Chainweb/Version/Stoa/GasFloor.hs` | **new** — the pure floor. Zero imports, integer arithmetic only |
| `Chainweb/Pact5/Validations.hs` | `assertMinGasPrice`, beside its sibling assertions |
| `Chainweb/Pact/PactService/Pact5/ExecBlock.hs` | `checkGasPrice` in `validateParsedChainwebTx` |
| `Chainweb/Pact/PactService/Pact4/ExecBlock.hs` | the same check, mirrored |
| `Chainweb/Version.hs` | `StoaMinGasPrice` at the end of the `Fork` enum |
| `Chainweb/Version/Guards.hs` | `enforceStoaMinGasPrice` |
| `Chainweb/Version/Stoa.hs` | **`ForkAtBlockHeight 600_000`, listed explicitly** |
| Mainnet / Testnet04 / Development / RecapDevelopment | `ForkNever` |

**No mempool change was needed.** `preInsertBatch` already routes through
`validateParsedChainwebTx`, so admission and block validation share one
implementation and cannot drift apart.

**The fork is listed explicitly in `Stoa.hs`, above the wildcard.** That file
ends its fork table with `_ -> AllChains ForkAtGenesis`, so a new constructor
left unlisted would activate *at genesis* and retroactively invalidate every
block ever mined. Mainnet, Testnet04 and RecapDevelopment enumerate exhaustively
and are protected by `-Werror`; stoa is not, so a test now asserts it.

---

## Verification

| check | result |
|---|---|
| floor function | 9 vectors + 5 properties |
| fork table | future height, not genesis; `ForkNever` elsewhere; boundary at exactly 600,000 |
| consensus predicate | exact floor accepted, 1 ANU under rejected, creation-time semantics — real signed transactions |
| live network across the fork | legacy accepted before · rejected after · **floor−1 rejected** · **floor accepted** · **stale transaction accepted at its own floor** |
| Pact ↔ Haskell pinning | pact 5.4.1, nine shared vectors, **verified falsifiable** |
| **full-history replay** | **550,567 blocks × 10 chains — passes** |
| **mis-gated replay** | **fails correctly** — proves the check is reached and that replay can detect a mis-gated fork |
| gas stations | tested on mainnet, working |
| regressions | none, against a clean `git archive HEAD` baseline |

The two replays matter together and neither alone is sufficient. With the fork
correctly gated at 600,000 the check is vacuous over all existing history, so
passing proves **the fork changes nothing that has already happened**. With it
deliberately mis-gated to height 1 the check fires and rejects a genuine
historical transaction — which is what proves it is wired in at all.

---

## Rollout

1. Pull `ghcr.io/stoachain/stoa-node:v3.2.1-stoa.3` on every node.
2. Restart node by node — peering is unaffected during a staged rollout.
3. **Verify every node reports `nodeLatestBehaviorHeight: 600001`** before the
   height lands.
4. Only move `:latest` once the fleet is healthy.

**Rollback** is clean until block 600,000 — block header format, RocksDB schema
and Pact SQLite schema are all unchanged, so the old binary reads the new
database. After activation the old binary rejects post-fork blocks, so treat the
activation height as the point of no return.

---

## Client requirement

**Any client still paying the flat `1e-8` minimum will be rejected from block
600,000.** Wallets and packages were updated ahead of this release. Anyone
running their own transaction builder must adopt the formula —
[`yin-engine-client-handoff.md`](yin-engine-client-handoff.md) carries the
reference implementation, the construction flow, and the nine test vectors.
