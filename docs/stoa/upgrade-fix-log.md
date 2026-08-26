# Upgrade fix log — `upgrade/chainweb-3.2.1`

A running record of **every** change applied on this branch, in order. One entry per commit.

Purpose: so that six months from now we can answer "what did we change, why, and what breaks if it's reverted?" without reading the diff. Issue numbers refer to [`vulnerabilities-fixed-in-3.2.md`](vulnerabilities-fixed-in-3.2.md); wave numbers to [`container-build-plan.md`](container-build-plan.md).

**Branch base:** `main` @ `7c3400f34`
**Target:** chainweb `3.2.1` (`d89bb530`) + Pact `5.4.1` (`72f42760`)
**Upstream remote:** `kdac` = `https://github.com/kda-community/chainweb-node.git`

| # | Commit | Wave | Closes | Summary |
|---|---|---|---|---|
| 1 | `ce33454d3` | 0 | **C-1** | Adopt 3.2.1 dependency graph; unblock CVE-2026-9648 |
| 2 | `4ceb23b78` | 0 | **C-1** | Update dependency bounds in the three `.cabal` files |
| 3 | `7eaa8f8ea`, `83982b9fb`, `201f42ee5`, `4ffd21cd3` + fixup | 1 | — | Build compatibility for the new dependency graph |
| 4 | `d9c91ff4c`, `1975d45c6`, `af4ab9fc8` | 2 | **H-3** | Cut-queue duplicate-flood DoS fix |
| 5 | `5025933a4` | 3 | **M-1** | Reject completed-defpact continuations at mempool pre-insert |
| 6 | `cbc5ca363` | - | - | Dockerfile GHC 9.10.1 -> 9.10.2 |
| 7 | `dddff65c6`, `ccf2baf4d` | - | - | Remove 5 redundant imports; **waves 0-3 compile and link** |

---

## Fix 1 — `ce33454d3` · adopt the 3.2.1 dependency graph

**Closes issue C-1** — CVE-2026-9648 ([CERT/CC VU#862559](https://kb.cert.org/vuls/id/862559), CVSS 9.1). `crypton-x509-validation` does not enforce RFC 5280 NameConstraints, so a holder of a name-constrained sub-CA can mint a certificate valid for **any** hostname. Fixed upstream in 1.9.1.

**Why it was blocked on us:** 1.9.1 requires `crypton >= 1.1`, and our own `cabal.project` pinned `crypton == 1.0.4`. Our bootstraps are built with `domainAddr2PeerInfo = fmap (PeerInfo Nothing)` — no pinned certificate fingerprint — so they fall back to `getSystemCertificateStore`, which is the affected path.

**Method:** took upstream 3.2.1's `cabal.project` wholesale, then repointed two locations at StoaChain forks. Verified beforehand that our file differed from theirs in exactly four things and nothing else.

| Change | Detail |
|---|---|
| Removed constraint block | `crypton == 1.0.4`, `memory == 0.18.0`, `merkle-log == 0.2.0`. These were a workaround for crypton 1.0.5+ migrating `memory` → `ram`; 3.2.1 completes that migration properly, so they are obsolete. |
| Removed `bytesmith < 0.3.14` | A GHC 9.6 `text-2.0` workaround, no longer needed. |
| `kadena-io/*` → `kda-community/*` | All source-repository-packages. The kadena-io repos are being archived. |
| `pact-5` → `StoaChain/pact-5` @ `72f42760` | Tag `5.4.1`. Carries the fixes for issues **SC-1** and **SC-2**. |
| `pact` → `StoaChain/pact` @ `ef859d8b` | Pact 4.13.2. **Still required** — see note below. |
| Added `merkle-log` source pin | `kda-community/merkle-log` @ `c502176`. |
| Dropped `allow-newer` entries | `wai-middleware-validation:*`, `validation:*`. |

**Safety checks performed:**
- `merkle-log` 0.2.0 → `c502176`: `src/Data/MerkleLog.hs` is **byte-identical**; only `.cabal` bounds, CI, bench and tests differ. **Block hashes cannot move.**
- No `kadena-io` pins remain; both blocking constraints gone; pact-5 confirmed at 5.4.1.

**Why Pact 4 is still a dependency** (it is not dead weight we can drop yet): `chainweb.cabal` lists `pact >= 4.2.0.1` in four stanzas, and **46 modules outside `src/Chainweb/Pact4/`** import Pact 4 types — including `src/Chainweb/Pact5/TransactionExec.hs` and our own `Version/Stoa.hs` (for `VerifierName`). The coupling is type-level vocabulary, not evaluation logic, but removing it is a large refactor that would break cherry-pick compatibility with upstream. Deliberately deferred.

**Residual divergence from upstream:** exactly two lines — the StoaChain fork URLs.

**If reverted:** the CVE returns and the build falls back to `crypton 1.0.4`.

---

## Fix 2 — dependency bounds in the `.cabal` files

**Completes issue C-1.** `cabal.project` now *permits* the new dependency graph, but the `.cabal` files still declared the old bounds and still named `memory` and `cryptonite`. Without this the solver cannot pick `crypton-x509-validation 1.9.1`.

**Method:** targeted line edits rather than cherry-picking `2dadedf75` / `336aa4c5f` / `9598bdb2a`. Those conflicted because they assume each other's ordering and our `.cabal` files carry Stoa-specific module entries. Editing the bounds directly keeps the change minimal and leaves version strings and Stoa entries untouched.

**`chainweb.cabal`** — 12 lines:

| From | To | × |
|---|---|---|
| `crypton >= 0.31` | `crypton >= 1.1.2` | 3 |
| `crypton-asn1-encoding >=0.9` | `crypton-asn1-encoding >= 0.10.0` | 1 |
| `crypton-asn1-types >=0.3` | `crypton-asn1-types >= 0.4.1` | 1 |
| `crypton-x509 >=1.7` | `crypton-x509 >= 1.8` | 1 |
| `time-hourglass >=0.3` | `time-hourglass >=0.2` | 1 |
| `memory >=0.14` | `ram >=0.2.2` | 2 |
| `merkle-log >=0.2` | `merkle-log >=0.2.1` | 3 |

**`cwtools/cwtools.cabal`** — 2 lines: `crypton` → `crypton >= 1.1.2`, `memory` → `ram >=0.2.2`.

**`libs/chainweb-storage/chainweb-storage.cabal`** — 2 lines: `cryptonite >= 0.25` → `crypton >= 1.1.2`, `memory >=0.14` → `ram >=0.2.2`. Note this file was still on the pre-crypton `cryptonite` package.

**Verified:** all dependency lines in all three files now match upstream 3.2.1 exactly. The only residual difference is the source-order of two `crypton-asn1-*` entries — cosmetic. No bare `memory` or `cryptonite` dependencies remain anywhere.

**Not yet proven:** that the solver actually resolves `crypton-x509-validation` to 1.9.1. This is a declaration change only; confirmation requires the first `cabal build`, which is the next milestone.

**If reverted:** the solver falls back to the old bounds and `ram`-based crypton will not resolve, breaking the build.

---

## Fix 3 — Wave 1 · build compatibility

Four upstream commits, cherry-picked directly (all applied clean), plus one fixup to remove a Stoa-local hack that upstream had solved properly.

| Commit | Upstream | What and why |
|---|---|---|
| `7eaa8f8ea` | `5cff7ad47` | Typo fixes across `BlockHeader/Validation.hs` and `ForkState.hs`. Cosmetic, taken to keep divergence at zero. |
| `83982b9fb` | `37c28c7dc` | `ChainMap` gains an `Unzip` instance (`ChainId.hs`). **Required by SemiAlign 1.4**, which the new dependency graph from fixes 1–2 pulls in. Without it the library will not compile. |
| `201f42ee5` | `0ebc2ba3a` | Import `Chainweb.Counter` qualified in `Chainweb.hs` instead of relying on a `hiding` clause. |
| `4ffd21cd3` | `4718f02a2` | `Field` instances for `T4` in `Utils.hs`. |

**Fixup — removed a Stoa-local hack.** Our `Chainweb.hs` carried `import Network.Wai.Handler.Warp hiding (Port, Counter)`; upstream has `hiding (Port)`. The cherry-pick of `0ebc2ba3a` added the qualified `Chainweb.Counter` import but left our extra `, Counter` in place, because the conflicting token was outside the patch context. With the qualified import present, hiding `Counter` from Warp is redundant divergence, so it was removed to match upstream exactly.

**Verified:** the `import` block of `src/Chainweb/Chainweb.hs` is now **byte-identical** to upstream 3.2.1. The only two remaining differences in that file are `maxBlockGasLimit v maxBound maxBound` (arrives in wave 4, ForkNumber signatures) and `readHighestCutHeaders mCutDb` (arrives in wave 2, `84e4eb6cb`) — both expected and scheduled.

**If reverted:** the tree will not compile against the wave 0 dependency graph — `ChainMap`'s missing `Unzip` instance is a hard build failure under SemiAlign 1.4.

## Fix 4 — Wave 2 · cut-queue duplicate-flood DoS

**Closes issue H-3.** Before this, `Data/PQueue.hs` was a `Data.Heap` of `Down CutHashes`. Equal cuts compare `EQ` and a heap admits duplicates, so `pQueueInsertLimit` could retain **N copies of a single attacker cut**, evicting every legitimate pending cut — and each copy re-triggers a full prerequisite header/payload fetch.

Remotely reachable by an unauthenticated peer: `cutPutHandler` only checks that the **attacker-supplied** `_cutOrigin` address exists in the local peer DB, not that the requester *is* that peer. Bootstrap addresses are public and hard-coded.

Applied in dependency order — `392c5b88d` conflicts standalone but goes clean once the other two land:

| Commit | Upstream | What |
|---|---|---|
| `d9c91ff4c` | `84e4eb6cb` | More flexible `readHighestCutHeaders` — introduces `readHighestCutHeaders'` taking explicit args, with the old name kept as a `CutDb`-based wrapper |
| `1975d45c6` | `5fd969c6c` | Cut queue buffer floor: `max 10 $ (order g ^ 2) * diameter g` |
| `af4ab9fc8` | `392c5b88d` | **Disallow duplicate cuts** — heap replaced by a keyed STM map |

### ⚠️ Conflict resolution — community-fork rewind deliberately excluded

`84e4eb6cb` conflicted in `src/Chainweb/CutDB.hs` (one block). Upstream's version of `readInitialCut` contained **Kadena-mainnet community-fork rewind logic** — checking whether the node sits on the community fork at `RankedBlockHash 6335871` on chain 2, and forcing an initial height limit of `6335858 - 1` if not.

That code arrived in `1286b1813` ("Rewind at startup if not on community fork"), which is on our **do-not-take** list, and which upstream themselves removed later in `828fc7038`. Our base predates 3.0, so we never had it.

**Resolution:** kept our structure, adopted only the `readHighestCutHeaders'` rename. The result is semantically identical to upstream master's post-`828fc7038` form (branch order of `Just`/`Nothing` differs, which is immaterial in a Haskell `case`).

**Safety checks after resolution:**
- The cherry-pick added **no new imports**, and none of the community-fork-only symbols (`ancestorOfEntry`, `RankedBlockHash`, `unsafeChainId`, `_versionCode`) appear in an explicit import list — so no unused-import breakage under `-Wall -Werror`.
- `readHighestCutHeaders` (unprimed) survives at `CutDB.hs:500`, now defined via the primed version, and its three call sites elsewhere still resolve.

### Verified after the wave

| Check | Result |
|---|---|
| Heap replaced by keyed STM map | `data PQueue a =` + `newEmptyPQueue getPrio getKey maybeMaxLen` |
| Dedup active | `if S.member k s then return () else …` |
| `Priority` sign flip at the production call site | `CutDB.hs:823` → `Priority (int (_cutHashesHeight hs))` (no negation) |
| Buffer floor | `CutDB.hs:191` → `max 10 $ (order g ^ 2) * diameter g` |
| Queue wired with weight + dedup key | `CutDB.hs:440` → `newEmptyPQueue _cutHashesWeight _cutHashesId …` |
| `Chainweb.hs` vs upstream | now differs by **one line only** (`maxBlockGasLimit`, arrives wave 4) |

**Known limitation, still open upstream:** this does **not** close the forged-weight flood. Dedup keys on `_cutHashesId` and priority on `_cutHashesWeight`, both attacker-supplied and unvalidated, so an attacker can still fill the buffer with *distinct* cuts claiming near-maximum weight. Upstream's own comment remains in the tree: *"FIXME: this is problematic. We should drop these much earlier before they are even added to the queue."*

**If reverted:** issue H-3 returns — an unauthenticated peer can evict all pending cuts. Note `af4ab9fc8` and the `Priority` sign flip are **coupled**: reverting one without the other inverts the header-fetch order.

## Fix 5 — Wave 3 · completed-defpact continuations in the mempool

**Closes issue M-1.** Cherry-picked `1aa616ba0` — applied clean, 3 files, +58/−46.

Pre-insert did not check whether a continuation targets a defpact that has **already completed**. An attacker could therefore fill mempools and blocks with guaranteed-failing cross-chain "finish" replays at minimal cost.

The check reads the defpact state and rejects when it is complete (`PactService.hs:1207-1209`):

```haskell
let isComplete = defPactState == Just Nothing
when isComplete $
    throwError (InsertErrorDefPactComplete (sshow pactId))
```

with the new error constructor at `Mempool/Mempool.hs:245`.

**Non-consensus.** This strictly *rejects more* at pre-insert; a node without it validates blocks identically. Safe to ship independently of any fork.

**If reverted:** issue M-1 returns — cheap mempool and block-space pollution.

---

## Fix 6 — Dockerfile GHC 9.10.1 → 9.10.2

`cbc5ca363`. 3.2.1's `cabal.project.freeze` pins `base ==4.20.1.0`, which ships only with GHC 9.10.2. The Dockerfile declared 9.10.1 (line 50), so a container build would fail resolution.

Upstream's own Dockerfile has the **same inconsistency** — declares 9.10.1 while shipping a freeze requiring 9.10.2 — so this must not be "fixed" by copying theirs.

---

## ✅ Build verification — DEPENDENCY RESOLUTION CONFIRMED

**Run 2026-08-23 on the AncientIntel build host** (`ancientbox@bytales.duckdns.org:22222`, Ubuntu 26.04, 16 cores, 62 GB RAM). The repo is local to that machine at `/home/ancientbox/ClaudeWS/StoaChain/_infra/stoa-chain` — the same directory exported to Windows as `Z:`.

No GHC or cabal on the host, so the check ran in a container:

```bash
docker run --rm -v "$PWD":/src:ro -v ~/cwbuild:/build \
  -e CABAL_DIR=/build/cabal -w /src haskell:9.10.2 \
  bash -c 'export PATH=/build/bin:$PATH; cabal build --dry-run chainweb --builddir=/build/dist'
```

### Result — issue C-1 is genuinely closed

| Package | Resolved | Requirement |
|---|---|---|
| **`crypton-x509-validation`** | **1.9.1** | **the CVE-2026-9648 fix** ✅ |
| `crypton` | 1.1.4 | `>= 1.1.2` ✅ |
| `crypton-x509` | 1.9.1 | `>= 1.8` ✅ |
| `crypton-asn1-types` | 0.4.1 | `>= 0.4.1` ✅ |
| `crypton-asn1-encoding` | 0.10.0 | `>= 0.10.0` ✅ |
| `merkle-log` | 0.2.1 | `>= 0.2.1` ✅ |
| `ram` | 0.22.1 | `>= 0.2.2` ✅ |
| `pact-tng` | **5.4.1** | carries fixes for SC-1, SC-2 ✅ |
| `pact` | 4.13.2 | Pact 4 ✅ |
| `tls` | 2.4.3 | ✅ |

Fixes 1–2 made the CVE fix *reachable*; this run proves it *resolves*. **Issue C-1 verified closed.**

### Both StoaChain forks validated

All nine `source-repository-package` entries cloned successfully, including ours:

```
pact-5  -> 72f42760  ("Revamp CI")                          = tag 5.4.1
pact    -> ef859d8b  ("Update crypton, and replace memory by ram")
```

### Two gotchas worth recording

**cabal-install must be ≥ 3.14.** The `haskell:9.10.2` image ships cabal-install 3.12.1.0 with `Cabal-3.12.1.0`, but `node/chainweb-node.cabal:68` declares `custom-setup: Cabal >= 3.14`. The solver fails with `Cabal-7107` — *"constraint from maximum version of Cabal used by Setup.hs requires <3.14"*. This is a property of the **test image**, not our tree: the real Dockerfile does `ghcup install cabal latest`. For ad-hoc checks, install cabal-install 3.14.1.1 into the container first. This matches the note in `CLAUDE.md` that Cabal 3.10 will fail.

**`cabal update` needs a writable cwd.** With the source mounted `:ro` it fails with `/src/dist-newstyle: createDirectory: permission denied`. Run `cabal update` from `/tmp` and pass `--builddir` to the build.

Persistent caches live at `~/cwbuild/{cabal,dist,bin}` on the build host, so re-runs skip the clones and the Hackage index download.

---

## ✅ Fix 7 — waves 0–3 COMPILE AND LINK

**`ccf2baf4d`.** After four build cycles, `chainweb-node` builds clean under `-Wall -Werror`:

```
[239 of 239] Compiling Chainweb.Chainweb
[6 of 6] Linking .../chainweb-node
BUILD_EXIT=0
```

And the binary runs:

```
$ chainweb-node --version
chainweb-node-2.32.0 (package chainweb-node-2.32.0 revision ccf2baf4d-upgrade/chainweb-3.2.1)

$ chainweb-node --chainweb-version stoa --print-config | grep chainwebVersion
  chainwebVersion: stoa
```

The revision string confirms `node/Setup.hs` embedded our actual commit and branch, and the `stoa` version still registers and prints its configuration.

### What this proves

Every uncertain part of waves 0–3 survived GHC:

- the **hand-resolved `readHighestCutHeaders'` conflict**, where upstream's community-fork rewind block was deliberately excluded
- the **`Unzip` instance** required by SemiAlign 1.4
- the **PQueue heap → keyed STM map** rewrite and the coupled `Priority` sign flip
- **Pact 5.4.1** compiled and linked against our tree

### Total code defects found: five redundant imports

All were the same class — a cherry-picked patch removed the *usage* while the `import` line sat outside the hunk context, so git had no reason to touch it. `-Wall -Werror` caught every one:

| File | Import | Why it went stale |
|---|---|---|
| `Chainweb.hs` | `hiding (Port, Counter)` | superseded by the qualified `Chainweb.Counter` import (`edcb1a426`) |
| `Data/PQueue.hs` | `Data.Foldable` | `foldl'` moved to `Prelude` in base-4.20; PQueue rewrite dropped the rest |
| `Pact5/Transaction.hs` | `Pact.Core.StableEncoding` | redundant under Pact 5.4.1 |
| `Pact/Types.hs` | `Pact.Core.Hash` | redundant under Pact 5.4.1 |
| `Pact/PactService.hs` | `Pact.Core.StableEncoding` | redundant under Pact 5.4.1 |

All five files are now byte-identical to upstream 3.2.1, except `PactService.hs`, which differs by exactly one line — the wave 5 `initialGasOf` signature, correct to still differ.

**Zero non-import errors.** No type errors, no missing instances, no signature mismatches.

### Method note — finding them all in one pass

Fixing these one build at a time cost a full chainweb recompile per line. The efficient move was a single diagnostic build with `--ghc-options=-Wwarn=unused-imports`, which downgrades that one warning so compilation continues past the first offender and reports every instance at once — and, more importantly, confirms whether anything *worse* is hiding behind them.

A static shortcut (diff every file against upstream, flag extra imports) was tried first and **over-reports**: upstream is ahead of us by waves 4–6, so files they changed later legitimately differ. It flagged nine files where only three were real. GHC is the only reliable judge.

### Four environment gaps — none from our tree

| Gap | Cause | Fix |
|---|---|---|
| `setup.Cabal >= 3.14` unsatisfiable | `haskell:9.10.2` ships cabal-install 3.12.1.0 | installed 3.14.1.1 to `~/cwbuild/bin` |
| `Missing C library: crypto` | base image lacks `libssl-dev` | apt list copied from the Dockerfile builder stage |
| `dubious ownership in repository at '/src'` | container runs as root, `/src` owned by `ancientbox`; `node/Setup.hs` shells out to `git rev-parse` | `git config --global --add safe.directory /src` |
| binary won't start outside the build image | linked against Debian's `libcrypto.so.1.1`; Ubuntu 22.04 ships OpenSSL 3 | n/a — see below |

⚠️ **The ad-hoc binary is not deployable.** It was linked inside the Debian-based `haskell:9.10.2` image, so it depends on `libcrypto.so.1.1` and will not run on Ubuntu 22.04. This is an artefact of the ad-hoc build only — the real `Dockerfile` uses `ubuntu:${UBUNTU_VERSION}` for **both** the builder and runtime stages, so its output is correctly matched. This build's purpose was typechecking, and that succeeded.

### Build recipe (reproducible)

Script at `~/cwbuild/run-build.sh` on the build host. Caches at `~/cwbuild/{cabal,dist,bin}` so re-runs skip the Hackage index and the nine source-repository clones.

```bash
docker run -d --name cwbuild -v "$PWD":/src:ro -v ~/cwbuild:/build \
  -e CABAL_DIR=/build/cabal -w /src haskell:9.10.2 /build/run-build.sh
```

**Use `--ghc-options=-j8`.** `cabal -j` parallelises across *packages*, which is useless once only `chainweb` remains — that stretch ran single-threaded at 101% CPU. With GHC-level parallelism it reached 506%.

### Still to verify

Version strings still read `2.32.0` — hand-edited leftovers, on the to-do list. And a compile is not a test run: the unit suites and the replay gate remain.

## Fix 8 — test suite adapted to Pact 5.4.1 and the tasty bump

**`21bffc7d6`.** The test suite did not build against the wave 0 dependency graph. Eleven fixes across 8 files, every one matching upstream 3.2.1's own resolution.

| Issue | Files | Cause |
|---|---|---|
| `ChainId` ambiguity → `hiding (ChainId)` | 5 | Pact 5.4.1's `Pact.Core.Command.Types` now re-exports `ChainId`, colliding with `Chainweb.Version.ChainId` |
| Redundant imports | 5 | `Pact.Core.Signer`, `Capabilities`, `StableEncoding`, `Verifiers`; `Pact.Core.Names` narrowed to `Field(..)` |
| `sequentialTestGroup` deprecated | 1 | tasty bump; upstream fixed it in `5500e40ff` |

`CmdBuilder.hs` was fixed surgically rather than taking upstream's version, which carries wave 5 changes (`PatternSynonyms`, `pattern PString`) we had not reached.

**Method note worth keeping.** An early diagnostic pass used `--ghc-options=-Wwarn=unused-imports`, which downgrades only that one category. A `-Werror=deprecations` error then halted compilation before several modules were reached, so the "complete" list was not complete and three build cycles were spent on the same class of problem. **Use plain `-Wwarn`** to downgrade every category at once, then fix everything in one commit and restore `-Werror`.

A second trap, hit three times: `grep '^import X$'` silently matches nothing on these CRLF files, because `$` will not match before `\r`. Use `\r*$` or `tr -d '\r'`.

---

## Fix 9 — Wave 4 · ForkNumber machinery

**`e001e7673`** plus 17 cherry-picked commits (`4ded15d8a` … `52c1a46c2`). 13 applied clean, 4 auto-resolved. **Built clean on the first attempt.**

### What landed

- **`ForkHeight` gained `ForkAtForkNumber`** with a hand-written `Ord` instance ordering `ForkAtGenesis < FN 0 < any BlockHeight < FN ≥1 < ForkNever`
- `maxBlockGasLimit`, `minimumBlockHeaderHistory` and `verifiersAt` became ForkNumber-aware, resolving height and fork number with `max`
- Registry validation tightened: `validateNoForkAtZero`, `validateNoHeightAfterChainweb31`
- Fork enum: `Chainweb232Pact` → `Chainweb31`; `Chainweb226Pact` and `Chainweb229Pact` deleted

### Conflict rule — MigratePlatformShare

All four conflicts had the same shape, so rather than hand-editing, the rule was encoded in a script (`resolve_mps.py`, kept in the session scratchpad):

> **take upstream's side, drop every line naming `MigratePlatformShare`.**

We deliberately do not take `3149131c8` ("Platform share migrate"), so that constructor does not exist in our tree. Upstream commits touching the Fork enum or per-version fork tables therefore conflict. Nine blocks and nine MPS lines were dropped in the first commit alone.

Because the resolver takes "theirs" wholesale, the Stoa wiring was verified afterwards: all 7 `Registry.hs` insertion points and the `Configuration.hs` entry are intact.

**Consequence worth stating plainly:** `MigratePlatformShare` now exists nowhere in the tree, so the `atNotGenesis` → `error "fork cannot be at genesis"` blocker is *permanently absent* rather than merely unhandled. The cost is one Fork constructor of divergence from upstream.

### `Stoa.hs` changes

| Field | Change |
|---|---|
| `_versionMinimumBlockHeaderHistory` | renamed to `_versionSpvProofRootValidWindow`; value stays `Bottom (minBound, Nothing)` — we do not adopt SPV expiry |
| `_versionForkVoteCastingLength` | **added**, `120 * 119`. Reproduces the pre-wave-4 hardcoded `forkEpochLength = 120 * 120` bit-for-bit: 14,280 casting + 120 counting = 14,400 blocks = exactly 5 days at our 30 s delay |

### ⚠️ Warning added at the wildcard fork table

`Stoa.hs` maps **every** fork to `ForkAtGenesis` via a wildcard. That is correct for our history so far, but **not** for `Chainweb32`: `ForkAtGenesis` is `minBound`, so the `chainweb32` guard would read as always-true and retroactively apply Pact 5.4.1 semantics to the entire chain, diverging replay. A comment now says so at the exact line where someone would hit it.

### Verified

`BUILD_EXIT=0`, zero errors. Binary runs. `stoa` still registers — so it passes both new registry checks. `--mining-target-fork-override` is present, confirming the fork-voting machinery is live. Test suite also builds clean against wave 4 (`BUILD_TESTS_EXIT=0`), including the auto-resolved `TestVersions.hs`.

---

## Fix 10 — Wave 5 · gas model machinery

`c13c0a1a1` (applied clean) and `460852eb1` (2 conflicts, resolved by hand — neither fitted the MPS rule).

| File | Resolution |
|---|---|
| `TestVersions.hs` | upstream's line references a `migrate` flag from the skipped MigratePlatformShare commit **and** adds the gas-model rule. Kept our `versionName`, took their rule. |
| `PactServiceTest.hs` | upstream's version predates our `hiding (ChainId)` fix and would have reverted it. Kept ours (upstream converges on the same thing later), took their added `Pact.Core.DefPacts.Types`. |

**`Chainweb32` is not involved in wave 5** — verified zero references in both commits. It arrives with `eacb3ceee` in wave 6.

### `Stoa.hs` — `_versionInitialGasModel = pre31GasModel`, deliberately

```haskell
, _versionInitialGasModel = AllChains $ Bottom (minBound, pre31GasModel)
```

StoaChain has always billed with the original formula. Activating `post32GasModel` retroactively would recompute gas for every historical transaction, moving payload hashes and breaking replay — the same trap as `Chainweb32`.

> **Wave 5 installs the machinery; it does NOT close issues H-1 and H-2.**
> Closing them means adding a rule keyed at a **future block height**, which is a release decision rather than a port step. Documented at the field.

## Still to do

| Wave | Scope | Consensus? |
|---|---|---|
| 0 | ✅ **done** (fixes 1–2) → closes **C-1** | no |
| 1 | ✅ **done** (fix 3) — build compat | no |
| 2 | ✅ **done** (fix 4) → closes **H-3** | no |
| 3 | ✅ **done** (fix 5) → closes **M-1** | no |
| — | ✅ **Dependency resolution verified** — `crypton-x509-validation-1.9.1` confirmed, issue **C-1** closed | — |
| — | ⏸ **Full compile** — not yet attempted; first real test that waves 0–3 typecheck together | — |
| 4 | ForkNumber machinery | **yes** |
| 5 | Gas model → closes **H-1**, **H-2** | **yes** |
| 6 | Pact 5.4.1 activation → closes **SC-1**, **SC-2** | **yes** |

Then: version strings (`chainweb.cabal` still reads `2.32.0`, which was hand-edited and never accurate), `Stoa.hs` field updates, GHC 9.10.1 → 9.10.2, and the test gates in [`container-build-plan.md`](container-build-plan.md) §5.

---

## Fix 11 — container provenance via OCI labels

`.dockerignore` excludes `.git` (it would add roughly a gigabyte to every build
context). Cabal's `PkgInfo` machinery therefore has no repository to read at
configure time, and the binary prints its revision as the **empty string**:

```
chainweb-node-3.2.1 (package chainweb-node-3.2.1 revision )
```

This is not cosmetic. [`RELEASE-v3.2.1-stoa.1.md`](RELEASE-v3.2.1-stoa.1.md)
told operators to *"check the revision string, not just the version"* — advice
that cannot be followed, and which would have had someone squinting at a blank
field and concluding the image was fine either way.

**Fix.** The `stoa-node` stage now carries OCI labels fed from build args:

```dockerfile
ARG STOA_VERSION=dev
ARG STOA_REVISION=unknown
LABEL org.opencontainers.image.version="${STOA_VERSION}"
LABEL org.opencontainers.image.revision="${STOA_REVISION}"
```

Built with:

```bash
docker build --target stoa-node -t stoa-node:v3.2.1-stoa.1 \
  --build-arg STOA_VERSION=v3.2.1-stoa.1 \
  --build-arg STOA_REVISION="$(git rev-parse HEAD)" .
```

The release notes' verification section was rewritten around three checks that
actually work — `/info` → `nodePackageVersion`, `/info` →
`nodeLatestBehaviorHeight`, and `docker inspect` on the labels.

### `nodeLatestBehaviorHeight` is the useful one

`GET /info` derives `nodeLatestBehaviorHeight` from the fork table **compiled
into the binary** — the highest fork height plus one. That makes it a direct
read-out of the consensus rules an image carries, obtainable from a running
node with one HTTP request and no shell access:

| Image | `nodeLatestBehaviorHeight` |
|---|---|
| old `:latest` (2.32.0) | `1` — every Stoa fork sat at genesis |
| `v3.2.1-stoa.1` | `525001` |

It is also how the fork-transition rehearsal below verified that its patched
test image had really been built from the patched source.

---

## Fix 12 — `--disable-pow` is inert on `stoa` (no code change; recorded so nobody re-derives it)

Two full test rounds produced **zero blocks** and cost the better part of a day.
The cause is a genuine asymmetry in how a `ChainwebVersion` gets resolved, and
it is worth writing down precisely.

`--disable-pow` is applied by `constructVersion`, in the option parser:

```haskell
-- src/Chainweb/Chainweb/Configuration.hs:618
& versionCheats . disablePow .~ disablePow'
```

Note it is an unconditional `.~`, not `%~ (|| …)`: when the flag is absent the
switch yields `False` and the assignment **overwrites** whatever the version
module declared. So patching `_disablePow = True` in `Stoa.hs` alone is not
enough — the config's copy of the version reverts to `False`.

But the *other* consumer never consults the config at all:

```haskell
-- src/Chainweb/BlockHeader/Internal.hs:404
instance HasChainwebVersion BlockHeader where
    _chainwebVersion = lookupVersionByCode . _blockChainwebVersion
```

and `lookupVersionByCode` short-circuits Stoa before it ever reaches the
registry:

```haskell
-- src/Chainweb/Version/Registry.hs:151-157
lookupVersionByCode code
    | code == _versionCode mainnet   = mainnet
    | code == _versionCode testnet04 = testnet04
    | code == _versionCode stoa      = stoa      -- ours, commit 1b6bd815f
    | otherwise = lookupVersion & versionCode .~ code
```

So there are two independent gates, reached by different paths:

| Gate | Resolved from | Effect |
|---|---|---|
| `runMiner` → `testMiner` vs `powMiner` (`MinerResources.hs:331`) | **config** version | picks the instant test miner or real CPU PoW |
| `prop_block_pow` (`Validation.hs:714`), via `extendCut` (`Cut/Create.hs:439`) | **compiled-in** `stoa` | whether a solved header's PoW is checked |

Satisfy only the source patch and you get `powMiner` grinding at production
difficulty on one core — silence, no error, indistinguishable from a hung node.
Satisfy only the CLI flag and you get `localTest` emitting unsolved headers that
`extendCut` rejects:

```
[Error] … Chainweb.Miner.Miners.localTest failed:
  InvalidSolvedHeader (BlockHeader {…_blockNonce = Nonce 0…}) "Invalid POW hash"
```

A test build needs **both**.

### This is a security property, not a bug

Because `lookupVersionByCode` pins `stoa` to the compiled-in value, a production
Stoa node **cannot be argued out of validating proof of work** by a command-line
flag, environment variable, or config file — the same protection `mainnet01` and
`testnet04` already had, extended to Stoa in commit `1b6bd815f`. The worst a
`--disable-pow` operator achieves is a node that mines headers its own consensus
layer then throws away.

The same pinning makes `--block-delay` and `--fork-upper-bound` half-applied for
Stoa: they alter the config's version but not the one block validation resolves.
Neither is used in production. Left as is, deliberately — narrowing the pin to
re-enable those knobs would also re-open `--disable-pow`.

---

## Fix 13 — the image's own HEALTHCHECK could never pass

Found while investigating why the fork-rehearsal container reported `unhealthy`
with a failing streak of 51 while serving traffic perfectly. Two independent
faults in the `HEALTHCHECK` inherited from upstream's `chainweb-node` stage:

```dockerfile
HEALTHCHECK CMD \
    [ $(ulimit -Sn) -gt 65535 ] \
    && exec 3<>/dev/tcp/localhost/1848 \
    && printf "GET /health-check HTTP/1.1\r\n…" >&3 \
    && grep -q "200 OK" <&3 \
    || exit 1
```

1. **`/dev/tcp` is a bash builtin.** `HEALTHCHECK CMD <string>` is executed as
   `/bin/sh -c`, and `/bin/sh` is dash in this image. dash answers
   `cannot create /dev/tcp/localhost/1848: Directory nonexistent` (exit 2).
2. **`ulimit -Sn` reads the wrong process.** A healthcheck exec does not inherit
   the container init process's rlimits. Under Docker 29.1.3 the exec gets soft
   nofile **1024** while PID 1 has **524288**, so the gate fails permanently.

Both were confirmed by running each clause separately inside the container.

### Not a regression — but it would have surfaced on redeploy

A **fresh container from the already-published `ghcr.io/stoachain/stoa-node:latest`**
is also permanently `unhealthy` on this host. The four live slaves report
`healthy` only because docker-compose replaces the image's healthcheck at
container-creation time:

```yaml
healthcheck:
  test: ["CMD-SHELL", "bash -c 'exec 3<>/dev/tcp/localhost/18488 && …'"]
```

— wrapped in `bash -c`, pointed at the slave's real service port, and with the
ulimit clause dropped. The override has been masking a broken built-in for as
long as the image has existed. Anyone running the image without that override
gets a container that works but never reports healthy.

### Fix

The `stoa-node` stage now overrides `HEALTHCHECK` (upstream's stage is left
untouched):

```dockerfile
HEALTHCHECK --interval=30s --timeout=10s --start-period=10m --retries=5 CMD \
    bash -c 'exec 3<>/dev/tcp/localhost/${SERVICE_PORT:-1848} && printf "GET /health-check HTTP/1.1\r\nhost: localhost\r\nConnection: close\r\n\r\n" >&3 && grep -q "200 OK" <&3'
```

- runs under `bash`, so `/dev/tcp` resolves;
- follows `SERVICE_PORT` instead of hard-coding 1848;
- drops the ulimit gate as **redundant**: `checkRLimits`
  ([node/src/Utils/CheckRLimits.hs:38](../../node/src/Utils/CheckRLimits.hs))
  already exits at startup when the hard limit is under 32768 and raises the
  soft limit to the hard limit otherwise. A startup precondition does not belong
  in a liveness probe.

Verified by running the exact command inside the container: exit 0.
