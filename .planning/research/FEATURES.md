# Feature Landscape

**Domain:** Chainweb blockchain fork -- modifying chain graph, coin contract, gas limits, and genesis for an independent network
**Researched:** 2026-02-10
**Overall Confidence:** HIGH (based on direct codebase analysis)

## Table Stakes

Features that must work correctly or the node will not start, will not mine, or will not validate blocks. Missing any of these means a non-functional chain.

### 1. Stoa Version Definition

| Aspect | Detail |
|--------|--------|
| Why Expected | Every chain operation resolves behavior through `ChainwebVersion`. Without a valid version, the node cannot start. |
| Complexity | Medium |
| Files | New `src/Chainweb/Version/Stoa.hs`, modify `src/Chainweb/Version/Registry.hs` |
| Notes | Must define: `_versionCode` (unique `Word32`), `_versionName` (`"stoa"`), `_versionGraphs` (Petersen only), `_versionForks` (all `ForkAtGenesis` -- start with all forks active), `_versionBlockDelay`, `_versionWindow`, `_versionMaxBlockGasLimit`, `_versionGenesis`, `_versionBootstraps`, `_versionCheats`, `_versionDefaults`, `_versionUpgrades` (empty -- fresh chain), `_versionQuirks` (`noQuirks`), `_versionVerifierPluginNames`, `_versionForkNumber`. Registry must include Stoa in `knownVersions` and initialize it in `versionMap`. |

### 2. Chain Graph: 20 to 10 Chains (Petersen Graph)

| Aspect | Detail |
|--------|--------|
| Why Expected | The Petersen graph is already a `KnownGraph` (`Petersen`, degree 3, diameter 2, order 10). Using it as the sole graph eliminates the 10-to-20 chain transition that mainnet had. Without correct graph definition, block headers cannot compute adjacent hashes and cuts cannot be formed. |
| Complexity | Low |
| Files | `src/Chainweb/Version/Stoa.hs` (version definition) |
| Notes | Set `_versionGraphs = Bottom (minBound, petersenChainGraph)` -- single graph, no transitions. Chain IDs will be 0-9. All `ChainMap` entries in genesis, forks, and upgrades must cover exactly chains 0-9. The graph is already validated by `validChainGraph` (symmetric, regular, irreflexive). No changes needed to `Chainweb.Graph` itself. |

### 3. Genesis Block Payloads (10 Chains)

| Aspect | Detail |
|--------|--------|
| Why Expected | Every chain must have a genesis payload defined in `_genesisBlockPayload`. Without it, `validateVersion` in the Registry fails and the node cannot start. Genesis payloads contain the initial Pact state (coin contract, keysets, namespaces, allocations). |
| Complexity | High |
| Files | New YAML files in `pact/genesis/stoa/`, new Genesis entries in `cwtools/ea/Ea/Genesis.hs` and `cwtools/ea/Ea.hs`, auto-generated `src/Chainweb/BlockHeader/Genesis/Stoa*Payload.hs` modules |
| Notes | Chain 0 gets differentiated genesis (A_InitialiseStoaChain with UR-STOA vault setup). Chains 1-9 get standard genesis (coin module, keysets, namespaces). Must run the `ea` tool (`cwtools/ea/Ea.hs`) to generate the payload Haskell modules. The `Genesis` record requires: version, tag, chain ID range, coinbase YAML, keysets YAML, allocations YAML, namespaces YAML, coin contract files. |

### 4. STOA Coin Contract Replacement

| Aspect | Detail |
|--------|--------|
| Why Expected | The coin contract is the fundamental token of the chain. Coinbase rewards, gas payments (`fund-tx`/`redeem-gas`), and all transfers depend on it. The Pact runtime hardcodes references to `ModuleName "coin" Nothing` in capabilities like `COINBASE`, `GENESIS`, `GAS`, `REMEDIATE` (see `Pact5/TransactionExec.hs:586-707` and `Pact4/TransactionExec.hs:274-278`). If the STOA coin contract does not implement these exact interfaces, the node cannot produce blocks. |
| Complexity | High |
| Files | New `pact/coin-contract/stoa/coin.pact` (or replace existing `pact/coin-contract/coin.pact`), associated YAML loading files, referenced from genesis definitions |
| Notes | The STOA coin contract MUST: (a) implement `fungible-v2` and `fungible-xchain-v1` interfaces, (b) define `GOVERNANCE`, `GAS`, `COINBASE`, `GENESIS` capabilities with exact names, (c) implement `fund-tx` as a defpact (used by gas buying in Pact4), (d) implement `coinbase` function called during block creation, (e) implement `redeem-gas` for gas redemption, (f) maintain the `coin-table` schema with `balance:decimal` and `guard:guard`. The module name MUST remain `"coin"` because the Haskell code hardcodes `ModuleName "coin" Nothing`. |

### 5. Gas Limit Changes (Default 400K, Max 500K)

| Aspect | Detail |
|--------|--------|
| Why Expected | Gas limits control block capacity. The default block gas limit (`_configBlockGasLimit`) is set to `150_000` in `defaultChainwebConfiguration`. The version-level max (`_versionMaxBlockGasLimit`) is `180_000` for mainnet. Without changing both, STOA blocks will be constrained to Kadena's limits. |
| Complexity | Low |
| Files | `src/Chainweb/Version/Stoa.hs` (for `_versionMaxBlockGasLimit`), `src/Chainweb/Chainweb/Configuration.hs` (for `_configBlockGasLimit` default) |
| Notes | Two separate mechanisms: (1) `_versionMaxBlockGasLimit` in the version definition -- a `Rule BlockHeight (Maybe Natural)` that caps what any node can set. Set to `Just 500_000` from genesis. (2) `_configBlockGasLimit` in configuration -- the default value miners use. Change from `150_000` to `400_000`. The code in `Chainweb.hs:402-442` already handles the case where config > version max by clamping to max. The mempool validation uses `_configBlockGasLimit`, while block validation uses `maxBlockGasLimit` from the version. Both must be updated. |

### 6. Miner Rewards Table

| Aspect | Detail |
|--------|--------|
| Why Expected | `blockMinerReward` divides the global reward from `miner_rewards.csv` by the chain count (`order $ chainGraphAt v h`). With 10 chains instead of 20, each block gets 2x the per-block reward from the same table. If STOA wants different tokenomics (16M genesis supply, declining emissions), the rewards CSV must be replaced and its SHA512 hashes updated. Without matching hashes, the node crashes at startup due to `mkMinerRewards` hash verification. |
| Complexity | Medium |
| Files | `rewards/miner_rewards.csv`, `src/Chainweb/MinerReward.hs` (hash constants `expectedMinerRewardsHash` and `expectedRawMinerRewardsHash`) |
| Notes | The rewards table is embedded at compile time via Template Haskell (`embedFile`). Format is CSV: `(BlockHeight, Decimal)` pairs representing total network reward at each 3-month period. With 10 chains, each block gets `totalReward / 10`. Must recalculate the entire table based on STOA's emission schedule. The hash verification is a critical safety check -- both `expectedMinerRewardsHash` (computed from parsed table) and `expectedRawMinerRewardsHash` (raw file hash) must be updated. |

### 7. Fork Heights: All at Genesis

| Aspect | Detail |
|--------|--------|
| Why Expected | Kadena's mainnet has 31 forks at various block heights spanning 2019-2025. A fresh network must enable all forks at genesis (`ForkAtGenesis`) so modern Pact5 behavior is available from block 0. If any fork is set to a non-zero height, the chain will start with legacy behavior and need to replay Kadena's historical upgrade path, which is nonsensical for a new network. |
| Complexity | Low |
| Files | `src/Chainweb/Version/Stoa.hs` |
| Notes | Set `_versionForks = tabulateHashMap $ \case _ -> AllChains ForkAtGenesis` (same pattern as Development version). This means all 31 `Fork` constructors (`SlowEpoch` through `Chainweb232Pact`) activate at block 0. No upgrade transactions needed (`_versionUpgrades = AllChains mempty`). |

### 8. Bootstrap Nodes

| Aspect | Detail |
|--------|--------|
| Why Expected | Without at least one bootstrap node, new nodes cannot discover peers and the network cannot form. The `_versionBootstraps` field must contain reachable `PeerInfo` entries. |
| Complexity | Low |
| Files | `src/P2P/BootstrapNodes.hs` (new STOA bootstrap hosts), `src/Chainweb/Version/Stoa.hs` |
| Notes | For initial development, can use empty list with `_disablePeerValidation = True`. For launch, need DNS entries and certificate fingerprints for bootstrap nodes. Format: `domainAddr2PeerInfo stoaBootstrapHosts`. |

### 9. Genesis Block Target (Initial Difficulty)

| Aspect | Detail |
|--------|--------|
| Why Expected | `_genesisBlockTarget` sets the initial mining difficulty. Mainnet started with `maxTarget` (easiest) for chains 0-9 and a tuned target for chains 10-19. STOA needs appropriate initial difficulty for all 10 chains. |
| Complexity | Low |
| Files | `src/Chainweb/Version/Stoa.hs` |
| Notes | For devnet: `AllChains $ HashTarget (maxBound \`div\` 100_000)` (same as Development). For mainnet launch: tune based on expected initial hash power. Using `maxTarget` (all chains) is safest for initial testing. |

### 10. Version Registration and Configuration Wiring

| Aspect | Detail |
|--------|--------|
| Why Expected | The node resolves versions by name ("stoa") and code at startup. `findKnownVersion` and `lookupVersionByCode` must find the STOA version. `validateChainwebVersion` currently only allows `development` or `recap-development` for custom versions; STOA needs either its own exception or registration in `knownVersions`. |
| Complexity | Medium |
| Files | `src/Chainweb/Version/Registry.hs`, `src/Chainweb/Chainweb/Configuration.hs`, `node/src/ChainwebNode.hs` |
| Notes | Add `stoa` to `knownVersions` list. Update `validateChainwebVersion` to allow STOA (currently it only allows development codes). Update `defaultChainwebConfiguration` to default to STOA version instead of Mainnet01. The `FromJSON` instance for `ChainwebConfiguration` currently defaults to `Mainnet01` -- change to STOA. Update CLI parser `parseVersion` if needed. |

## Differentiators

Features specific to STOA that require special handling beyond simple parameter changes. These are what make STOA distinct from a vanilla Kadena fork.

### 1. UR-STOA Staking Vault on Chain 0

| Aspect | Detail |
|--------|--------|
| Value Proposition | STOA's tokenomics include a staking vault that lives on chain 0. This is initialized in the genesis block of chain 0 via `A_InitialiseStoaChain`. |
| Complexity | High |
| Files | Chain 0 genesis YAML (keysets, grants, coin contract setup), STOA coin contract (vault-related functions) |
| Notes | This is purely Pact-level: the Haskell runtime does not need to know about staking. It is deployed as genesis transactions on chain 0 only. The differentiation between chain 0 and chains 1-9 genesis is already a pattern in Kadena (chain 0 gets keysets/allocations, others get simpler genesis). Must ensure the vault initialization transaction gas fits within genesis block limits. |

### 2. 7 Stoa Master Keysets

| Aspect | Detail |
|--------|--------|
| Value Proposition | Replaces Kadena's keyset structure with 7 STOA master keysets for governance. |
| Complexity | Medium |
| Files | New `pact/genesis/stoa/keysets.yaml`, referenced from genesis definition |
| Notes | Keysets are defined in genesis YAML and loaded as part of genesis block creation. No Haskell code changes needed -- this is purely Pact-level configuration. The `keysets.yaml` defines keyset names and their public key sets. Must define STOA-specific governance keysets that the coin contract and other modules reference. |

### 3. STOA-Specific Tokenomics (16M Genesis Supply, Declining Emissions)

| Aspect | Detail |
|--------|--------|
| Value Proposition | Different total supply and emission schedule than Kadena's ~1B KDA / ~120 year schedule. |
| Complexity | High |
| Files | `rewards/miner_rewards.csv`, `src/Chainweb/MinerReward.hs`, genesis allocation YAMLs |
| Notes | Two components: (a) Genesis allocations distribute the initial 16M STOA across accounts via allocation YAML files loaded during genesis. (b) The miner rewards CSV defines the emission curve. Kadena's curve is ~120 years of declining rewards. STOA needs a new curve matching its "declining emissions" design. The rewards table format is `(BlockHeight, Decimal)` pairs where the decimal is the total network reward (divided by chain count at runtime). Must regenerate both SHA512 hashes after replacing the CSV. |

### 4. Bundled Interfaces in Coin Contract

| Aspect | Detail |
|--------|--------|
| Value Proposition | STOA bundles `fungible-v2` and `fungible-xchain-v1` interfaces directly into the coin contract or genesis, rather than loading them as separate transactions. |
| Complexity | Medium |
| Files | Coin contract Pact files, genesis YAML loading order |
| Notes | Kadena loads interfaces as separate files (`fungibleAssetV1`, `fungibleAssetV2`, `fungibleXChainV1`) before the coin contract in genesis. STOA can simplify by bundling these into a single deployment or keeping the same multi-file approach with STOA-specific versions. The Haskell code does not care about the interface deployment strategy -- it only cares that the `coin` module exists with the right capabilities. |

### 5. Increased Block Capacity (400K/500K Gas)

| Aspect | Detail |
|--------|--------|
| Value Proposition | ~2.7x larger blocks than Kadena (400K default vs 150K, 500K max vs 180K). Enables more transactions per block. |
| Complexity | Low (parameter change) |
| Files | Version definition, configuration defaults |
| Notes | While this is technically a table-stakes parameter change, the 2.7x increase is a deliberate STOA differentiator. The mempool fetch limit is calculated as `blockGasLimit \`div\` 1000`, so it will automatically scale up. Transaction time limits are calculated as `2.5 * txTimeHeadroomFactor * fromIntegral blockGasLimit`, so they also scale automatically. No additional code changes needed beyond the parameter values. |

## Anti-Features

Features to explicitly NOT change from Kadena's codebase. These are things that might seem like they need changing but should be left alone.

### 1. Do NOT Change the Module Name "coin"

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| Renaming the coin module to "stoa" or "stoa-coin" | The Haskell runtime hardcodes `ModuleName "coin" Nothing` in at least 6 places across Pact4 and Pact5 transaction execution. Capabilities `COINBASE`, `GAS`, `GENESIS`, `REMEDIATE` are all resolved against the `coin` module name. Changing this would require modifying core runtime code in both Pact versions. | Keep the module name as `coin`. The STOA coin contract replaces the implementation but keeps the same module name and interface. |

### 2. Do NOT Change the Block Hash / Merkle Tree Structure

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| Modifying how block headers compute their Merkle hash or how adjacent hashes work | The block header structure (`BlockHeader` in `Internal.hs`) includes `_blockAdjacentHashes` as a `BlockHashRecord`. The Merkle log computation is deeply integrated. The Petersen graph naturally has 3 adjacencies per chain (degree 3), same as the Twenty graph. | Let the existing adjacency system work unchanged. The Petersen graph is already a valid `ChainGraph` and all adjacency calculations work automatically. |

### 3. Do NOT Change the PoW Algorithm

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| Switching to a different mining algorithm or PoS | The PoW implementation is deeply integrated into block header creation, validation, difficulty adjustment, and the mining API. It would be a massive rewrite. | Keep SHA-256d PoW. Adjust `_versionBlockDelay` and `_versionWindow` if needed for different target block times. The difficulty adjustment algorithm works independently of chain count. |

### 4. Do NOT Change the SPV Proof Mechanism

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| Modifying cross-chain SPV proofs | SPV proofs traverse the Merkle tree across chains and are critical for cross-chain transfers (`fungible-xchain-v1`). They work based on the chain graph structure. | The SPV system works automatically with any valid `ChainGraph`. With 10 chains and diameter 2 (Petersen), proofs are actually shorter than with 20 chains (diameter 3 for Twenty graph). No changes needed. |

### 5. Do NOT Change the Pact Runtime Integration

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| Modifying how the Pact service is invoked, how coinbase is computed, or the gas payment flow | The Pact4/Pact5 transaction execution is complex and tightly integrated. The coinbase flow, gas buying (`fund-tx`), and gas redemption (`redeem-gas`) are deeply coupled. | Keep the Pact runtime unchanged. The STOA coin contract must conform to the existing Pact calling conventions. All changes are at the Pact contract level, not the Haskell runtime level. |

### 6. Do NOT Change the Difficulty Adjustment Algorithm

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| Modifying epoch-based difficulty adjustment | The DA algorithm uses `_versionWindow` and `_versionBlockDelay` to adjust difficulty. It is chain-count-aware through the graph. Guards like `SlowEpoch`, `OldTargetGuard`, `OldDAGuard` control DA behavior at different heights. | Keep the DA algorithm. With all forks at genesis, the latest DA behavior is active from block 0. The algorithm automatically adapts to 10 chains. Set `_versionBlockDelay = BlockDelay 30_000_000` (30 seconds) and `_versionWindow = WindowWidth 120` (same as Kadena) unless different block times are desired. |

### 7. Do NOT Remove Historical Fork Infrastructure

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| Deleting the `Fork` data type constructors or removing historical upgrade code | The `Fork` type is `Bounded` and `Enum`. The version validation (`validateVersion`) checks that `_versionForks` has entries for ALL fork constructors. Removing constructors breaks validation for all versions including test versions. | Keep all 31 `Fork` constructors. Set them all to `ForkAtGenesis` in the STOA version. The dead code for historical upgrades has zero runtime cost when forks are at genesis. |

### 8. Do NOT Create Separate Haskell Modules for STOA Logic

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| Creating new `Chainweb.Stoa.*` module hierarchy | Per project philosophy: "change existing code, don't create new modules" unless absolutely necessary. Scattered logic is harder to maintain. | The only new module should be `Chainweb.Version.Stoa` (following the existing pattern of `Version.Mainnet`, `Version.Testnet04`, `Version.Development`). All other changes should modify existing files. |

## Feature Dependencies

```
Version Definition (Stoa.hs) --> depends on nothing, everything depends on this
    |
    +-- Chain Graph (Petersen) --> used by Version Definition
    |
    +-- Genesis Payloads --> depend on:
    |       |
    |       +-- STOA Coin Contract (must exist first)
    |       |
    |       +-- Keyset YAMLs (must exist first)
    |       |
    |       +-- Allocation YAMLs (must exist first)
    |       |
    |       +-- Namespace YAMLs (must exist first)
    |       |
    |       +-- ea tool execution (generates Haskell payload modules)
    |
    +-- Gas Limits --> set in Version Definition + Configuration
    |
    +-- Miner Rewards --> independent, but needed before first block
    |
    +-- Fork Heights --> set in Version Definition
    |
    +-- Bootstrap Nodes --> needed for network launch, not for devnet
    |
    +-- Registry Wiring --> depends on Version Definition existing

Genesis Payloads --> blocks Version Definition compilation
    (circular: version imports payload modules, payloads are generated
     using the version. Resolved by ea tool generating payloads first,
     then building the version module that references them.)
```

## MVP Recommendation

**Phase 1: Minimal bootable node (must have all of these)**

1. **Version Definition** (`Chainweb.Version.Stoa`) -- the foundation everything depends on
2. **Petersen graph selection** -- trivial, already exists as `petersenChainGraph`
3. **All forks at genesis** -- trivial, pattern from Development version
4. **Gas limit parameters** -- trivial, two number changes
5. **Miner rewards table** -- needed for first block reward computation
6. **Genesis payloads for 10 chains** -- the coin contract must be deployed at genesis
7. **STOA coin contract** -- must implement `coin` module with required capabilities
8. **Registry and configuration wiring** -- node must find and use the STOA version

**Phase 2: Network-ready (defer until node boots and mines)**

9. **UR-STOA staking vault on chain 0** -- complex Pact logic, can be a genesis-only concern
10. **Bootstrap nodes** -- needed for multi-node network, not for single-node devnet
11. **Production difficulty tuning** -- only matters for real mining

**Defer: Do not prioritize**

- Custom block delay/window (keep 30s/120 defaults until testing shows need to change)
- Verifier plugins (keep Kadena defaults, they are harmless)
- Custom namespace policy (keep Kadena namespace YAML structure)

## Critical Path Analysis

The single highest-risk item is the **STOA coin contract**. Every other change is either a parameter tweak or follows an established pattern. The coin contract must:

1. Implement all required Pact interfaces (`fungible-v2`, `fungible-xchain-v1`)
2. Define all capabilities the Haskell runtime expects (`COINBASE`, `GAS`, `GENESIS`, `GOVERNANCE`)
3. Implement `fund-tx` as a defpact (specific Pact4 calling convention)
4. Implement `coinbase` accepting miner ID and reward
5. Implement `redeem-gas` for gas redemption
6. Work correctly within the genesis block gas budget
7. Handle the 16M initial supply distribution

If the coin contract is wrong, the node will crash on the first block after genesis. There is no partial success -- the contract either works completely or the chain is dead.

The second highest risk is the **genesis payload generation pipeline** (`ea` tool). The tool must be modified to support STOA genesis definitions, and the circular dependency between version definition and payload modules must be carefully managed.

## Sources

- Direct codebase analysis of Kadena Chainweb Node v2.32.0
- `src/Chainweb/Graph.hs` -- KnownGraph definitions, Petersen graph properties (HIGH confidence)
- `src/Chainweb/Version.hs` -- ChainwebVersion data type, all version fields (HIGH confidence)
- `src/Chainweb/Version/Mainnet.hs` -- Reference version definition, 20-chain transition pattern (HIGH confidence)
- `src/Chainweb/Version/Development.hs` -- Development version pattern with all forks at genesis (HIGH confidence)
- `src/Chainweb/MinerReward.hs` -- Reward computation, CSV embedding, hash verification (HIGH confidence)
- `src/Chainweb/Chainweb/Configuration.hs` -- Gas limit configuration, defaults (HIGH confidence)
- `src/Chainweb/Version/Registry.hs` -- Version registration and validation (HIGH confidence)
- `src/Chainweb/Pact5/TransactionExec.hs` -- Hardcoded `coin` module references (HIGH confidence)
- `src/Chainweb/Pact4/TransactionExec.hs` -- Magic capabilities, fund-tx/redeem-gas (HIGH confidence)
- `cwtools/ea/Ea.hs` and `cwtools/ea/Ea/Genesis.hs` -- Genesis payload generation tool (HIGH confidence)
- `pact/coin-contract/coin.pact` -- Current coin contract structure (HIGH confidence)
