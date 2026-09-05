# The Yin Engine — protocol-enforced rising minimum gas price

**Design document. No code yet.** Companion target release: **v3.2.1-stoa.3**.

This is the "Yin" half of the Yin/Yang economic engine: a minimum gas price that
rises deterministically with time, enforced at the **consensus** layer. (The
"Yang" counterpart — the declining coinbase it eventually crosses — is out of
scope here.)

---

## 0. Summary

Today StoaChain has the *formula* for a rising gas floor deployed in the coin
contract, but **nothing enforces it**: the only floor actually applied is a
static `1e-8` checked at mempool admission only — which is itself one of the
findings from the upstream audit (a floor enforced at admission but not at
consensus is not a rule a miner must obey).

This update promotes the time-based floor from *"a helper function plus a static
mempool check"* into a **real consensus rule**, gated behind a new fork at a
future height, and fixes the cross-chain gas-station guard that would otherwise
break the instant the rule goes live.

Locked design decision (see §3): the floor a transaction must beat is the floor
**at its own creation time**, not at incorporation time.

---

## 1. What exists today (grounded)

| Piece | Where | State |
|---|---|---|
| The floor formula | `pact/genesis/stoa/stoa-genesis-4.pact:306` `UC_MinimumGasPriceANU` | Deployed, but a **client-facing helper** — nothing enforces it. Reads **block-time**. |
| Constants | `stoa-genesis-4.pact:84-89` | `GENESIS-TIME 2026-02-23T18:00:00Z`, `GENESIS-MIN-GAS-PRICE 10000` (ANU), `MAX-GAS-PRICE 400000` (ANU), `GAS-PRICE-INTERVAL 10800.0` (3h). `1 STOA = 1e12 ANU`. |
| The enforced floor | `Configuration.hs:458` `_configMinGasPrice = 1e-8`; `InMem.hs:439` `gasPriceMinCheck` | Static, **mempool-admission only**. Never checked at block validation. |
| Creation-time field | `_pmCreationTime`; `Pact5/Validations.hs:182` `assertTxTimeRelativeToParent` | Present, and already bounded to `<= TTL` in the past. |
| Cross-chain gas stations | `pact/genesis/stoa/stoa-genesis-5.pact:28` `create-xchain-gas-account` | `kadena-xchain-gas` (legacy) and `stoa-xchain-gas` (new). **The new one's price guard is frozen — see §5.4.** |

The floor per the formula is **already ~11,500 ANU today** (~1,550 three-hour
ticks since the Feb 2026 genesis), i.e. already well above the `10000` (`1e-8`)
that the static check and the gas-station guard assume.

---

## 2. The formula

```
F_anu(t) = min( GENESIS_MIN + floor( (t - GENESIS_TIME) / INTERVAL ), MAX )
         = min( 10000 + floor( (t_seconds - genesis_seconds) / 10800 ), 400000 )
F_stoa(t) = F_anu(t) / 1e12
```

- `t` is in **POSIX seconds** (match the unit of Pact `block-time` / the tx
  `creationTime` exactly — a unit slip here is a consensus bug).
- All inputs are integers, so the whole computation is **integer arithmetic** —
  no floating point anywhere near consensus. (The audit's refuted F-13 was
  precisely about float leaking into consensus-hashed gas; do not reintroduce
  the smell.)

The two consumers evaluate the same formula at **different time inputs**, and
that is intentional:
- The **Pact helper** `UC_MinimumGasPriceANU` reads **block-time** → "what is the
  floor right now" (for clients/contracts to query).
- The **consensus rule** (new, §5.1) reads the transaction's **creationTime** →
  "what floor did this transaction have to beat when it was signed."

---

## 3. Core decision — creation-time comparison (LOCKED)

**A transaction is valid iff `gasPrice >= F(creationTime)`** — the floor as of
the transaction's own creation time, not the block it lands in.

Rationale (confirmed by the owner's requirement "submitted transactions must not
fail because they were incorporated later when the min price rose"):

1. **Fair.** A user who paid the correct floor when they signed is not voided by
   mempool latency or a tick that fires while the tx waits to be mined.
2. **Safe from back-dating.** `creationTime` is client-supplied but already
   bounded by `assertTxTimeRelativeToParent` to at most one TTL in the past
   (~2 days). Max under-payment vs the live floor is therefore ~16 ticks = 16
   ANU against a 10,000+ floor — negligible, and shrinking as the floor climbs.
3. **Economically irrelevant slack.** The engine is a 133-year drift; a ≤16-ANU
   per-tx slack does not affect its purpose.

Consequence: a transaction is rejected **only** when it under-pays its *own
creation-time* floor. It is never rejected merely for being mined after a tick.

---

## 4. The exact comparison (no float)

`gasPrice` is a `Decimal` (STOA) constrained to ≤ 12 decimal places
(`assertGasPrice` / `defaultMaxCoinDecimalPlaces`). `F_anu(creationTime)` is an
integer (ANU). Compare in **ANU, as integers**:

```
gasPrice_anu = gasPrice * 1e12        -- exact integer, since gasPrice has <= 12 dp
reject if   gasPrice_anu < F_anu(creationTime)
```

Use `Data.Decimal`'s exact mantissa/exponent to scale; never `fromRational`/
`Double`. This is the single most consensus-sensitive line in the change.

---

## 5. Implementation — the change surfaces

### 5.1 Haskell consensus check (the core)

Add `checkGasPriceFloor` to `validateParsedChainwebTx`, the function that already
runs the five block-validation checks in **both** paths:
- `src/Chainweb/Pact/PactService/Pact5/ExecBlock.hs` (`validateParsedChainwebTx`, ~:487)
- `src/Chainweb/Pact/PactService/Pact4/ExecBlock.hs` (the sibling list, ~:250)

```
checkGasPriceFloor tx =
    when (guardEnabled StoaMinGasPrice v cid bh) $
      unless (gasPriceAnu tx >= floorAnu (creationTime tx)) $
        throwError (InsertErrorUndersized ...)   -- or a new dedicated error
```

- It must live on the **block-validation** path, not only the mempool — that is
  the whole point (the current floor's mempool-only placement is the audit gap
  we are closing).
- `floorAnu :: Word64 -> Integer` is the pure §2 function, living in one Haskell
  module (proposed `Chainweb/Version/Stoa/GasFloor.hs` or beside the version).

### 5.2 Mempool alignment

Replace the static `gasPriceMinCheck` (`InMem.hs:439`, `_inmemTxMinGasPrice`)
with the same creation-time floor, fork-gated, so the mempool rejects exactly
what consensus would — no admitting-then-rejecting churn, no dropping-valid.
Pre-fork the behaviour is unchanged (static `1e-8`).

### 5.3 Pact ↔ Haskell sync (the owner's requirement #2)

- Haskell `floorAnu` is **authoritative for consensus**; the Pact
  `UC_MinimumGasPriceANU` is the **client-facing mirror**.
- They must agree on the four constants (`GENESIS-TIME`, `10000`, `400000`,
  `10800`). Put a **pinning test** in the suite that, for a spread of timestamps
  (genesis, tick boundaries, mid-interval, past the cap), evaluates the Pact
  function in the repl/`/local` and asserts it equals `floorAnu`. This test is
  the guarantee that "protocol and coin module stay in sync."

### 5.4 The gas-station fix (CRITICAL — it is broken as written)

`create-xchain-gas-account` (`stoa-genesis-5.pact:35-39`) builds the price guard
by **freezing** the floor at account-creation time:

```lisp
(minimum-stoa-gas-price:decimal (/ (dec (coin.UC_MinimumGasPriceANU)) 1e12))  ; evaluated ONCE
(create-user-guard (util.gas-guards.enforce-below-or-at-gas-price minimum-stoa-gas-price))
```

`create-user-guard` captures its argument **by value**, and
`enforce-below-or-at-gas-price` (`stoa-genesis-3.pact:132`) enforces
`(<= (chain-gas-price) gasPrice)` against that frozen number. So the guard is a
**static ceiling** pinned to the floor-at-creation. Once the consensus rule
requires `price >= current-floor` and the current floor exceeds that frozen
ceiling (already true today), **no gas price can satisfy both** → the gas station
can pay for nothing.

**Fix:** a new **argument-less, dynamic** predicate that reads the live floor at
enforcement time:

```lisp
(defun enforce-at-or-below-current-min-gas-price:bool ()
  (enforce (<= (chain-gas-price) (coin.UC_MinimumGasPriceSTOA))
           "gas price above current minimum"))
```

built with `(create-user-guard (enforce-at-or-below-current-min-gas-price))` —
no captured value, re-reads `UC_MinimumGasPriceSTOA` (block-time) each time.

- Why a ceiling `<= floor` still passes correct txs: consensus makes a valid tx
  pay `>= F(creationTime)`; the guard checks `<= F(blockTime)`; since
  `blockTime >= creationTime` and `F` is non-decreasing, a floor-priced tx
  satisfies both. (Gas station pays minimum-priced redemptions only; priority
  pricing is the user's own gas — acceptable and intended.)
- **Rotation, not recreation.** `stoa-xchain-gas`'s outer guard is
  `enforce-or(ns-admin-keyset, gas-restriction)`, so the admin keyset can
  **rotate** the account's guard to the dynamic one. Ship this as a Pact
  transaction timed to the fork; no genesis change, no new account.
- `kadena-xchain-gas` stays on its legacy `1e-8` guard and is retired from
  cross-chain payouts at the fork (per the intent noted at
  `stoa-genesis-5.pact:83-84`).

### 5.5 Client tooling (the owner's requirement #3, and #4's other half)

- The floor is deterministic, so a wallet **computes `F(creationTime)` locally**
  (four constants + the tx's own creation time) and pre-fills
  `gasPrice = F(creationTime)`, **adjustable upward only**.
- A node query exists already (`UC_MinimumGasPriceANU` via `/local`), useful as a
  convenience, but the *local* computation is the exact one because the Pact
  call returns the floor at the latest *block*-time, which can lag "now" by up to
  one block near a tick boundary.
- Deliver a tiny reference helper (JS/TS + the formula) so wallet authors adopt
  it by copy-paste.

### 5.6 Fork gating

- Add a new `Fork` constructor (proposed `StoaMinGasPrice`) at the **end** of the
  enum in `src/Chainweb/Version.hs`.
- List it **explicitly** in every version's fork table: `ForkNever` for
  mainnet/testnet/development/recapDevelopment, and a **future block height** in
  `Stoa.hs`. Because the table is total (`tabulateHashMap`), a missing entry is a
  build/consensus hazard — and this is exactly the class flagged in the
  `stoa-forkatgenesis-forward-hazard` note.
- **Future height, never past.** A past activation retroactively rewrites gas
  rules for existing blocks → replay recomputes gas → payload hashes move → the
  node rejects its own history. Same discipline as the Chainweb32 / 516,500
  activation; pick the height with the same margin over the live tip.

---

## 6. Test plan

Ordered so the highest-value test comes first.

1. **Gas-station tick-crossing (the regression guard for §5.4).** A cross-chain
   redemption paid by `stoa-xchain-gas`, floor-priced, mined after a tick:
   with the frozen guard it **fails**; with the dynamic guard it **passes**.
   This is the "I hope I wrote it correctly" → "we watched it work" test.
2. **Pact↔Haskell pinning (§5.3).** `floorAnu(t) == UC_MinimumGasPriceANU@t` at
   genesis, each side of a tick boundary, mid-interval, and past the cap.
3. **Consensus accept/reject.** Block with a tx priced below `F(creationTime)`
   → rejected at validation; at/above → accepted.
4. **Creation-time behaviour (requirement #4).** A tx priced at `F(Tc)`, mined
   *after* a tick → **accepted** (not rejected). The property the whole decision
   exists for.
5. **Fork boundary.** Below the fork height the old static rule applies; at/above
   the new rule. Old blocks still replay.
6. **No-float / exact-comparison.** A gas price exactly equal to the floor, and
   one ANU below, at 12-dp precision → accept / reject with no rounding error.

Harness: the in-memory chainweb Pact5 test framework, with a **shrunk
`GAS-PRICE-INTERVAL`** (seconds, not 3h) or manipulated block-creation times so a
test run can actually cross ticks. This rides on the same harness build as the
F-2 proof-of-concept, so building it once serves both.

---

## 7. Rollout — v3.2.1-stoa.3

Not a separate package: the next coordinated release of the fork, bundling three
things released together and gated on the same fork height:

1. **Node** — the consensus check (§5.1) + mempool alignment (§5.2) + the fork
   guard (§5.6). Fork-gated, so upgrading nodes is safe before the height.
2. **Pact transaction** — deploy the dynamic guard predicate (§5.4) and rotate
   `stoa-xchain-gas`, timed to the fork.
3. **Client SDK** — the `F(creationTime)` helper (§5.5).

Client upgrade is **unavoidable**: a consensus minimum means an under-priced
transaction is rejected, so every transaction maker must set
`gasPrice >= F(creationTime)` after the fork. The change per client is tiny
(compute four constants against the creation time). Sequence the fork height to
give wallet authors a window to adopt the helper first.

Same node-upgrade discipline as stoa.2: every node must be on stoa.3 **before**
the fork height or it will stall at the transition (`nodeLatestBehaviorHeight`
being the tell, per `stoachain-node-upgrade-verification`).

---

## 8. Risks & open questions

- **Float creeping into the floor comparison** — the top risk; §4 is the guard
  against it. Enforce integer-ANU comparison in review.
- **Unit mismatch** (seconds vs micros) between the Haskell `creationTime` and
  the Pact `block-time` — caught by the §6.2 pinning test; call it out in review.
- **Gas-station drain vector** — a dynamic ceiling of `<= current floor` means
  the station pays only floor-priced txs; confirm no path lets an attacker make
  it pay `MAX` (400,000 ANU) repeatedly. (Consensus caps price at the floor for
  station-paid txs, so the exposure is bounded, but verify.)
- **Fork-table completeness** — the new `Fork` must be mapped in *every* version
  or the build/consensus breaks. Diff the table before release.
- **Wallet adoption lag** — some transactions will be rejected after the fork if
  their maker did not update. This is inherent to a new consensus minimum;
  mitigate with lead time and a loud heads-up, not code.

---

## 9. Build order

- **Phase 0** — this doc reviewed; confirm the fork name and target height.
- **Phase 1** — pure `floorAnu` + the Pact↔Haskell pinning test (§5.3, §6.2).
  Nothing else can be trusted until these agree.
- **Phase 2** — the dynamic gas guard + rotation transaction + the tick-crossing
  test (§5.4, §6.1). Fix the known-broken thing first, with its regression test.
- **Phase 3** — the consensus check + mempool alignment + fork guard, and the
  accept/reject, creation-time, and fork-boundary tests (§5.1, §5.2, §5.6, §6.3-5).
- **Phase 4** — the client helper (§5.5) and rollout choreography (§7).

STOP after each phase and verify against its tests before the next.
