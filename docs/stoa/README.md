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
| [`container-build-plan.md`](container-build-plan.md) | Ordered task list for building and shipping the fixed `v3.2.1-stoa.1` container, including the test gates |

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

1. **Waves 0–3** (~2.5 d, no fork, no coordination) — closes #5 (CVSS 9.1 CVE), #6, #8.
2. **Waves 4–6** (~4–6 d, one coordinated fork) — closes #1, #2, #3, #4.

Target **chainweb 3.2.1** (`d89bb530`) and **Pact 5.4.1** (`kda-community/pact-5` tag `72f42760`).

## Upgrading the live network without breaking it

Established by audit, all verified against source:

- **Block header format is unchanged** — the `FeatureFlags` → `ForkState` rename happened *at our base*; Merkle tag `0x0006` and header size are identical.
- **RocksDB schema is unchanged** — the `libs/chainweb-storage/` diff is 2 lines, both dependency renames. There is no DB version stamp anywhere, so nothing can refuse an old database.
- **Pact SQLite schema is unchanged** — no `CREATE TABLE` / `PRAGMA` / `user_version` in the diff.
- **No genesis payload changed** ⇒ no genesis hash can move.
- **merkle-log's `src/` is byte-identical** to 0.2.0 ⇒ block hashes cannot move.

⇒ **No resync. No chain restart. A binary swap.** But note three constraints:

1. **The cutover must be simultaneous on node1 and node2.** `isAcceptedVersion` requires peers ≥ `NodeVersion [3,0]`, so a 3.x node refuses to peer with an un-upgraded one. Stop both, swap, start both.
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
