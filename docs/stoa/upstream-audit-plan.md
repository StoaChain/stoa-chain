# Upstream audit — plan

**Targets:** `kda-community/chainweb-node` and `kda-community/pact-5`, latest tagged releases
**Purpose:** a findings report we can hand to the upstream maintainers
**Status:** PLAN ONLY. No audit work has started. Nothing here is a finding.

---

## 0. Scope and size

| | files | lines |
|---|---|---|
| chainweb-node `src/ node/ cwtools/ libs/` | 260 | 67,909 |
| pact-5 | 162 | 64,912 |
| chainweb test suite | 84 | 30,069 |

~133k lines of Haskell. Pact is in scope because it is inseparable in
practice: a Pact evaluator bug reaches every contract on every chain running
it, and SC-2 was exactly that.

### What we can and cannot do — read this before believing any output

**Can:** read and reason about any bounded region; sweep the whole tree for a
stated pattern; trace call sites and data flow; generate adversarial
hypotheses; validate a candidate against source.

**Cannot:** hold 133k lines in one context; formally verify; fuzz at scale;
guarantee completeness.

**The audit is exactly as good as its lenses.** This plan is lens-first for
that reason, and the report must say so. An audit that implies exhaustiveness
it does not have is worse than no audit.

---

## 1. Why Haskell changes what we are looking for

Reports of "AI found 5,000+ vulnerabilities in Bitcoin Core" are about C++.
That class is overwhelmingly memory safety: buffer overflow, use-after-free,
double-free, null dereference, uninitialised reads, type confusion.

**Haskell deletes that entire category.** No manual memory, no pointer
arithmetic, no null (`Maybe` instead), immutability by default, STM rather
than shared mutable state. Kadena did not pick Haskell by accident, and the
choice paid: it removed the bugs that fill most audit reports.

**But it does not remove logic bugs, and it introduces its own hazards.** The
empirical case is our own 3.2 audit — fourteen findings, and **not one was a
memory bug**:

| finding | actual class |
|---|---|
| SC-1 identity forgery | logic — keyed on the wrong field |
| SC-2 capability theft | logic — a guard omitted on one path |
| H-1 / H-2 / H-4 unmetered size, CPU, proofs | metering diverging from real cost |
| H-3 cut-queue flood | **`Ord`/`Eq` semantics** — equal cuts compare `EQ`, a heap admits duplicates |
| M-1 defpact continuations | a missing check |
| the SPV proof-creation failure | **partial function** — irrefutable `Just x <-` |
| the compacted-node fork-off | **uncaught exception** — `TreeDbAncestorMissing` caught nowhere |

That is the real target list. The lens set below is built from it, not from a
generic checklist.

### What Haskell does *not* protect against

1. **Partial functions.** `head`, `fromJust`, `!!`, incomplete `case`,
   irrefutable `Just x <-`. These throw at runtime and **the type system does
   not catch them.** Already burned us once.
2. **`error` calls.** An explicit escape hatch. Every one is a claimed
   impossibility — `atNotGenesis` would `error` on every block if
   `MigratePlatformShare` were adopted against our fork table.
3. **`Int` silently wraps.** `Int` is fixed-width 64-bit; `Integer` is
   arbitrary precision. `fromIntegral` between them is a classic bug site, and
   anywhere an attacker influences the value it is a candidate.
4. **Hand-written `Ord`/`Eq` instances.** Break a law and every ordered
   container built on it misbehaves. `ForkHeight` has a hand-written `Ord`;
   `PQueue` — the site of H-3 — was a heap keyed on one.
5. **Laziness.** Unbounded thunk accumulation is a memory-exhaustion DoS that
   looks like nothing in the source. Exceptions inside pure code surface at
   unpredictable points.
6. **Exceptions crossing abstraction boundaries** with no handler anywhere.
7. **`unsafePerformIO` / `unsafeCoerce`** — explicit escapes from every
   guarantee above.
8. **Rational → integer conversion.** The gas model computes in exact
   `Rational` and then `ceiling`s. Precision boundaries are where money bugs
   live.

---

## 2. How we use nectar

**Keep the machinery, replace the lens library.**

`nectar:audit`'s stock lenses are web-app shaped — OWASP top 10, N+1 queries,
missing indexes, bundle size, accessibility, dead endpoints. Against a Haskell
consensus node most of those produce noise or nothing. Running the skill
unmodified would be the "5,000 findings" mistake in a different costume.

What we keep, unchanged, because it is exactly right:

- **`nectar:lens` agents** — read-only by construction, so "no fixes" is
  enforced rather than requested. One lens per agent, dispatched in parallel,
  each with its own entry-point list. Never one generic list for all.
- **`nectar:validator` agents** — fresh context that did not author the
  finding, actively trying to refute it.
- **The finding format** — Where / Evidence / Why it matters / Suggested fix,
  with evidence as quoted code, never a paraphrase.
- **Dedup with agreement as a confidence signal** — two lenses independently
  hitting the same defect matters.
- **Lean REFUTED when ambiguous**, and **a finding without quotable evidence
  is REFUTED by definition.**
- **Disclose the REFUTED count.** The kill rate is what makes the survivors
  credible.
- **Audits never mutate.** The report is the only artefact.

What we replace: the ten stock lens scopes, with the eleven below.

Severity uses our own scale (`SC`/`C`/`H`/`M`/`L`) rather than nectar's
CRITICAL→LOW, for continuity with the 3.2 report and because `SC` — theft by
any attacker, no privilege — is a distinction the stock scale cannot express.

---

## 3. The lens set

Eleven lenses. Each states its hypothesis, its entry points, and **the
evidence that it is productive** — a finding we already hold in that class.
A lens with no prior evidence is speculative and ranked last.

### L1 · Mempool-versus-consensus asymmetry
> Checks enforced at mempool admission but not at block validation, so a miner
> can decline to apply them.

**Evidence: two confirmed instances, both found by accident.** The
100-signature cap (`assertSigSize`, reachable only from
`assertPreflightMetadata` and mempool pre-insert) and the gas price floor
(`_inmemTxMinGasPrice`, node config only).

**Entry points:** `Pact5/Validations.hs`, `Pact4/Validations.hs`,
`Mempool/InMem.hs`, `Chainweb.hs` (`validatingMempoolConfig`),
`PactService/Pact5/ExecBlock.hs`.
**Method:** enumerate every check; for each, determine reachability from
`execValidateBlock`. Anything unreachable is a candidate.

### L2 · Axiom audit — invariants nothing enforces
> The codebase asserts properties that nothing checks, and nobody tests them
> because everyone believes them.

**Evidence: SC-2.** Capability scoping was bedrock to every Pact developer
alive, which is exactly why no test existed.

**Where assumptions are written down:**
- every `error "..."` — a claimed impossibility
- partial functions: `head`, `fromJust`, `!!`, `Just x <-`, incomplete `case`
- comments containing *cannot*, *never*, *always*, *guaranteed*, *must be*,
  *safe because*, *by construction*
- **properties enforced in one place but relied on in many** — SC-2's shape,
  and the hardest to see

For each: state the invariant, then construct a state that violates it.

### L3 · Partial functions and exception escape
> A runtime throw the type system cannot see, with no handler anywhere.

**Evidence:** `CreateProof.hs:264,384` irrefutable `Just x <-` → pattern-match
failure and opaque 500s; `TreeDbAncestorMissing` thrown and **caught nowhere
in the tree**.

**Method:** enumerate every partial application and custom exception; trace
whether any handler exists on the path to a node's top level.

### L4 · Numeric, precision and conversion
> `Int` wraps, `fromIntegral` truncates, `Rational → ceiling` rounds, and
> money lives at those boundaries.

**Evidence:** the gas model is `Rational` throughout with a single `ceiling`
at the end; `Gas` wraps `SatWord` wraps `Word` — saturating, not wrapping,
which is a deliberate choice worth verifying holds everywhere it is assumed.

**Method:** every `fromIntegral`, `truncate`, `floor`, `ceiling`, `round`,
`div`, `Int` in a path an attacker can influence.

### L5 · `Ord` / `Eq` law violations and their consumers
> A hand-written instance that breaks a law, used inside an ordered container.

**Evidence: H-3 is exactly this.** `PQueue` was a heap of `Down CutHashes`;
equal cuts compare `EQ`; a heap admits duplicates; the queue filled with
copies of one attacker cut. `ForkHeight` also carries a hand-written `Ord`
where `ForkAtGenesis = minBound` — the trap that nearly caught us.

**Method:** every hand-written `Ord`/`Eq`, checked for reflexivity,
antisymmetry, transitivity and `Eq`/`Ord` consistency; then every ordered
container, `sort`, `nub`, `Map`/`Set` key, and priority queue built on one.

### L6 · Metering versus real resource cost
> Gas charged diverges from the resource actually consumed.

**Evidence: three findings — H-1, H-2, H-4** — plus our own measurements that
gas does not bound block data at all (a flat 100 bytes per gas below 50 KiB,
with a 2 MiB *transport* constant doing the real work).

**Method:** for every metered operation, compare the charge against CPU, bytes
transferred, and permanent storage. Look for anything free that a node pays
for.

### L7 · Fork guards and version rules
> A guard that reads always-true or always-false because of how a version
> table is populated.

**Evidence:** `ForkAtGenesis = minBound`, so an unlisted fork in a wildcard
table reads as always-true and retroactively rewrites history. We caught this
in review, not in testing.

**Method:** every `Chainweb.Version.Guards` predicate, against every version's
fork table, including the defaults.

### L8 · Laziness and resource exhaustion
> Unbounded thunk accumulation, or an unbounded collection, reachable by a
> remote peer.

**Evidence:** none yet in our findings — but H-3 was an unbounded *queue*, and
the class is adjacent. Ranked accordingly.

**Method:** long-lived loops, accumulating folds, `IORef`/`MVar`/`TVar`
updated without forcing, and any container fed from the network without a
bound.

### L9 · Pact evaluator — capabilities, guards, module boundaries
> A security property enforced in one evaluator but not the other, or on one
> path but not its sibling.

**Evidence: SC-2 needed fixing in *both* CEK and Direct.** Any finding here
must be checked against both, always.

**Entry points:** `CEK/Evaluator.hs`, the Direct evaluator, `Capabilities`,
`Guards`, `Namespace`, `DefPacts`.

### L10 · Cross-chain and SPV lifecycle
> Value can be destroyed, or a node forked off, by the interaction of proof
> validity, compaction and pruning.

**Evidence: three findings already** — the proof-expiry fund-destruction path
(`transfer-crosschain` has two plain `(step`s and no rollback), compacted
nodes unable to *create* proofs, and the uncaught `TreeDbAncestorMissing` on
upgrade.

**This is the one most likely to produce an `SC`.** Handle with the disclosure
protocol front of mind.

### L11 · Consensus determinism
> Two honest nodes computing different results for the same block.

**Evidence:** none yet — but this is the highest-consequence class in any
chain, so it earns a lens on stakes rather than on prior hits.

**Method:** anything time-, locale-, environment-, iteration-order- or
map-ordering-dependent on a path that feeds a payload hash; `Data.Map` vs
`HashMap` iteration; floating point anywhere near consensus.

---

## 4. Phasing

Each phase: **dispatch lenses → dedup → adversarial validation → record →
STOP and report.** Do not start the next phase until the previous is written
up and reviewed.

| phase | lenses | rationale |
|---|---|---|
| **0** | — | Pin exact commits. Create the master doc. No analysis. |
| **1 (pilot)** | L1 | One question, two prior hits, cheap. Produces real cost data before committing further. |
| **2** | L2, L3, L5 | The Haskell-specific structural classes. Highest value per token. |
| **3** | L6, L7, L11 | Consensus and economics on chainweb. |
| **4** | L10, L8 | Cross-chain and exhaustion. Most likely to need private disclosure. |
| **5** | L9 | Pact evaluator. Hardest target, highest blast radius. |
| **6** | — | Synthesis, recommendations, maintainer-facing report. |

**Phase 1 is a genuine go/no-go.** If a single-hypothesis sweep with two known
prior instances produces nothing new, that is strong evidence the codebase is
tighter than we think, and we should stop and say so rather than grind on.

---

## 5. Validation — where the cost goes

Every candidate gets independent validators whose job is to **refute** it.
Default REFUTED when uncertain.

- A finding a validator cannot reproduce from the stated scenario does not ship
- Disagreement is recorded, not resolved by majority
- `SC` and `C` findings need a working demonstration, or an explicit statement
  that none was constructed
- Every verdict carries a one-line note naming what was checked

**Budget accordingly: validation is the product, the sweep is the raw
material.** A wrong finding in a report handed to maintainers costs them a
remediation cycle and costs us every other finding's credibility.

---

## 6. Findings versus Observations

Two structurally separate tracks. **Never mixed in one section** — mixing lets
a reader dismiss a defect as opinion.

**Findings** — defects. All five required, or it does not ship: what, where
(file:line at the tagged commit), a concrete failure scenario, quoted
evidence, and a validation verdict.

**Observations** — improvements, hardening, ergonomics. **No severity rating**
— a severity implies a defect. Each must state the tradeoff or the reason the
current design may be deliberate. **If we cannot articulate the
counter-argument, we do not understand it well enough to raise it.**

The maintainers know their constraints and we do not. Labelling opinion as
opinion costs nothing and makes the Findings track more credible by contrast.

---

## 7. Disclosure protocol — agreed before any work starts

Kadena mainnet is a live chain securing real value.

1. **Nothing published while unfixed.** No article, no Telegram, no commit
   message, no public issue.
2. `SC`, `C` and `H` go to the maintainers **privately** first.
3. They get a reasonable window. We do not set a public deadline unilaterally.
4. Publication only once fixed, or with their explicit agreement.
5. `M`, `L` and Observations can be shared openly — but still go to them first.
6. Work happens on a **private** branch; the report is not committed to a
   public repo until cleared.

Deciding this now rather than in the excitement of a discovery is the point.

---

## 8. The master document

Single file, the deliverable. Must state:

- **Exact commits audited** — full SHAs and tags for both repos, with dates
- **The lens manifest** — which lenses ran, and for any dropped, why. Without
  it, a lens with no findings is ambiguous between *clean* and *not examined*
- **What was and was not examined**, by subsystem, honestly
- **Findings**, severity-ordered, each with the five required elements
- **Observations**, separately, labelled as opinion
- **The REFUTED count**, plainly stated
- **What we got wrong** — every withdrawn candidate and why

That last section is the credibility mechanism, not humility. Our 3.2 audit
published three of our own errors and that is why the rest was believed.

---

## 9. Cost control

- Phase gate: report and stop after each phase
- Kill a lens early if its first pass is empty; do not keep digging because it
  felt promising
- No blanket file-by-file sweeps. Every agent gets a stated question
- One deep validated finding beats ten unvalidated candidates

---

## 10. Open decisions

1. **Run Phase 1 as a pilot before committing to the rest?** Recommended: yes.
2. **Tell the maintainers before we start?** Recommended: yes. Turning up
   unannounced with findings reads worse than announcing intent, and costs
   nothing.
3. **Where does the report live?** Recommended: private repo until cleared.
