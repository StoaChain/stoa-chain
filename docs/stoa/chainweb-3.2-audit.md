# Chainweb Community Edition 3.2 — Technical Audit & StoaChain Upgrade Assessment

**Date:** 2026-08-02 · **Revised:** 2026-08-03 · **Auditor:** Claude Code (nectar multi-agent audit)
**Subject:** `kda-community/chainweb-node` tags `3.2` (`eacb3cee`) and `3.2.1` (`d89bb530`)

> **Revision note (2026-08-03).** Two things changed after the first version of this document:
> 1. Upstream published the [Ad-Vitam Transparency Report](https://medium.com/@communitykadena/chainweb-3-2-ad-vitam-transparency-report-cfcfff237f43) disclosing four vulnerabilities, and released **3.2.1** with the complete Pact source. §2's blocking finding is **resolved**.
> 2. That report's disclosure of Pact's CPU pricing rate (**1 gas per 2.5 µs**) **refutes** this audit's original HIGH finding that the WebAuthn gas constant was ~1000× too low. See §5.
>
> The per-issue breakdown with StoaChain exposure verdicts now lives in [`vulnerabilities-fixed-in-3.2.md`](vulnerabilities-fixed-in-3.2.md). Fork voting is documented in [`miner-fork-voting.md`](miner-fork-voting.md).

**Compared against:** StoaChain `main` @ `7c3400f`
**Method:** full source clone, 110-commit diff review, 5 parallel specialist audits, all headline claims independently re-verified against code.

---

## 1. Executive summary

| Claim in the release article | Verdict |
|---|---|
| Miner voting fully integrated into forking mechanism | **TRUE**, mechanism is sound BIP9-style hashrate signalling |
| "2/3 of the **miners** have voted" | **MISLEADING** — it is 2/3 of *blocks* (hashrate-weighted). 67% hashrate = unilateral fork |
| "A voting round lasts 5 days" | **TRUE** — 14,400 blocks × 30 s = exactly 5 days, at target block rate |
| SPV window reintegrated at 6 months | **TRUE as intent** — 525,600 blocks = 182.5 days exactly. **But dormant**: activates only on a miner vote |
| DB "400 GB → less than 50 GB" | **PARTIALLY SUPPORTED** — end state credible, but ~350 GB of it is payload pruning that predates and is unrelated to the SPV window |
| New gas model charges every signature by size/complexity | **TRUE**, clean implementation |
| "small increase of almost 40 gas" for ED25519 | **OVERSTATED ~1.8×** — actual is +22.38; their own tests assert +22 |
| "Prepares for post-quantum signatures" | **ABSENT** — zero PQ code. A pricing hook only, and a `-Werror`-breaking one |
| "Many bugs and security fixes" | **TRUE** — includes a real, unlisted CVE fix, undisclosed as such |
| "Closes all already identified and never addressed issues" | **FALSE** — several acknowledged FIXMEs remain open in 3.2 |

**Overall:** a substantive release with real security value, oversold in the marketing. As of **3.2.1 (2026-08-03)** it is fully buildable from source and the four fixed vulnerabilities are disclosed — see [`vulnerabilities-fixed-in-3.2.md`](vulnerabilities-fixed-in-3.2.md) for the per-issue breakdown and StoaChain exposure verdicts.

---

## 2. ~~Blocking finding: 3.2 cannot be built from source~~ — RESOLVED 2026-08-03

> **RESOLVED.** `kda-community/pact-5-special-fix` is now public, `kda-community/pact-5` carries a **`5.4.1`** tag (`72f42760`, verified `version: 5.4.1` and containing both fixes), and **chainweb 3.2.1** (4 files, 12 insertions) repoints the pin to that public tag. Upstream confirmed the embargo was deliberate: *"Chainweb 3.2 fixed several important vulnerabilities that we did not want to disclose before the hard fork."* The original finding is preserved below as the record of what was true on 2026-08-02.
>
> Residual: `pact`, `pact-5` and `merkle-log` still carry no `--sha256`, so Nix content-pinning remains incomplete for those three. Cabal builds are unaffected (git SHAs are content-addressed).

`cabal.project` at tag 3.2 pins Pact to a repository that does not exist publicly:

```
location: https://github.com/kda-community/pact-5-special-fix
tag: eee1d0a59a8e098e88a23b4a5eb9dc6c7d7b8444
```

Verified:
- `git ls-remote` → **`remote: Repository not found`** (control: `kda-community/pact-5`, `/pact`, `/merkle-log`, `/chainweb-node` all resolve)
- the pinned SHA is **not** in the public `pact-5` (`upload-pack: not our ref`); newest public tag is `5.4`, version `5.4`. **There is no public Pact 5.4.1.**
- their CI injects `secrets.SPECIAL_FIX_PAT` — confirming it is private, not deleted
- `--sha256` lines were dropped from `pact`, `pact-5-special-fix` and `merkle-log`, breaking Nix content pinning

The only in-tree evidence of the Pact fix is a guard whose flag is defined solely inside the missing repo:

```haskell
guardDisablePact54FixFlags txCtx            -- Pact5/TransactionExec.hs:1063
  | guardCtx' chainweb32 txCtx = Set.empty
  | otherwise = Set.singleton FlagDisablePact54Fix
```

**Consequences:** the release's "Pact vulnerabilities" claim is unauditable; third parties cannot build or reproduce 3.2; only the prebuilt Ubuntu tarball (GHC 9.10.2, 83.3 MB) and Docker image are usable. This is most plausibly a deliberate disclosure embargo, but it is a hard external blocker for anyone forking.

**Action:** request the tree behind `eee1d0a5…` from kda-community before treating 3.2's Pact claims as substantiated.

---

## 3. Miner fork voting

### Mechanism

The vote lives in the **existing 64-bit `featureFlags` header field, renamed `ForkState`** — *no field added, no wire-format change, same Merkle tag `0x0006`.*

| Bits | Meaning |
|---|---|
| 0–31 | `ForkNumber` (Word32) — ruleset this block was built under |
| 32–63 | `ForkVotes` (Word32) — vote counter, quantized to `voteStep = 1000` |

Timing (now version-parameterized, `Version.hs:619-629`):

```haskell
voteCountingLength  = 120                                          -- global constant
forkEpochLength v   = _versionForkVoteCastingLength v + voteCountingLength
decideVotes v votes = round (votes % voteStep) * 3 >= _versionForkVoteCastingLength v * 2
```

All versions set `_versionForkVoteCastingLength = 120 * 119` = **14,280** casting blocks + 120 counting = **14,400 = 5 days**. Threshold = **9,520** = exactly 2/3 (works only because 14,280 divides by 3).

**Rules:** one vote per PoW block (delta capped at 0 or +1000); voting yes is the **default** (`--mining-target-fork-override` to abstain); a block signaling `forkNumber > current+1` is invalid; activation is **mandatory** once the threshold is met — a block failing to increment is rejected; non-upgraded nodes reject all post-fork blocks with `UnknownForkNumber` and stall.

Only **one** fork is vote-gated in 3.2: `Chainweb32 → ForkAtForkNumber 1`. Even `Chainweb31`, the fork that introduces voting, is height-gated.

### Findings

| Sev | Finding |
|---|---|
| **HIGH** | **Vote counting is not the documented "average consensus."** `countVotes = sum votes \`quot\` length` is a **one-sided** update — only the mining chain pulls toward neighbours, which is not mean-preserving. **The converged value depends on the order chains are mined in**, and that order is miner-selectable via the public mining API (`Miner/RestAPI.hs:49` `QueryParam "chain"` → `Coordinator.hs:213`). Rounding is `quot` (truncation), not the documented banker's rounding. Exploitable magnitude UNVERIFIED and self-limiting, but **there is no convergence test at all.** |
| **MED** | **Voting is not gated by `Chainweb31`.** The `chainweb31` guard has **zero call sites** — verified. All fork-vote validation is gated on `SkipFeatureFlagValidation` (mainnet height 530,500, ~2020-05) instead. The "all heights sort before all fork numbers" ordering assumption is enforced only at version-definition time, never at runtime. |
| **MED** | **Deep reorg silently deactivates an activated fork.** Monotonicity holds only along one chain's history. No node-local state pins the achieved fork number. Zero test coverage. |
| **MED** | **Chains can disagree on activation.** Each chain decides from its own parent; correctness requires all chains to hold bit-identical counts after 120 asynchronous truncating steps. Nothing enforces this. Not a consensus split (deterministic), but a *partially activated* fork. |
| **LOW** | `UnknownForkNumber` is classified a "definite" (blacklist-worthy) failure, though it depends on the *validating* node's version — a stale node would blacklist every honest peer. Currently inert: `definiteValidationFailures` has no call sites. |
| **LOW** | Test versions use `castingLength = 20` (threshold 70%, not 2/3). The production constant 9,520 is never exercised. `Arbitrary ForkState` is dead code — header generator hardcodes `ForkState 0`. |

**Correctly defended:** cheap multi-voting, Word32 overflow, forged fork numbers (intrinsic check, pre-DB), vote counting over non-final cuts, low-hashrate chains, fork skipping, historical replay, wire compatibility.

---

## 4. SPV proof window & database reduction

### Mechanism

New field `_versionSpvProofRootValidWindow :: Rule ForkHeight (Maybe Word64)`. Enforced at **verification only**, never at creation. Mainnet rule stack (newest first):

| From | Window |
|---|---|
| `Chainweb32` (**vote-gated**) | `Just 525_600` ← 182.5 days, exactly 6 months |
| after `Chainweb31` | `Nothing` (disabled) |
| after `Chainweb231Pact` | `Just 20_000` (~7 days — Kadena's failed first attempt) |
| genesis | `Nothing` |

**Mainnet expiry is currently OFF.** With fork number 0, `searchKey = ForkAtBlockHeight bh` sorts below `ForkAtForkNumber 1`, so the 525,600 entry is skipped. It activates only on the miner vote — no date, no height.

Note the CHANGELOG's "shrink to 6 months" is relative to 3.1's infinity; relative to 2.31/3.0 it is a **20× expansion**.

### The DB claim

Causal chain: window → offline `compact` may drop old **headers** → two RocksDB tables shrink. That is the *entire* contribution.

- **Headers** ≈ 45–50 GB of the ~400 GB → ~4 GB with the window.
- **Payloads** (~350 GB, the bulk) are pruned to ~3,000 blocks **unconditionally** — `Compaction.hs:829`, ungated by the window, available since the tool existed.

So the end state is credible; the *attribution* overstates the window's role by roughly an order of magnitude. Further: nothing shrinks automatically (offline tool, stopped node, copies to a second directory so peak disk ≈ old + new), the flag is hidden and off by default, and on mainnet today it yields **zero** header savings.

### Findings

| Sev | Finding |
|---|---|
| **HIGH** | **A compacted node cannot *create* SPV proofs.** Verification needs headers; creation needs payloads. `CreateProof.hs:264,384` use irrefutable `Just x <-` binds → pattern-match failure; the REST handler carries literally `-- FIXME: add proper error handling` → opaque 500s. Protocol promises 6-month redeemability; a compacted node can mint proofs covering ~25 minutes. |
| **HIGH** | **Upgrading a previously-compacted node can fork it off the network.** A node compacted under the 20,000 window, upgraded and reaching fork 1 (window 525,600), has a *disconnected* header DB (`initBlockHeaderDb` re-inserts genesis every startup) → `minRank` reads 0 → guard never fires → `throwM TreeDbAncestorMissing`, which is **never caught anywhere in the tree** (verified). Full nodes return a clean "out of bounds"; this node throws and cannot validate. Their own comment: *"this behaviour may be dangerous in case of changes on the minimum block history."* |
| **HIGH (economic)** | **X-chain transfers become a hard 6-month deadline with permanent fund destruction and no recovery.** Verified: `transfer-crosschain` has two plain `(step` and **no `step-with-rollback`** anywhere in `coin.pact` — step 1 burns via `(emit-event (TRANSFER sender "" amount))`, step 2 is unreachable without a valid proof. No allowlist, quirk, or admin rescue in `src/`, `pact/`, or `allocations/`. Compounding: `/spv` roots proofs at the *earliest* reachable header and the in-window-root fix was **reverted** (`061ec789a`, 11 min after landing), so a late discovery cannot obtain a fresh proof. The mempool `preinsert` check catches only double-completion, not expiry — doomed continuations are mined and burn gas forever. Already destroyed real value per their own commit message. **No user-facing warning anywhere.** |
| **MED** | Fresh-node bootstrap has no checkpoint/fast-sync path and no way to discover archival peers. Survives only while enough operators decline to compact. |
| **MED** | **Zero public-network coverage.** Testnet06 — shipped *with* this release — has SPV expiry `Nothing`. Testnet04 is frozen at `Just 20_000` with `Chainweb31/32 = ForkNever`. Unit tests use a 20-block window. |

**Correctly defended:** rule determinism (pure function of header fields; registry validates monotonicity), deep reorgs (`defaultReorgLimit = 480` ≪ 525,600 — defence by coincidence), all `<` vs `<=` boundaries checked clean.

---

## 5. New gas model

### Mechanism

Data-driven `InitialGasModel` record replaces the hard-coded formula, selected per-chain by `Rule ForkHeight`:

```
G = ceiling( 0.01·(α·rawSize + β·proofSize + γ·sigsSize) + (C/512)^7 + Σ c(scheme) )

              α     β     γ     c(ED25519)  c(WebAuthn)
pre31        1.0   0.0   0.0       0          0          == 2.32 exactly
post31       1.0   1.0   0.0       0          0          == 3.1 exactly
post32       1.0   1.0   1.0      21.0      526.0        new
```

`pre31`/`post31` are byte-exactly equivalent to their predecessors. All arithmetic is `Rational`; one `ceiling` on the final sum; `Gas` is a saturating `SatWord`. **No overflow, no rounding exploit, no O(n²) path found.**

### Findings

| Sev | Finding |
|---|---|
| ~~HIGH~~ **REFUTED** | ~~The WebAuthn price is internally inconsistent by ~1000×.~~ **This finding was wrong and is withdrawn.** The transparency report states Pact's CPU pricing rate explicitly: **1 gas per 2.5 µs**. Both constants are correct and mutually consistent at that rate — WebAuthn 1,315,000 ns ÷ 2,500 = **526** ✓, ED25519 52 µs ÷ 2.5 µs = 20.8 ≈ **21** ✓. The real defect is the source comment `-- Benchmarked at 52 ns`, which should read **52 µs**; a 52 ns Ed25519 verify is ~150 CPU cycles and physically impossible. The original finding inferred the scale from a pact-core comment and picked the wrong side of the inconsistency. **No re-benchmarking is required before enabling `post32`.** (Still true: no test exercises WebAuthn pricing.) |
| **HIGH** | **Gas is charged after verification; the mempool applies no gas model at all.** `initialGasOf` appears in exactly two places, both post-`buyGas`. Signature verification runs on every mempool insert — unauthenticated, unmined, unpaid. `assertTxSize` (initial gas < gas limit) is **dead code in both Pact4 and Pact5** — verified zero call sites. This is a fee, not a rate limit. |
| **HIGH** | **testnet04 + recapDevnet activate `post31` at the wrong fork** (`Chainweb231Pact` instead of `Chainweb31`). Since testnet04 has `Chainweb31 = ForkNever`, 3.1 never charged proof bytes there but 3.2 will from height 5,783,986 → payload-hash mismatch → replay failure. The release commit fixed mainnet and left both others wrong. |
| **MED** | Mainnet `post31` activates one block later than 3.1 did (`succByHeight` keyed at 6,510,743 but consumed with the *parent* height). The sibling `_versionMaxBlockGasLimit` uses the same idiom with the *current* height — the two consumers disagree. |
| **MED** | Charged signature size is the canonical **re-encoding**, not on-wire bytes; `_cmdHash` covers only the payload, so signature bytes are **malleable** — a relay can inflate a third party's transaction on the wire without changing its gas. |
| **MED** | `assertSigSize` (100-sig cap) is not enforced on the block-validation path — only in the mempool and `/local`. Bounded by PoW + the 2 MB cap. |

### The two secondary claims

- **"almost 40 gas"** → actual **+22.38** (21.0 flat + 1.38 for the 138-byte encoded sig). Their own tests assert +22 twice (`PactServiceTest.hs:688→715`, `RemotePactTest.hs:349`). **Overstated ~1.8×**, in users' favour.
- **"prepares for post-quantum"** → `grep -rniE "dilithium|kyber|falcon|sphincs|post-?quantum|ml-dsa|slh-dsa|pqc"` over `src/` and `test/` returns **zero hits**. `PPKScheme` is a closed 2-constructor upstream type. Worse: the `\case` is **total** under `-Wall -Werror`, so adding a PQ constructor will *fail to compile* this file — a change-forcing point, not an extension point.

### Quirks (the replay fix)

`_quirkGasFees` pins hard-coded gas values for historical transactions whose Pact-4 module-cache-dependent metering can't be reproduced. `f3e097988` grew the mainnet table from 2 → 14 entries (heights 4.58–4.59 M, 12 chains). Missing entries cause a recomputed gas value → different tx output → different payload hash → **full replay from genesis fails**. Never present in this repo's history — a long-standing upstream omission, not a 3.2 regression. Irrelevant to a chain with its own genesis.

---

## 6. Security fixes

### CRITICAL — CVE-2026-9648 (undisclosed as such)

`crypton-x509-validation` does not enforce RFC 5280 NameConstraints → a holder of a name-constrained sub-CA can mint a certificate valid for **any** hostname. [CERT/CC VU#862559](https://kb.cert.org/vuls/id/862559). Fixed in **1.9.1**.

3.2 picks it up via the freeze bump (`crypton-x509{,-validation} 1.6.14/1.7.7 → 1.9.1`, `tls 2.1.11 → 2.4.3`). Their CHANGELOG files it only as "Upgrade several upstream libraries" — **no CVE mention anywhere in the release**.

### Full inventory (2.32 → 3.2)

| Sev | Fix | Class | Remote by unauth. peer? |
|---|---|---|---|
| CRITICAL | crypton-x509 → 1.9.1 | TLS cert forgery / MITM | **Yes** |
| HIGH | `460852eb1` signature gas | metering bypass → CPU exhaustion | **Yes** (public `/send` + gossip) |
| HIGH | `c13c0a1a1` continuation-proof gas | metering bypass → bandwidth/storage | **Yes** |
| HIGH | `392c5b88d` disallow duplicate cuts | CutDB DoS — heap admitted unlimited duplicates, evicting all legitimate cuts | **Yes** (`PUT /cut` only checks the *attacker-supplied* origin is in the peer DB) |
| HIGH | `1e3f63239` remove service date | hard-coded kill switch | No (time-triggered) |
| HIGH | SPV window churn | economic — stranded X-chain transfers | Indirect |
| MED | `24ae0b4e1` node-version header | `"2.32-community"` fails the dotted-integer parser → all community peers rejected | No |
| MED | `f3e097988` missing quirks | replay-blocking | No |
| MED | `2f11bda25` compaction off-by-one | seeks from `latestHeader` not `minBlockHeight` → deletes needed headers | No | **← StoaChain ALREADY HAS THIS FIX** (`Compaction.hs:786` reads `int minBlockHeight`); it arrived with our post-3.0 base. No backport needed. |
| MED | `58681f677` unknown fork number | consensus | Yes |
| MED | `5167be993` fork-vote off-by-one | consensus split at epoch boundary | Yes |
| MED | `5fd969c6c` cut buffer size 0 | liveness on diameter-0 graphs | Yes |
| MED-LOW | `1aa616ba0` defpact preinsert | mempool pollution | **Yes** |

### New risk introduced by 3.2

- **`--p2p-disable-cert-verification`** sets `TlsInsecure`: empty cert store, always-accept validation cache. Defaults off and warns — acceptable as shipped, but the help text and field comment both say "**Client** cert verification" when it disables *server*-cert verification on outbound connections. Misleadingly named, exposed as both CLI flag and JSON key.
- **The cut-queue fix is partial.** Dedup keys on `_cutHashesId`, priority on `_cutHashesWeight` — **both attacker-supplied, unvalidated JSON**. An attacker can still flood with distinct cuts claiming near-max weight. Their own comment: *"FIXME: this is problematic. We should drop these much earlier before they are even added to the queue."* Still open.
- **`isAcceptedVersion` is spoofable** — the peer self-reports its `NodeVersion` in an HTTP header. An operational filter, not a security control, still shipping with a hard-coded past date and a `fromJuste`.

---

## 7. StoaChain upgrade assessment

### Baseline correction

**StoaChain is not forked from 2.32.** Its true base is `4aedec3bb` ("Forks done right", 2025-11-19) — verified an **ancestor of 3.2**, contained in tags **3.1 and 3.2, not 2.32**. The `version: 2.32.0` string was hand-edited. `src/Chainweb/ForkState.hs` is **byte-identical** to upstream at that commit.

**Distance to 3.2: 110 commits / 95 files / +2,182 −1,205.** A real git merge-base exists.

### Divergence

54 Stoa commits over a squashed import. 66 modified + 17 added files, but only **15 files conflict** with upstream's changes, ~140 substantive lines:

- **Consensus-critical (5):** `Version/Stoa.hs`; `Pact5/TransactionExec.hs` (+18 — `applyCoinbase` injects a DEBIT magic cap and chain-stamped `coinbaseMeta` for the STOA vault); `cwtools/ea/Ea.hs` (+24 — chain-id stamping on genesis txs); `rewards/miner_rewards.csv` + `MinerReward.hs` SHA-512 pins; `Genesis/Stoa*Payload.hs`
- **Wiring (3):** `Registry.hs`, `Configuration.hs`, `Ea/Genesis.hs`
- **Collateral (44):** all non-Stoa genesis/transaction modules were regenerated by the patched `ea` and now carry hashes differing from upstream. Mainnet01/Testnet04 are effectively broken in our binary. Won't conflict, but is permanent unintended divergence.
- **Evaporating (2):** our `System.Hourglass → Time.System` and `asn1-* → crypton-asn1-*` patches — 3.2 makes byte-identical changes.

### Chain-data compatibility — definitive

**Drop-in binary swap. No resync, no chain restart, no hard fork of existing blocks.**

| Question | Answer |
|---|---|
| Block header binary format | **Unchanged.** The `FeatureFlags → ForkState` rename happened *at our base*. Merkle tag `0x0006` identical, `_versionHeaderBaseSizeBytes` unchanged. We already have the 3.x header format. |
| Pre-fork blocks still validate | **Yes**, with `_versionForkNumber = 0` and the fork table fixed (below). |
| RocksDB schema | **Unchanged.** `libs/chainweb-storage/` diff = 2 lines, both dependency renames. No DB version stamp exists anywhere. |
| Pact SQLite schema | **Unchanged.** No `CREATE TABLE`/`PRAGMA`/`user_version` in the diff. |
| Genesis payloads | **Unchanged.** Only 2 new Testnet06 files; no existing payload module modified. |
| merkle-log repin (0.2.0 → `c502176`) | **Safe.** `src/Data/MerkleLog.hs` is byte-identical; only `.cabal` bounds, CI, bench, tests changed. **Block hashes unaffected.** |

Caveat: it *is* a **coordinated fleet-wide restart** — `isAcceptedVersion` requires peers ≥ `NodeVersion [3,0]` after a now-past date, so node1 and node2 must cut over together. Rollback is clean because on-disk formats don't change.

### 🔴 Blockers

**1. `MigratePlatformShare` at genesis → total outage.**

```haskell
atNotGenesis _ ForkAtGenesis = error "fork cannot be at genesis"   -- Guards.hs:121
migratePlatformShare = checkFork atNotGenesis MigratePlatformShare -- Guards.hs:333
```

Our `Stoa.hs:37-38` wildcard maps **every** Fork to `ForkAtGenesis`. `applyUpgrades` falls through to the `migratePlatformShare` guard because `_versionUpgrades = AllChains mempty`, and `applyCoinbase` calls it unconditionally → `error` on every block. Compiles fine; fails loud at runtime. Testnet06 correctly sets `ForkNever`.

Had it not errored, `doMigratePlatformShare` would have overwritten 16 keysets (`PS_C0..9`, `ns-admin-keyset`, `ns-operate-keyset`, `kip-ns-admin`, `marmalade-admin`, `util-ns-admin`, `flux-ns-admin`) with **Kadena's five community public keys.**

**2. `pact-5-special-fix` is unobtainable** — see §2. No downstream phase can be validated until resolved.

### Required `Stoa.hs` edits

| # | Action |
|---|---|
| 1 | ADD `import Chainweb.Pact5.InitialGasModel` |
| 2 | **REPLACE the wildcard fork table:** `Chainweb31 → ForkNever`, `Chainweb32 → ForkNever`, `MigratePlatformShare → ForkNever`, `_ → ForkAtGenesis` |
| 3 | RENAME `_versionMinimumBlockHeaderHistory` → `_versionSpvProofRootValidWindow` (value `Bottom (minBound, Nothing)` unchanged — **keeps us free of every SPV finding in §4**) |
| 4 | ADD `_versionInitialGasModel = AllChains $ Bottom (minBound, pre31GasModel)` — **not** `post32GasModel`; `Development.hs` is the wrong template |
| 5 | ADD `_versionForkVoteCastingLength = 120 * 119` — must be exactly this to reproduce the base's hardcoded `forkEpochLength` bit-for-bit |
| 6 | KEEP `_versionForkNumber = 0` — all live Stoa headers carry `fnum = 0` |
| 7 | No change needed: graphs, delay, window, header size, bootstraps, genesis, gas limit, cheats, defaults, verifier plugins |

Template to follow: **`Version/Testnet04.hs` @ 3.2** (a live chain migrated with zero resync). **Not** `Development.hs`.

### Dependency situation — 3.2 fixes our current pain

Our last three commits are all firefighting the crypton graph. Our `cabal.project:100` pins `crypton == 1.0.4`. **`crypton-x509-validation-1.9.1` requires `crypton >= 1.1 && < 1.2`** — so our pin *blocks the CVE fix*. 3.2 completes the `memory → ram` migration properly (`crypton >= 1.1.2`, `ram >= 0.2.2`, `merkle-log >= 0.2.1`). **Delete our three pins and the `bytesmith < 0.3.14` pin; take 3.2's `cabal.project` wholesale.**

Our exposure is real: `domainAddr2PeerInfo = fmap (PeerInfo Nothing)` — our bootstraps carry **no pinned fingerprint**, so they fall through to `getSystemCertificateStore`, the CVE-affected path.

**Docs correction:** [CLAUDE.md](CLAUDE.md) says `_disablePeerValidation = True` "allows self-signed certificates between peers." **Wrong.** It has exactly two uses: skipping `validateP2pConfiguration` and permitting reserved/RFC1918 peer addresses. Nothing to do with TLS.

### Toolchain

GHC **9.10.1 → 9.10.2** (3.2's freeze pins `base ==4.20.1.0`). Cabal 3.8 unchanged. Note 3.2's own `Dockerfile:56` still says `ARG GHC_VERSION=9.10.1`, contradicting its freeze — an upstream bug that will break our container path.

### Migration plan — strategy (B) merge, via graft

**Phase 0 — Repo topology (0.5 d).** `git remote add kdac …`; `git replace --graft 44c59b5 4aedec3bb…` so git computes the correct 3-way base. Verify `git merge-base HEAD 3.2` = `4aedec3`. Rollback: `git replace -d`.

**Phase 1 — 🔴 Unblock `pact-5-special-fix` (0.5 d + unbounded).** External. Do first; nothing downstream validates without it.

**Phase 2 — Merge and resolve (1.5–2 d).** 15 conflicts. Take theirs wholesale: `SelfSigned.hs`, `Chainweb.hs`, `LICENSE`, `CHANGELOG.md`. Take theirs + re-apply our hunk: `Registry.hs` (note `versionMap` is now `[mainnet, testnet06]`), `Configuration.hs`, `Ea.hs`, `Ea/Genesis.hs`, `chainweb.cabal`. `TransactionExec.hs`: all three Stoa anchors survive verbatim in 3.2 — re-apply the DEBIT cap + `coinbaseMeta`. `cabal.project`: take 3.2's entirely.

**Phase 3 — Rewrite `Stoa.hs` (1 d).** The 7 edits above. Add a unit test asserting `registerVersion stoa` succeeds and `migratePlatformShare stoa cid h == False` (it currently *throws*).

**Phase 4 — Toolchain green (1–2 d).** GHC 9.10.2, adopt 3.2's freeze, fix `Dockerfile`/`deploy.sh`. Keep Stoa Dockerfile deltas (`libmpfr`, `cwtools:exe:ea`, disabled slowtests, `stoa-node` stage).

**Phase 5 — 🔴 Offline replay validation on a DB copy (2–3 d) — THE GATE.** Snapshot live RocksDB + Pact SQLite. Boot 3.2 against the **copy** with `--prune-chain-database=full` to force `validateBlockHeaderM` over every stored header. Then wipe only the Pact SQLite and replay from RocksDB — this proves gas + Pact 5.4.1 determinism end-to-end and is the highest-value test in the plan. Never run `--prune-chain-database` on production before this passes.

**Phase 6 — Test suite (1–2 d).** Expect breakage in `MinerReward.hs` and any test constructing a `ChainwebVersion` literal. Upstream also changed `TestVersions.hs`, `PQueue.hs`, `TaskQueue.hs` and added `migratePlatformShareTest`.

**Phase 7 — Staging + cutover (1–2 d).** Throwaway 2-node network from the DB copy. **Simultaneous** cutover on node1+node2. Keep old binary + snapshot. Rollback is clean.

**Total: 8.5–13 engineer-days**, plus unbounded Phase 1.

### Additional risks

| Sev | Risk |
|---|---|
| HIGH | `Chainweb32 → ForkAtGenesis` would make `chainweb32` always true (`ForkAtGenesis` is `minBound`) → clears `FlagDisablePact54Fix` → Pact 5.4.1 semantics applied retroactively → replay divergence. Same root cause as blocker 1. |
| MED | Our `ea` patch changed all 44 non-Stoa genesis modules (`Mainnet0Payload` expectedHash `k1H3Ds…` → `V0ou4Ns…`). Any future `ea` run must be understood as Stoa-only. |
| MED | pact-4 (`4208012e → ef859d8b`) and pact-5 pins not inspectable. Chainweb gates the *known* 5.4.1 change, but ungated behaviour changes inside those pins can't be ruled out. Phase 5 replay is the mitigation. |
| MED | 3 of 9 `source-repository-package` blocks at 3.2 lack `--sha256`. |
| LOW | 3.2's `default.nix` `overridePact` is silently dead — its awk matches `kadena-io/pact.git` but 3.2 says `kda-community/pact.git`. |
| LOW | Three tracked 0-byte junk files in our repo root (`=`, `naming`, `unpacking`) — shell-redirect artifacts from the squashed import. |

---

## 8. Recommendation

**Do not adopt 3.2 wholesale right now.** Phase it.

**Now — no fork required, high value:**
1. **Break the `crypton == 1.0.4` pin and take CVE-2026-9648's fix.** This is the single highest-value action in this document and needs no consensus change. Adopting 3.2's dependency graph is the cleanest route.
2. **Backport the PQueue dedup** (`392c5b88d` + `5fd969c6c`) — non-consensus, self-contained, closes a remote cut-flood DoS. Backport the `Priority` sign flip at `CutDB.hs:823` *together with it*.
3. **Backport `1aa616ba0`** (defpact preinsert) — mempool-only, strictly rejects more. **Verified cherry-picks CLEAN.**
4. ~~Backport `2f11bda25`~~ — **not needed, we already have it.**
5. **Fix the CLAUDE.md TLS claim.**

### Cherry-pick feasibility (measured, not estimated)

Because our base `4aedec3bb` is a genuine ancestor of 3.2, upstream commits can be `git cherry-pick`ed rather than hand-reimplemented. Tested in a disposable clone:

| Commit | Result |
|---|---|
| `5fd969c6c` minimum cut queue size | **CLEAN** |
| `1aa616ba0` defpact preinsert check | **CLEAN** |
| `392c5b88d` disallow duplicate cuts | 1 conflict (`CutDB.hs`); `Data/PQueue.hs` + `WebBlockHeaderStore.hs` + all 3 test files apply clean |
| `c13c0a1a1` continuation-proof gas | all **source** files clean; 1 test file conflicts |
| `460852eb1` InitialGasModel | 10 conflicts — but the new `InitialGasModel.hs` itself applies clean; every conflict is `ForkNumber` plumbing |
| `52b872fbf` disable cert verification | conflicts (and we don't want it anyway) |

**The split is exactly along the ForkNumber line:** anything not threading `ForkNumber` through `Rule ForkHeight` ports cleanly.

### Pact version reality check

Our pin `kadena-io/pact-5@bfc5310c` reports `version: 5.4` — **we are already on Pact 5.4.** The gap to 5.4.1 is exactly one patch release, and that patch is the embargoed security fix. We are not generally behind on Pact.

**Next — the full port.** The migration is genuinely tractable (110 commits, 15 conflicts, clean rollback) and gets us onto a maintained upstream. Phase 1 is now satisfied; the only remaining gate is Phase 5 (replay validation).

**Worth taking:**
- **The gas model.** Clean, version-parameterized, and it closes issues H-1 and H-2 (unmetered signature size and verification CPU). Both gas constants are correct as shipped \u2014 no re-benchmarking needed. Note our `_versionMaxBlockGasLimit = 2_000_000` (vs mainnet's 180,000) means the `(C/512)^7` penalty bites at a much larger transaction size — recompute our effective max tx size.
- **Fork-number voting**, if we ever want more than one validator. Every adversarial finding in §3 is a mainnet-scale multi-miner problem; on a 10-chain network where we run the miners, `_versionForkVoteCastingLength` is just a knob. Set `Chainweb31/32 → ForkNever` for now and adopt later.

**Not worth taking:**
- **SPV expiry.** Keep `_versionSpvProofRootValidWindow = Bottom (minBound, Nothing)`. It buys us ~45 GB of header pruning we don't need at our chain size, in exchange for permanent X-chain fund destruction, a compaction/upgrade footgun that can fork a node off the network, and a feature untested on any public network. If we want a smaller DB, the `compact` tool already delivers ~90% of the saving today, on 2.32, with none of this.

**Ask kda-community:** whether the testnet04/recapDevnet `post31` fork key (`Chainweb231Pact` instead of `Chainweb31`) is a known bug \u2014 the other two questions were answered by the transparency report and the 3.2.1 release.
