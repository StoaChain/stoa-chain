# Stoic Digest handoff — the Yin Engine

**For:** whoever writes the Yin Engine section of the Economy & Tokenomics article.
**Status:** ships as `v3.2.1-stoa.3`. Client-side behaviour is **already live**;
protocol enforcement begins at **block 600,000**.
**Purpose of this file:** give the writer every number, date and claim in a form
that can be quoted directly, so nothing has to be reconstructed or invented.

---

## 1. Where this fits in the article

The article's arc is the economy of the chain. The Yin Engine is the closing
move, and it only reads as a closing move if the *other* half is set up first.

**The pairing, in one sentence:** emission thins toward a permanent trickle on a
fixed schedule, and the minimum fee rises on a fixed schedule — two curves set
before the first block, moving in opposite directions, with nobody deciding
anything.

**Yang — emission.** Computed by `coin.UC_YearEmission`, a closed-form function
of the chain's year:

```
emission(t) = (500,000 t² + 99,500,000 t + 47,916,000,000) / ((t + 99)(t + 100))
```

| chain year | emission that year | supply | inflation |
|---|---|---|---|
| 0 | 4,840,000 STOA | 16,000,000 | 30.25% |
| 10 | 4,083,486 | 60.8M | 6.71% |
| 100 | 1,579,548 | 284.1M | 0.56% |
| 338 *(the year Yin caps)* | 724,476 | 520.7M | 0.139% |
| 1000 | 535,541 | 910.9M | 0.059% |
| → ∞ | **500,000** | grows without bound | **→ 0%** |

Emission **never reaches zero**. It decays asymptotically to a permanent
500,000 STOA per year — a tail emission. Because supply keeps growing while the
tail stays flat, the *inflation rate* tends to zero even though issuance never
stops. Security stays funded forever without the supply ever being capped.

**Yin — the fee floor.** Rises 10,000 → 1,000,000 ANU/gas over ~339 years.

> ⚠️ **Do not use `rewards/miner_rewards.csv` for this section.** It is present
> for interface compatibility only and shows a schedule decaying to zero at
> block 127,278,720. StoaChain does not use it: `coin.coinbase` explicitly notes
> the passed amount is "kept for csv read compatibility" and computes the real
> figure via `URC_Emissions` → `UC_YearEmission`. Quoting the CSV would state
> the tokenomics backwards.

> ⚠️ **Confirm before publishing:** the coin contract itself refers to "Yang
> Emissions" (`stoa-genesis-4.pact:1411`), so the pairing is the project's own
> language, not my inference. Still worth stating formally in the article what
> Yang covers.

---

## 2. What the Yin Engine actually is

The minimum price of gas is no longer a constant. It is a function of time:

```
minimum gas price = 10,000 ANU  +  1 ANU for every 3 hours since genesis
                    (capped at 1,000,000 ANU)
```

That is the whole mechanism. Some framings that are accurate and worth using:

- **It is arithmetic, not policy.** No oracle, no price feed, no governance
  vote, no multisig, no discretion. Anyone can compute the floor for any instant
  — past or future — on paper, offline, without asking the network.
- **It was always predictable.** The schedule was fixed at genesis in
  February 2026. Nothing about it is being decided now; what is being added is
  *enforcement*.
- **It rises slowly enough to be invisible and fast enough to matter.**
  8 ANU per day. 2,920 ANU per year. A 100× increase, but spread over three
  centuries.
- **The cap is a promise.** 1,000,000 ANU is exactly **one microSTOA per unit of
  gas**. The protocol is committing that the minimum will never exceed that,
  ever. Worth stating as a ceiling on the commitment, not just a technical bound.

### Why a rising floor at all

The honest economic argument, in plain terms: a minimum fee fixed in token units
only stays meaningful if the token's value stays flat. If STOA appreciates, a
fixed floor silently becomes cheaper and cheaper in real terms, and the cost of
flooding the chain falls with it. A floor that rises on a schedule is a way of
saying "the cost of consuming shared capacity does not drift toward zero" —
without anyone having to intervene, and without pretending to know what STOA
will be worth.

The counterpart to that: it is a **floor**, not a price. It sets what you cannot
go below. It does not set what you pay in a busy block, and it does not cap
anything.

### The obvious objection, and the answer

A reader who follows the argument will immediately ask: *if STOA becomes
enormously valuable, doesn't a rising fee floor make the chain unusable?*

It is a fair question and it deserves a straight answer in the article, because
the answer is good.

The floor is denominated in **ANU**, the smallest unit of STOA — currently one
trillionth. If STOA appreciates far enough that gas becomes expensive in real
terms, the response is to **increase the precision**: make one STOA divide into
ten trillion ANU instead of one trillion. An ANU becomes worth ten times less,
so the same floor costs ten times less to pay.

What makes this the right lever rather than a patch is what it *doesn't* touch:

> **The Yin engine itself never changes.** The floor still runs 10,000 →
> 1,000,000 ANU, still rises by exactly 1 ANU every three hours, still takes
> the same 339 years. The curve is never re-based, never slowed, never reset.
> Only the size of the unit changes underneath it.

The alternative — cutting the floor's constants — would work economically but
would break the schedule every time it was used: dividing the range by ten
either exhausts it in 34 years instead of 339, or forces the interval from
3 hours to 30 and throws away nine tenths of the granularity. Precision costs
none of that.

So the honest framing for readers is: **the schedule is permanent; the unit is
scalable.** The promise that the floor only ever rises, on a fixed schedule,
survives any amount of appreciation — because appreciation is absorbed by the
denomination, not by the engine.

Two caveats worth stating rather than glossing:

- It is **one-way and coarse** — precision can only increase, in factors of ten.
  That is a deliberate trade for keeping the schedule intact.
- The **trigger is a human decision**, not an automatic one. The chain cannot
  observe a market price without an oracle, and an oracle would be a trusted
  third party inside consensus. So the criterion is watched off-chain and the
  change is scheduled on-chain at a future block — the same way every other fork
  works, including this one.

Design note with the full mechanism, including the replay hazard that makes it
non-trivial to implement: `docs/stoa/precision-scaling-design-note.md`.

---

## 3. The state of play — the bit readers most need to get right

This is the message that must not blur, because it is the thing people will
mis-read:

> **The ANU floor is already being applied by the wallets and the UI. It is
> not yet enforced by the protocol. Enforcement begins at block 600,000.**

Concretely:

- **Now:** Ouronet UI and the Stoa wallets construct transactions priced by the
  new formula. Transactions already carry the rising floor. Nothing rejects a
  transaction that does not.
- **At block 600,000:** the network itself begins rejecting transactions priced
  below the floor. From then on it is consensus, not convention.
- **The explorer** now surfaces the schedule directly. The dashboard carries a
  **GAS FLOOR** panel showing the live floor in ANU (11,568 at time of writing),
  a progress bar through the 990,000-step schedule, and a countdown to the next
  +1 ANU step. Hovering opens the full schedule: where it is now, when it next
  moves and to what, the ceiling with its date and the steps remaining, and the
  rule itself stated plainly — *from 10,000 ANU at 2026-02-23 18:00 UTC, then
  +1 ANU / 3h*.

  Worth noting for the article, because it is the honest version of the claim:
  the explorer computes the schedule **locally** and says so on the panel
  ("no chain read"). It is not reporting a number the chain told it; it is
  independently computing the same arithmetic and arriving at the same answer.
  A reader can do the sum themselves and check it.

Two consequences worth spelling out for readers:

1. **Nothing breaks before 600,000.** Everything valid today stays valid. The
   new pricing was deliberately designed to be *stricter* than the old rule, so
   a client can adopt it early and be correct under both regimes. That is what
   made it safe to ship the wallets ahead of the protocol.
2. **Wallets must be updated before 600,000.** After that height, a client still
   paying the old flat minimum will have its transactions rejected. This is the
   one genuine call to action in the section, and it should be unambiguous.

---

## 4. Numbers you can quote

| | |
|---|---|
| Unit | 1 STOA = **1,000,000,000,000 ANU** (1e12) |
| Genesis of the schedule | **2026-02-23 18:00:00 UTC** |
| Starting floor | **10,000 ANU** = 0.00000001 STOA |
| Rate | **+1 ANU every 3 hours** (8/day, 2,920/year) |
| Cap | **1,000,000 ANU** = 0.000001 STOA = 1 microSTOA per gas |
| Cap reached | **2364-12-18** (990,000 steps) |
| Enforcement begins | **block 600,000** |
| Release | **v3.2.1-stoa.3** |

**Floor at time of writing (2026-09-07): 11,568 ANU.** Recompute at publication —
it moves 8 per day. Anyone can check it live by reading
`coin.UC_MinimumGasPriceANU` on chain.

Two illustrative costs, useful for grounding the scale:

- A simple transfer (~700 gas) costs about **0.0000081 STOA** at today's floor,
  and **0.0007 STOA** if the cap is ever reached in 2364.
- The floor has risen **15.7%** since genesis — from 10,000 to 11,568 ANU — over
  roughly six and a half months.

---

## 5. How it was verified

Worth a short passage. The credibility of a consensus change is the testing, and
this one has an unusually concrete story.

- **The floor exists in four independent implementations** — the node (Haskell),
  the on-chain `coin` contract (Pact), the client libraries, and the explorer.
  All four must agree exactly; if two nodes computed different floors the chain
  would split, and an explorer that drifted would quietly misinform everyone
  reading it. A *pinning test* runs the same nine timestamps through the node and
  the on-chain contract and asserts identical answers.
- **The whole chain was replayed.** Every block StoaChain has ever produced —
  550,567 blocks across 10 chains — was re-executed under the new software to
  confirm it agrees with all existing history. The fork changes nothing that has
  already happened.
- **The tests were checked for the ability to fail.** A deliberately
  mis-configured build, with enforcement backdated to the beginning of the chain,
  was replayed and confirmed to *fail* — rejecting a genuine historical
  transaction. A test that cannot fail proves nothing, so this was run
  explicitly.
- **The transition itself was mined.** A test network was run through the
  activation height and observed changing behaviour at exactly the right block:
  the old pricing accepted before, rejected after, and correct pricing working on
  both sides.

If the section needs one line on this: *"the change was verified by replaying
every block the chain has ever produced, and by proving the tests could fail
before trusting them when they passed."*

---

## 6. Things to get right

- **"Floor", not "fee" or "price".** It is a minimum. Saying "gas now costs
  more" is wrong; saying "gas cannot cost less than" is right.
- **ANU, not STOA, for the floor.** The floor is a whole number of ANU. Writing
  it in STOA produces long decimals and invites rounding errors.
- **The schedule is not new; the enforcement is.** The formula has been on chain
  and computable since genesis.
- **Don't call it inflation or a fee increase.** It is a lower bound on the cost
  of consuming shared capacity, rising on a schedule fixed in advance.
- **Don't imply it responds to congestion or market price.** It does neither. It
  responds only to the clock. That is the point.

### Out of bounds

**Nothing from the upstream chainweb/Pact security audit may appear in this
article, in any form.** That work is confidential and unrelated to the Yin
Engine narrative. If the writer needs a "how do we know the code is sound"
angle, use the verification story in §5, which is entirely about StoaChain's own
code and entirely publishable.

Also avoid describing the gas-station guard work done alongside this. It is
StoaChain's own infrastructure and it is fixed, but it is operational detail
that adds nothing to a tokenomics piece and invites questions the article is not
trying to answer.

---

## 7. Suggested shape for the section

1. **The problem** — a fee minimum fixed in token units decays in real terms.
   Most chains solve this with governance. Governance is discretion.
2. **The answer** — put it on the clock. +1 ANU every three hours, capped,
   fixed at genesis, computable by anyone forever.
3. **Closing the loop** — pair it with the emission curve. Rewards fall to zero;
   the floor rises. Security funding hands off from issuance to fees on two
   schedules that were both set before the chain produced its first block.
4. **Where we are** — live in the wallets, enforced at block 600,000, visible in
   the explorer. Update your wallet.
5. **How we know it works** — §5, briefly.

The strongest line available is probably the handoff itself: **two curves fixed
at genesis, one falling and one rising, that between them decide how the chain
pays for its own security for the next three hundred years — with nobody
deciding anything.**

---

## 8. Open items for the writer

- Confirm the formal definition of **Yang** (§1).
- Recompute the **current floor** at publication time (§4).
- Decide whether to publish the activation **date** alongside the block height.
  600,000 is roughly 2026-09-25, but block heights drift; a date will be
  approximate and may need hedging as "around".
