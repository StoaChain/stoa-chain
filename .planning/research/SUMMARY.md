# Project Research Summary

**Project:** Stoa Chain - Kadena Chainweb Fork Modification
**Domain:** Blockchain infrastructure modification (Haskell/Proof-of-Work)
**Researched:** 2026-02-10
**Confidence:** HIGH

## Executive Summary

Stoa Chain is a fork of Kadena's Chainweb Node (v2.32.0) that modifies three core aspects: chain topology (20 to 10 chains), genesis coin contract (Kadena coin to STOA coin with staking vault), and gas limits (150k default / 180k max to 400k default / 500k max). Research reveals this is a well-trodden path - Kadena itself started with 10 chains using the Petersen graph before transitioning to 20 chains. The codebase already contains all necessary infrastructure for 10-chain operation, making this a parameter configuration project rather than an architectural rewrite.

The recommended approach is conservative: create a new ChainwebVersion definition that references the existing Petersen graph, write genesis payloads using the existing Ea tool, and update gas configuration through version-level settings. The Haskell codebase uses height-indexed rules and per-chain configuration maps that cleanly support multiple network versions. The critical path item is verifying the STOA coin contract - the Haskell runtime hardcodes module name "coin" in 8+ locations for gas buying, coinbase, and capabilities. If the contract's module name, function signatures, or capability names differ from expectations, the chain will halt.

Key risks are concentrated in the coin contract verification (unverified as of this research) and genesis payload generation pipeline. The Ea tool is a compile-time code generator that produces Haskell source files with hash verification - any change to genesis transactions requires regeneration and recompilation. All other changes are parameter adjustments with well-established patterns in the existing Development and Testnet versions.

## Key Findings

### Recommended Stack

From STACK.md, the existing Chainweb codebase provides all necessary infrastructure. No external dependencies need to be added.

**Core technologies (already in use):**
- **Petersen graph (KnownGraph)**: 10-node, degree-3, diameter-2 graph already defined and validated - exact fit for Stoa's 10 chains
- **Ea tool (cwtools)**: Genesis payload generator that compiles Pact transactions into Haskell modules with hash verification - used to create Stoa genesis
- **Rule type**: Height-indexed configuration system for gas limits, chain graphs, and fork activations - enables clean version management
- **ChainMap type**: Per-chain or all-chain value specification - handles asymmetric genesis (chain 0 vs chains 1-9)

**Critical version requirements:**
- GHC 9.10 or 9.8 (Haskell compiler)
- Cabal 3.4+ (build system)
- Module name "coin" is hardcoded in Pact4/Pact5 transaction execution - cannot be changed without modifying 8+ locations

### Expected Features

From FEATURES.md, the project has clear table stakes and one critical single-point-of-failure.

**Must have (table stakes - node will not start without these):**
- Stoa version definition with unique ChainwebVersionCode and ChainwebVersionName
- Petersen graph selection (simple: `_versionGraphs = Bottom (minBound, petersenChainGraph)`)
- Genesis payloads for all 10 chains (chain 0 differentiated with UR-STOA vault)
- STOA coin contract implementing fungible-v2, fungible-xchain-v1, gas-payer-v1 interfaces
- All forks set to ForkAtGenesis (fresh chain, no historical upgrades)
- Gas limits set at both version level (500k max) and configuration level (400k default)
- Miner rewards CSV with STOA tokenomics (16M genesis, declining emissions)
- Version registration in Registry.hs knownVersions

**Should have (differentiators - what makes this Stoa, not Kadena):**
- UR-STOA staking vault on chain 0 (initialized via A_InitialiseStoaChain in genesis)
- 7 Stoa Master keysets (replaces Kadena's governance structure)
- Bundled interfaces in coin contract (single Pact file instead of 5 separate files)
- 2.7x larger blocks (400k/500k vs 150k/180k gas) - auto-scales mempool and transaction timeouts

**Defer (v2+ or launch-time):**
- Bootstrap nodes (can use empty list + _disablePeerValidation = True during development)
- Production difficulty tuning (use maxBound div 100_000 for initial testing)
- Custom block delay/window (keep Kadena's 30s / 120 defaults unless testing shows need)

### Architecture Approach

From ARCHITECTURE.md, the version system is the integration hub. All blockchain behavior flows through the ChainwebVersion record.

**Major components:**

1. **ChainwebVersion definition** - Central configuration authority with 16 required fields including chain graph, genesis payloads, fork heights, gas limits, bootstrap peers, PoW parameters. Uses lazy lenses for self-referential construction. Validated on registration with strict checks (all forks defined, all chains covered, payload hashes match).

2. **Ea tool (genesis pipeline)** - Build-time code generator: reads Pact YAML + .pact files → executes via PactService → generates Haskell source modules with hardcoded PayloadWithOutputs + hash verification. Transaction ordering is position-sensitive: coinContract → namespaces → keysets → allocations → coinbase. Chain 0 and chains 1-9 need separate Genesis records due to different payloads.

3. **Gas limit composition** - Three-layer control: (a) _versionMaxBlockGasLimit in version (consensus-enforced cap), (b) _configBlockGasLimit in configuration (operator preference, default 150k), (c) Startup clamping: `min(config, versionMax)`. Effective limit flows to PactService, mempool validation, and block execution.

4. **Graph/Cut system** - Chain graph defines topology (order, degree, diameter). BlockHeaders store adjacent chain hashes. Cuts are cross-chain consistent states validated by adjacency checks. Petersen graph (10 chains, degree 3, diameter 2) produces shorter SPV proofs than Twenty graph (20 chains, degree 3, diameter 3).

5. **Miner rewards** - CSV embedded at compile time via Template Haskell with SHA512 hash verification. Total network reward divided by chain count. With 10 chains instead of 20, per-block reward doubles from same table - STOA needs custom CSV.

**Key architectural constraints:**
- Genesis payloads are compile-time constants (hardcoded Haskell source)
- Version codes must be globally unique (Word32, used in protocol)
- Fork heights must cover all chains (validateVersion enforces)
- Module name "coin" is hardcoded in Pact runtime
- Gas limits have two independent controls that must be coordinated

### Critical Pitfalls

From PITFALLS.md, 16 pitfalls identified. Top 5 by severity and blocking impact:

1. **Unverified STOA contract (P15 - Critical)** - The coin contract is the single point of failure. Every block depends on it for gas buying (fund-tx defpact), coinbase rewards (coin.coinbase), and transfers. The Haskell runtime hardcodes calls to coin.COINBASE, coin.GENESIS, coin.GAS capabilities. If any function/capability is missing, renamed, or has wrong signature, the chain halts. PREVENTION: Verify contract in Pact REPL before any integration work. Test module deployment, coinbase, fund-tx defpact, transfer, create-account, table creation, governance keysets.

2. **Hardcoded "coin" module name (P1 - Critical)** - ModuleName "coin" Nothing is hardcoded in 8+ locations across Pact4/Pact5 execution engines for gas buying, coinbase minting, module admin, and capabilities. If STOA contract uses any other module name, every block fails. PREVENTION: Keep module name as "coin" in Pact contract. This is a design constraint, not negotiable without modifying runtime.

3. **Genesis payload hash immutability (P4 - Critical)** - Genesis payloads are Haskell source files with compile-time hash verification. Any contract change invalidates the hash. The Ea tool only generates Pact4 transactions - if STOA needs Pact5 features, tool must be modified. Genesis gas limit is testBlockGasLimit (100k for Pact4 path, 999M for Pact5 path). PREVENTION: Finalize contract before running Ea. Always regenerate after changes. Never manually edit *Payload.hs files.

4. **ChainMap AllChains vs OnChains mismatch (P3 - Critical)** - validateVersion checks that OnChains maps contain exactly the chains in the graph. If any OnChains contains chain IDs 10-19 (from copy-pasting Mainnet code) or is missing any chain 0-9, node crashes at startup with "version does not have heights for all forks". PREVENTION: Prefer AllChains everywhere possible. When using OnChains (e.g., different genesis payloads), enumerate exactly chains 0-9. Run registerVersion as first integration test.

5. **Gas limit three control points (P6 - High)** - Block gas limit controlled by: (a) _versionMaxBlockGasLimit in version (hard cap), (b) _configBlockGasLimit in configuration (default 150k), (c) startup clamping: min(config, versionMax). If config = 400k but versionMax = 180k, actual limit silently clamped to 180k. PREVENTION: Set _versionMaxBlockGasLimit to Just 500_000 in version. Set _configBlockGasLimit to 400_000 in configuration. Verify config <= versionMax.

**Other notable pitfalls:**
- Petersen graph has degree 3 (same as Twenty) so header size (208 + 36*3 + 2 = 318 bytes) stays same - no change to _versionHeaderBaseSizeBytes needed
- Miner reward doubles per-block (same CSV divided by 10 chains instead of 20) - need STOA-specific CSV
- All forks must be ForkAtGenesis with _versionUpgrades = AllChains mempty (no upgrade transactions for fresh chain)
- Chain 0 asymmetric state (UR-STOA vault) requires separate Genesis record - use onChains pattern from Mainnet
- SPV proofs are shorter with Petersen (diameter 2 vs 3) but test vectors may reference chains 10-19

## Implications for Roadmap

Based on research, dependencies dictate this phase structure:

### Phase 1: Contract Verification and Genesis Definition
**Rationale:** The STOA coin contract is the critical path. Every other change waits on this. Contract verification cannot happen in parallel with other work because the contract defines what goes into genesis, which determines payload hashes, which are hardcoded into the version definition.

**Delivers:**
- STOA coin contract verified working in Pact REPL
- Contract implements fungible-v2, fungible-xchain-v1, gas-payer-v1 interfaces
- Module name confirmed as "coin"
- All required capabilities defined (COINBASE, GENESIS, GAS, GOVERNANCE)
- fund-tx defpact implemented correctly
- Gas consumption measured (must fit in genesis block budget)
- Tables verified (LocalSupply, StoaTable, UrStoaVault)

**Addresses:**
- P15 (unverified contract) - verification is the core deliverable
- P1 (hardcoded coin name) - confirmed in contract design
- P5 (bundled interfaces gas budget) - measured in REPL

**Avoids:**
- Building infrastructure before knowing if contract works
- Late discovery of contract incompatibility with Haskell runtime
- Genesis generation failures due to gas limits or missing functions

**Research needed:** None - pure Pact contract development and testing

### Phase 2: Version Definition and Foundation
**Rationale:** Once contract is verified, create the version definition. This is pure data configuration with well-established patterns from Development version. Must be complete before genesis payload generation because Ea tool needs the version to exist.

**Delivers:**
- src/Chainweb/Version/Stoa.hs created with all 16 required fields
- Unique ChainwebVersionCode (e.g., 0x00000010)
- ChainwebVersionName "stoa"
- _versionGraphs = Bottom (minBound, petersenChainGraph)
- _versionForks = tabulateHashMap (\_ -> AllChains ForkAtGenesis)
- _versionUpgrades = AllChains mempty
- _versionMaxBlockGasLimit = Bottom (minBound, Just 500_000)
- _configBlockGasLimit default changed to 400_000 in Configuration.hs
- Genesis placeholders (updated in Phase 3)
- Version registered in Registry.hs knownVersions

**Uses:**
- Petersen graph (already defined in Graph.hs)
- Rule type for height-indexed config
- ChainMap type for per-chain values

**Implements:**
- Version management component (central configuration authority)

**Avoids:**
- P3 (ChainMap mismatch) - use AllChains pattern, enumerate chains 0-9 in OnChains
- P6 (gas limit three control points) - set both version and config
- P9 (fork heights) - all ForkAtGenesis with empty upgrades
- P11 (version registration) - unique code and name, added to knownVersions

**Research needed:** None - follow Development version pattern exactly

### Phase 3: Genesis Payload Generation
**Rationale:** With contract verified and version defined, generate genesis payloads. This is the Ea tool workflow: YAML → Pact execution → Haskell source generation. Chain 0 needs differentiated genesis (UR-STOA vault), chains 1-9 share standard genesis.

**Delivers:**
- pact/stoa-coin/stoa-coin.pact (bundled contract or separate files)
- pact/stoa-coin/load-stoa-coin.yaml (YAML loader)
- pact/genesis/stoa/keysets.yaml (7 Stoa Master keysets)
- pact/genesis/stoa/grants0.yaml (chain 0: A_InitialiseStoaChain call)
- pact/genesis/stoa/grantsN.yaml (chains 1-9: standard grants)
- pact/genesis/ns-v2.yaml (namespaces - reuse or customize)
- cwtools/ea/Ea/Genesis.hs updated (stoaChain0, stoaChainN records)
- cwtools/ea/Ea.hs updated (stoa = mkPayloads [...])
- Run: cabal run cwtools -- ea
- Generated: src/Chainweb/BlockHeader/Genesis/Stoa0Payload.hs
- Generated: src/Chainweb/BlockHeader/Genesis/Stoa1to9Payload.hs
- Version definition updated to import and reference payload modules

**Addresses:**
- P4 (genesis payload hash) - Ea tool generates with hash verification
- P14 (chain 0 asymmetric state) - separate Genesis records for chain 0 vs 1-9
- P13 (Ea tool Pact4-only) - contract uses Pact4-compatible syntax

**Avoids:**
- Manual payload construction (error-prone, no hash verification)
- Genesis transaction ordering errors (Ea tool enforces correct order)
- ChainMap validation failures (Genesis records define correct chain ranges)

**Research needed:** None - Ea tool usage follows established pattern

### Phase 4: Tokenomics Integration
**Rationale:** Generate STOA-specific miner rewards CSV and update hash constants. This is independent of genesis (rewards start after block 0) but needed before compilation.

**Delivers:**
- rewards/miner_rewards.csv replaced with STOA emission schedule
- Format: (BlockHeight, Decimal) pairs for 3-month periods
- Total network reward (divided by 10 chains at runtime)
- 16M genesis supply, declining emissions modeled
- expectedRawMinerRewardsHash updated (SHA512 of raw CSV)
- expectedMinerRewardsHash updated (SHA512 of parsed table)
- Unit tests verifying rewards at genesis, year 1, year 10, final entry

**Addresses:**
- P7 (miner reward table hash check) - regenerate hashes after CSV replacement
- P2 (reward doubling with 10 chains) - STOA CSV accounts for 10-chain division

**Avoids:**
- Compile failures from hash mismatch
- Unexpected reward amounts (2x if using Kadena CSV)
- Reward calculation failures beyond table's last entry

**Research needed:** None - CSV format and hash generation are straightforward

### Phase 5: Integration and Validation
**Rationale:** All pieces exist. Build, test registration, boot a node, mine blocks, validate cross-chain operations.

**Delivers:**
- cabal build chainweb-node succeeds
- Version validation passes (registerVersion succeeds)
- Node boots from genesis (all 10 chains)
- Block 1 mined successfully (coinbase works)
- Transaction submission accepted (gas buying works)
- Cross-chain SPV proof between chains 0-9 validated
- Test suite updated for 10-chain topology
- Bootstrap configuration (empty for dev, real for production)

**Addresses:**
- P8 (SPV proofs with Petersen graph) - validate cross-chain transfers
- P10 (-Wall -Werror false confidence) - comprehensive testing beyond compilation
- P12 (header base size) - verify serialization roundtrips
- P16 (bootstrap nodes) - configure for network type

**Avoids:**
- Silent failures (wrong values that compile but break at runtime)
- Cross-chain topology bugs (test all chain pairs)
- Peer networking issues (configure bootstrap correctly)

**Research needed:** Standard integration testing - no new patterns

### Phase Ordering Rationale

- **Contract first (Phase 1)** because it defines genesis content, which determines payload hashes, which are compiled into version definition. No parallelization possible.
- **Version second (Phase 2)** because Ea tool needs version to exist, and version needs contract verified. Genesis placeholders allow version to compile before payloads exist.
- **Genesis third (Phase 3)** because it depends on both contract and version. Ea tool execution requires both inputs.
- **Tokenomics independent (Phase 4)** but needed before compilation. Can happen in parallel with Phase 3 if needed, but cleaner sequentially.
- **Integration last (Phase 5)** because it needs all pieces. Cannot validate what doesn't exist.

**Dependency chain:**
```
Contract verification → Version definition → Genesis generation → Compilation → Integration
                              ↓
                        Tokenomics (rewards CSV) → Compilation
```

### Research Flags

**Phases with well-documented patterns (skip research-phase):**
- **Phase 2 (Version definition):** Development version is perfect template, all patterns established
- **Phase 3 (Genesis generation):** Ea tool usage documented in codebase, Mainnet genesis as reference
- **Phase 4 (Tokenomics):** CSV format and hash generation are straightforward file operations
- **Phase 5 (Integration):** Standard testing, existing test infrastructure

**Phases needing deeper research (none for this project):**
The codebase is the primary source - all patterns are established and working examples exist. No external API research or niche domain investigation needed.

**Validation checkpoints:**
- After Phase 1: Contract works in Pact REPL with gas metering
- After Phase 2: Version validates without errors (registerVersion succeeds)
- After Phase 3: Genesis payload hashes match, compilation succeeds
- After Phase 4: Reward calculations produce expected values
- After Phase 5: Node mines blocks, transactions validate, cross-chain transfers work

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Direct codebase analysis. All infrastructure exists. Petersen graph already defined and validated. Ea tool working and documented. |
| Features | HIGH | Table stakes derived from validateVersion requirements. Differentiators clearly marked in contract spec. Anti-features identified by hardcoded runtime references. |
| Architecture | HIGH | ChainwebVersion structure well-documented. Genesis pipeline traced through Ea tool. Gas limit flow mapped across 6 files. All patterns have working examples in existing versions. |
| Pitfalls | HIGH | 16 pitfalls identified through codebase analysis. Hardcoded module name found in 8+ locations. Hash verification logic traced. Genesis generation constraints documented. |

**Overall confidence:** HIGH

Research is based on direct codebase analysis of Stoa Chain (Chainweb v2.32.0 fork). All findings verified against actual source files. No speculation or inference from external sources. The critical unknowns (STOA contract verification, gas consumption, UR-STOA vault design) are flagged explicitly as Phase 1 validation requirements.

### Gaps to Address

**Contract verification (critical gap):** STOA coin contract has not been verified working. This is the highest-risk item and must be Phase 1 deliverable. No other work should proceed until contract is verified in Pact REPL with all required interfaces, capabilities, and functions tested.

**Genesis gas budget (medium gap):** Bundled interfaces approach may exceed genesis block gas limit. Testing in Pact REPL with gas metering will reveal if contract needs to be split into multiple transactions. If bundled file too large, fallback to multi-file approach like Kadena (fungible-v2.pact, coin.pact, gas-payer.pact as separate files).

**UR-STOA vault design (medium gap):** Chain 0 initialization (A_InitialiseStoaChain) design not fully specified. Need to confirm: (a) vault lives only on chain 0, (b) cross-chain operations don't reference vault tables, (c) initialization fits in genesis transaction gas budget, (d) 7 Stoa Master keysets defined before module that references them.

**Pact4 vs Pact5 genesis (low gap):** Ea tool generates Pact4 transactions but Pact5Fork is ForkAtGenesis. The execNewGenesisBlock function has both paths - Pact5 path accepts Pact4 transactions and converts them. As long as contract uses Pact4-compatible syntax, this works. If Pact5-only features needed, Ea tool requires modification.

**Bootstrap infrastructure (low gap):** Production bootstrap nodes need DNS, TLS certificates, and PeerInfo configuration. This is a launch-time concern, not a development blocker. Can proceed with empty bootstrap list and _disablePeerValidation = True.

## Sources

### Primary (HIGH confidence - direct codebase analysis)
- src/Chainweb/Graph.hs - Petersen graph definition, KnownGraph enum, ChainGraph type
- src/Chainweb/Version.hs - ChainwebVersion record, Fork enum, Rule type, ChainMap type
- src/Chainweb/Version/Development.hs - Template for new version with all forks at genesis
- src/Chainweb/Version/Mainnet.hs - Reference for 10-to-20 chain transition pattern
- src/Chainweb/Version/Registry.hs - validateVersion requirements, knownVersions registration
- src/Chainweb/Chainweb/Configuration.hs - Gas limit defaults, configuration structure
- src/Chainweb/Version/Guards.hs - maxBlockGasLimit, fork guard functions
- src/Chainweb/Pact4/TransactionExec.hs - Hardcoded "coin" module references, fund-tx, magic capabilities
- src/Chainweb/Pact5/TransactionExec.hs - Coinbase, genesis, gas capabilities, module admin
- src/Chainweb/BlockHeader/Internal.hs - Header serialization, size calculation, adjacency hashes
- src/Chainweb/MinerReward.hs - Reward CSV embedding, hash verification, per-chain division
- cwtools/ea/Ea.hs - Genesis payload generator, mkPayload function, Pact service invocation
- cwtools/ea/Ea/Genesis.hs - Genesis record structure, transaction ordering
- src/Chainweb/SPV/CreateProof.hs - SPV proof generation, graph traversal
- src/Chainweb/Chainweb.hs - Gas limit composition, startup clamping logic

### Secondary (not needed - project uses codebase as ground truth)
No external sources required. All patterns and constraints derived from existing code.

---
*Research completed: 2026-02-10*
*Ready for roadmap: yes*
