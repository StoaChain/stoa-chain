# Design note — scaling ANU precision as STOA appreciates

**Status:** design only. Nothing here is implemented, and nothing needs to be
for a long time. This exists so that whoever pulls the trigger — possibly
decades from now — inherits the reasoning and, more importantly, the one hazard
that would otherwise brick the chain.

**Decision recorded:** if STOA appreciates enough that gas becomes expensive in
real terms, the response is to **increase decimal precision**, not to lower the
Yin engine's constants.

---

## 1. The problem this solves

```
real cost of computation  =  (floor in STOA)  ×  (real value per STOA)
```

The Yin engine schedules the first factor upward. If StoaChain succeeds at the
scale it is aimed at, the second factor also rises — potentially by orders of
magnitude. The two compound.

Concretely, a 700-gas transfer at the 1,000,000 ANU ceiling:

| value per STOA | cost of that transfer |
|---|---|
| $1 | $0.0007 |
| $1,000 | $0.70 |
| $1,000,000 | **$700** |

The ceiling is not reached until 2364, so this is not urgent. But the direction
is real: **the engine assumes the token's real value is roughly stable, and the
project's thesis is that it will not be.**

---

## 2. Two ways to fix it, and why precision wins

Both make gas cheaper in real terms. They are economically equivalent — the
payer sends the same STOA either way. They differ entirely in what they cost to
execute and what they preserve.

### Option A — lower the Yin constants

Divide `GENESIS-MIN-GAS-PRICE` and `MAX-GAS-PRICE` by 10.

*Cost:* two constants in the coin module, two in `GasFloor.hs`. Contained, and
reversible in either direction.

*But it damages the schedule.* 10,000 → 1,000,000 is 990,000 steps at one per
3 hours, which is 339 years. 1,000 → 100,000 is 99,000 steps — the same 3-hour
rate now exhausts the range in **34 years**, not 339. To preserve the span you
must also stretch the interval to 30 hours, which costs 90% of the granularity
and makes the schedule progressively coarser with every adjustment. Repeat it a
few times and the "1 ANU every 3 hours" mechanism no longer exists.

### Option B — increase precision *(chosen)*

Raise `MINIMUM_PRECISION` from 12 to 13. One STOA now divides into 1e13 ANU
instead of 1e12, so an ANU is worth ten times less.

*What it preserves:* **the Yin engine is untouched.** The floor still runs
10,000 → 1,000,000 ANU at 1 ANU per 3 hours over 339 years. The ANU curve stays
monotonic forever — it never resets, never slows, never gets re-based. The
granularity is identical. The only thing that changes is what an ANU is worth.

That is a genuine property and not merely cosmetic: the engine's promise is
"the floor in ANU only ever rises, on a fixed schedule". Option A breaks that
promise every time it is used. Option B never does.

*What it costs:* more surface, listed in §4 — including a chainweb consensus
constant and every client.

### The trade, stated honestly

Option B is **coarse and one-way**: adjustments come only in 10× steps, and a
precision increase can never be undone. Option A is continuous and reversible.

That is a real disadvantage, accepted deliberately. The reasoning: adjustments
of this kind are expected to be rare (once a century or less), the direction is
predictable (value up, so precision up), and preserving the engine's schedule
across centuries is worth more than fine-grained tuning.

---

## 3. THE HAZARD — precision must be height-gated, not bumped

**This is the part that matters. Everything else is bookkeeping.**

`STOA_PREC` is used as a rounding argument throughout the coin module:

```lisp
(floor amount STOA_PREC)
```

Including inside emission (`stoa-genesis-4.pact:387`):

```lisp
(floor (/ yearly-stoa-supply (dec yearly-blocks-total)) STOA_PREC)
```

That is a **division**, which produces more decimal places than its inputs.
`floor(x, 12)` and `floor(x, 13)` give **different results** for such a value.

So if `MINIMUM_PRECISION` is simply raised from 12 to 13:

1. A node replaying a block from 2027 recomputes that block's emission to 13
   places, where it was originally computed to 12.
2. The minted amount differs.
3. Balances differ, the state hash differs.
4. **The node rejects its own history.**

This is the same failure class as gating a consensus fork at genesis, and it is
harder to spot because nothing about `(defconst MINIMUM_PRECISION 13)` looks
dangerous.

### The fix

Precision must be a **function of block height**, gated at the activation
height, so that replaying any historical block reproduces the precision in force
at the time:

```lisp
(defconst PRECISION-13-HEIGHT  <future height>)

(defun UC_Precision:integer ()
    @doc "Decimal precision in force at the current block height. HEIGHT-GATED \
        \ ON PURPOSE: rounding with a different precision than a block was \
        \ originally computed with changes emission amounts and breaks replay."
    (if (>= (at "block-height" (chain-data)) PRECISION-13-HEIGHT) 13 12))
```

Every `(floor x STOA_PREC)` becomes `(floor x (UC_Precision))`, and
`precision()` returns `(UC_Precision)`.

**Verify with a read-only replay before shipping**, exactly as was done for the
Yin engine: run the full chain under the new binary and confirm it still
validates, then run it with the gating deliberately removed and confirm it
*fails*. A test that cannot fail proves nothing.

---

## 4. Full blast radius

| where | change | safe on its own? |
|---|---|---|
| coin module | `STOA_PREC` → height-aware `UC_Precision`; ~10 call sites; `precision()` | **NO — see §3** |
| coin module | the `1e12` divisor in `UC_MinimumGasPriceSTOA` | yes |
| chainweb | `defaultMaxCoinDecimalPlaces` → fork-gated, in `Pact4/Validations.hs`, `Pact5/Validations.hs`, `InMem.hs` | yes (more permissive) |
| chainweb | new `Fork` constructor per precision step; entry in **every** version table | see the `StoaMinGasPrice` precedent |
| Yin engine | `anuPerStoa`, the `× 1e12` scaling, `Decimal 12` → height-aware | yes |
| clients | `ANU_PER_STOA`, decimal-string padding | yes, but must be coordinated |
| ecosystem | `precision()` is a `fungible-v1` interface function — exchanges, bridges and wallets read it | additive, so integrations assuming 12 keep working |

Raising an allowance is always the safe direction: transactions valid under 12
places remain valid under 13. Only the **rounding** is dangerous, and only
because it is used on divided values.

---

## 5. The trigger is a human decision, and that is fine

The chain cannot observe a dollar price. Any on-chain threshold
("when STOA exceeds $1,000 for seven years") requires an oracle, which means
inserting a trusted third party into consensus. That is not a coding problem
that cleverness solves; it is an information barrier.

The workable split is the one every fork already uses: **observe off-chain,
schedule on-chain.** Watch the price for as long as you like, then schedule a
precision fork at a future block height. The chain never needs to know why.

Worth writing the criterion down when it is chosen, so the decision is
reviewable rather than discretionary — e.g. *"sustained above $X for N years,
measured as Y"*. The criterion is policy; the mechanism is arithmetic.

---

## 6. The cheap thing to do now

**Clients should read `coin.precision()` rather than hardcoding 12.**

It costs nothing today, while the wallet teams are already in this code for the
Yin engine rollout. It converts a future precision change from an
ecosystem-wide coordination problem into a fork that clients follow
automatically.

Everything else in this note can wait until it is needed.
