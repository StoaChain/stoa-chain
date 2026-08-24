# StoaChain v3.2.1-stoa.1 — Release Notes

**Base:** chainweb-node **3.2.1** (`kda-community`, `d89bb530`) + Pact **5.4.1** (`72f42760`)
**Image:** `ghcr.io/stoachain/stoa-node:v3.2.1-stoa.1`
**Branch:** `upgrade/chainweb-3.2.1`
**Previous:** `v2.32.0-stoa.1`

> ## ⚠️ HARD DEADLINE — BLOCK 525,000
>
> This release schedules a **consensus fork at block height 525,000 per chain**.
> **Every node must be running `v3.2.1-stoa.1` before that height or it will stall.**
>
> At the time of writing the chain was at **508,047**, giving ~16,953 blocks of
> margin — about **5.9 days** at our 30-second block delay.
>
> Nodes below the fork height interoperate normally with upgraded nodes, so the
> rollout can be staged. The deadline is the *height*, not the restart.

---

## Why this release exists

Kadena's community fork disclosed four vulnerabilities in their
[Ad-Vitam Transparency Report](https://medium.com/@communitykadena/chainweb-3-2-ad-vitam-transparency-report-cfcfff237f43)
(2026-08-02). An audit of the 3.2 release against our tree found **eight** issues
that StoaChain was exposed to — the four disclosed, plus four more found in the
diff, including an undisclosed CVSS 9.1 CVE.

This release closes all eight. Full analysis in
[`vulnerabilities-fixed-in-3.2.md`](vulnerabilities-fixed-in-3.2.md); the
per-commit record is in [`upgrade-fix-log.md`](upgrade-fix-log.md).

---

## Fixes active immediately on upgrade

These need no fork. They take effect the moment a node restarts on this image.

### #5 · CVE-2026-9648 — X.509 NameConstraints not enforced · **CVSS 9.1**

`crypton-x509-validation` did not enforce RFC 5280 NameConstraints, so a holder
of a name-constrained sub-CA could mint a certificate valid for **any** hostname
([CERT/CC VU#862559](https://kb.cert.org/vuls/id/862559)).

Our bootstraps are built with `domainAddr2PeerInfo = fmap (PeerInfo Nothing)` —
no pinned certificate fingerprint — so they fall back to the system CA store,
which is exactly the affected path. Exposure was primarily at peer discovery.

**Our own `cabal.project` pin `crypton == 1.0.4` was what blocked the fix**, since
`crypton-x509-validation-1.9.1` requires `crypton >= 1.1`. Resolving that meant
adopting upstream's completed `memory` → `ram` migration.

Not mentioned in any upstream changelog or in the transparency report.

### #6 · Cut-queue duplicate-flood DoS

`Data/PQueue.hs` was a heap of `Down CutHashes`. Equal cuts compare `EQ` and heaps
admit duplicates, so the queue could fill with N copies of a single attacker cut,
evicting every legitimate pending cut — each copy re-triggering a full prerequisite
header/payload fetch.

Reachable by an **unauthenticated peer**: `cutPutHandler` only checks that the
*attacker-supplied* `_cutOrigin` address exists in the peer DB, not that the
requester is that peer.

Fixed by replacing the heap with a keyed STM map that drops duplicates.

> **Known limitation, still open upstream.** Dedup keys on `_cutHashesId` and
> priority on `_cutHashesWeight`, both attacker-supplied and unvalidated, so a
> flood of *distinct* cuts claiming near-maximum weight is still possible.
> Upstream's own `FIXME` remains in the tree.

### #8 · Completed-defpact continuations accepted into the mempool

Pre-insert did not check whether a continuation targeted an already-completed
defpact, so an attacker could cheaply fill mempools and blocks with
guaranteed-failing cross-chain replays. Now rejected with
`InsertErrorDefPactComplete`.

---

## Fixes that activate at block 525,000

All five share one activation height, so a single fork turns everything on at once.

### #1 · Identity forgery via the signer `addr` field · **CRITICAL**

A `Signer` may carry an optional `_siAddress`. Pre-fix, Pact keyed the
message-signature map on `fromMaybe pubK addr` — an attacker-controlled field.
`verifyUserSig` enforces `addr == pubKey`, **but only in the ED25519 branch**; the
WebAuthn branch never checked it.

**The attack:** sign with your own WebAuthn key, set `addr` to a victim's ED25519
public key. Signature verification passes (checked against *your* key), but the
signature map is keyed under *theirs* — so every `enforce-keyset` and
`enforce-guard` for that victim succeeds. A complete authentication bypass:
impersonate any ED25519 keyset holder and drain any account.

StoaChain was exposed because our fork table puts every fork at genesis, so
`chainweb221Pact` has been true since block 0 and WebAuthn signers have always
been accepted.

### #2 · Capability theft via `compose-capability` · **CRITICAL**

Pact's core security property is that *a capability can only be acquired by code
within the same module*. `composeCap` called `evalCap` **without**
`guardForModuleCall`, so `(compose-capability ...)` could acquire a capability
belonging to a third-party module. Upstream's assessment: *"most existing
contracts were potentially vulnerable to this attack."*

### #3 · Unmetered signature size · HIGH

Signatures were capped at 100 per transaction but charged **zero** gas —
`payloadBytes` excludes `_cmdSigs`. WebAuthn signatures carry arbitrary-size
embedded metadata, so blocks could be inflated beyond what the P2P layer
propagates efficiently while staying inside the block gas limit.

### #4 · Block-validation CPU exhaustion · HIGH

WebAuthn verification costs ~1.315 ms against ED25519's ~52 µs, and was unmetered.
Filling a block with WebAuthn-signed transactions pushed validation time toward
the 30-second block delay — risking an uncontrolled network fork.

> **StoaChain was materially worse off than Kadena on #3 and #4.** Upstream's
> mitigating argument was that their 150k gas-per-block cap bounded the damage.
> Our `_versionMaxBlockGasLimit` is **2,000,000** — roughly 10× theirs — so the
> margin they called *"uncomfortably small"* was about ten times smaller here.

### #7 · Unmetered SPV continuation-proof size · HIGH

Our code **deliberately subtracted** proof bytes from the billed size
(`txSize = payloadBytes - contProofSize`), so arbitrarily large SPV proofs could
be written into blocks at zero marginal gas — permanent storage and
Merkle-verification cost on every node, forever.

### What changes at 525,000

`post32GasModel` replaces `pre31GasModel`:

| | pre31 (all history) | post32 (from 525,000) |
|---|---|---|
| payload bytes | 0.01/byte | 0.01/byte |
| SPV proof bytes | **free** | 0.01/byte |
| signature bytes | **free** | 0.01/byte |
| per ED25519 signer | **free** | **21 gas** |
| per WebAuthn signer | **free** | **526 gas** |

**Practical impact:** a single-signer ED25519 transfer costs **+22.38 gas**.
(Upstream's announcement said "almost 40"; their own regression tests assert +22.)

The per-scheme constants are correct at Pact's stated rate of 1 gas per 2.5 µs:
52 µs ÷ 2.5 = 21, and 1.315 ms ÷ 2.5 µs = 526. A source comment reading
`-- Benchmarked at 52 ns` is a typo for µs.

---

## Deliberately NOT adopted

| Upstream feature | Decision |
|---|---|
| **SPV proof expiry** (6-month window) | **Rejected.** Buys ~45 GB of header pruning we don't need at our chain size, in exchange for permanent X-chain fund destruction with no recovery path, a compaction/upgrade hazard that can throw an uncaught `TreeDbAncestorMissing` and fork a node off the network, and a feature not exercised on *any* public network — including the testnet shipped alongside it. `_versionSpvProofRootValidWindow` stays `Nothing`. |
| **`MigratePlatformShare`** | Not taken. It migrates 16 keysets to Kadena's community keys and is meaningless for StoaChain. Its absence also permanently removes the `error "fork cannot be at genesis"` hazard from our tree. |
| **`--p2p-disable-cert-verification`** | Not taken. Sets `TlsInsecure` — empty cert store, always-accept validation. Also misdocumented upstream as "*client* cert verification" when it disables *server* verification. |
| **Testnet06** | Their new testnet, irrelevant to us. |
| **Mainnet gas quirks** | Kadena mainnet history only; we have our own genesis. |
| **Fork-number voting** | Machinery is compiled in and `--mining-target-fork-override` is available, but all our forks remain height-gated. Voting solves coordination among mutually distrusting miners, which we do not have. Revisit if StoaChain ever gains independent miners. |

---

## Compatibility

| Property | Status |
|---|---|
| Block header binary format | **unchanged** — the `FeatureFlags` → `ForkState` rename predates our base; Merkle tag `0x0006` identical |
| RocksDB schema | **unchanged** — no version stamp exists, nothing can reject an old database |
| Pact SQLite schema | **unchanged** |
| Genesis payloads | **unchanged** — no genesis hash moves |
| Block hashes | **unchanged** — `merkle-log` repin verified byte-identical in `src/` |
| Peering with old nodes | **works** — we retain `minAcceptedVersion = NodeVersion [1,2]` |

**No resync. No chain restart. A binary swap**, and a staged rollout is safe.

**Rollback** is clean *until block 525,000 passes*, because no on-disk format
changes — the old binary reads the new database. After the fork activates,
rolling back means rewinding the chain. **Treat 525,000 as the point of no return.**

---

## Also fixed in this release

**A CRLF checkout produced a node that could not mine.** `rewards/miner_rewards.csv`
is embedded by Template Haskell and its SHA-512 is pinned in `MinerReward.hs`.
`embedFile` takes bytes as they sit on disk, so a CRLF working tree embedded
different bytes, failed the pinned check, and killed coinbase.

This was invisible to a clean build, a running binary, `--version` and
`--print-config`. Only the unit suite caught it. `.gitattributes` now forces
`eol=lf` on that file, and five shell scripts that were still CRLF were
renormalised (CRLF scripts fail in Linux containers with `bad interpreter`).

**`main` no longer builds at all** — unpinned dependency drift (`validation`
gained a `Data.Validation.either` colliding with `Prelude.either`, and semialign
1.4 began requiring an `Unzip` instance). This branch is currently the only
buildable state of the repository, independent of any security consideration.

---

## Upgrade procedure

1. Pull `ghcr.io/stoachain/stoa-node:v3.2.1-stoa.1`
2. Restart nodes with **identical configuration** — no config change is required
3. Verify each node reports `chainweb-node-3.2.1`
4. **Confirm every node is upgraded well before block 525,000**

Nodes may be rolled one at a time; old and new peer normally below the fork height.

### Verifying a node

```bash
docker exec <container> chainweb-node --version
# expect: chainweb-node-3.2.1 (package chainweb-node-3.2.1 revision <sha>-upgrade/chainweb-3.2.1)
```

Check the **revision string**, not just the version — `--version` embeds the git
SHA at configure time, and a stale binary will happily report a plausible-looking
result.

---

## Verification status

| Check | Status |
|---|---|
| Builds clean under `-Wall -Werror` | ✅ |
| Dependency resolution — `crypton-x509-validation-1.9.1` | ✅ verified |
| Unit suite builds | ✅ |
| Unit suite runs | ⚠️ 21/1441 fail — all trace to pre-existing Stoa/Kadena divergence on code paths we do not execute; see below |
| Replay against real chain history | ⏳ pending |
| Live block extension under mining | ⏳ pending |
| Fork transition rehearsal | ⏳ pending |
| Old-node stall behaviour | ⏳ pending |

**On the 21 test failures.** All golden files are byte-identical to upstream's, yet
our tree diverges from upstream in 28 genesis payload modules, 17 transaction
modules and the miner-rewards schedule — none of which this branch touched. Those
tests compare Kadena behaviour against Kadena expectations on a tree that is
deliberately not Kadena. Exactly **one** test file in the entire suite references
the `stoa` version. A clean baseline comparison was not possible because `main`
no longer builds.
