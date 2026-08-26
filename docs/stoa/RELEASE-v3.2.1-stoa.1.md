> # ⛔ SUPERSEDED — DO NOT DEPLOY
>
> **`v3.2.1-stoa.1` was never deployed to the fleet and must not be.** It was
> replaced on 2026-08-26 by **`v3.2.1-stoa.2`**, which moves the activation
> height from 525,000 down to **516,500** so that issue SC-2 (capability theft via
> `compose-capability`) closes hours from now rather than days.
>
> Deploying this image after 516,500 would put a node on the *old* execution
> rules past the fork — it would stall at the first post-fork block carrying a
> transaction.
>
> **Current release: [`CONTAINER-README.md`](CONTAINER-README.md).**
>
> Everything below is retained as the verification record: the replay, the fork
> transition rehearsal and the measured gas figures were all produced from this
> tree, and `v3.2.1-stoa.2` differs from it by exactly one constant — the
> activation height, changed in both places it appears.

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

### C-1 · CVE-2026-9648 — X.509 NameConstraints not enforced · **CVSS 9.1**

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

### H-3 · Cut-queue duplicate-flood DoS

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

### M-1 · Completed-defpact continuations accepted into the mempool

Pre-insert did not check whether a continuation targeted an already-completed
defpact, so an attacker could cheaply fill mempools and blocks with
guaranteed-failing cross-chain replays. Now rejected with
`InsertErrorDefPactComplete`.

---

## Fixes that activate at block 525,000

All five share one activation height, so a single fork turns everything on at once.

### SC-1 · Identity forgery via the signer `addr` field · **CRITICAL**

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

### SC-2 · Capability theft via `compose-capability` · **CRITICAL**

Pact's core security property is that *a capability can only be acquired by code
within the same module*. `composeCap` called `evalCap` **without**
`guardForModuleCall`, so `(compose-capability ...)` could acquire a capability
belonging to a third-party module. Upstream's assessment: *"most existing
contracts were potentially vulnerable to this attack."*

### H-1 · Unmetered signature size · HIGH

Signatures were capped at 100 per transaction but charged **zero** gas —
`payloadBytes` excludes `_cmdSigs`. WebAuthn signatures carry arbitrary-size
embedded metadata, so blocks could be inflated beyond what the P2P layer
propagates efficiently while staying inside the block gas limit.

### H-2 · Block-validation CPU exhaustion · HIGH

WebAuthn verification costs ~1.315 ms against ED25519's ~52 µs, and was unmetered.
Filling a block with WebAuthn-signed transactions pushed validation time toward
the 30-second block delay — risking an uncontrolled network fork.

> **StoaChain was materially worse off than Kadena on H-1 and H-2.** Upstream's
> mitigating argument was that their 150k gas-per-block cap bounded the damage.
> Our `_versionMaxBlockGasLimit` is **2,000,000** — roughly 10× theirs — so the
> margin they called *"uncomfortably small"* was about ten times smaller here.

### H-4 · Unmetered SPV continuation-proof size · HIGH

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

### What an un-upgraded node actually does at 525,000 — read this

**It does not stop at 525,000.** Auditing every guard on the `Chainweb32` fork
turned up exactly one execution site:

```haskell
-- src/Chainweb/Pact5/TransactionExec.hs:1041
guardDisablePact54FixFlags txCtx
  | guardCtx' chainweb32 txCtx = Set.empty
  | otherwise = Set.singleton FlagDisablePact54Fix
```

and that flag set is consumed only by `applyCmd` and `applyLocal`. `applyCoinbase`
(line 478), `buyGas` (769) and `redeemGas` (881) take
`guardDisablePact52And53Flags` only, and are therefore untouched by this fork.
The gas-model rule keyed at the same height changes `initialGasOf`, which is
applied to **transactions** and not to the coinbase.

The consequence:

| Post-fork block contains | Old node |
|---|---|
| coinbase only (an idle chain) | **accepts it** — output is byte-identical under both rule sets |
| one or more transactions | **rejects it** — `initialGasOf` differs, so the command result's gas differs, so the outputs hash differs, so the payload hash does not match the header |

So an un-upgraded node sails past 525,000 looking perfectly healthy and then
stalls at the **first post-fork block carrying a transaction** — which could be
seconds or hours later, depending on network activity. Its cut simply stops
advancing on the affected chain; if it is mining it starts building a minority
chain.

Operationally this means two things:

1. The deadline is still 525,000. You cannot predict when the first post-fork
   transaction lands, so there is no safe margin past the fork height.
2. **Do not use "the node is still following the chain" as evidence that it is
   upgraded.** Use `/info` → `nodeLatestBehaviorHeight == 525001`. An old node
   gives no error and no log line at 525,000.

### Verifying a node

**Do not rely on `chainweb-node --version` for provenance.** `.dockerignore`
excludes `.git` from the build context, so the revision it embeds at configure
time is the **empty string** — the binary prints `revision ` with nothing after
it. Use the three checks below instead.

**1. Package version (from a running node, no exec needed):**

```bash
curl -s http://<host>:1848/info | jq -r .nodePackageVersion
```

Expect `3.2.1`. The old image reports `2.32.0`.

**2. Compiled consensus rules — this is the check that matters:**

```bash
curl -s http://<host>:1848/info | jq -r .nodeLatestBehaviorHeight
```

Expect **`525001`**. This value is derived from the fork table compiled into the
binary (highest fork height + 1), so it proves the node carries the 525,000
activation. The old image reports `1`, because before this release every Stoa
fork sat at genesis. A node reporting anything other than `525001` will fork
away from the network at block 525,000 — treat it as not upgraded.

**3. Git provenance, without starting the container:**

```bash
docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' \
  ghcr.io/stoachain/stoa-node:v3.2.1-stoa.1
docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' \
  ghcr.io/stoachain/stoa-node:v3.2.1-stoa.1
```

These OCI labels are populated from `--build-arg STOA_REVISION` /
`STOA_VERSION` at build time and are the replacement for the unusable
`--version` revision string.

### Note on `--disable-pow`

The flag exists but **cannot weaken a Stoa node**, by design.
`Registry.lookupVersionByCode` short-circuits version code `0x0A` to the
compiled-in `stoa` value (the same protection `mainnet01` and `testnet04` get),
so `prop_block_pow` never sees a CLI override. Passing `--disable-pow` only
swaps the in-node miner for the test miner, whose unsolved headers are then
rejected with `InvalidSolvedHeader … "Invalid POW hash"`. A test build that
genuinely needs PoW off must set `_disablePow = True` in
`src/Chainweb/Version/Stoa.hs` **and** pass the flag; see
[upgrade-fix-log.md](upgrade-fix-log.md).

---

## Verification status

| Check | Status |
|---|---|
| Builds clean under `-Wall -Werror` | ✅ |
| Dependency resolution — `crypton-x509-validation-1.9.1` | ✅ verified |
| Unit suite builds | ✅ |
| Unit suite runs | ⚠️ 21/1441 fail — all trace to pre-existing Stoa/Kadena divergence on code paths we do not execute; see below |
| Replay against real chain history | ✅ 508,079 blocks replayed from wiped Pact state; all 10 chains matched target hashes byte-for-byte |
| Live block extension under mining | ✅ ~180 blocks mined across all 10 chains, 0 errors; coinbase credited at 0.478482 ANU/block |
| Fork transition rehearsal | ✅ all 10 chains crossed the activation height and kept producing; 0 errors |
| Gas model engages at the fork | ✅ measured — see below |
| Old-node stall behaviour | ⚠️ resolved analytically, not empirically — see "What an un-upgraded node actually does" |
| Image healthcheck | ✅ `healthy` (the published image never could — see fix 13) |
| Image provenance | ✅ OCI labels carry version + git SHA |

### Fork transition rehearsal — method and result

Testing at the real activation height was impossible: the chain tip was ~508,080
and 525,000 is 17,000 blocks away. So the rehearsal used a purpose-built image,
`stoa-node:TESTONLY-fork2`, identical to the release build except for a
three-line patch — activation and gas-model transition moved from 525,000 to
**508,090**, and `_disablePow = True`. It was run against a copy of real chain
state taken from a live slave's backup API, on an `--internal` Docker network so
it could never reach the production network. The patch was reverted immediately
after the build; the release image is built from an unmodified tree.

That the patch actually reached the binary was confirmed independently, before
drawing any conclusions from the run: `/info` reported
`nodeLatestBehaviorHeight = 508091`.

**Result.** The node mined from 508,078 to 508,096 on all ten chains — through
and past the activation height — with **zero errors** and no
`InvalidSolvedHeader`, no payload-hash mismatch, and no stall. The coinbase kept
paying across the boundary (miner balance on chain 0 reached exactly
19 × 0.478482 ANU).

**Gas model.** Measured with `/local?preflight=true`, which runs the same
`initialGasOf` the block executor uses, against `stoa-foundation` on chain 0:

| signers | pre-fork (exec height 508,080) | post-fork (exec height 508,090) | delta |
|---|---|---|---|
| 1 | 87 | **109** | +22 |
| 2 | 88 | **132** | +44 |

Both deltas match `post32GasModel` exactly: `21` per ED25519 signer plus
`0.01 × sigsSize` (138 and 276 bytes), with `ceiling` applied to the total. The
marginal cost of a second signer went from **+1** gas (only the raw payload grew)
to **+23**. This is the direct evidence that issues **H-1**, **H-2** and **H-4** are
closed at the fork and not merely wired up.

**On the 21 test failures.** All golden files are byte-identical to upstream's, yet
our tree diverges from upstream in 28 genesis payload modules, 17 transaction
modules and the miner-rewards schedule — none of which this branch touched. Those
tests compare Kadena behaviour against Kadena expectations on a tree that is
deliberately not Kadena. Exactly **one** test file in the entire suite references
the `stoa` version. A clean baseline comparison was not possible because `main`
no longer builds.
