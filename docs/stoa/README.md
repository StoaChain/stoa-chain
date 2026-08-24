# StoaChain-specific documentation

Everything in this directory is StoaChain's own. The parent `docs/` directory holds
upstream Kadena documentation — keeping ours here means upstream cherry-picks and
merges never touch these files.

## Contents

| File | What it is |
|---|---|
| [`vulnerabilities-fixed-in-3.2.md`](vulnerabilities-fixed-in-3.2.md) | **Start here.** Numbered issue list (#1–#14) with a verified StoaChain exposure verdict for each |
| [`chainweb-3.2-audit.md`](chainweb-3.2-audit.md) | Full technical audit of chainweb 3.2 / 3.2.1, every headline claim verified against source |
| [`chainweb-3.2-backport-plan.md`](chainweb-3.2-backport-plan.md) | Wave-by-wave cherry-pick plan with measured (not estimated) conflict status per commit |
| [`miner-fork-voting.md`](miner-fork-voting.md) | How miner fork voting actually works, and what it takes to adopt it for StoaChain |
| [`upgrade-fix-log.md`](upgrade-fix-log.md) | **Running record of every change applied on `upgrade/chainweb-3.2.1`** — one entry per commit, with rationale and revert consequences |
| [`container-build-plan.md`](container-build-plan.md) | Ordered task list for building and shipping the fixed `v3.2.1-stoa.1` container, including the test gates |
| [`RELEASE-v3.2.1-stoa.1.md`](RELEASE-v3.2.1-stoa.1.md) | **Operator-facing release notes** — what ships, the 525,000 activation, how to verify a node is really upgraded, and the full verification record |

## Status as of 2026-08-03

**The upgrade is no longer blocked, and it is no longer optional.**

On 2026-08-02 upstream published the
[Ad-Vitam Transparency Report](https://medium.com/@communitykadena/chainweb-3-2-ad-vitam-transparency-report-cfcfff237f43),
disclosing four vulnerabilities that 3.2 fixed, and released **chainweb 3.2.1** with the
complete Pact source. Everything is now public and buildable.

**StoaChain is exposed to 7 of the 14 catalogued issues**, including two that permit outright
theft:

- **#1 Identity forgery via the `addr` field** — a WebAuthn signer with a forged `addr` impersonates any ED25519 keyset holder. Complete authentication bypass.
- **#2 Capability theft via `compose-capability`** — any module can acquire another module's capabilities.

On **#3** and **#4** (unmetered signature size and verification CPU) our exposure is *worse*
than Kadena mainnet's, because our block gas limit is roughly 10× theirs.

See [`vulnerabilities-fixed-in-3.2.md`](vulnerabilities-fixed-in-3.2.md) for the evidence
behind every verdict.

## Plan

Work happens on a dedicated branch off `main`, never on `main` directly.
Current branch: **`upgrade/chainweb-3.2.1`**.

Target **chainweb 3.2.1** (`d89bb530`) and **Pact 5.4.1** (`kda-community/pact-5` tag `72f42760`).

### Release sequencing — decided 2026-08-23

**One release, not two.** An interim security-only container carrying just waves 0–3 was
considered and **rejected**: everything ships together, fully tested.

| Release | Contents | Status |
|---|---|---|
| **`v3.2.1-stoa.1`** | Waves 0–6 — closes issues **#1, #2, #3, #4, #5, #6, #8** | in progress |
| **`v3.2.1-stoa.2`** | Minimum gas price floor (10,000 ANU at genesis, +1 ANU / 3 h, cap 400,000) | after stoa.1 is stable |

The gas floor is deliberately a **separate release**. Its formula already exists in
`pact/stoa-coin/new-coin.pact` (`UC_MinimumGasPriceANU`) but is currently dead code —
nothing calls it, and chainweb's only floor is the per-node, mempool-only
`_configMinGasPrice = 1e-8`. Making it consensus-enforced needs a `_versionMinGasPrice`
rule checked in `validateParsedChainwebTx`. **No Pact fork is required** — gas price is
transaction metadata validated by chainweb, not by the Pact interpreter.

### Remaining work for `v3.2.1-stoa.1`

| | Work | Closes |
|---|---|---|
| ✅ | Waves 0–3 | #5, #6, #8 |
| ✅ | Dependency resolution verified (`crypton-x509-validation-1.9.1`) | — |
| ⏳ | Full compile | — |
| ☐ | Wave 4 — ForkNumber machinery | enables 5 & 6 |
| ☐ | Wave 5 — gas model | **#3, #4** |
| ☐ | Wave 6 — Pact 5.4.1 activation | **#1, #2** |
| ☐ | `Stoa.hs` fields; `Chainweb31`/`Chainweb32`/`MigratePlatformShare` set **explicitly** | — |
| ☐ | Version strings (`chainweb.cabal` still reads `2.32.0`) | — |
| ☐ | Choose the activation block height | — |
| ☐ | CRLF fix: `run-stoa.sh`, `deploy.sh`, `scripts/collectArtifacts.sh` | — |
| ☐ | Replay against a copy of the live database | gate |
| ☐ | Cloned 2-node network driven *through* the activation height | gate |
| ☐ | `docker build` → GHCR | release |

## Upgrading the live network without breaking it

Established by audit, all verified against source:

- **Block header format is unchanged** — the `FeatureFlags` → `ForkState` rename happened *at our base*; Merkle tag `0x0006` and header size are identical.
- **RocksDB schema is unchanged** — the `libs/chainweb-storage/` diff is 2 lines, both dependency renames. There is no DB version stamp anywhere, so nothing can refuse an old database.
- **Pact SQLite schema is unchanged** — no `CREATE TABLE` / `PRAGMA` / `user_version` in the diff.
- **No genesis payload changed** ⇒ no genesis hash can move.
- **merkle-log's `src/` is byte-identical** to 0.2.0 ⇒ block hashes cannot move.

⇒ **No resync. No chain restart. A binary swap.** But note three constraints:

1. **A rolling upgrade is fine — provided we do not cherry-pick `ade03946b`.** Our tree has `minAcceptedVersion = NodeVersion [1,2]` (`NodeVersion.hs:88`), so new and old Stoa nodes peer normally and the fleet can be updated node by node. The community version raises this to `>= [3,0]` with a hardcoded Kadena fork date, which *would* force a synchronised restart — another reason that commit stays on the do-not-take list. What still requires coordination is the **activation point**: every node must be on the new image before the fork height lands, or the stragglers stall.
2. **Never activate the Pact fixes at genesis.** `ForkAtGenesis` is `minBound`, so `chainweb32` would read as always-true and apply the fixed semantics to our whole history — diverging replay if any historical transaction used the buggy paths. Gate at a **future block height** (or a fork number, if adopting voting).
3. **Run the replay gate before production.** Boot the new binary against a *copy* of the live database with `--prune-chain-database=full`, then wipe only the Pact SQLite and let it replay from RocksDB. That is the one test that proves gas and Pact determinism against our real history.

Rollback is clean: because no on-disk format changes, the old binary reads the new database.

## Dependency sourcing

Chainweb pins its dependencies as `source-repository-package` entries — git URL plus commit
SHA, fetched at build time. There is no vendoring and no registry.

The `pact-5-special-fix` episode is a live demonstration of the risk: for about a day, the
repository chainweb 3.2 pinned returned **404** to everyone outside the org, which made the
release unbuildable from source. Upstream repositories can be renamed, made private, or
deleted, and our builds break when that happens.

**Recommendation:** keep StoaChain-owned forks of at least `pact-5`, `pact` and `merkle-log`
under the `StoaChain` org, and point `cabal.project` at those. GitHub forks (rather than bare
mirrors) preserve the upstream link, so pulling future fixes stays a normal fetch-and-merge.
Keep the upstream repository *names* so `cabal.project` stays readable.

## Two standing corrections

1. **`CLAUDE.md` is wrong about TLS.** It claims `_disablePeerValidation = True` "allows
   self-signed certificates between peers." It does not — that flag only skips
   `validateP2pConfiguration` and permits reserved/RFC1918 peer addresses. It has nothing to
   do with certificate validation.

2. **Our base is not 2.32.** StoaChain's real upstream base is `4aedec3bb` ("Forks done
   right"), an **ancestor of 3.2** contained in tags 3.1 and 3.2 — despite `chainweb.cabal`
   reading `version: 2.32.0`. That is why upstream commits can be `git cherry-pick`ed directly.
