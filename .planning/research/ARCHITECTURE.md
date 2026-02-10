# Architecture Research: Chainweb Fork Modification

**Research Date:** 2026-02-10
**Dimension:** Architecture
**Scope:** Chain graphs, genesis transactions, gas configuration, and version management

---

## 1. Component Map

### 1.1 Chain Graph System

**Files:**
- `/Users/codera/Development/Stoa/stoa-chain/src/Chainweb/Graph.hs` -- Core graph types and known graphs
- External dependency: `Data.DiGraph` (provides `petersenGraph`, `twentyChainGraph`, etc.)

**Structure:**
The `ChainGraph` type wraps a `DiGraph ChainId` with a `KnownGraph` tag, a shortest-path cache, and a hash. All chain graphs are required to be symmetric, regular, irreflexive, and strongly connected.

Known graphs are enumerated in the `KnownGraph` ADT:
```haskell
data KnownGraph
    = Singleton    -- order 1, degree 0
    | Pair         -- order 2, degree 1
    | Triangle     -- order 3, degree 2
    | Petersen     -- order 10, degree 3, diameter 2  <-- TARGET FOR STOA
    | Twenty       -- order 20, degree 3, diameter 3  <-- CURRENT KADENA MAINNET
    | HoffmanSingleton  -- order 50, degree 7
    | D3K4 | D4K3 | D4K4 | D5K3 | D5K4
```

Each known graph has a memoized `ChainGraph` value (e.g., `petersenChainGraph`, `twentyChainGraph`). The actual graph topology is defined in the `Data.DiGraph` external library, not in this codebase.

**Key insight:** The Petersen graph (order 10, degree 3, diameter 2) already exists in the codebase and is already used for test versions. It maps chains 0-9 which is the target for Stoa's 10-chain configuration.

**Graph transitions in versions:** Versions use `Rule BlockHeight ChainGraph` to define graph changes over time. For example, Kadena mainnet started with Petersen (10 chains) and transitioned to Twenty (20 chains) at block height 852,054:
```haskell
_versionGraphs =
    (to20ChainsMainnet, twentyChainGraph) `Above`
    Bottom (minBound, petersenChainGraph)
```

For Stoa (always 10 chains), this simplifies to:
```haskell
_versionGraphs = Bottom (minBound, petersenChainGraph)
```

### 1.2 Version Management System

**Files:**
- `/Users/codera/Development/Stoa/stoa-chain/src/Chainweb/Version.hs` -- Core types: `ChainwebVersion`, `Fork`, `ForkHeight`, `VersionGenesis`, `PactUpgrade`
- `/Users/codera/Development/Stoa/stoa-chain/src/Chainweb/Version/Mainnet.hs` -- Kadena mainnet definition
- `/Users/codera/Development/Stoa/stoa-chain/src/Chainweb/Version/Testnet04.hs` -- Kadena testnet definition
- `/Users/codera/Development/Stoa/stoa-chain/src/Chainweb/Version/Development.hs` -- Development/devnet definition
- `/Users/codera/Development/Stoa/stoa-chain/src/Chainweb/Version/RecapDevelopment.hs` -- Recap devnet definition
- `/Users/codera/Development/Stoa/stoa-chain/src/Chainweb/Version/Registry.hs` -- Global mutable version registry
- `/Users/codera/Development/Stoa/stoa-chain/src/Chainweb/Version/Guards.hs` -- Fork activation guard functions
- `/Users/codera/Development/Stoa/stoa-chain/src/Chainweb/Utils/Rule.hs` -- `Rule` type for height-indexed behaviors

**`ChainwebVersion` record (critical fields for modification):**
```haskell
data ChainwebVersion = ChainwebVersion
    { _versionCode :: ChainwebVersionCode          -- Unique numeric ID (Word32)
    , _versionName :: ChainwebVersionName           -- Text name (used in REST endpoints)
    , _versionGraphs :: Rule BlockHeight ChainGraph -- Chain graph history
    , _versionForks :: HashMap Fork (ChainMap ForkHeight) -- Per-chain fork activation heights
    , _versionUpgrades :: ChainMap (HashMap BlockHeight PactUpgrade) -- Upgrade transactions
    , _versionBlockDelay :: BlockDelay              -- Target PoW time (microseconds)
    , _versionWindow :: WindowWidth                 -- PoW difficulty window
    , _versionMaxBlockGasLimit :: Rule BlockHeight (Maybe Natural) -- Block gas cap
    , _versionBootstraps :: [PeerInfo]              -- Bootstrap peers
    , _versionGenesis :: VersionGenesis             -- Genesis block data
    , _versionCheats :: VersionCheats               -- Debug flags (disable PoW, etc.)
    , _versionDefaults :: VersionDefaults           -- Peer/mempool defaults
    , _versionVerifierPluginNames :: ChainMap (Rule BlockHeight (Set VerifierName))
    , _versionQuirks :: VersionQuirks               -- Gas fee quirks
    , _versionForkNumber :: ForkNumber              -- Fork numbering (v2.33+)
    }
```

**`ChainMap` type:** Represents per-chain values. Either `AllChains a` (same value for all chains) or `OnChains (HashMap ChainId a)` (per-chain values). This is used extensively in version definitions.

**`Rule` type:** A stack of height-indexed values, most recent on top. `Above (height, value) rest` means "value applies at or above height". `Bottom (minBound, value)` is the base case. Used for graph transitions, gas limits, and other height-dependent behaviors.

**Version Registry:** A global `IORef` mapping `ChainwebVersionCode` to `ChainwebVersion`. Mainnet and testnet are hardcoded and cannot be replaced. Other versions must be registered before use. The `validateVersion` function checks:
- All forks have heights defined for all chains
- Graph history heights are decreasing
- Gas limit heights are decreasing
- Genesis data exists for all chains
- All upgrade transactions are non-empty

**Fork system:** The `Fork` ADT lists all protocol changes chronologically. Each fork has a `ChainMap ForkHeight` specifying when it activates on each chain. Guard functions in `Chainweb.Version.Guards` query fork status at a given block height.

### 1.3 Genesis Transaction System

**Files:**
- `/Users/codera/Development/Stoa/stoa-chain/cwtools/ea/Ea.hs` -- Main genesis payload generator ("Ea" tool)
- `/Users/codera/Development/Stoa/stoa-chain/cwtools/ea/Ea/Genesis.hs` -- Genesis transaction definitions
- `/Users/codera/Development/Stoa/stoa-chain/src/Chainweb/BlockHeader/Genesis/` -- Auto-generated Haskell payload modules (DO NOT EDIT)
- `/Users/codera/Development/Stoa/stoa-chain/src/Chainweb/Pact/Transactions/` -- Auto-generated upgrade transaction modules
- `/Users/codera/Development/Stoa/stoa-chain/src/Chainweb/BlockHeader/Internal.hs` -- `genesisBlockHeaders`, `makeGenesisBlockHeader`
- `/Users/codera/Development/Stoa/stoa-chain/pact/` -- Pact source files and YAML transaction definitions

**Genesis data flow:**

```
pact/*.yaml + pact/*.pact files
        |
        v
    Ea tool (cwtools/ea/Ea.hs)
        | reads YAML, compiles Pact, executes genesis txs
        | via PactService's execNewGenesisBlock
        v
    src/Chainweb/BlockHeader/Genesis/*Payload.hs  (auto-generated)
        | hardcoded PayloadWithOutputs as Haskell source
        v
    Version definition (_genesisBlockPayload field)
        | references payloadBlock from generated modules
        v
    makeGenesisBlockHeader (BlockHeader/Internal.hs)
        | constructs BlockHeader from VersionGenesis data
        v
    Node startup: genesisBlockHeaders creates headers for all chains
```

**Genesis record in `Ea/Genesis.hs`:**
```haskell
data Genesis = Genesis
    { _version :: ChainwebVersion
    , _tag :: T.Text              -- Module name tag (e.g., "Development")
    , _txChainIds :: ChainIdRange -- Which chains this genesis applies to
    , _coinbase :: Maybe FilePath  -- Coinbase grants YAML
    , _keysets :: Maybe FilePath    -- Keyset definitions YAML
    , _allocations :: Maybe FilePath -- Token allocation YAML
    , _namespaces :: Maybe FilePath  -- Namespace definitions YAML
    , _coinContract :: [FilePath]   -- Coin contract YAML files (ordered)
    }
```

**Transaction ordering is position-sensitive:** The Ea tool concatenates: `coinContract ++ namespaces ++ keysets ++ allocations ++ coinbase` in that exact order. Each YAML file references a `.pact` code file.

**Current Development genesis (the pattern for Stoa):**
```haskell
fastDevelopment0 = Genesis
    { _version = Development
    , _tag = "Development"
    , _txChainIds = onlyChainId 0
    , _coinContract = [fungibleAssetV1, fungibleXChainV1, fungibleAssetV2, installCoinContractV6, gasPayer]
    , _namespaces = Just devNs2
    , _keysets = Just devKeysets
    , _allocations = Just devAllocations
    , _coinbase = Just dev0Grants
    }
```

This deploys: `fungible-v1.pact`, `fungible-xchain-v1.pact`, `fungible-v2.pact`, `coin-install.pact` (the coin module), then `gas-payer.pact`. Each `.pact` file contains a single module or interface definition.

**Multi-definition files in genesis:** Each YAML file points to one `.pact` code file. Each `.pact` file is deployed as one Pact transaction. A file containing multiple top-level definitions (e.g., an interface and a module) would be deployed as a single transaction -- Pact supports this. The current pattern deploys interfaces and the coin module as separate transactions. For a new coin contract that bundles interfaces in one file, a single YAML referencing that file would be sufficient, but it changes the genesis payload hash, requiring re-running the Ea tool.

### 1.4 Gas Configuration System

**Files:**
- `/Users/codera/Development/Stoa/stoa-chain/src/Chainweb/Chainweb/Configuration.hs` -- `_configBlockGasLimit` (default: 150,000)
- `/Users/codera/Development/Stoa/stoa-chain/src/Chainweb/Version.hs` -- `_versionMaxBlockGasLimit` field
- `/Users/codera/Development/Stoa/stoa-chain/src/Chainweb/Version/Guards.hs` -- `maxBlockGasLimit` function
- `/Users/codera/Development/Stoa/stoa-chain/src/Chainweb/Pact/Types.hs` -- `_psBlockGasLimit`, `_pactNewBlockGasLimit`, `testBlockGasLimit`
- `/Users/codera/Development/Stoa/stoa-chain/src/Chainweb/Chainweb.hs` -- Gas limit composition logic
- `/Users/codera/Development/Stoa/stoa-chain/src/Chainweb/Pact4/Validations.hs` -- Transaction gas limit validation
- `/Users/codera/Development/Stoa/stoa-chain/src/Chainweb/Pact5/Validations.hs` -- Pact5 transaction gas limit validation

**Gas limit data flow:**

```
Version definition: _versionMaxBlockGasLimit :: Rule BlockHeight (Maybe Natural)
    |
    v
maxBlockGasLimit :: ChainwebVersion -> BlockHeight -> Maybe Natural
    | looks up the applicable limit for a given height
    v
Configuration: _configBlockGasLimit :: GasLimit (default 150,000)
    | CLI/config override; clamped to maxBlockGasLimit
    v
Chainweb.hs initialization: _pactNewBlockGasLimit = maybe id min maxGasLimit configBlockGasLimit
    | effective limit = min(config, version max)
    v
PactService: _psBlockGasLimit
    | used during block creation and validation
    v
ExecBlock (Pact4/Pact5): fetches blockGasLimit for mining and validation
    | individual transaction gasLimit must not exceed block gas limit
```

**Current gas limits by version:**

| Version | `_versionMaxBlockGasLimit` | Config default |
|---------|---------------------------|----------------|
| Mainnet | `Just 180_000` (from Chainweb216Pact+) | 150,000 |
| Testnet | `Just 180_000` (from Chainweb216Pact+) | 150,000 |
| RecapDev | `Just 180_000` (all heights) | 150,000 |
| Development | `Nothing` (no version cap) | 150,000 |
| Test versions | `Just 2_000_000` (all heights) | 100,000 (`testBlockGasLimit`) |

**Per-transaction gas limit:** Validated in `Pact4/Validations.hs` and `Pact5/Validations.hs` via `assertBlockGasLimit`. Transaction `gasLimit` must not exceed block `gasLimit`.

**To change gas limits for Stoa:**
1. Set `_versionMaxBlockGasLimit` in the new Stoa version definition
2. Optionally change `_configBlockGasLimit` default in `Configuration.hs`
3. The effective limit is `min(config, versionMax)`, so both matter

### 1.5 Mining Rewards

**Files:**
- `/Users/codera/Development/Stoa/stoa-chain/src/Chainweb/Miner/Pact.hs` -- `MinerRewards`, `readRewards`
- `/Users/codera/Development/Stoa/stoa-chain/rewards/miner_rewards.csv` -- Embedded reward schedule

Mining rewards are loaded from an embedded CSV file (`rewards/miner_rewards.csv`) at compile time via Template Haskell's `embedFile`. The reward schedule maps block heights to reward amounts (decimals). This is a separate concern from gas limits but may need adjustment for Stoa's economics.

---

## 2. Component Boundaries

### Version Definition -> Everything
The `ChainwebVersion` record is the central configuration authority. It flows into:
- Block header creation/validation (graph, genesis, forks)
- Pact service (gas limits, fork guards, upgrade transactions)
- P2P networking (bootstrap peers, version code in protocol)
- REST API (version name in URL paths)
- Mining (block delay, difficulty window)

### Ea Tool -> Genesis Payloads
The Ea tool is a build-time code generator. It reads `.yaml`/`.pact` files, runs them through PactService, and generates Haskell source files. These generated files are committed to the repository and compiled into the node binary. The Ea tool must be re-run whenever genesis transactions change.

### Configuration -> Runtime Behavior
The `ChainwebConfiguration` provides runtime overrides (CLI flags, config files). Gas limits, peer settings, and other operational parameters can be adjusted without changing the version definition, subject to version-imposed maximums.

---

## 3. Data Flow for Genesis Block Creation

```
1. Node starts, loads ChainwebVersion (e.g., Stoa mainnet)
2. For each ChainId in the chain graph:
   a. Look up _genesisBlockPayload for that chain -> PayloadWithOutputs
   b. Look up _genesisBlockTarget, _genesisTime for that chain
   c. Compute genesis parent hash from (version code, chain id)
   d. Build BlockHeader via Merkle tree from all genesis data
   e. Cache in genesisBlockHeaderCache
3. CutDB initializes with genesis cut (one genesis header per chain)
4. Block sync begins from genesis
```

---

## 4. Modification Dependencies and Suggested Order

### Phase 1: Foundation (no code changes yet)
1. **Understand the Petersen graph** -- already defined, 10 chains (0-9), degree 3

### Phase 2: Version Definition (core change)
Create a new Stoa version module (e.g., `src/Chainweb/Version/Stoa.hs`), or modify an existing one:

**Dependencies:** None -- this is a pure data definition
**Changes:**
- New `ChainwebVersionCode` (unique, e.g., `0x00000010`)
- New `ChainwebVersionName` (e.g., `"stoa01"`)
- `_versionGraphs = Bottom (minBound, petersenChainGraph)` -- 10 chains only
- `_versionForks` -- decide which forks activate at genesis vs. at specific heights
- `_versionMaxBlockGasLimit` -- set new gas limits
- `_versionGenesis` -- reference new genesis payloads (Phase 3)
- `_versionBlockDelay` -- same or different PoW timing
- `_versionBootstraps` -- new bootstrap nodes for Stoa network
- `_versionUpgrades` -- remove Kadena-specific upgrade history
- `_versionQuirks` -- `noQuirks` (fresh chain, no historical quirks)

### Phase 3: Coin Contract and Genesis Payloads
**Dependencies:** Phase 2 (version definition needed for Ea tool)
**Changes:**

1. **New coin contract:** Place new `.pact` file(s) in `pact/coin-contract/stoa/` (or similar)
2. **New YAML loader(s):** Create YAML files referencing the new Pact code
3. **New genesis definitions in `Ea/Genesis.hs`:**
   - Define `stoa0 :: Genesis` for chain 0 (with allocations, keysets)
   - Define `stoaN :: Genesis` for chains 1-9
   - Reference new coin contract files
4. **Run Ea tool:** `cabal run cwtools -- ea` generates `src/Chainweb/BlockHeader/Genesis/Stoa*Payload.hs`
5. **Wire into version:** Import generated payload modules in version definition

**Multi-definition file handling:** If the new coin contract bundles interfaces (e.g., `fungible-v2`, `fungible-xchain-v1`) and the module in a single `.pact` file, create a single YAML:
```yaml
codeFile: stoa-coin.pact
nonce: stoa-coin-genesis
keyPairs: []
```
The Ea tool will deploy this as one transaction. The genesis payload hash will be different from Kadena's, which is expected and correct.

### Phase 4: Gas Limit Configuration
**Dependencies:** Phase 2 (version definition)
**Changes:**

1. **Version-level max:** Set `_versionMaxBlockGasLimit` in Stoa version:
   ```haskell
   _versionMaxBlockGasLimit = Bottom (minBound, Just <new_limit>)
   ```
2. **Config default (optional):** Change `_configBlockGasLimit` in `Configuration.hs` if the default 150,000 is wrong for Stoa
3. **Test block gas limit (optional):** Update `testBlockGasLimit` in `Pact/Types.hs` if test versions need different limits

### Phase 5: Registry and Integration
**Dependencies:** Phases 2-4
**Changes:**

1. **Register version:** Add Stoa version to `knownVersions` in `Registry.hs`
2. **Register in Ea tool:** Add `registerVersion Stoa` in `Ea.hs` main
3. **Update `findKnownVersion`:** Ensure CLI can select Stoa version
4. **Update node startup:** Ensure `ChainwebNode.hs` can initialize with Stoa version

### Phase 6: Cleanup
**Dependencies:** All above
**Changes:**

1. Remove or disable Kadena-specific versions if not needed
2. Update test versions to use Stoa graph/genesis
3. Update bootstrap node lists
4. Update reward schedule CSV if economics differ

---

## 5. Key Architectural Constraints

### Constraint 1: Genesis payloads are compile-time constants
Genesis payload data is hardcoded as Haskell source (generated by Ea). Any change to genesis transactions requires re-running the Ea tool and recompiling. This is by design for security/reproducibility.

### Constraint 2: Version codes must be globally unique
The `ChainwebVersionCode` is a `Word32` embedded in block headers and used in P2P protocol. Collisions cause node failures. Kadena uses codes 0x01-0x07.

### Constraint 3: Fork heights must cover all chains
The `validateVersion` function enforces that every `Fork` has a `ChainMap ForkHeight` entry for every chain in the graph. For Stoa with Petersen (chains 0-9), all fork heights must be defined for exactly chains 0-9.

### Constraint 4: The Petersen graph is already validated
`petersenChainGraph` passes `validChainGraph` checks (symmetric, regular, degree >= 1, strongly connected). No new graph definition is needed for 10 chains.

### Constraint 5: Graph transitions create new genesis blocks
When Kadena transitioned from 10 to 20 chains, chains 10-19 got genesis blocks at height 852,054 (not height 0). Since Stoa uses only Petersen with no transition, all genesis blocks are at height 0.

### Constraint 6: Gas limits have two levels of control
`_versionMaxBlockGasLimit` is the hard protocol cap (consensus-enforced). `_configBlockGasLimit` is the operator preference (clamped to protocol cap). Both must be considered.

---

## 6. Risk Areas

1. **Genesis payload hash sensitivity:** Any byte-level change to genesis transactions changes the payload hash, which changes the genesis block hash, which changes the chain identity. Genesis payloads must be generated exactly once and frozen.

2. **Fork compatibility matrix:** Some forks have dependencies (e.g., Pact5Fork depends on earlier Pact upgrades being active). If Stoa activates all forks at genesis, ensure no ordering issues.

3. **P2P protocol version mismatch:** Stoa nodes must reject connections from Kadena nodes and vice versa. The `ChainwebVersionCode` in the protocol handles this, but bootstrap nodes must be configured correctly.

4. **Coin contract state at genesis:** The new coin contract must create the same table structure (`coin-table`) that the gas system expects. The `fund-tx` function signature is hardcoded in the Pact service.

5. **Miner rewards CSV:** The rewards schedule assumes Kadena's 20-chain economics. With 10 chains, per-chain rewards may need adjustment to maintain intended token emission rate.

---

*Architecture research completed: 2026-02-10*
