# StoaChain

<p align="center">
<img src="assets/StoaLogo.png" width="200" height="200" alt="StoaChain Logo" title="StoaChain">
</p>

<h3 align="center">A Proof-of-Work Parallel-Chain Protocol</h3>

> **StoaChain** is a blockchain built on Kadena's Chainweb protocol. This repository is the **node implementation** — a **software fork** of [`kadena-io/chainweb-node`](https://github.com/kadena-io/chainweb-node) that runs as its own independent blockchain with its own genesis (2026-02-23). It is **not a chain fork** of Kadena: it shares no ledger history with Kadena's mainnet.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Built with Haskell](https://img.shields.io/badge/Built%20with-Haskell-5e5086.svg)](https://www.haskell.org/)
[![Pact Version](https://img.shields.io/badge/Pact-5.4-blue.svg)](https://pact-language.readthedocs.io/)

---

## Table of Contents

- [Overview](#overview)
- [Live Network](#live-network)
- [Building From Source](#building-from-source)
- [Running a Node](#running-a-node)
- [Repository Layout](#repository-layout)
- [Key Code Entry Points](#key-code-entry-points)
- [Key Differences from Chainweb-Node](#key-differences-from-chainweb-node)
- [Tests](#tests)
- [Documentation](#documentation)
- [License](#license)
- [Development Method](#development-method)

---

## Overview

StoaChain is a **braided, parallelized Proof-of-Work blockchain** built on the Chainweb consensus protocol. Relative to upstream `chainweb-node`, this repo carries:

- A new `ChainwebVersion` named `stoa` — single network, 10 chains, Petersen graph, 30-second block delay
- A new genesis (`2026-02-23T18:00:00Z`) with 16,000,000 STOA and 1,000,000 URSTOA pre-minted on Chain 0
- Raised block gas limits: **1.6M default / 2M max** (vs upstream 150k/180k)
- A replacement coin module at [`pact/stoa-coin/new-coin.pact`](pact/stoa-coin/new-coin.pact) that computes emission inside Pact (`coin.URC_Emissions`) and defines both STOA and URSTOA
- `stoa-ns`-namespaced interfaces (`stoic-fungible-v1`, `stoic-xchain`, `stoic-predicates`, etc.)

**Pact version.** The live chain runs **stock upstream Pact 5.4** — no fork, no `chain-data` extensions. The node code still carries Pact 4 infrastructure under `src/Chainweb/Pact4/` (extraction was attempted and abandoned because Pact 4 and Pact 5 share code paths). Document both facts wherever Pact version comes up: code retains Pact 4 infra, live chain runs 5.4.

---

## Live Network

| Property | Value |
|----------|-------|
| **Network** | `stoa` (single network — no separate testnet/devnet) |
| **Version code** | `0x0000000A` (= 10) |
| **Chains** | 10 (Petersen graph, degree-3) |
| **Block delay** | 30 seconds |
| **Genesis time** | `2026-02-23T18:00:00.000000Z` |
| **CLI flag** | `--chainweb-version stoa` |

### Public nodes

| URL | Role |
|-----|------|
| `https://node1.stoachain.com` | Public HTTPS endpoint + protocol bootstrap (`node1.stoachain.com:1789`) |
| `https://node2.stoachain.com` | Public HTTPS endpoint + protocol bootstrap (`node2.stoachain.com:1789`) |

Liveness check:

```bash
curl -s https://node1.stoachain.com/info
# {"nodeVersion":"stoa","nodeNumberOfChains":10,"nodeBlockDelay":30000000,
#  "nodePackageVersion":"2.32.0", ...}
```

Bootstrap peers are declared in [`src/Chainweb/Version/Stoa.hs`](src/Chainweb/Version/Stoa.hs) under `_versionBootstraps`. Adding or removing a bootstrap requires a rebuild and redeploy on every node.

---

## Building From Source

Prerequisites:
- **GHC 9.10.1**
- **Cabal 3.14.1.1** (or newer)
- A Unix-like environment with standard build tooling (`pkg-config`, `libsodium`, `libgmp`, `libtool`, etc.)

Generate genesis payloads (if you have regenerated any genesis YAML or the coin source), then build:

```bash
cd cwtools && cabal run ea
cd ..      && cabal build chainweb-node
```

The resulting binary is located under `dist-newstyle/`. Use `cabal list-bin chainweb-node` to print its exact path.

Nix users can build via the project flake/nix expressions committed to the repo (see `nix/` and `flake.nix`), though Cabal is the first-class path.

---

## Running a Node

The repo ships a few convenience scripts used by the production deployment:

| File | Purpose |
|------|---------|
| [`deploy.sh`](deploy.sh) | Pulls / builds / installs the binary on a server |
| [`run-stoa.sh`](run-stoa.sh) | Wraps `chainweb-node --chainweb-version stoa` with the canonical config |
| [`stoa-node.service`](stoa-node.service) | systemd unit that invokes `run-stoa.sh` |

For the full launch procedure (config files, keyset setup, ports, TLS), see the checklist in the documentation repo: **[NODE_LAUNCH_CHECKLIST.md](https://github.com/StoaChain/StoaChain-Docs/blob/main/docs/chainweb-node/NODE_LAUNCH_CHECKLIST.md)**.

---

## Repository Layout

```
stoa-chain/
├── src/Chainweb/                 Haskell source for the node
│   ├── Version/Stoa.hs           Stoa network definition (version, bootstraps, genesis, gas limits)
│   ├── Version/Registry.hs       Version registration (registers `stoa`)
│   ├── Chainweb/Configuration.hs Default runtime configuration (block gas limit = 1.6M)
│   ├── Pact4/                    Pact 4 infrastructure (retained, not exercised by live chain)
│   └── Pact5/                    Pact 5.4 execution layer (live)
├── pact/
│   ├── stoa-coin/new-coin.pact   Coin module — defines STOA, URSTOA, UrStoaVault
│   └── genesis/stoa/             Genesis YAMLs for Chain 0 and Chains 1-9
├── rewards/miner_rewards.csv     Legacy upstream CSV (retained but ignored; emission is Pact-driven)
├── cwtools/                      `ea` tool for regenerating genesis payloads
├── test/                         Test suites (chainweb-tests, pact tests, etc.)
├── cabal.project                 Build project file, pins Pact 5.4 source-repository-package
├── deploy.sh / run-stoa.sh       Deployment scripts
├── stoa-node.service             systemd unit
└── assets/StoaLogo.png           Project logo
```

---

## Key Code Entry Points

If you are reading this code for the first time, the StoaChain-specific surface area is small and concentrated:

- [`src/Chainweb/Version/Stoa.hs`](src/Chainweb/Version/Stoa.hs) — `ChainwebVersion` definition: name, version code, graph, block delay, genesis payloads, genesis time, block-gas-limit cap, bootstrap peers, verifier plugin allow-list.
- [`src/Chainweb/Version/Registry.hs`](src/Chainweb/Version/Registry.hs) — registers `stoa` so it is selectable via `--chainweb-version stoa`.
- [`src/Chainweb/Chainweb/Configuration.hs`](src/Chainweb/Chainweb/Configuration.hs) — runtime defaults; note `_configBlockGasLimit = 1_600_000`.
- [`src/Chainweb/BlockHeader/Genesis/Stoa0Payload.hs`](src/Chainweb/BlockHeader/Genesis/Stoa0Payload.hs) and [`Stoa1to9Payload.hs`](src/Chainweb/BlockHeader/Genesis/Stoa1to9Payload.hs) — precompiled genesis payloads (regenerated by `cwtools/ea`).
- [`pact/stoa-coin/new-coin.pact`](pact/stoa-coin/new-coin.pact) — coin module source at genesis. **The live modules have diverged via post-genesis upgrades** — for authoritative live behavior, fetch `describe-module` from a node or inspect the explorer.
- [`pact/genesis/stoa/`](pact/genesis/stoa/) — genesis YAMLs for Chain 0 (the mint + module install) and Chains 1-9 (no-ops).

---

## Key Differences from Chainweb-Node

| Aspect | Kadena Chainweb | StoaChain |
|--------|-----------------|-----------|
| **Native Token** | KDA (`coin` module) | STOA (`stoa-ns.*` modules) |
| **Token Interface** | `fungible-v2` + `fungible-xchain-v1` | `stoa-ns.stoic-fungible-v1` + `stoa-ns.fungible-xchain-v1` |
| **TRANSFER Capability** | Managed (`@managed`) only | Dual: `C_Transfer` wraps the managed original; `C_Transmit` exposes the same transfer logic with a non-managed capability |
| **Main Namespace** | `kadena` | `stoa-ns` |
| **Pact Version (on-chain)** | Pact 4 → Pact 5 migration | Pact 5.4 stock (node retains Pact 4 infra internally) |
| **Emission Model** | CSV-based (`rewards/miner_rewards.csv`) | Computed inside Pact by `coin.URC_Emissions`; CSV retained but ignored |
| **Networks** | mainnet01, testnet04, development, recap-development | Single network: `stoa` |
| **Chain Count** | 20 chains (mainnet) | 10 chains (Petersen graph) |
| **Block Gas Limit** | 180k max / 150k default | **2M max / 1.6M default** (production nodes run at 2M) |
| **Gas Price Minimum** | Static (1e-8 KDA) | Static (inherited from upstream). Periodic ramp is planned, not shipped |

For the full picture — emission formula, UrStoaVault staking (RPS model), 90/10 Yang split, governance via 7 Stoa Masters keysets, pre-launch configuration checklist — see the documentation repo at **[StoaChain-Docs](https://github.com/StoaChain/StoaChain-Docs)**.

---

## Tests

The repository ships the full upstream `chainweb-tests` suite plus Pact-specific tests:

```bash
# Full test suite
cabal test chainweb-tests

# Pact 5 unit tests only
cabal test chainweb-tests --test-options='--pattern "Pact5"'

# Run a single test pattern
cabal test chainweb-tests --test-options='--pattern "<pattern>"'
```

Test sources live under `test/` — `test/unit/` for unit tests, `test/lib/` for shared fixtures, and the Pact 4 / Pact 5 test trees under `Chainweb.Test.Pact4.*` and `Chainweb.Test.Pact5.*`.

---

## Documentation

Deep-dive documentation lives in a separate repo:

- **StoaChain-Docs** — [`github.com/StoaChain/StoaChain-Docs`](https://github.com/StoaChain/StoaChain-Docs)
  - `docs/chainweb-node/EMISSION_SYSTEM.md` — Yang emission formula
  - `docs/chainweb-node/GAS_PRICE_SYSTEM.md` — Yin earnings and the planned gas-price ramp
  - `docs/chainweb-node/GENESIS_SYSTEM.md` — Genesis payload pipeline
  - `docs/chainweb-node/NODE_LAUNCH_CHECKLIST.md` — Pre-launch configuration
  - `docs/chainweb-node/PACT4_REMOVAL.md` — Retrospective on the abandoned Pact 4 extraction
  - `docs/pact-5/README.md` — Pact 5.4 overview as used on StoaChain
- **GitBook** — [`demiourgos-holdings-tm.gitbook.io/kadena-evolution`](https://demiourgos-holdings-tm.gitbook.io/kadena-evolution)
- **Explorer** — [`explorer.stoachain.com`](https://explorer.stoachain.com) / [`apiexplorer.stoachain.com`](https://apiexplorer.stoachain.com)

---

## License

StoaChain is released under the **MIT License**. See [LICENSE](LICENSE).

This project is a software fork of [Kadena Chainweb](https://github.com/kadena-io/chainweb-node), which is also MIT licensed.

---

## Acknowledgments

- **Kadena Team** — for creating the Chainweb protocol and the Pact language.
- **StoaChain Contributors** — for adapting, extending, and operating the codebase.

---

## Development Method

The extensive modifications to the Chainweb codebase — transforming it into StoaChain — were accomplished through a proprietary time dilation methodology. The StoaChain Admin, having cultivated mastery over spiritual energies — tapping into the primordial creational force that underlies existence — employed temporal manipulation capabilities to accelerate the development process.

Within a carefully constructed time dilation field, the ratio of 1 minute of external time to approximately 3 hours of internal time allowed what would normally require months of effort (learning Haskell, mastering its intricacies, understanding the complex Chainweb infrastructure) to be completed in mere hours of real-world time.

The Admin secluded himself within this temporal bubble with a laptop and a fuel-powered generator (operating at an accelerated rate to match the dilated timeframe), enabling the comprehensive overhaul of the codebase while the outside world experienced only a fraction of the elapsed duration.

---

*StoaChain — Building the future of decentralized computing.*
