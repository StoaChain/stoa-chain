# StoaChain node container — `ghcr.io/stoachain/stoa-node`

`chainweb-node` built for the **stoa** network. This page documents the
`v3.2.1-stoa.2` image: what it fixes, what changes at block 516,500, and how to
verify a running node is really on it.

```bash
docker pull ghcr.io/stoachain/stoa-node:v3.2.1-stoa.2
```

| | |
|---|---|
| Base | Ubuntu 22.04 |
| Compiler | GHC 9.10.2 |
| chainweb-node | 3.2.1 |
| Pact | 5.4.1 |
| Consensus change | **activates at block height 516,500, all chains** |
| Upgrade type | binary swap — no resync, no database migration |

---

## Why this release exists

Kadena disclosed four vulnerabilities alongside chainweb 3.2. We audited all
four against our own tree, then audited the full 3.2 diff ourselves and found
ten more issues. **Eight of the fourteen affected StoaChain.** Two of them
permit outright theft of funds.

Every one of the eight is closed by this image.

### The eight issues that affected us

| # | Issue | Severity | How it's closed |
|---|---|---|---|
| **SC-1** | **Identity forgery via the `addr` field.** A WebAuthn signer could set `addr` to any ED25519 public key and be accepted as that key's owner — impersonating any keyset holder on the chain. | SUPERCRITICAL | Pact 5.4.1 keys `mkMsgSigs` on the real public key instead of `fromMaybe pubK addr`. Gated at 516,500. |
| **SC-2** | **Capability theft through composition.** `compose-capability` did not re-check module boundaries, letting a module acquire capabilities belonging to another module. | SUPERCRITICAL | Pact 5.4.1 adds `guardForModuleCall` to `composeCap`. Gated at 516,500. |
| **C-1** | **CVE-2026-9648** — X.509 `NameConstraints` were not enforced by the pinned `crypton` version, so the holder of a name-constrained sub-CA could mint a certificate valid for any hostname. | CRITICAL (CVSS 9.1) | Dependency graph moved to `crypton >= 1.1.2`. **Active immediately.** |
| **H-1** | **Unmetered signature size.** Signatures were excluded from transaction size metering, so a transaction could carry near-unbounded signature data at no gas cost. Our exposure was **worse than Kadena mainnet's**, because our block gas limit is ~13x theirs (2,000,000 vs 150,000). | HIGH (DoS) | `post32GasModel` meters `sigsSize`. Gated at 516,500. |
| **H-2** | **Block-validation CPU exhaustion.** WebAuthn signature verification is far more expensive than ED25519 but was billed the same, so a cheap block could pin every validator's CPU. Again worse for us than for Kadena. | HIGH (consensus) | `post32GasModel` charges 526 gas per WebAuthn signer vs 21 for ED25519, calibrated to 1 gas per 2.5 µs. Gated at 516,500. |
| **H-3** | **Cut-queue duplicate flood.** A remote peer could flood the cut pipeline with duplicates and starve real cut processing. | HIGH (remote DoS) | Deduplication in the cut queue. **Active immediately.** |
| **H-4** | **Unmetered SPV continuation-proof size.** Continuation proofs were not billed for their size. | HIGH | `post32GasModel` adds `proofSizeFactor`. Gated at 516,500. |
| **M-1** | **Completed-defpact continuations accepted into the mempool.** Transactions continuing an already-finished defpact were admitted, then failed at execution — free mempool occupancy. | MEDIUM | Mempool rejects them at admission. **Active immediately.** |

Six further issues (H-5, and M-2 through M-6) were audited and found **not to affect StoaChain** —
either already fixed in our tree, or reachable only through code paths we don't
run. They are documented with the reasoning in
[`vulnerabilities-fixed-in-3.2.md`](vulnerabilities-fixed-in-3.2.md).

### Container and build fixes in this image

| Fix | Detail |
|---|---|
| **Miner-rewards checksum** | `rewards/miner_rewards.csv` was being embedded with CRLF line endings on Windows checkouts, so its pinned SHA-512 failed and the node died at the first coinbase. Invisible to `build`, `--version` and `--print-config`. Fixed with `.gitattributes eol=lf`. |
| **Image provenance** | `.dockerignore` excludes `.git`, so `--version` printed an empty revision string. Version and commit SHA now travel as OCI labels. |
| **Working HEALTHCHECK** | The image's own healthcheck could never pass — it used the bash-only `/dev/tcp` under `dash`, and its `ulimit` gate read the healthcheck process's limits rather than PID 1's. **This affects the previously published `:latest` too.** Now reports `healthy`. |
| **GHC 9.10.2** | Required by the 3.2.1 dependency graph. |

---

## What happens at block 516,500

Issues SC-1, SC-2, H-1, H-2 and H-4 change how transactions execute, so they cannot be
switched on retroactively without invalidating chain history. They activate
together at height **516,500 on every chain** — a single fork point, set
2026-08-26 against a live tip of 516,149: 351 blocks, roughly 3 hours at our
30 s block delay.

> This was brought forward from the 525,000 that `v3.2.1-stoa.1` shipped with,
> to close issue SC-2 sooner. **`v3.2.1-stoa.1` is superseded and must not be
> deployed** — it would wait for a height this network will already have passed
> under the new rules.

A fork height must always sit *ahead* of the live tip. Setting one in the past
does not mean "activate immediately": it rewrites the rules for blocks that
already exist, so replay recomputes their gas, their payload hashes move, and
the node rejects the chain's own history.

Issues C-1, H-3 and M-1 do not affect execution semantics and are **live the moment
the container starts**.

> **Every node must be running this image before block 516,500.**

### An un-upgraded node will not warn you

Exactly one guard hangs off the fork, and it is consumed only by transaction
execution — never by `applyCoinbase`. A post-fork block containing only a
coinbase is **byte-identical under both rule sets**. So an old node sails past
516,500 reporting perfect health, and stalls later, at the first post-fork block
that carries an actual transaction.

**A healthy node is not evidence of an upgraded node.** Check the version.

---

## Verifying a node is really upgraded

One request, no shell access needed:

```bash
curl -s http://<host>:1848/info | jq '{v:.nodePackageVersion, fork:.nodeLatestBehaviorHeight}'
```

Expected output:

```json
{ "v": "3.2.1", "fork": 516501 }
```

`nodeLatestBehaviorHeight` is the reliable field — it is derived from the
compiled-in fork table, so it cannot be faked by a config file or a stale image
tag. Anything other than `516501` will fork off the network at 516,500.

To confirm exactly which build you pulled:

```bash
docker inspect ghcr.io/stoachain/stoa-node:v3.2.1-stoa.2 --format '{{index .Config.Labels "org.opencontainers.image.revision"}}'
```

---

## Upgrading

The block header format, RocksDB schema and Pact SQLite schema are all
unchanged. This is a **binary swap**: stop the container, start the new one on
the same data directory. No resync, no compaction, no migration.

Rollback is clean **until block 516,500 passes**. After that, a rolled-back node
is an un-upgraded node and will stall as described above.

```bash
docker pull ghcr.io/stoachain/stoa-node:v3.2.1-stoa.2
```

Then recreate the container against your existing volume and environment.

---

## Running

```bash
docker run -d --name stoa-node --restart=unless-stopped -p 1789:1789 -v stoa-data:/data -e P2P_HOSTNAME=your-public-dns-name ghcr.io/stoachain/stoa-node:v3.2.1-stoa.2
```

`P2P_HOSTNAME` is required — the node needs to advertise a reachable address to
peers. To enable mining coordination, set `ENABLE_MINING_COORDINATION=true` and
supply `MINING_PUBKEY`.

---

## How this image was verified

| Check | Result |
|---|---|
| Replay of real chain history | 508,079 blocks replayed from wiped Pact state; all 10 chains matched target hashes byte-for-byte |
| Live block production | ~180 blocks mined across all 10 chains, zero errors, coinbase credited correctly |
| Fork transition | On a copy of real chain state with activation moved to 508,090, all 10 chains mined through the boundary and kept producing. Zero errors. |
| Gas model engages at the fork | Measured via `/local` preflight on chain 0: **87 → 109** gas (1 signer) and **88 → 132** (2 signers) exactly at the boundary. Marginal cost of an extra signer went **+1 → +23**, matching `post32GasModel` to the gas. |
| Transaction execution under new rules | `/local?preflight=true` calls the same `applyCmd` block execution uses. A full transaction ran post-fork through `buyGas` → evaluation → `redeemGas`, successfully. |

The one thing **not** demonstrated empirically: the disclosed exploits being
*rejected*. That rests on upstream Pact 5.4.1's correctness plus the unit suite,
because the rehearsal chain has no funded signing key with which to craft an
adversarial transaction. Recorded here rather than glossed over.

Full record: [`RELEASE-v3.2.1-stoa.2.md`](RELEASE-v3.2.1-stoa.2.md).

---

## Further reading

| Document | Contents |
|---|---|
| [`vulnerabilities-fixed-in-3.2.md`](vulnerabilities-fixed-in-3.2.md) | All 14 issues, with a verified StoaChain exposure verdict for each |
| [`RELEASE-v3.2.1-stoa.2.md`](RELEASE-v3.2.1-stoa.2.md) | Operator release notes and the full verification record |
| [`upgrade-fix-log.md`](upgrade-fix-log.md) | Every change applied, one entry per commit, with revert consequences |
| [`chainweb-3.2-audit.md`](chainweb-3.2-audit.md) | The underlying audit of chainweb 3.2 / 3.2.1 |
| [`miner-fork-voting.md`](miner-fork-voting.md) | How upstream's miner fork voting works, and what adopting it would take |
