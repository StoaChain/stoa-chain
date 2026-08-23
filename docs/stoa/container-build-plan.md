# StoaChain container build plan — chainweb 3.2.1 + Pact 5.4.1

Target artefact: `ghcr.io/stoachain/stoa-node:v3.2.1-stoa.1`
Closes issues **#1, #2, #3, #4, #5, #6, #7, #8** from [`vulnerabilities-fixed-in-3.2.md`](vulnerabilities-fixed-in-3.2.md).

---

## 0. First, a correction to a common assumption

**There is no choice between a "double container" and a "single container."**

Every chainweb binary carries *every ruleset the chain has ever used*, permanently. That is not a voting feature — it is a requirement of being a blockchain node. A node must be able to re-validate its own history, and historical blocks were produced under historical rules. Remove the old codepath and the node can no longer resync, rewind, or bootstrap a fresh peer. This is why Kadena still ships Pact 4 code years after Pact 5.

So the binary always contains old rules + new rules + a fork guard selecting between them. The size cost is negligible (the entire new gas model is one 77-line file; the Pact fix is ~10 lines behind a flag).

**The only real decision is *when the new rules switch on*.** Three options, §3.

---

## 1. Repository preparation

- [ ] Fork `kda-community/pact-5` into the `StoaChain` org (master only — master HEAD **is** tag `5.4.1` = `72f42760`).
- [ ] Fork `kda-community/pact` (Pact 4, tag `ef859d8b`).
- [ ] Fork `kda-community/merkle-log` (`c502176`).

Rationale: chainweb pins dependencies as bare git URL + SHA, fetched at build time. There is no vendoring and no registry. The `pact-5-special-fix` episode — where the pinned repo returned 404 to everyone for a day — is the concrete failure mode. Forks protect against a repo being renamed, privatised or deleted.

- [ ] Generate `--sha256` values for the three pins upstream ships without them:
      `nix-prefetch-git --url <location> --rev <tag>`. This content-pins them even against a rewritten history.

## 2. Source integration

Work on a branch off `main`. Never on `main`.

- [ ] `git remote add kdac https://github.com/kda-community/chainweb-node.git && git fetch kdac --tags`
- [ ] Follow [`chainweb-3.2-backport-plan.md`](chainweb-3.2-backport-plan.md) waves 0–6, targeting tag **`3.2.1`** (not `3.2`).
- [ ] Point `cabal.project` at **our** forks of pact-5 / pact / merkle-log, not kda-community's.
- [ ] Delete our `crypton == 1.0.4` / `memory == 0.18.0` / `merkle-log == 0.2.0` constraint block and the `bytesmith < 0.3.14` pin — they block the CVE fix (#5).
- [ ] Fix `chainweb.cabal` `version:` — currently reads `2.32.0`, which was hand-edited and never accurate. Set to `3.2.1`.
- [ ] `Stoa.hs` edits: add `_versionForkVoteCastingLength`, rename `_versionMinimumBlockHeaderHistory` → `_versionSpvProofRootValidWindow` (value stays `Nothing`), add `_versionInitialGasModel`, set `Chainweb31` / `Chainweb32` / `MigratePlatformShare` **explicitly** — never via the wildcard.

> **Do not cherry-pick `ade03946b`** ("Accept only new post-fork nodes"). It raises `minAcceptedVersion` to `>= [3,0]` with a hardcoded Kadena fork date. Our tree has `minAcceptedVersion = NodeVersion [1,2]` (`NodeVersion.hs:88`), which is what lets new and old Stoa nodes peer during a rolling upgrade. Keeping it is deliberate.

> **Do not cherry-pick `3149131c8`** ("Platform share migrate"). It introduces `MigratePlatformShare` plus Kadena's community keysets, and combined with our wildcard fork table it throws `error "fork cannot be at genesis"` on every block.

## 3. Choose the activation mechanism

| Option | How | Pros | Cons |
|---|---|---|---|
| **A. Height gate** *(recommended)* | `Chainweb32 -> ForkAtBlockHeight <current tip + N>` | deterministic, fast, no new machinery | no safety net — the height arrives whether or not the fleet is upgraded |
| **B. Vote gate** | `Chainweb32 -> ForkAtForkNumber 1` + `_versionForkNumber = 1` | partial rollout **fails safe** — vote simply never reaches 2/3 | needs the ForkNumber machinery (wave 4); 5-day epoch unless `_versionForkVoteCastingLength` is lowered |
| **C. Genesis** | `Chainweb32 -> ForkAtGenesis` | simplest | **only safe if no historical transaction used the buggy paths** — must be proven by a chain scan, not assumed |

**Recommendation: A** for this release. These are security fixes; a known activation time beats a 5-day vote. Pick a height a few hours out, verify every container is upgraded, let it land.

Option C is viable for a young private chain and would activate the fixes immediately — but only after scanning history for (a) any signer carrying an `addr` field, (b) any cross-module `compose-capability`. If both are absent, C replays identically. The replay test in §5 proves it either way.

### 3a. Note on "just disable WebAuthn" as a shortcut

Issues #1, #3 and #4 all require WebAuthn signatures, so blocking that scheme would mitigate all three at once. **But it is not the one-line change it appears to be.**

`validPPKSchemes` is enforced **only on the Pact 4 code path** — all four call sites go through `Pact4.assertCommand` (`Pact/PactService.hs:820`, `Pact/RestAPI/Server.hs:721`, `Pact4/Validations.hs:92`, `Pact/PactService/Pact4/ExecBlock.hs:339`). Verified: `grep -rn "validPPKSchemes" src/Chainweb/Pact5/ src/Chainweb/Pact/PactService/Pact5/` returns **nothing**.

StoaChain runs Pact 5 (all forks at genesis), where validation goes `validateParsedChainwebTx` → `checkTxSigs` → `assertValidateSigs` → `verifyUserSig`, which dispatches on `_siScheme` and accepts WebAuthn unconditionally. So setting `validPPKSchemes` to ED25519-only would **not** block WebAuthn on our chain.

Blocking it requires our own patch to the Pact 5 validation path (a few lines rejecting `Just WebAuthn`), which is StoaChain-local divergence, still a consensus change, and still needs a fork gate and the full replay test.

**Conclusion:** take the Pact 5.4.1 fixes as the primary remedy. If we are confident StoaChain will never use passkey signing, add the WebAuthn rejection to the *same* release as defence in depth — same fork, marginal extra work. Do not treat it as a faster alternative to the upgrade.

## 4. Build

- [ ] `Dockerfile`: `ARG GHC_VERSION` 9.10.1 → **9.10.2** (3.2.1's freeze pins `base ==4.20.1.0`). Upstream's own Dockerfile still says 9.10.1 and contradicts its freeze — do not copy it.
- [ ] Adopt 3.2.1's `cabal.project.freeze` verbatim.
- [ ] Keep our Dockerfile deltas: `libmpfr`/`libmpfr-dev`, `cwtools:exe:ea`, disabled slowtests, `stoa-node` final stage.
- [ ] `cabal build all` clean under `-Wall -Werror`.
- [ ] `docker build -t stoa-node:v3.2.1-stoa.1 .`

## 5. Testing — before this passes, nothing ships

### 5a. Unit and integration suites
- [ ] `cabal test chainweb-tests` — expect breakage in `MinerReward.hs` (Stoa-rewritten) and anything constructing a `ChainwebVersion` literal.
- [ ] `cabal test multi-node-network-tests`.
- [ ] Add a test asserting `registerVersion stoa` succeeds and `migratePlatformShare stoa cid h == False` (today it *throws*).

### 5b. Replay against real history — the critical gate
- [ ] Snapshot the live RocksDB + Pact SQLite from the production node.
- [ ] Boot the new binary against the **copy** with `--prune-chain-database=full`. This forces `validateBlockHeaderM` over every stored header offline. **Never run this against production.**
- [ ] Wipe **only** the Pact SQLite on the copy; let it replay from RocksDB. This re-executes every transaction in our history under the new binary and proves gas + Pact determinism end to end. If a single historical block produces a different payload hash, this fails loudly here rather than on the live chain.
- [ ] Confirm `Stoa0Payload.payloadBlock` loads without an `expectedHash` error.

### 5c. Cloned network rehearsal
- [ ] Stand up a throwaway 2-node network from the DB copy, on an isolated network, with the **same flags and config** as production.
- [ ] Confirm peering, block production, and that the cut advances.
- [ ] Advance past the chosen activation height (or trigger the vote) and confirm the network keeps producing blocks *through* the transition — this is the single most important rehearsal, because it exercises the exact moment the rules change.
- [ ] Submit a transfer before and after the activation point; confirm both succeed and gas changes as expected (+22 per ED25519 signer).
- [ ] Negative test: point an **old** binary at the post-activation chain and confirm it stalls rather than forking silently.

### 5d. Exploit regression tests
- [ ] Reproduce issue #2 using upstream's `compose-caps-bug.repl` against our build — must fail post-activation, succeed pre-activation.
- [ ] Construct a transaction with a WebAuthn signer carrying a forged `addr` (issue #1) and confirm it no longer satisfies the impersonated keyset post-activation.

## 6. Deployment

- [ ] Publish to GHCR as `v3.2.1-stoa.1`, and only move `:latest` after the fleet is healthy.
- [ ] Roll out node by node. Peering keeps working during the rollout because we retain `minAcceptedVersion = [1,2]`.
- [ ] Verify **every** container is on the new image before the activation height lands.
- [ ] Keep the previous image and a database snapshot on hand.

**Rollback:** because block header format, RocksDB schema and Pact SQLite schema are all unchanged, the old binary reads the new database. Rollback is clean *until the activation point passes* — after that, the old binary will reject post-fork blocks. Rollback after activation means rewinding the chain, so treat the activation height as the point of no return.

---

## Chain scan (worth doing regardless)

Upstream scanned mainnet and found no evidence any of #1–#4 were exploited. The equivalent scan on StoaChain is cheap and answers two questions at once — whether we were attacked, and whether option C (genesis activation) is safe:

- any transaction whose signer list contains an `addr` field
- any transaction invoking `compose-capability` across a module boundary
