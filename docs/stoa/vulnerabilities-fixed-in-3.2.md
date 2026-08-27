# Vulnerabilities fixed in Chainweb 3.2 / Pact 5.4.1 — severity-ordered issue list

**Sources:** [Ad-Vitam Transparency Report](https://medium.com/@communitykadena/chainweb-3-2-ad-vitam-transparency-report-cfcfff237f43) (2026-08-02), plus our own audit of the `4aedec3bb..3.2.1` diff.

**Every "StoaChain exposed?" verdict below was verified against our own source tree and our pinned `pact-5@bfc5310c`.**

## How these are identified

Findings carry a **severity-prefixed ID**, so the identifier itself tells you how
bad it is, and sorting by ID sorts by severity:

| Prefix | Tier | Meaning |
|---|---|---|
| `SC-` | **SUPERCRITICAL** | Permits theft of funds by any attacker, with no special position or privilege |
| `C-` | CRITICAL | Complete compromise of a security property, but requires a privileged position |
| `H-` | HIGH | Denial of service, consensus risk, or availability loss |
| `M-` | MEDIUM | Correctness, liveness or hygiene issues with bounded impact |
| `L-` | LOW | *(none in this set)* |

`SUPERCRITICAL` sits above the standard scale, which stops at CRITICAL. The
distinction is real and worth keeping: `SC-1` and `SC-2` let **any** user drain
**any** account, while `C-1` — a CVSS 9.1 CVE — requires the attacker to already
hold a name-constrained subordinate CA. Same word, very different bar.

Legend — **EXPOSED** = present and reachable on StoaChain today · **NOT EXPOSED** = verified inapplicable · **N/A** = fixes a mechanism we don't have.

**Who found what:** `SC-1`, `SC-2`, `H-1` and `H-2` were disclosed by Kadena in the
transparency report. The other ten came out of our own commit-by-commit read of
the 3.2 diff — including `C-1`, the most severe item on the list, which appears in
no upstream changelog and not in the transparency report.

---

## SUPERCRITICAL

### SC-1 · Identity forgery via the `addr` field — StoaChain **EXPOSED** — *disclosed by Kadena*

**What:** A `Signer` may carry an optional `_siAddress`. Pre-fix, Pact's `mkMsgSigs` keyed the message-signature map on `fromMaybe pubK addr` — an attacker-controlled field. `verifyUserSig` enforces `addr == pubKey`, **but only in the ED25519 branch**; the WebAuthn branch never checks it.

**Exploit:** Sign with your own WebAuthn key, set `addr` to a victim's ED25519 public key. Signature verification passes (checked against *your* key); `msgSigs` is keyed under *the victim's* key; every `enforce-keyset` / `enforce-guard` for that victim then succeeds. Complete authentication bypass — impersonate any ED25519 signer, drain any account.

**Fix:** `pact/Pact/Core/Evaluate.hs` — always key on `pubK`, never `addr`, unless `FlagDisablePact54Fix` is set.

**Our exposure — every link verified:**
- `grep -rn "_siAddress" src/` → **no hits**. Chainweb never validates it.
- `verifyUserSig` (pact-request-api `Command/Types.hs:211`) checks `addr` only under `(ED25519Sig, ED25519)`.
- `Stoa.hs` maps **every** fork to `ForkAtGenesis` ⇒ `chainweb221Pact` true from block 0 ⇒ `validPPKSchemes = [ED25519, WebAuthn]` ⇒ **WebAuthn accepted since genesis**.
- Our pinned `pact-5@bfc5310c` contains the vulnerable `toPair (Signer _scheme pubK addr capList) = (PublicKeyText (fromMaybe pubK addr), ...)` — read directly from the blob.

**Adopted:** yes — Pact 5.4.1 (`72f42760`) plus `guardDisablePact54FixFlags`. **Active at block 516,500.**

### SC-2 · Capability theft through composition — StoaChain **EXPOSED** — *disclosed by Kadena*

**What:** Pact's core security property is *"a capability can only be acquired by code within the same module."* `composeCap` called `evalCap` **without** `guardForModuleCall`, so `(compose-capability ...)` could acquire a capability belonging to a third-party module.

**Exploit** (upstream PoC, `pact-tests/pact-tests/compose-caps-bug.repl`): an `attacker` module defines `(defcap ATTACKER-CAP () (compose-capability (vulnerable.MY-CAP-IN-MODULE-VULNERABLE)))`, then calls `vulnerable.test-cap`, which is guarded by `(require-capability (MY-CAP-IN-MODULE-VULNERABLE))` — and it succeeds. Upstream's assessment: *"most existing contracts were potentially vulnerable to this attack."*

**Fix:** both evaluators (CEK + Direct) gain `unlessExecutionFlagSet FlagDisablePact54Fix $ guardForModuleCall info (_fqModule capFqn) $ pure ()`.

**Our exposure:** our pin's `composeCap` (`CEK/Evaluator.hs:844`) has no module guard — verified. Reachable by anyone who can deploy a module. Capabilities whose bodies independently enforce a guard still run those guards; capabilities that rely on module-boundary protection alone are fully bypassable.

**Adopted:** yes — same Pact 5.4.1 bump as SC-1. **Active at block 516,500.**

---

## CRITICAL

### C-1 · CVE-2026-9648 — X.509 NameConstraints not enforced — CVSS 9.1 — StoaChain **EXPOSED** — *found by us*

`crypton-x509-validation` ignores RFC 5280 NameConstraints, so a holder of a name-constrained sub-CA can mint a certificate valid for **any** hostname ([CERT/CC VU#862559](https://kb.cert.org/vuls/id/862559)). Fixed in **1.9.1**.

Our bootstraps are built with `domainAddr2PeerInfo = fmap (PeerInfo Nothing)` — **no pinned fingerprint** — so they fall back to `getSystemCertificateStore`, the affected path. **Our own `cabal.project:100` pin `crypton == 1.0.4` blocked the fix**, because `crypton-x509-validation-1.9.1` requires `crypton >= 1.1`.

Not mentioned in any upstream changelog or in the transparency report. We found it by noticing that upstream had bumped `crypton`, and asking why.

**Adopted:** yes — `9598bdb2a` plus three hand-adapted commits (`24ec33804`, `2dadedf75`, `4d6ff1912`) moving sixteen dependency bounds. **Active immediately** — no fork needed.

---

## HIGH

### H-1 · Oversized transactions/blocks via unmetered signatures — StoaChain **EXPOSED, WORSE THAN KADENA** — *disclosed by Kadena*

**What:** Signatures were capped at 100/tx but charged **zero** gas — `payloadBytes` excludes `_cmdSigs`. WebAuthn signatures embed arbitrary-size metadata, so blocks could be inflated far beyond what the P2P layer propagates efficiently while staying inside the block gas limit.

**Fix:** `post32GasModel` charges signature bytes at the normal 0.01/byte via `_signatureSizeFactor = 1.0`.

**Our exposure — and why it is worse for us:** upstream's mitigating argument is that the **150k gas-per-block cap** bounded block size. Our `_versionMaxBlockGasLimit = 2_000_000` with default `_configBlockGasLimit = 1_600_000` — roughly **10x their cap**. The margin they described as *"uncomfortably small"* is about ten times smaller on StoaChain.

**Adopted:** yes — `460852eb1`. **Active at block 516,500.**

### H-2 · Block-validation CPU exhaustion via WebAuthn verification — StoaChain **EXPOSED, WORSE THAN KADENA** — *disclosed by Kadena*

**What:** WebAuthn verification is expensive (~1.315 ms worst case; root cause possibly ASN.1 parsing). Filling a block with WebAuthn-signed transactions pushed block validation time *"dangerously close to the 30-second block time"* — risking an uncontrolled network fork.

**Fix:** flat per-scheme verification charge at Pact's CPU price of **1 gas per 2.5 microseconds**: `ED25519 -> 21.0` (52 µs), `WebAuthn -> 526.0` (1.315 ms).

**Our exposure:** same 30 s block delay, same WebAuthn availability, ~13x the gas budget per block. Strictly worse margin than mainnet.

**What the fix means for our 2,000,000 block gas cap.** Because the charge is denominated in time, the block gas limit becomes a **CPU-time budget**: worst-case verification work is `gasLimit × 2.5 µs` regardless of signature mix.

| | Block gas limit | Worst-case signature CPU | Share of a 30 s block |
|---|---|---|---|
| StoaChain hard cap | 2,000,000 | **5.00 s** | 16.7 % |
| StoaChain configured default | 1,600,000 | **4.00 s** | 13.3 % |
| Kadena mainnet | 150,000 | 0.375 s | 1.25 % |

At our hard cap that is 3,802 WebAuthn signatures (2,000,000 ÷ 526) or 95,238 ED25519 (÷ 21). The cap did not need to change — it needed to *mean* something, and now it does.

> **Correction to our earlier audit.** A previous revision of this document claimed the WebAuthn constant was ~1000x too low and advised re-benchmarking. **That was wrong.** At the disclosed rate of 1 gas per 2.5 µs both constants are correct and mutually consistent: 1,315,000 ns / 2,500 = 526 and 52 µs / 2.5 µs ≈ 21. The typo is the source comment `-- Benchmarked at 52 ns`, which should read **52 µs** (a 52 ns Ed25519 verify is ~150 CPU cycles — physically impossible). No re-benchmarking is required.

**Adopted:** yes — `460852eb1`. WebAuthn was **kept enabled**, deliberately, to preserve passkey / seed-phrase-free onboarding as a future option. Note also that the scheme allowlist `validPPKSchemes` is wired only into Pact 4 paths — it appears **zero times** under `src/Chainweb/Pact5/` — so it could not have gated the execution path we actually run. **Active at block 516,500.**

### H-3 · Cut-queue duplicate flood — remote DoS — StoaChain **EXPOSED** — *found by us*

`Data/PQueue.hs` was a heap of `Down CutHashes`; equal cuts compare `EQ` and a heap admits duplicates, so `pQueueInsertLimit` could retain *N copies of one attacker cut*, evicting every legitimate pending cut. Each copy re-triggers a full prerequisite header/payload fetch.

Remotely reachable: `cutPutHandler` only checks that the **attacker-supplied** `_cutOrigin` exists in the peer DB — not that the requester is that peer. Fixed in `392c5b88d` (heap to keyed STM map).

**Partially fixed only:** dedup keys on `_cutHashesId` and priority on `_cutHashesWeight`, both attacker-supplied and unvalidated. Upstream's own comment remains: *"FIXME: this is problematic. We should drop these much earlier before they are even added to the queue."*

**Adopted:** yes — `84e4eb6cb`, then `5fd969c6c`, then `392c5b88d`, **in that order**; the last conflicts if applied alone. **Active immediately.**

### H-4 · Unmetered SPV continuation-proof size — StoaChain **EXPOSED** — *found by us*

Our code **deliberately subtracts** proof bytes from the billed size: `txSize = payloadBytes - contProofSize`. Arbitrarily large SPV proofs can be written into blocks at zero marginal gas — bandwidth, permanent storage, and Merkle-verification CPU on every node, forever. Fixed in 3.1 (`c13c0a1a1`), generalised to `_proofSizeFactor` in 3.2. Same class as H-1.

**Adopted:** yes — `c13c0a1a1` and `460852eb1`. **Active at block 516,500.**

### H-5 · Service-date kill switch — availability — StoaChain **NOT EXPOSED** — *found by us*

2.32 mainnet carried `_versionServiceDate = Just "2026-01-07T00:00:00Z"`; `withServiceDate` throws and terminates the process. It is a deliberate dead-man's switch to force operators to upgrade.

It fires **only** when `_versionCode` equals mainnet's or testnet04's. Ours is `0x0000_000A`, and the mechanism is already absent from our base.

**Adopted:** nothing to adopt — not exposed, mechanism absent.

---

## MEDIUM

### M-1 · Completed-defpact continuations accepted into the mempool — StoaChain **EXPOSED** — *found by us*

Pre-insert did not check whether a continuation targets an already-completed defpact, so an attacker can cheaply fill mempools and blocks with guaranteed-failing cross-chain replays. Fixed in `1aa616ba0` (`InsertErrorDefPactComplete`). Mempool-only; a node without it validates blocks identically.

**Adopted:** yes — `1aa616ba0`. **Active immediately**, and needs no coordination at all.

### M-2 · Pact-4 module-cache replay divergence — StoaChain **NOT EXPOSED** — *found by us*

`_quirkGasFees` grew from 2 to 14 mainnet entries. Missing entries make a from-genesis replay recompute different gas, producing a different payload hash and failing replay. **Mainnet history only; StoaChain has its own genesis and its own (empty) quirk table.**

**Adopted: no — declined.** `f3e097988` imports fourteen assertions about a chain history that is not ours.

### M-3 · Compaction header off-by-one — StoaChain **ALREADY FIXED** — *found by us*

`2f11bda25` changed `runBack` from `latestHeader` to `minBlockHeight`. Our `Compaction.hs:786` already reads `int minBlockHeight` — the fix arrived with our post-3.0 base. No action.

> An earlier revision of this document listed this as needing a backport. It did not. Checked, found already present, corrected.

### M-4 · Cut-queue buffer size of zero — liveness — StoaChain **NOT EXPOSED** — *found by us*

`_cutDbParamsBufferSize = order^2 * diameter` evaluates to **0** on a diameter-0 (singleton) graph, truncating the queue on every insert. We use `petersenChainGraph` (10 chains, diameter 2), giving 800.

**Adopted: yes, despite not needing it** — `5fd969c6c` is a prerequisite for H-3, which conflicts without it.

### M-5 · Fork-vote off-by-one and unknown-fork-number acceptance — **N/A** — *found by us*

`5167be993` and `58681f677` fix bugs in the fork-voting machinery. Only relevant once we adopt voting — see [`miner-fork-voting.md`](miner-fork-voting.md).

**Adopted: yes, but dormant.** Both came in with the ForkNumber machinery that H-1/H-2/H-4 depend on. `_versionForkNumber = 0`, and the vote epoch is `120 × 119` casting blocks + 120 counting = 14,400, exactly five days at our block delay. The apparatus is in the binary; we do not use it.

### M-6 · Node-version header unparseable — StoaChain **NOT EXPOSED** — *found by us*

`"2.32-community"` failed `NodeVersion`'s dotted-integer parser, so `guardPeerDb` rejected every community peer. Ours is the bare `CURRENT_PACKAGE_VERSION`.

**Adopted: no — declined.** `24ae0b4e1` fixes a suffix we never had.

---

## Summary

| Affects StoaChain | Count | Issues |
|---|---|---|
| **EXPOSED — must fix** | **7** | SC-1, SC-2, C-1, H-1, H-2, H-3, H-4 |
| Exposed — should fix | 1 | M-1 |
| Not exposed / already fixed / N/A | 6 | H-5, M-2, M-3, M-4, M-5, M-6 |

**Two findings are SUPERCRITICAL and permit outright theft (SC-1, SC-2); one more is CRITICAL (C-1).** On H-1 and H-2 our exposure is materially worse than Kadena mainnet's, because our block gas limit is roughly 13x theirs.

Upstream state that their chain scan found **no evidence any of the four disclosed issues were exploited**. We have not performed the equivalent scan on StoaChain; it is cheap and worth doing.
