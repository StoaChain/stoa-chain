# Roadmap: Stoa Chain

## Overview

Stoa Chain transforms the existing Kadena Chainweb Node (v2.32.0) into a new blockchain with STOA tokenomics, 10 parallel chains, and increased gas capacity. The work follows a strict dependency chain: the coin contract must be verified first (it defines genesis content), then the version definition and gas limits are configured, then genesis payloads are generated using the Ea tool, then the custom rewards CSV is created, and finally everything is integrated and validated end-to-end. Every phase modifies existing code -- no new modules or architectural patterns.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Contract Verification** - Verify STOA coin contract works correctly in Pact REPL before any integration
- [x] **Phase 2: Version Definition and Gas Limits** - Create Stoa version with 10-chain Petersen graph and updated gas configuration
- [ ] **Phase 3: Genesis Payload Generation** - Generate genesis payloads for chain 0 (full init) and chains 1-9 (coin only) via Ea tool
- [ ] **Phase 4: Tokenomics** - Create STOA miner rewards CSV with declining emissions and update hash constants
- [ ] **Phase 5: Integration and Validation** - Build, boot, mine, and validate cross-chain operations on all 10 chains

## Phase Details

### Phase 1: Contract Verification
**Goal**: The STOA coin contract is proven correct and compatible with the Haskell runtime before any codebase modifications begin
**Depends on**: Nothing (first phase)
**Requirements**: CONT-01, CONT-02, CONT-03, CONT-04, CONT-05, CONT-06
**Success Criteria** (what must be TRUE):
  1. STOA coin contract loads in Pact REPL and all interfaces (fungible-v2, fungible-xchain-v1, gas-payer-v1, StoaFungibleV1) deploy in a single transaction without errors
  2. The contract module is named "coin" and exposes COINBASE, GENESIS, GAS, and GOVERNANCE capabilities with signatures matching Haskell runtime expectations
  3. The fund-tx defpact (buy-gas step 0, redeem-gas step 1) executes successfully in REPL with correct gas accounting
  4. The coinbase function computes correct STOA emission amounts using the declining formula for representative block heights
  5. Cross-chain transfer defpact (transfer-crosschain) completes a full transfer-crosschain / transfer-crosschain-receive cycle in REPL
**Plans**: 2 plans

Plans:
- [x] 01-01-PLAN.md — Install Pact REPL and deploy STOA contract with bundled interfaces (CONT-01, CONT-02, CONT-03)
- [x] 01-02-PLAN.md — Verify runtime touchpoints: coinbase, fund-tx, cross-chain transfers (CONT-04, CONT-05, CONT-06)

### Phase 2: Version Definition and Gas Limits
**Goal**: A complete Stoa version definition exists in the codebase with 10-chain Petersen graph topology, all forks at genesis, and gas limits configured at both version and configuration levels
**Depends on**: Phase 1
**Requirements**: VERS-01, VERS-02, VERS-03, VERS-04, VERS-05, VERS-06, GAS-01, GAS-02, GAS-03
**Success Criteria** (what must be TRUE):
  1. A Stoa version definition with unique ChainwebVersionCode exists, uses petersenChainGraph (10 chains, degree 3, diameter 2), and all ChainMap entries reference only chains 0-9
  2. All 37 Fork constructors have entries in _versionForks set to ForkAtGenesis, and validateVersion passes without errors when version is registered
  3. The version is registered in Registry.hs knownVersions and is selectable via node CLI arguments
  4. _versionMaxBlockGasLimit is set to 500,000 and _configBlockGasLimit defaults to 400,000, and startup clamping logic correctly applies min(config, versionMax)
**Plans**: 2 plans

Plans:
- [x] 02-01-PLAN.md — Create Stoa version definition module with Petersen graph, all forks at genesis, and 500k gas limit (VERS-01, VERS-02, VERS-03, VERS-04, GAS-01)
- [x] 02-02-PLAN.md — Wire Stoa into Registry, Configuration, and cabal; set 400k gas default; verify compilation (VERS-05, VERS-06, GAS-02, GAS-03)

### Phase 3: Genesis Payload Generation
**Goal**: Genesis payloads are generated via the Ea tool for all 10 chains, with chain 0 containing the full STOA + UR-STOA + vault initialization and chains 1-9 containing coin module deployment only
**Depends on**: Phase 1, Phase 2
**Requirements**: GENS-01, GENS-02, GENS-03, GENS-04, GENS-05, GENS-06, GENS-07
**Success Criteria** (what must be TRUE):
  1. Genesis YAML and Pact files exist for chain 0 (coin module + 7 Stoa Master keysets + A_InitialiseStoaChain call) and chains 1-9 (coin module deployment only)
  2. The Ea tool successfully generates Haskell genesis payload modules with hash-verified data, and the project compiles with these modules included
  3. Chain 0 genesis includes UR-STOA token (1M supply) minted, UrStoa Vault initialized with foundation account, and 16M STOA genesis supply minted to foundation account
  4. The bundled interfaces plus coin module fit within the genesis block gas budget (verified by Ea tool execution without gas exhaustion)
**Plans**: 2 plans

Plans:
- [ ] 03-01-PLAN.md — Create genesis YAML files and Ea tool Genesis records for Stoa (GENS-01, GENS-02)
- [ ] 03-02-PLAN.md — Run Ea tool, wire generated payloads into Stoa version, verify build (GENS-03, GENS-04, GENS-05, GENS-06, GENS-07)

### Phase 4: Tokenomics
**Goal**: STOA-specific miner rewards are defined with a declining emission schedule that correctly divides by 10 chains, and the 90/10 miner/vault split operates correctly
**Depends on**: Phase 1 (emission formula from contract), Phase 2 (chain count)
**Requirements**: TOKN-01, TOKN-02, TOKN-03, TOKN-04, TOKN-05
**Success Criteria** (what must be TRUE):
  1. A STOA miner rewards CSV exists with declining emission schedule entries, and SHA512 hash constants (raw and parsed) are updated to match the new CSV
  2. Reward calculation at runtime correctly divides by 10-chain count (not 20), producing expected per-block rewards at genesis, year 1, and year 10
  3. The 90/10 miner/vault emission split is implemented such that 10% of each block's coinbase emission is directed to the UR-STOA vault on chain 0
**Plans**: TBD

Plans:
- [ ] 04-01: TBD

### Phase 5: Integration and Validation
**Goal**: The complete Stoa node compiles, boots from genesis, mines blocks on all 10 chains, and validates cross-chain operations end-to-end
**Depends on**: Phase 2, Phase 3, Phase 4
**Requirements**: INTG-01, INTG-02, INTG-03, INTG-04, INTG-05
**Success Criteria** (what must be TRUE):
  1. The project compiles with -Wall -Werror -Wcompat producing zero warnings across all packages (chainweb, chainweb-node, cwtools, chainweb-storage)
  2. A Stoa node boots from genesis, initializes all 10 chains, and begins producing blocks (block height advances beyond 0 on all chains)
  3. Cross-chain SPV proofs are generated and verified between chains 0-9 (at least one cross-chain transfer completes successfully)
  4. Gas buying (fund-tx defpact) and redemption works for submitted transactions, confirming Pact runtime integration with the STOA coin contract
**Plans**: TBD

Plans:
- [ ] 05-01: TBD
- [ ] 05-02: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 -> 2 -> 3 -> 4 -> 5
(Phases 3 and 4 depend on Phase 2 but are independent of each other; however, both must complete before Phase 5.)

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Contract Verification | 2/2 | COMPLETE | 2026-02-10 |
| 2. Version Definition and Gas Limits | 2/2 | COMPLETE | 2026-02-11 |
| 3. Genesis Payload Generation | 0/2 | Not started | - |
| 4. Tokenomics | 0/1 | Not started | - |
| 5. Integration and Validation | 0/2 | Not started | - |
