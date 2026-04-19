# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is **StoaChain** — a fork of Kadena's `chainweb-node` (a Haskell implementation of a braided Proof-of-Work parallel-chain blockchain). It is not vanilla Kadena: a new `ChainwebVersion` called **`stoa`** has been added alongside `mainnet01` / `testnet` / `development`, with its own genesis payloads, coin contract, miner-rewards schedule, and deployment targeting `node1.stoachain.com`.

The upstream README ([README.md](README.md)) still documents Kadena; use it for general chainweb concepts, but note that active development here is Stoa-specific.

## Build & run

Haskell project, toolchain pinned to **GHC 9.10.1** and **Cabal 3.14.1.1** (required by the custom-setup in `node/chainweb-node.cabal`; older `3.10` will fail).

```bash
cabal update
cabal build                              # builds everything
cabal build chainweb-node                # just the node binary
cabal list-bin chainweb-node             # print the built binary path
```

Nix is also supported via [flake.nix](flake.nix) (`nix build`, `nix develop`). Binary caches are configured in `nixConfig`.

Run the Stoa node locally with the flags used in production ([run-stoa.sh](run-stoa.sh)):

```bash
chainweb-node --chainweb-version stoa \
  --enable-mining-coordination --enable-node-mining \
  --node-mining-public-key=<hex-pubkey> \
  --p2p-hostname=<public-hostname> --p2p-port=1789 \
  --service-port=1848 --database-directory=<path>
```

`--chainweb-version stoa` is the key switch — it picks the Stoa version from the registry (see "Version wiring" below).

## Tests & benchmarks

Four cabal test-suites live in `chainweb.cabal`:

```bash
cabal test chainweb-tests                 # fast unit tests (test/unit)
cabal test compaction-tests               # test/compaction
cabal test multi-node-network-tests       # test/multinode
cabal test remote-tests                   # test/remote
cabal bench bench                         # benchmarks (bench/)
```

Run a single test group by passing a tasty pattern:

```bash
cabal test chainweb-tests --test-options='-p "MinerReward"'
cabal run chainweb-tests -- -p "Pact5.TransactionExec"
```

Unit tests (`test-suite chainweb-tests`) must be fast, parallel-safe, and must not initialize their own RocksDB — they share an overlay over a provided resource. See comments at [chainweb.cabal:604](chainweb.cabal:604) before adding new tests.

## Deployment

- [deploy.sh](deploy.sh) — end-to-end Ubuntu 22 server bootstrap (installs GHCup + deps, clones, builds, installs to `/usr/local/bin`, configures UFW ports 1789/1848, writes & starts the `stoa-node` systemd unit).
- [stoa-node.service](stoa-node.service) / [run-stoa.sh](run-stoa.sh) — systemd service definition and exec wrapper.
- Target host: `node1.stoachain.com` (also hard-coded as the sole bootstrap peer in the Stoa version).

## Architecture — what matters for Stoa work

Three Haskell packages share one `cabal.project`:

- `chainweb` (library, [src/](src/)) — the bulk of the protocol: cuts, block headers, mempool, Pact integration, P2P, consensus, REST APIs.
- `chainweb-node` ([node/](node/)) — thin executable wrapping the library. `main` is [node/src/ChainwebNode.hs](node/src/ChainwebNode.hs); it parses config, **registers the selected ChainwebVersion**, then runs the node.
- `cwtools` ([cwtools/](cwtools/)) — CLI utilities: `ea` (generates genesis payload Haskell modules from YAML), `compact`, `genconf`, `header-dump`, `run-nodes`, `pact-diff`, etc.

Plus [libs/chainweb-storage](libs/chainweb-storage/) (RocksDB wrapper) as a separate in-tree package.

### Version wiring (the Stoa-specific spine)

A `ChainwebVersion` is a first-class value that fixes graph topology, block delay, forks, genesis, gas limits, bootstraps, and verifier plugins. Adding or modifying a version is a multi-step process — every step must stay in sync:

1. **Version module** — [src/Chainweb/Version/Stoa.hs](src/Chainweb/Version/Stoa.hs) defines `stoa :: ChainwebVersion` and the `Stoa` pattern synonym. Bootstrap peers, genesis time, genesis payloads, `_versionMaxBlockGasLimit` (currently **2,000,000**), and verifier plugins all live here.
2. **Cabal registration** — the module is listed in [chainweb.cabal](chainweb.cabal) under `Chainweb.Version.*`.
3. **Registry** — [Chainweb.Version.Registry](src/Chainweb/Version/Registry.hs). `registerVersion` is invoked from [node/src/ChainwebNode.hs:496](node/src/ChainwebNode.hs:496) after config parsing.
4. **Genesis payloads** — generated Haskell modules under `src/Chainweb/BlockHeader/Genesis/` (e.g. `Stoa0Payload`, `Stoa1to9Payload`) are built from YAML/JSON source in [pact/genesis/stoa/](pact/genesis/stoa/) via `cwtools/ea`. Regenerate with `cabal run ea -- ...` when genesis transactions change; the version module imports the resulting modules.
5. **Default block gas limit** — `_configBlockGasLimit` default is in [src/Chainweb/Chainweb/Configuration.hs](src/Chainweb/Chainweb/Configuration.hs) (currently **1,600,000**). Keep ≤ the version's hard cap.
6. **Miner rewards** — emission schedule in [rewards/miner_rewards.csv](rewards/miner_rewards.csv); SHA-512 hash constants pinned in code must match (see commit history for `04-01`).
7. **Stoa coin contract** — [pact/stoa-coin/new-coin.pact](pact/stoa-coin/new-coin.pact), loaded via [pact/genesis/stoa/load-stoa-coin.yaml](pact/genesis/stoa/load-stoa-coin.yaml).

When touching any of 1/4/5/6/7, expect all of them to need review together — mismatches produce nonsensical errors deep in Pact or block validation.

### Other architectural pointers

- **Pact integration** straddles two major versions: [src/Chainweb/Pact4/](src/Chainweb/Pact4/) and [src/Chainweb/Pact5/](src/Chainweb/Pact5/). Tests are correspondingly split (`Chainweb.Test.Pact4.*`, `Chainweb.Test.Pact5.*`). Both Pact libraries are pulled via `source-repository-package` pins in [cabal.project](cabal.project).
- **Upstream dependency pins** — `cabal.project` pins pact, pact-5, pact-json, rocksdb-haskell-kadena, kadena-ethereum-bridge, wai-middleware-validation, ixset-typed, and base64-bytestring-kadena to specific commits. Bumping any of these is a coordinated change; update the `--sha256` lines accordingly (see the comment in `cabal.project` for `nix-prefetch-git` usage).
- **P2P bootstrap** — bootstrap peers are baked into each `ChainwebVersion`. Stoa has only `node1.stoachain.com:1789`; runtime overrides available via `--known-peer-info` / `--enable-ignore-bootstrap-nodes`.
- **TLS** — `_disablePeerValidation = True` on the Stoa version allows self-signed certificates between peers (intentional for the small network; see commit 962d44e).

## Conventions to follow

- **Before editing a test suite**, read the header comments in [chainweb.cabal:604](chainweb.cabal:604) (unit-test invariants re: RocksDB, parallelism, speed).
- **Warning flags are strict**: the library and node are compiled with `-Wall -Werror`. New code must build cleanly; don't suppress warnings except where the existing `common warning-flags` block already does.
- **CHANGELOG** — [CHANGELOG.md](CHANGELOG.md) is the upstream Kadena changelog; do not repurpose it. Project-specific change narrative currently lives in commit messages (see the `docs(phase-*)` / `feat(NN-NN)` pattern in `git log`).
