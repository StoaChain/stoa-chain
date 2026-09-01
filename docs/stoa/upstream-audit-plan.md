# Upstream audit — plan

**Targets:** `kda-community/chainweb-node` and `kda-community/pact-5`, latest tagged releases
**Purpose:** produce a findings report we can hand to the upstream maintainers
**Status:** PLAN ONLY. No audit work has started. Nothing here is a finding.

---

## 0. Scope and size

| | files | lines |
|---|---|---|
| chainweb-node `src/ node/ cwtools/ libs/` | 260 | 67,909 |
| pact-5 | 162 | 64,912 |
| chainweb test suite | 84 | 30,069 |

~133k lines of Haskell. Pact is in scope because it is inseparable from
chainweb in practice: a Pact evaluator bug reaches every contract on every
chain running it, and SC-2 was exactly that.

### What we can and cannot do — read this before believing any output

**Can:** read and reason about any bounded region; sweep the whole tree for a
stated pattern; trace call sites and data flow; generate adversarial
hypotheses; validate a candidate finding against source.

**Cannot:** hold 133k lines in one context; formally verify; fuzz at scale;
guarantee completeness.

**Therefore the audit is exactly as good as its hypotheses.** This plan is
hypothesis-first for that reason, and the report must say so plainly. An audit
that implies exhaustiveness it does not have is worse than no audit.

### The Bitcoin Core comparison does not transfer

Reports of "AI found 5,000+ vulnerabilities in Bitcoin Core" are about C++.
The overwhelming majority of that class is memory safety: buffer overflows,
use-after-free, integer overflow, null dereference. Haskell has essentially
none of it — no manual memory, no pointer arithmetic, `Word` saturates rather
than wrapping.

What is left here is **logic, consensus and economic** bugs. Those are the
class a generic scanner is worst at and a stated hypothesis is best at.

**Volume is an anti-goal.** Handing maintainers 5,000 unvalidated findings
destroys the only asset we have, which is that our numbers are checkable. One
well-evidenced finding beats a thousand maybes.

---

## 1. Disclosure protocol — agreed before any work starts

Kadena mainnet is a live chain securing real value.

1. **Nothing is published while unfixed.** No article, no Telegram, no commit
   message, no public repo issue.
2. Findings rated `SC`, `C` or `H` go to the maintainers **privately** first.
3. They get a reasonable window. We do not set a public deadline unilaterally.
4. Publication only once fixed, or with their explicit agreement.
5. `M` and `L` findings and all Observations can be shared openly, but still
   go to them before anywhere else.
6. Work happens on a **private** branch. The report is not committed to a
   public repo until cleared.

Deciding this now, rather than in the excitement of a discovery, is the point.

---

## 2. Output format

Two structurally separate tracks. **Never mix them in one section** — mixing
lets a reader dismiss a defect as opinion.

### Findings — defects

Every finding must carry all five, or it does not go in the report:

1. **What** — the defect, one sentence
2. **Where** — file and line, in the tagged release
3. **Failure scenario** — concrete inputs or state producing a wrong result,
   a crash, or a loss. Not "could theoretically"
4. **Evidence** — quoted source, and any measurement performed
5. **Verdict** — CONFIRMED or PLAUSIBLE, from adversarial validation (§4)

Severity uses the same scale as our 3.2 audit:

| | |
|---|---|
| `SC-` | theft of funds by any attacker, no privilege needed |
| `C-` | total compromise of a security property, from a privileged position |
| `H-` | denial of service, consensus risk, availability |
| `M-` | bounded correctness, liveness, hygiene |
| `L-` | minor |

### Observations — improvements, not defects

Performance, hardening, ergonomics, clarity. **No severity rating** — a
severity implies a defect, and these are not.

Each carries: what, why it might be better, **and the tradeoff or reason the
current design may be deliberate**. If we cannot state the counter-argument we
do not understand it well enough to raise it.

These are explicitly labelled as opinion. The maintainers know their design
constraints and we do not. That framing costs us nothing and makes the
Findings track more credible by contrast.

---

## 3. Phases

Each phase: **hypothesis → sweep → adversarial validation → record**. Stop and
report between phases. Do not start the next until the previous is written up.

### Phase 0 — scaffolding
Pin the exact commits under audit. Create the master document. No analysis.

### Phase 1 — mempool-versus-consensus asymmetry *(start here)*

> **Hypothesis:** checks exist that are enforced at mempool admission but not
> at block validation, so a miner can simply decline to apply them.

We already have **two confirmed instances** and neither was found by looking
for the pattern:

- the 100-signature cap (`assertSigSize` — reachable only from
  `assertPreflightMetadata` and the mempool pre-insert check)
- the gas price floor (`_inmemTxMinGasPrice`, node config, mempool only)

Method: enumerate every check in `Pact5/Validations.hs`, `Mempool/InMem.hs`,
the `preInsert` path and `Chainweb.hs`, then determine for each whether it is
reachable from `execValidateBlock`. Anything that isn't is a candidate.

Narrow, cheap, and if it turns up a third instance the whole exercise pays for
itself. If it comes back empty that is a real result too.

### Phase 2 — axiom audit *(the highest-value phase)*

> **Hypothesis:** the codebase asserts invariants that nothing enforces, and
> nobody tests them because everyone believes them.

**This is the SC-2 class.** Capability scoping was held as bedrock by every
Pact developer alive, which is precisely why no test existed. The bug was
found by something that did not share the assumption.

Concrete places assumptions are written down:

- `error "..."` calls — every one is a claimed impossibility
- irrefutable patterns and partial functions: `Just x <-`, `head`, `fromJust`,
  incomplete `case`
- comments containing "cannot", "never", "always", "guaranteed", "must be",
  "safe because", "by construction"
- properties enforced in **one** place but relied upon in **many** — SC-2's
  exact shape, and the hardest to see

For each: state the invariant, then try to construct a state that violates it.

### Phase 3 — gas, metering, economics
Already visibly under-examined. We found that `/local` under-reports size cost
entirely, that the seventh-power penalty does not bound block data (100 bytes
per gas, flat, below 50 KiB), and that a WAI transport constant is what
actually caps block size. Look for other places the meter and the resource
diverge.

### Phase 4 — SPV and cross-chain
Three findings already from a partial look: the proof-expiry fund-destruction
path, compacted nodes unable to *create* proofs, and an uncaught
`TreeDbAncestorMissing` that can fork a node off. Finish the sweep.

### Phase 5 — Pact evaluator core
Capabilities, guards, module boundaries, defpacts, the CEK and Direct
evaluators. Highest payoff, hardest target. **Both evaluators must be checked
for every finding** — SC-2 needed fixing in each.

### Phase 6 — synthesis
Deduplicate, rank, write recommendations, produce the maintainer-facing report.

---

## 4. Adversarial validation — non-negotiable

Every candidate finding gets independent validators whose job is to **refute**
it, not confirm it. Default to REFUTED when uncertain.

Rules:
- A finding a validator cannot reproduce from the stated scenario does not ship
- Disagreement is recorded, not resolved by majority alone
- `SC` and `C` findings need a working demonstration or an explicit statement
  that none was constructed

This is what made the 3.2 audit worth reading, and it is where most of the
cost goes. **Budget accordingly: validation is the product, not the sweep.**

---

## 5. The master document

Single file, the deliverable. Must state:

- **Exact commits audited** — full SHAs and tags for both repos, plus dates
- **What was and was not examined**, by subsystem, honestly
- **Method** per phase, including the hypothesis
- **Findings**, severity-ordered, each with the five required elements
- **Observations**, separately, labelled as opinion
- **What we got wrong** — every withdrawn candidate and why

That last section is not humility, it is the credibility mechanism. Our 3.2
audit published three of our own errors and it is the reason the rest was
believed.

---

## 6. Cost control

- Phase gate: report and stop after each phase
- Kill a hypothesis early if the first pass is empty; do not keep digging
  because it felt promising
- No blanket file-by-file sweeps. Every agent gets a stated question
- Prefer one deep validated finding to ten unvalidated candidates

---

## 7. Open decisions

1. **Both repos or chainweb first?** Recommendation: Phase 1 on chainweb
   alone as a pilot, then decide with real cost data in hand.
2. **Do we tell the maintainers we are doing this?** Recommendation: yes,
   before starting. It costs nothing, and turning up unannounced with findings
   reads worse than announcing intent.
3. **Where does the report live?** Recommendation: private repo until cleared.
