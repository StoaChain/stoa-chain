# Yin Engine — Client Implementation Handoff

**Audience:** Ouronet UI, Stoa Wallet, and any other transaction constructor.
**Status:** implement now, ship now. Nothing here needs to wait for the fork.
**Target protocol release:** v3.2.1-stoa.3.

---

## 0. The one-paragraph version

StoaChain's minimum gas price stops being a fixed number and becomes a function
of time: it starts at 10,000 ANU and rises by 1 ANU every 3 hours, capped at
1,000,000 ANU. After the fork, consensus rejects any transaction priced below the
floor **as of that transaction's own `creationTime`**. Clients must therefore
compute the floor and set `gasPrice` accordingly. The floor is a **pure function
of one input that the client itself chooses**, so it is computed locally — there
is no endpoint to call and no race to lose.

---

## 1. Why you can ship this before the fork

The rule after the fork is **strictly stricter** than the rule today.

| | lower bound on `gasPrice` | upper bound (gas-station guard) |
|---|---|---|
| **Today (pre-fork)** | `>= 1e-8` (static mempool floor) | `<= F(blockTime)` |
| **After the fork** | `>= F(creationTime)` (consensus) | `<= F(blockTime)` |

`F(t) >= 10,000 ANU = 1e-8` for every `t`, because the formula *starts* at 10,000
and only ever rises. Therefore:

> **Anything that will be valid after the fork is already valid now.**

So there is **no feature flag needed for the price computation**. Ship the new
pricing today; the fork changes nothing for a correctly priced transaction. The
only cost of switching early is paying the true floor instead of the legacy
10,000 ANU — around 15% more gas as of late 2026, and in absolute terms
negligible. (The floor moves 8 ANU per day, so do not hard-code a "today" value
anywhere: compute it.)

This is also why `stoa-xchain-gas` can be wired in as the cross-chain gas payer
**before** the fork. It is already funded and already carries the live-floor
guard.

---

## 2. The formula

```
F(t) = min( 10000 + floor( (t - GENESIS_TIME) / 10800 ), 1000000 )    [ANU]
```

| constant | value | meaning |
|---|---|---|
| `GENESIS_TIME` | `2026-02-23T18:00:00Z` = **1771869600** (unix seconds) | tick 0 |
| `GENESIS_MIN_GAS_PRICE` | `10000` ANU | floor at genesis |
| `MAX_GAS_PRICE` | `1000000` ANU | hard cap (= 1 microSTOA per gas) |
| `GAS_PRICE_INTERVAL` | `10800` seconds (3 h) | one tick |
| unit | 1 STOA = **1e12** ANU | ANU is the smallest unit |

`t` is **unix seconds**, and it is the transaction's own `creationTime` field.

Source of truth: `pact/genesis/stoa/stoa-genesis-4.pact:84-89`
(`UC_MinimumGasPriceANU`, `:412`). The chainweb genesis time in
`src/Chainweb/Version/Stoa.hs:80` is the same instant, by design.

> ⚠️ Do **not** copy these constants from `pact/stoa-coin/new-coin.pact` or from
> `Ouronet/00_StoaSandbox/coin.pact`. Both are stale copies carrying different
> `GENESIS-TIME` values. Only `stoa-genesis-4.pact` is authoritative.

---

## 3. Reference implementation

```ts
export const GENESIS_TIME_S        = 1771869600;   // 2026-02-23T18:00:00Z
export const GENESIS_MIN_GAS_ANU   = 10_000;
export const MAX_GAS_ANU           = 1_000_000;
export const GAS_PRICE_INTERVAL_S  = 10_800;
export const ANU_PER_STOA          = 1_000_000_000_000;  // 1e12

/** Minimum gas price, in ANU, for a transaction created at `creationTimeS`. */
export function minGasPriceAnu(creationTimeS: number): number {
  if (!Number.isInteger(creationTimeS)) throw new Error("creationTime must be integer seconds");
  // Math.floor (NOT Math.trunc), and NO lower clamp: this mirrors the deployed
  // coin module exactly, including its behaviour below genesis. See rule 3.
  const ticks = Math.floor((creationTimeS - GENESIS_TIME_S) / GAS_PRICE_INTERVAL_S);
  return Math.min(GENESIS_MIN_GAS_ANU + ticks, MAX_GAS_ANU);
}

/**
 * Format ANU as the decimal string Pact expects for `gasPrice`.
 * Built by STRING PADDING, never by float division — 11558 -> "0.000000011558".
 */
export function anuToStoaString(anu: number): string {
  if (!Number.isInteger(anu) || anu < 0) throw new Error("anu must be a non-negative integer");
  return "0." + String(anu).padStart(12, "0");
}
```

**Three rules that are not optional:**

1. **Integer arithmetic only.** Never `Math.floor` a float you produced by
   dividing into STOA. Stay in ANU until the very last step.
2. **Never build the decimal with float division.** `11558 / 1e12` in JS gives
   `1.1558e-8`, which serialises as `"1.1558e-8"` — Pact will reject it. Use the
   string padding above. Chainweb caps `gasPrice` at 12 decimal places
   (`defaultMaxCoinDecimalPlaces = 12`, `src/Chainweb/Pact5/Validations.hs:126`),
   which is exactly ANU granularity — that is what makes the on-chain comparison
   exact, so never emit more than 12 places.
3. **Do NOT clamp the lower bound, and use `Math.floor`, never `Math.trunc`.**
   The deployed `coin` module clamps only the UPPER bound, so a pre-genesis
   timestamp yields a value *below* 10,000. Your implementation must reproduce
   that, oddity included — matching the chain everywhere is worth more than being
   tidy in a region that cannot occur. (It cannot occur:
   `assertTxTimeRelativeToParent` bounds a transaction's creation time to within
   its TTL of the parent block, and the maximum TTL is 2 days.) `Math.trunc`
   would round toward zero and diverge below genesis; `Math.floor` matches Pact's
   `floor` and Haskell's `div`.

---

## 4. The flow in a transaction constructor

**Derive the price *from* the `creationTime` you are stamping. Never from a
separate clock read.**

```ts
// 1. Choose creationTime ONCE. This is the value that goes in the tx.
const creationTime = Math.floor(Date.now() / 1000) - 15;   // small backdate, see §5

// 2. Derive the price from THAT value. No network call.
const gasPriceAnu = minGasPriceAnu(creationTime);
const gasPrice    = anuToStoaString(gasPriceAnu);          // "0.000000011558"

// 3. Build the command with both, consistently.
const meta = {
  chainId, sender, gasLimit,
  gasPrice,
  creationTime,
  ttl: 600,
};
```

Why this has no race: consensus will check `gasPrice >= F(creationTime)` using
**the same `creationTime` you just wrote into the transaction**. Both sides
evaluate the same pure function on the same input. There is nothing to be stale
about.

If you instead polled a "current price" endpoint at time `T1` and then stamped
`creationTime = T2 > T1`, you would *manufacture* a race: a tick crossing between
`T1` and `T2` leaves you underpriced and consensus rejects. **Do not poll to
price.**

### Displaying vs pricing — two different jobs

| | how | when |
|---|---|---|
| **Display** ("network minimum: 0.000000011558 STOA") | `/local` dirty-read of `(coin.UC_MinimumGasPriceANU)`, or just `minGasPriceAnu(now)` | refresh on a timer; cosmetic |
| **Pricing** (the `gasPrice` field) | `minGasPriceAnu(creationTime)`, locally | once, at construction |

The `/local` read is still worth doing occasionally as a **live cross-check**: if
the chain's answer ever disagrees with your local formula, something has drifted
and you want to know loudly.

### Previewing a station-paid transaction

Gas-station guards read `gas-price` **and** `gas-limit` out of `chain-data`, and in
a `/local` call `chain-data` reflects the `publicMeta` of the command *you sent* —
not any chain default. A read-only dirty read typically sets a huge placeholder
`gasLimit` (100,000,000 is common), which makes any notional-based station guard
compute a nonsense value and reject.

So when previewing a station-paid transaction:

- use `/local` with **`preflight=true`**, and
- send the **same `gasLimit` and `gasPrice` you will actually submit**.

Otherwise the preview and the chain disagree about whether the station will pay,
and you get "it worked in preview, failed on submit". A plain dirty read is fine
for reading values; it is **not** a valid test of whether a gas station will
cover a transaction.

---

## 5. Backdating `creationTime`, and the gas-station ceiling

The cross-chain gas stations (`stoa-xchain-gas`, and `kadena-xchain-gas` until it
is drained) carry a guard that pays only for transactions priced **at or below**
the floor at *block* time. So a station-paid transaction must satisfy:

```
F(creationTime)  <=  gasPrice  <=  F(blockTime) + headroom
```

Normally `blockTime > creationTime`, `F` is non-decreasing, and pricing at exactly
`F(creationTime)` satisfies both. But chainweb permits `creationTime` to run
**ahead** of the parent block by `defaultLenientTimeSlop = 95` seconds
(`src/Chainweb/Pact5/Validations.hs:256`), while the Stoa block delay is 30
seconds (`src/Chainweb/Version/Stoa.hs:71`). So `creationTime` can legitimately be
up to ~65 s *later* than the block that mines it. If a tick boundary falls in that
window, `F(creationTime) = F(blockTime) + 1` and the station rejects.

Because **95 s ≪ 10,800 s**, at most **one** tick can be crossed. Hence:

- **Protocol side:** the station ceiling carries **+1 ANU** of headroom. That is
  provably sufficient and allows an overpay of 1 part in ~11,558.
- **Client side:** backdate `creationTime` by ~15 s (as in §4). Cheap insurance,
  costs nothing, and it also helps the tx survive normal clock skew.

Do **not** over-price a station-paid cross-chain transaction for priority. The
station pays *minimum-priced* redemptions only; priority pricing is on the user's
own account, from the user's own balance.

---

## 6. Test vectors

Assert these in both codebases. They are the same vectors the protocol-side
pinning test uses, so all implementations are checked against one list.

| `creationTime` (unix s) | UTC | expected ANU | expected `gasPrice` string |
|---|---|---|---|
| 1771869600 | 2026-02-23T18:00:00Z (genesis) | 10000 | `0.000000010000` |
| 1771869601 | genesis + 1 s | 10000 | `0.000000010000` |
| 1771880399 | genesis + 10799 s (last second of tick 0) | 10000 | `0.000000010000` |
| 1771880400 | genesis + 10800 s (first second of tick 1) | 10001 | `0.000000010001` |
| 1788696000 | 2026-09-06T12:00:00Z | 11558 | `0.000000011558` |
| 12463869600 | 2364-12-18T18:00:00Z (cap reached) | 1000000 | `0.000001000000` |
| 14000000000 | well past the cap | 1000000 | `0.000001000000` |
| 1771869599 | one second *before* genesis | **9999** | `0.000000009999` |
| 1771858799 | 10,801 s before genesis | **9998** | `0.000000009998` |

The two tick-boundary rows (10799 / 10800) catch off-by-one errors. The two
pre-genesis rows catch the wrong rounding mode — they are the ones that fail if
you clamp the lower bound or reach for `Math.trunc`. All four are unreachable-or-
boring in production and are exactly the rows people delete. Keep them.

---

## 7. What NOT to wire up

- **`GET /config`** (`src/Chainweb/RestAPI/Config.hs:41`) returns the node's
  `ChainwebConfiguration`, which includes a `minGasPrice` field
  (`src/Chainweb/Chainweb/Configuration.hs:485`). That field is the **static
  legacy mempool floor of `1e-8`**. It is correct today only by coincidence and
  becomes **actively wrong** after the fork — it will keep reporting `1e-8` while
  consensus demands 11,558+. Do not read it.
- **A hardcoded `1e-8`.** Whatever is currently hardcoded in the constructors is
  the thing being replaced.
- **Any "current gas price" poll used to set the price.** See §4.

There is no chainweb REST endpoint that serves the time-varying floor today.

A small **read-only** endpoint is planned that will serve the four constants plus
the current value and an `active` flag. When it lands, use it for **cross-checking
your constants and for display** — never to price a transaction. Pricing stays
local, derived from the `creationTime` you stamp (§4). The endpoint's purpose is
to let you detect drift loudly, and to serve explorers and exchanges that will not
implement the formula themselves.

`/config`'s `minGasPrice` will **not** be changed to report the protocol floor —
it is a per-node mempool knob that must keep round-tripping as configuration, not
a protocol fact. Treat it as unrelated to this document.

---

## 8. Keeping three implementations honest

The floor now exists in **four** places: Haskell (consensus, authoritative),
Pact (`coin.UC_MinimumGasPriceANU`, the on-chain mirror the gas-station guard
reads), your client library, and the **StoaChain Explorer**, which computes the
schedule locally rather than reading it from the chain. They must agree exactly.

That last one is easy to overlook precisely because it is only a display: an
explorer that quietly drifts does not break a transaction, it misinforms every
person who trusts the number. Hold it to the same vectors.

This is handled by a **pinning test**, not by hoping. The protocol-side test
evaluates all three over the §6 vector list and asserts equality. Export your
implementation in a form that test can call, or reproduce the same vectors in your
own suite — either way, the vectors are the contract.

If you ever need to change a constant, all three change together in one release.
They are not independently tunable.

---

## 9. Rollout checklist

- [x] `stoa-ns.stoic-xchain` upgraded to the live-floor guard
- [x] `stoa-xchain-gas` guard rotated
- [x] `stoa-xchain-gas` funded (1000 STOA per chain)
- [ ] Station ceiling gains +1 ANU headroom (§5) — module upgrade
- [ ] Confirm whether the headroom change needs a **re-rotation** or whether a
      module upgrade alone updates the already-created guard *(open — being
      tested in the sandbox harness)*
- [ ] Ouronet UI transaction constructors ship §3 + §4
- [ ] Stoa Wallet transaction constructors ship §3 + §4
- [ ] Both switch the cross-chain gas payer to `stoa-xchain-gas`
- [ ] Pinning test green across Haskell / Pact / client
- [ ] **Then** the v3.2.1-stoa.3 fork activates
- [ ] `kadena-xchain-gas` drained into `stoa-xchain-gas` and retired

Steps 1–3 are done. Everything down to the fork can proceed in parallel and none
of it needs to wait, because of §1.
