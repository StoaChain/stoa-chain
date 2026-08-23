# Upgrade fix log — `upgrade/chainweb-3.2.1`

A running record of **every** change applied on this branch, in order. One entry per commit.

Purpose: so that six months from now we can answer "what did we change, why, and what breaks if it's reverted?" without reading the diff. Issue numbers refer to [`vulnerabilities-fixed-in-3.2.md`](vulnerabilities-fixed-in-3.2.md); wave numbers to [`container-build-plan.md`](container-build-plan.md).

**Branch base:** `main` @ `7c3400f34`
**Target:** chainweb `3.2.1` (`d89bb530`) + Pact `5.4.1` (`72f42760`)
**Upstream remote:** `kdac` = `https://github.com/kda-community/chainweb-node.git`

| # | Commit | Wave | Closes | Summary |
|---|---|---|---|---|
| 1 | `ce33454d3` | 0 | **#5** | Adopt 3.2.1 dependency graph; unblock CVE-2026-9648 |
| 2 | `4ceb23b78` | 0 | **#5** | Update dependency bounds in the three `.cabal` files |
| 3 | `7eaa8f8ea`, `83982b9fb`, `201f42ee5`, `4ffd21cd3` + fixup | 1 | — | Build compatibility for the new dependency graph |

---

## Fix 1 — `ce33454d3` · adopt the 3.2.1 dependency graph

**Closes issue #5** — CVE-2026-9648 ([CERT/CC VU#862559](https://kb.cert.org/vuls/id/862559), CVSS 9.1). `crypton-x509-validation` does not enforce RFC 5280 NameConstraints, so a holder of a name-constrained sub-CA can mint a certificate valid for **any** hostname. Fixed upstream in 1.9.1.

**Why it was blocked on us:** 1.9.1 requires `crypton >= 1.1`, and our own `cabal.project` pinned `crypton == 1.0.4`. Our bootstraps are built with `domainAddr2PeerInfo = fmap (PeerInfo Nothing)` — no pinned certificate fingerprint — so they fall back to `getSystemCertificateStore`, which is the affected path.

**Method:** took upstream 3.2.1's `cabal.project` wholesale, then repointed two locations at StoaChain forks. Verified beforehand that our file differed from theirs in exactly four things and nothing else.

| Change | Detail |
|---|---|
| Removed constraint block | `crypton == 1.0.4`, `memory == 0.18.0`, `merkle-log == 0.2.0`. These were a workaround for crypton 1.0.5+ migrating `memory` → `ram`; 3.2.1 completes that migration properly, so they are obsolete. |
| Removed `bytesmith < 0.3.14` | A GHC 9.6 `text-2.0` workaround, no longer needed. |
| `kadena-io/*` → `kda-community/*` | All source-repository-packages. The kadena-io repos are being archived. |
| `pact-5` → `StoaChain/pact-5` @ `72f42760` | Tag `5.4.1`. Carries the fixes for issues **#1** and **#2**. |
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

**Completes issue #5.** `cabal.project` now *permits* the new dependency graph, but the `.cabal` files still declared the old bounds and still named `memory` and `cryptonite`. Without this the solver cannot pick `crypton-x509-validation 1.9.1`.

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

## Still to do

| Wave | Scope | Consensus? |
|---|---|---|
| 0 | ✅ complete after fix 2 | no |
| 1 | Build compat: `37c28c7dc`, `0ebc2ba3a`, `4718f02a2`, `5cff7ad47` | no |
| 2 | P2P/DoS: `84e4eb6cb`, `5fd969c6c`, `392c5b88d` → closes **#6** | no |
| 3 | Mempool: `1aa616ba0` → closes **#8** | no |
| 4 | ForkNumber machinery | **yes** |
| 5 | Gas model → closes **#3**, **#4** | **yes** |
| 6 | Pact 5.4.1 activation → closes **#1**, **#2** | **yes** |

Then: version strings (`chainweb.cabal` still reads `2.32.0`, which was hand-edited and never accurate), `Stoa.hs` field updates, GHC 9.10.1 → 9.10.2, and the test gates in [`container-build-plan.md`](container-build-plan.md) §5.
