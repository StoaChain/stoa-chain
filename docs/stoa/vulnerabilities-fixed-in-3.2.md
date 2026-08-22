# Vulnerabilities fixed in Chainweb 3.2 / Pact 5.4.1 — numbered issue list

**Sources:** [Ad-Vitam Transparency Report](https://medium.com/@communitykadena/chainweb-3-2-ad-vitam-transparency-report-cfcfff237f43) (2026-08-02), plus our own audit of the `4aedec3bb..3.2.1` diff.

**Every "StoaChain exposed?" verdict below was verified against our own source tree and our pinned `pact-5@bfc5310c`.**

Legend — **EXPOSED** = present and reachable on StoaChain today · **NOT EXPOSED** = verified inapplicable · **N/A** = fixes a mechanism we don't have.

---

## Part A — The four disclosed vulnerabilities

### #1 · Identity forgery via the `addr` field — CRITICAL — StoaChain **EXPOSED**

**What:** A `Signer` may carry an optional `_siAddress`. Pre-fix, Pact's `mkMsgSigs` keyed the message-signature map on `fromMaybe pubK addr` — an attacker-controlled field. `verifyUserSig` enforces `addr == pubKey`, **but only in the ED25519 branch**; the WebAuthn branch never checks it.

**Exploit:** Sign with your own WebAuthn key, set `addr` to a victim's ED25519 public key. Signature verification passes (checked against *your* key); `msgSigs` is keyed under *the victim's* key; every `enforce-keyset` / `enforce-guard` for that victim then succeeds. Complete authentication bypass — impersonate any ED25519 signer, drain any account.

**Fix:** `pact/Pact/Core/Evaluate.hs` — always key on `pubK`, never `addr`, unless `FlagDisablePact54Fix` is set.

**Our exposure — every link verified:**
- `grep -rn "_siAddress" src/` → **no hits**. Chainweb never validates it.
- `verifyUserSig` (pact-request-api `Command/Types.hs:211`) checks `addr` only under `(ED25519Sig, ED25519)`.
- `Stoa.hs:37-38` maps **every** fork to `ForkAtGenesis` ⇒ `chainweb221Pact` true from block 0 ⇒ `validPPKSchemes = [ED25519, WebAuthn]` ⇒ **WebAuthn accepted since genesis**.
- Our pinned `pact-5@bfc5310c` contains the vulnerable `toPair (Signer _scheme pubK addr capList) = (PublicKeyText (fromMaybe pubK addr), ...)` — read directly from the blob.

### #2 · Capability theft through composition — CRITICAL — StoaChain **EXPOSED**

**What:** Pact's core security property is *"a capability can only be acquired by code within the same module."* `composeCap` called `evalCap` **without** `guardForModuleCall`, so `(compose-capability ...)` could acquire a capability belonging to a third-party module.

**Exploit** (upstream PoC, `pact-tests/pact-tests/compose-caps-bug.repl`): an `attacker` module defines `(defcap ATTACKER-CAP () (compose-capability (vulnerable.MY-CAP-IN-MODULE-VULNERABLE)))`, then calls `vulnerable.test-cap`, which is guarded by `(require-capability (MY-CAP-IN-MODULE-VULNERABLE))` — and it succeeds. Upstream's assessment: *"most existing contracts were potentially vulnerable to this attack."*

**Fix:** both evaluators (CEK + Direct) gain `unlessExecutionFlagSet FlagDisablePact54Fix $ guardForModuleCall info (_fqModule capFqn) $ pure ()`.

**Our exposure:** our pin's `composeCap` (`CEK/Evaluator.hs:844`) has no module guard — verified. Reachable by anyone who can deploy a module. Capabilities whose bodies independently enforce a guard still run those guards; capabilities that rely on module-boundary protection alone are fully bypassable.

### #3 · Oversized transactions/blocks via unmetered signatures — HIGH (DoS) — StoaChain **EXPOSED, WORSE THAN KADENA**

**What:** Signatures were capped at 100/tx but charged **zero** gas — `payloadBytes` excludes `_cmdSigs`. WebAuthn signatures embed arbitrary-size metadata, so blocks could be inflated far beyond what the P2P layer propagates efficiently while staying inside the block gas limit.

**Fix:** `post32GasModel` charges signature bytes at the normal 0.01/byte via `_signatureSizeFactor = 1.0`.

**Our exposure — and why it is worse for us:** upstream's mitigating argument is that the **150k gas-per-block cap** bounded block size. Our `_versionMaxBlockGasLimit = 2_000_000` (`Stoa.hs:58`) with default `_configBlockGasLimit = 1_600_000` — roughly **10x their cap**. The margin they described as *"uncomfortably small"* is about ten times smaller on StoaChain.

### #4 · Block-validation CPU exhaustion via WebAuthn verification — HIGH (consensus) — StoaChain **EXPOSED, WORSE THAN KADENA**

**What:** WebAuthn verification is expensive (~1.315 ms worst case; root cause possibly ASN.1 parsing). Filling a block with WebAuthn-signed transactions pushed block validation time *"dangerously close to the 30-second block time"* — risking an uncontrolled network fork.

**Fix:** flat per-scheme verification charge at Pact's CPU price of **1 gas per 2.5 microseconds**: `ED25519 -> 21.0` (52 us), `WebAuthn -> 526.0` (1.315 ms).

**Our exposure:** same 30 s block delay, same WebAuthn availability, ~10x the gas budget per block. Strictly worse margin than mainnet.

> **Correction to our earlier audit.** A previous revision of this document claimed the WebAuthn constant was ~1000x too low and advised re-benchmarking. **That was wrong.** At the disclosed rate of 1 gas per 2.5 us both constants are correct and mutually consistent: 1,315,000 ns / 2,500 = 526 and 52 us / 2.5 us = 20.8 ~= 21. The typo is the source comment `-- Benchmarked at 52 ns`, which should read **52 us** (a 52 ns Ed25519 verify is ~150 CPU cycles — physically impossible). No re-benchmarking is required.

---

## Part B — Additional issues from our own diff audit

### #5 · CVE-2026-9648 — X.509 NameConstraints not enforced — CRITICAL (CVSS 9.1) — StoaChain **EXPOSED**

`crypton-x509-validation` ignores RFC 5280 NameConstraints, so a holder of a name-constrained sub-CA can mint a certificate valid for **any** hostname ([CERT/CC VU#862559](https://kb.cert.org/vuls/id/862559)). Fixed in **1.9.1**.

Our bootstraps are built with `domainAddr2PeerInfo = fmap (PeerInfo Nothing)` — **no pinned fingerprint** — so they fall back to `getSystemCertificateStore`, the affected path. **Our own `cabal.project:100` pin `crypton == 1.0.4` blocks the fix**, because `crypton-x509-validation-1.9.1` requires `crypton >= 1.1`.

Not mentioned in any upstream changelog or in the transparency report.

### #6 · Cut-queue duplicate flood — HIGH (remote DoS) — StoaChain **EXPOSED**

`Data/PQueue.hs` was a heap of `Down CutHashes`; equal cuts compare `EQ` and a heap admits duplicates, so `pQueueInsertLimit` could retain *N copies of one attacker cut*, evicting every legitimate pending cut. Each copy re-triggers a full prerequisite header/payload fetch.

Remotely reachable: `cutPutHandler` only checks that the **attacker-supplied** `_cutOrigin` exists in the peer DB — not that the requester is that peer. Fixed in `392c5b88d` (heap to keyed STM map).

**Partially fixed only:** dedup keys on `_cutHashesId` and priority on `_cutHashesWeight`, both attacker-supplied and unvalidated. Upstream's own comment remains: *"FIXME: this is problematic. We should drop these much earlier before they are even added to the queue."*

### #7 · Unmetered SPV continuation-proof size — HIGH — StoaChain **EXPOSED**

Our code **deliberately subtracts** proof bytes from the billed size: `txSize = payloadBytes - contProofSize`. Arbitrarily large SPV proofs can be written into blocks at zero marginal gas — bandwidth, permanent storage, and Merkle-verification CPU on every node, forever. Fixed in 3.1 (`c13c0a1a1`), generalised to `_proofSizeFactor` in 3.2. Same class as #3.

### #8 · Completed-defpact continuations accepted into the mempool — MEDIUM — StoaChain **EXPOSED**

Pre-insert did not check whether a continuation targets an already-completed defpact, so an attacker can cheaply fill mempools and blocks with guaranteed-failing cross-chain replays. Fixed in `1aa616ba0` (`InsertErrorDefPactComplete`). Mempool-only; a node without it validates blocks identically.

### #9 · Pact-4 module-cache replay divergence — MEDIUM — StoaChain **NOT EXPOSED**

`_quirkGasFees` grew from 2 to 14 mainnet entries. Missing entries make a from-genesis replay recompute different gas, producing a different payload hash and failing replay. **Mainnet history only; StoaChain has its own genesis and its own (empty) quirk table.**

### #10 · Compaction header off-by-one — MEDIUM — StoaChain **ALREADY FIXED**

`2f11bda25` changed `runBack` from `latestHeader` to `minBlockHeight`. Our `Compaction.hs:786` already reads `int minBlockHeight` — the fix arrived with our post-3.0 base. No action.

### #11 · Service-date kill switch — HIGH (availability) — StoaChain **NOT EXPOSED**

2.32 mainnet carried `_versionServiceDate = Just "2026-01-07T00:00:00Z"`; `withServiceDate` throws and terminates the process. It fires **only** when `_versionCode` equals mainnet's or testnet04's. Ours is `0x0000_000A`, and the mechanism is already absent from our base.

### #12 · Cut-queue buffer size of zero — MEDIUM (liveness) — StoaChain **NOT EXPOSED**

`_cutDbParamsBufferSize = order^2 * diameter` evaluates to **0** on a diameter-0 (singleton) graph, truncating the queue on every insert. We use `petersenChainGraph` (10 chains, diameter 2), giving 800. Take `5fd969c6c` anyway as a prerequisite for #6.

### #13 · Fork-vote off-by-one and unknown-fork-number acceptance — MEDIUM — **N/A**

`5167be993` and `58681f677` fix bugs in the fork-voting machinery. Only relevant once we adopt voting — see [`miner-fork-voting.md`](miner-fork-voting.md).

### #14 · Node-version header unparseable — MEDIUM — StoaChain **NOT EXPOSED**

`"2.32-community"` failed `NodeVersion`'s dotted-integer parser, so `guardPeerDb` rejected every community peer. Ours is the bare `CURRENT_PACKAGE_VERSION`.

---

## Summary

| Affects StoaChain | Count | Issues |
|---|---|---|
| **EXPOSED — must fix** | **7** | #1, #2, #3, #4, #5, #6, #7 |
| Exposed — should fix | 1 | #8 |
| Not exposed / already fixed / N/A | 6 | #9, #10, #11, #12, #13, #14 |

**Four of the seven are CRITICAL or HIGH, and two (#1, #2) permit outright theft.** On #3 and #4 our exposure is materially worse than Kadena mainnet's, because our block gas limit is roughly 10x theirs.

Upstream state that their chain scan found **no evidence any of #1–#4 were exploited**. We have not performed the equivalent scan on StoaChain; it is cheap and worth doing before the fork.
