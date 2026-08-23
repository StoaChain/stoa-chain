# StoaChain — Selective Backport Plan from chainweb-node 3.2

**Strategy:** cherry-pick selected upstream commits onto StoaChain `main` rather than merging the 3.2 tree.
**Baseline:** our base `4aedec3bb` is a genuine ancestor of 3.2 → cherry-pick works natively.
**Feasibility:** measured in a disposable clone, not estimated. Applying the candidate set in upstream order: **16 clean / 12 needing manual resolution**, and most conflicts are one small file.

```bash
git remote add kdac https://github.com/kda-community/chainweb-node.git
git fetch kdac --tags
```

> **Key advantage of this path:** the `MigratePlatformShare` blocker — `error "fork cannot be at genesis"` on every block — is introduced by `3149131c8 Platform share migrate`, a community-mainnet 3.0 commit **we do not take**. It is absent from our tree today. On the selective path that blocker never exists. It only appears if you merge their whole tree.

---

## Wave 0 — CVE-2026-9648 · do this first · not a cherry-pick

The fix is `crypton-x509-validation >= 1.9.1`, which needs `crypton >= 1.1 && < 1.2`. Our `cabal.project:100` pins `crypton == 1.0.4`, which **blocks it**. Their commits touch a `cabal.project` that has diverged from ours, so hand-edit rather than cherry-pick:

1. Delete our constraint block (`cabal.project:99-102`): `crypton == 1.0.4`, `memory == 0.18.0`, `merkle-log == 0.2.0`.
2. Delete the `bytesmith < 0.3.14` pin (`cabal.project:244`).
3. Repoint source-repository-packages from `kadena-io/*` → `kda-community/*` (the kadena-io repos are being archived), and add `merkle-log` → `kda-community/merkle-log@c502176`. **Verified safe:** `src/Data/MerkleLog.hs` is byte-identical to 0.2.0; only `.cabal` bounds, CI, bench and tests differ. Block hashes cannot move.
4. Keep `kadena-io/pact-5@bfc5310c` for now — it is already `version: 5.4`.

Then these two apply clean and complete the `memory → ram` migration:

| Commit | Files | Status |
|---|---|---|
| `336aa4c5f` Bump crypton, memory→ram for cwtools | 1 | **CLEAN** |
| `9598bdb2a` Bump crypton, memory→ram for chainweb-storage | 1 | **CLEAN** |

Adapt by hand (they conflict because our `cabal.project`/`chainweb.cabal` diverged): `24ec33804`, `2dadedf75`, `4d6ff1912` (bound `validation` to 1.1).

**Verify:** `cabal build chainweb` resolves `crypton-x509-validation-1.9.1`.
**Effort:** 0.5–1 d. **No consensus impact. No fork. No coordination.**

---

## Wave 1 — Build compatibility · all clean

| Commit | What | Status |
|---|---|---|
| `37c28c7dc` | `ChainMap` instance of `Unzip` (needed by SemiAlign 1.4) | **CLEAN** |
| `0ebc2ba3a` | Import `Counter` qualified — supersedes our `hiding (Port, Counter)` hack | **CLEAN** |
| `4718f02a2` | `Field` instances for `T4` | **CLEAN** |
| `5cff7ad47` | Typo fixes | **CLEAN** |

Also drop our now-redundant `asn1-* → crypton-asn1-*` and `hourglass → time-hourglass` edits — 3.2 makes byte-identical changes upstream.

**Effort:** 0.5 d.

---

## Wave 2 — P2P / DoS hardening · the security payload

Apply **in this order** — `392c5b88d` conflicts standalone but goes **clean** after the two that precede it.

| # | Commit | What | Status |
|---|---|---|---|
| 1 | `84e4eb6cb` | More flexible `readHighestCutHeaders` | conflict: `CutDB.hs` (1 file) |
| 2 | `5fd969c6c` | Minimum cut queue size (`max 10 $ order² · diameter`) | **CLEAN** |
| 3 | `392c5b88d` | **Disallow duplicate cuts** — PQueue heap → keyed STM map | **CLEAN in sequence** |

`392c5b88d` is the highest-value security item after the CVE. 2.32-era code lets an unauthenticated peer flood `PUT /cut` with copies of one cut and evict every legitimate pending cut. `cutPutHandler` only checks that the *attacker-supplied* origin address exists in the peer DB — not that the requester is that peer.

⚠️ It also flips `Priority` semantics — the single production call site changes to `Priority (int (_cutHashesHeight hs))` (was negated). The cherry-pick carries this; **do not split these commits**, or fetch order inverts.

**Known limitation:** this does *not* close the forged-weight flood. Dedup keys on `_cutHashesId`, priority on `_cutHashesWeight` — both attacker-supplied and unvalidated. Upstream's own comment: *"FIXME: this is problematic. We should drop these much earlier before they are even added to the queue."* Still open in 3.2.

**Effort:** 1 d. **No consensus impact — safe to ship independently.**

---

## Wave 3 — Mempool

| Commit | What | Status |
|---|---|---|
| `1aa616ba0` | Reject already-completed defpact continuations at pre-insert | **CLEAN** |

Mempool-only, strictly rejects more; a node without it validates blocks identically. Stops cheap mempool/block pollution with guaranteed-failing cross-chain replays.

**Effort:** 0.25 d.

---

## Wave 4 — ForkNumber refactor · OPTIONAL, decide deliberately

Needed only if you want the gas model wired upstream-style, or want miner voting later. **Skippable** — see the Wave 5 alternative.

Apply in this order:

| Commit | Status |
|---|---|
| `4ded15d8a` rename `versionMinimumBlockHeaderHistory` → `versionSpvProofRootValidWindow` | **CLEAN** |
| `11d2f38ff` add it to `Ord ChainwebVersion` | **CLEAN** |
| `2cc3c86d2` `s/Chainweb232Pact/Chainweb31` | conflict: 6 files (version modules + TestVersions) |
| `20dca058c` `infixr Above` | **CLEAN** |
| `df732599e` allow overriding target fork number | **CLEAN** |
| `5167be993` off-by-one in forkstate validation + vote length in version | **CLEAN** |
| `58681f677` reject blocks with unknown fork number | **CLEAN** |
| `21b9bde45` comment update | **CLEAN** |
| `23f2ccca3` delete unused `Fork`s | conflict: `Guards.hs` |
| `7d02e2a2f` **extend `ForkHeight` with `ForkAtForkNumber`** | conflict: `Guards.hs`, `TestVersions.hs` |
| `489728fb9`, `92fff2a02` review fixes/comments | conflict: `Version.hs` (small) |
| `dd5a906b2` `maxBlockGasLimit`/`minimumBlockHeaderHistory`/`verifiersAt` use ForkNumber | conflict: 3 files |
| `4e7fb56b4` header compaction keyed on ForkNumber | **CLEAN** |
| `e0f4b5f4c` forbid height rules after Chainweb31 | conflict: 2 files |
| `e64444cd4` review fixes | conflict: 3 files |
| `52c1a46c2` forbid `ForkAtForkNumber 0` | conflict: `Registry.hs` |

Conflicts cluster in exactly two places: (a) `Version.hs`/`Guards.hs` where our Stoa work sits, and (b) *other chains'* version modules + `TestVersions.hs`, where "take theirs" is nearly always right.

**Then `Stoa.hs` needs:**
- `_versionMinimumBlockHeaderHistory` → `_versionSpvProofRootValidWindow`, value stays `Bottom (minBound, Nothing)`
- ADD `_versionForkVoteCastingLength = 120 * 119` — must be exactly this to reproduce the base's hardcoded `forkEpochLength` bit-for-bit
- KEEP `_versionForkNumber = 0`
- Set `Chainweb31 → ForkNever`, `Chainweb32 → ForkNever` explicitly. **Do not leave them on the wildcard** — `ForkAtGenesis` is `minBound`, so `chainweb32` would read as always-true and retroactively change Pact semantics.

**Effort:** 2–3 d. ⚠️ Touches consensus-adjacent code — requires the replay test (below).

---

## Wave 5 — Gas model

**Path A (after Wave 4):**

| Commit | Status |
|---|---|
| `c13c0a1a1` charge gas for continuation proof size | **CLEAN in sequence** |
| `460852eb1` InitialGasModel + charge signatures | conflict: `TestVersions.hs` only (down from 10 standalone) |

**Path B (skip Wave 4 entirely):** `src/Chainweb/Pact5/InitialGasModel.hs` is self-contained and applies clean on its own. Port it and select the model with a plain `BlockHeight` guard instead of `Rule ForkHeight`. ~1 d, leaves `Version.hs` untouched.

**Before enabling `post32`:**
- ~~Re-benchmark WebAuthn.~~ **Withdrawn 2026-08-03.** At the disclosed rate of 1 gas per 2.5 µs both constants are correct: WebAuthn 1,315,000 ns ÷ 2,500 = 526 ✓, ED25519 52 µs ÷ 2.5 µs ≈ 21 ✓. The source comment `-- Benchmarked at 52 ns` is the typo (should be 52 µs). Ship the constants as-is.
- **This wave closes issues #3 and #4** — unmetered signature *size* and unmetered signature *verification CPU*. Both are live on StoaChain and our exposure is worse than mainnet's, because our block gas limit is ~10× theirs.
- **Recompute our max transaction size.** The `(C/512)^7` penalty reaches our `_versionMaxBlockGasLimit = 2_000_000` at a very different point than mainnet's 180,000.
- Gate it at a **future block height**, never at genesis — activating retroactively changes gas for historical transactions → payload-hash mismatch → replay failure.

**Effort:** 1–2 d.

---

## Wave 6 — Pact 5.4.1 · **UNBLOCKED 2026-08-03** · closes issues #1 and #2

Source is public. `kda-community/pact-5` tag **`5.4.1`** = `72f427605406df61be8284091922f1fe1af7541b`, verified `version: 5.4.1` and containing both fixes. Chainweb **3.2.1** (`d89bb530`) pins exactly this.

**This wave is the whole point of the exercise** — it closes issue #1 (identity forgery via `addr`, critical auth bypass) and issue #2 (capability theft via `compose-capability`). Both are live on StoaChain today.

Steps:
1. Repoint the pact-5 `source-repository-package` to `https://github.com/kda-community/pact-5` tag `72f42760…`. Note upstream ships **no `--sha256`** for `pact`, `pact-5` or `merkle-log`; generate ours with `nix-prefetch-git` if we care about the Nix path.
2. Take `guardDisablePact54FixFlags` (`Pact5/TransactionExec.hs`) — it needs a `chainweb32` guard, so it depends on Wave 4 (or a height-gated equivalent).
3. **Choose the activation point deliberately** — see the warning below. Skip the mainnet quirk table (`f3e097988`); it is mainnet-history-only and irrelevant to our genesis.

> ### ⚠️ Do not activate the Pact fixes at genesis
>
> The fixes are gated by `FlagDisablePact54Fix`, which is *cleared* when `chainweb32` is true. Our wildcard fork table would make `Chainweb32 = ForkAtGenesis` — `minBound` — so `chainweb32` reads as **always true** and the fixed semantics would apply to our **entire history**. If any historical StoaChain transaction used an `addr` field or a cross-module `compose-capability`, replay diverges and the node rejects its own chain.
>
> Set `Chainweb32` to a **future block height** (or `ForkAtForkNumber 1` if adopting voting). History then replays under the old semantics, and only new blocks get the fix. This is exactly what upstream did.
>
> Alternative, if you want the fix live immediately: scan our chain for any transaction carrying a signer `addr` or a cross-module `compose-capability`. On a small private chain there are almost certainly none, in which case `ForkAtGenesis` replays identically — but the replay test must prove it rather than assuming.

---

## Do NOT take

| Commit | Why |
|---|---|
| `3149131c8` Platform share migrate | Adds `MigratePlatformShare` + Kadena's five community keysets. **Source of the genesis-crash blocker.** Skipping it keeps the whole problem out of our tree. |
| `56dacf4c4`, `2802baee9` bootstraps/repos | Kadena mainnet bootstrap nodes |
| `abab307eb`, `cfed1230d`, `ea4344f49`, `e60dd0ff7`, `d82d11d6f`, `5e46fa79f` | Community version-string bumps |
| `24ae0b4e1` version header | Fixes a `"-community"` suffix we never had |
| `ade03946b` accept only post-fork peers | Hard-coded past date + spoofable self-reported `NodeVersion` |
| `1286b1813` / `828fc7038` community fork rewind | Kadena-fork-specific startup rewind |
| `580cde83d` delay migration | Mainnet migration timing |
| `52b872fbf` disable cert verification | **Weakens security.** Sets `TlsInsecure` — empty cert store, always-accept cache. Also misdocumented as "*Client* cert verification" when it disables server-cert verification on outbound connections. |
| `9422947b9` Testnet06 | Their new testnet |
| `f3e097988` missing quirks (table) | Mainnet history only; we have our own genesis |
| `8b43600c7`, `0ae653039` | Mainnet SPV/fork heights |
| `d07ed7a7f` devnet MigratePlatformShare | Moot once `3149131c8` is skipped |
| SPV expiry (`_versionSpvProofRootValidWindow = Just …`) | **Keep it `Nothing`.** Buys ~45 GB of header pruning we don't need, in exchange for permanent X-chain fund destruction, a compaction/upgrade path that can throw an uncaught `TreeDbAncestorMissing` and fork a node off the network, and a feature not exercised on any public network. |

## Already ours — no action

- `2f11bda25` compaction off-by-one — `Compaction.hs:786` already reads `int minBlockHeight`
- Full `compact` tool — `cwtools/compact/Main.hs`, same CLI
- `src/Chainweb/ForkState.hs` — byte-identical to upstream
- Block header format incl. `ForkState` field and Merkle tag `0x0006`
- `1e3f63239` service-date removal — our `_versionCode 0x0000_000A` is exempt anyway

---

## Validation gate — run before ANY consensus-touching wave reaches production

Waves 0–3 are non-consensus and can ship on normal testing. Waves 4–6 must clear this:

1. Snapshot the live RocksDB + Pact SQLite from `node1`.
2. Boot the new binary against the **copy** with `--prune-chain-database=full` — forces `validateBlockHeaderM` over every stored header offline. Never run this on production first.
3. Wipe **only** the Pact SQLite on the copy; let it replay from RocksDB. This proves gas and Pact determinism end-to-end and is the single highest-value test available.
4. Assert `Stoa0Payload.payloadBlock` loads without the `expectedHash` error.
5. Two-node staging network from the copy before cutover.

Cutover must be **simultaneous** on node1 + node2 (`isAcceptedVersion` requires peers ≥ `NodeVersion [3,0]`). Rollback is clean — no on-disk format changes.

---

## Summary

| Wave | Scope | Consensus? | Effort |
|---|---|---|---|
| 0 — CVE + deps | dependency graph | no | 0.5–1 d |
| 1 — build compat | 4 commits, all clean | no | 0.5 d |
| 2 — P2P/DoS | 3 commits, 1 conflict | no | 1 d |
| 3 — mempool | 1 commit, clean | no | 0.25 d |
| 4 — ForkNumber *(optional)* | 16 commits, 8 conflicts | **yes** | 2–3 d |
| 5 — gas model | 2 commits (or Path B) | **yes** | 1–2 d |
| 6 — Pact 5.4.1 | dependency repin + fork gate | **yes** | 0.5–1 d |

### Revised priority (2026-08-03)

The transparency report changes the calculus. Waves 4–6 are no longer optional polish — **Wave 6 closes the two critical vulnerabilities (#1 identity forgery, #2 capability theft) that StoaChain is exposed to today**, and Wave 5 closes #3 and #4, where our exposure is worse than mainnet's.

Recommended sequence:

1. **Waves 0–3 first** (~2.5 d) — no fork, no coordination, closes #5 (CVSS 9.1 CVE), #6 (cut-flood DoS) and #8. Ship independently and immediately.
2. **Waves 4 + 5 + 6 together** (~4–6 d) — one coordinated fork closing #1, #2, #3, #4. They share the ForkNumber plumbing and one activation point, so doing them as a single fork is both less work and less risk than three separate ones.

Target **chainweb 3.2.1**, not 3.2 — same code, buildable from source.

### Container build — everything needed is now available

| Component | Source | Status |
|---|---|---|
| chainweb-node 3.2.1 | `kda-community/chainweb-node` tag `3.2.1` | public |
| Pact 5.4.1 | `kda-community/pact-5` tag `72f42760` | public |
| Pact 4 | `kda-community/pact` tag `ef859d8b` | public |
| merkle-log | `kda-community/merkle-log` tag `c502176` | public, `src/` byte-identical to 0.2.0 |
| all other pins | `kda-community/*` | public, `--sha256` present |
| Dockerfile + `stoa-node` stage | ours | already in repo |

Only change needed for the container: `ARG GHC_VERSION` 9.10.1 → **9.10.2** (3.2.1's freeze pins `base ==4.20.1.0`). Upstream's own Dockerfile still says 9.10.1 and contradicts its freeze — do not copy that.
