# Stack Research: Modifying Chainweb for Stoa Chain

**Research Date:** 2026-02-10
**Scope:** Tools, libraries, and approaches for modifying chain graph (20 to 10), replacing genesis coin contracts, and updating gas limits in a Kadena Chainweb Node fork (Haskell).

---

## 1. Chain Graph Modification (20 chains to 10 chains)

### 1.1 Approach: Use Existing Petersen Graph

**Confidence: HIGH (95%)**

The codebase already contains the exact graph needed. The `Petersen` graph in `src/Chainweb/Graph.hs` is:
- **Order 10** (10 vertices = 10 chains)
- **Degree 3** (each chain has 3 adjacent chains for cross-chain validation)
- **Diameter 2** (maximum 2 hops between any two chains -- better than Twenty's diameter 3)
- **Already validated** as a proper ChainGraph (symmetric, regular, irreflexive)

Kadena's own mainnet started with the Petersen graph for its initial 10 chains and only transitioned to the Twenty graph at block height 852,054. The Petersen graph is the canonical 10-chain topology for this codebase.

**What to change:**

In the new Stoa version definition file (modeled on `src/Chainweb/Version/Development.hs`):

```haskell
_versionGraphs = Bottom (minBound, petersenChainGraph)
```

This is a single-line change. There is no graph transition needed since Stoa starts fresh from genesis.

### 1.2 Header Size Implications

**Confidence: HIGH (95%)**

The header size is computed in `src/Chainweb/BlockHeader/Internal.hs`:
```haskell
headerSizes v = (\g -> _versionHeaderBaseSizeBytes v + 36 * degree g + 2) <$> _versionGraphs v
```

Both Petersen and Twenty graphs have **degree 3**, so `_versionHeaderBaseSizeBytes` (currently `318 - 110 = 208` across all versions) does NOT need to change. The serialized header size remains `208 + 36*3 + 2 = 318 bytes`.

### 1.3 Files That Reference Chain Count

**Confidence: HIGH (90%)**

The chain count is NOT hardcoded as a number; it is derived from the chain graph. Places that iterate over chains use `chainIds v` which reads from the graph. However, the following need attention:

| File | What References 20 Chains | Action |
|------|--------------------------|--------|
| `src/Chainweb/Version/Development.hs` | `[(unsafeChainId i, DNN.payloadBlock) \| i <- [1..19]]` | Change to `[1..9]` |
| `pact/coin-contract/coin.pact` | `VALID_CHAIN_IDS (enumerate 0 19)` | This is Kadena's coin contract -- replaced entirely by STOA's coin contract |
| `pact/coin-contract/coin-install.pact` | Same `VALID_CHAIN_IDS` | Same -- replaced |
| `cwtools/ea/Ea/Genesis.hs` | `mkChainIdRange 1 19` (fastDevelopmentN) | Change to `mkChainIdRange 1 9` for Stoa genesis entries |
| Genesis payload modules | `Development1to19Payload.hs` | New payload modules needed: `Stoa0Payload.hs`, `Stoa1to9Payload.hs` |

### 1.4 What NOT to Change

- **`src/Chainweb/Graph.hs`** -- The Petersen graph definition and the KnownGraph enum are correct as-is. Do NOT add a new graph variant.
- **`_versionHeaderBaseSizeBytes`** -- Same degree means same header size. Do NOT change this value.
- **`src/Chainweb/BlockHeader/Internal.hs`** -- Header serialization is graph-agnostic. Do NOT touch.
- **Test versions** -- Test infrastructure in `test/lib/Chainweb/Test/TestVersions.hs` already parameterizes over all KnownGraphs including Petersen. Tests will work.

---

## 2. Genesis Transaction Loading

### 2.1 Architecture of Genesis Loading

**Confidence: HIGH (95%)**

Genesis loading has three layers:

**Layer 1: Pact source files (.pact, .yaml)**
Located in `pact/coin-contract/` and `pact/genesis/`. YAML files reference `.pact` files via `codeFile:` or inline `code:` fields. Each YAML file becomes one transaction.

**Layer 2: Genesis definitions (`cwtools/ea/Ea/Genesis.hs`)**
Each `Genesis` record specifies:
- `_coinContract :: [FilePath]` -- ordered list of YAML files for the coin module and interfaces
- `_keysets :: Maybe FilePath` -- keyset definitions
- `_allocations :: Maybe FilePath` -- token allocations
- `_coinbase :: Maybe FilePath` -- coinbase grants (initial balances)
- `_namespaces :: Maybe FilePath` -- namespace setup

The transaction list is built as: `coinContract <> namespaces <> keysets <> allocations <> coinbase` (position-sensitive).

**Layer 3: Payload generation (`cwtools/ea/Ea.hs`)**
The `mkPayload` function:
1. Reads YAML files and creates Pact4 transactions via `mkChainwebTxs`
2. Runs `genPayloadModule` which boots a temporary Pact service, executes `execNewGenesisBlock`, and captures the resulting `PayloadWithOutputs`
3. Writes the result as auto-generated Haskell modules (e.g., `src/Chainweb/BlockHeader/Genesis/Development0Payload.hs`)

These auto-generated modules contain hardcoded payload data with hash verification. They are imported by the version definition file.

### 2.2 Approach: New STOA Genesis Entries

**Confidence: HIGH (90%)**

Create new `Genesis` records in `cwtools/ea/Ea/Genesis.hs`:

```haskell
-- Chain 0: Full init (STOA coin + UR-STOA + vault + keysets + grants)
stoaChain0 :: Genesis
stoaChain0 = Genesis
    { _version = Stoa  -- new version pattern
    , _tag = "Stoa"
    , _txChainIds = onlyChainId 0
    , _coinbase = Just "pact/genesis/stoa/grants0.yaml"
    , _keysets = Just "pact/genesis/stoa/keysets.yaml"
    , _allocations = Nothing  -- or STOA allocations if needed
    , _namespaces = Just "pact/genesis/ns-v2.yaml"
    , _coinContract = ["pact/stoa-coin/load-stoa-coin.yaml"]  -- single bundled file
    }

-- Chains 1-9: Coin module only (no UR-STOA, no vault)
stoaChainN :: Genesis
stoaChainN = stoaChain0
    & txChainIds .~ mkChainIdRange 1 9
    & coinbase ?~ "pact/genesis/stoa/grantsN.yaml"
```

### 2.3 Bundled Interfaces in One File

**Confidence: MEDIUM (75%)**

The STOA coin contract bundles interfaces (fungible-v2, fungible-xchain-v1, gas-payer-v1, StoaFungibleV1) with the coin module in a single `.pact` file. The current genesis loading runs each YAML file as a separate Pact4 transaction. As long as the bundled file compiles as a single Pact execution unit (with interface definitions preceding the module that `implements` them), this should work with a single YAML entry:

```yaml
# pact/stoa-coin/load-stoa-coin.yaml
codeFile: stoa-coin.pact
nonce: stoa-coin-genesis
keyPairs: []
```

**Risk:** If the combined file exceeds genesis block gas limits, it may fail. The current development genesis has no gas limit (`_versionMaxBlockGasLimit = Bottom (minBound, Nothing)`), and genesis blocks bypass normal gas enforcement in `Pact4/ExecBlock.hs`. However, if the file is very large, Pact parsing time may be an issue. The bundled approach works for Kadena's own `coin-install.pact` which includes the full v6 coin contract in a single transaction.

**Mitigation:** If the bundled file is too large, split into multiple YAML files in order: (1) interfaces, (2) coin module, (3) UR-STOA init. The `_coinContract` field accepts a list of file paths.

### 2.4 Genesis YAML File Structure

**Confidence: HIGH (95%)**

For the 7 Stoa Master keysets, create `pact/genesis/stoa/keysets.yaml`:
```yaml
code: |-
  (define-keyset "stoa-master-1" (read-keyset "stoa-master-1"))
  (define-keyset "stoa-master-2" (read-keyset "stoa-master-2"))
  ... (7 keysets)
data:
  stoa-master-1: ["<public-key-hex>"]
  stoa-master-2: ["<public-key-hex>"]
  ...
nonce: stoa-keysets
keyPairs: []
```

For chain 0 grants (calling `A_InitialiseStoaChain`):
```yaml
code: |-
  (coin.A_InitialiseStoaChain)
data: {}
nonce: stoa-init-chain0
keyPairs: []
```

### 2.5 Payload Generation Workflow

**Confidence: HIGH (90%)**

After creating the YAML/Pact files:

1. Add `stoaChain0` and `stoaChainN` genesis entries to `cwtools/ea/Ea/Genesis.hs`
2. Add a `stoa` entry to `cwtools/ea/Ea.hs` main function:
   ```haskell
   stoa = mkPayloads [stoaChain0, stoaChainN]
   ```
3. Run the Ea tool: `cabal run cwtools -- ea` (from `stoa-chain/` directory)
4. This generates `src/Chainweb/BlockHeader/Genesis/Stoa0Payload.hs` and `src/Chainweb/BlockHeader/Genesis/Stoa1to9Payload.hs`
5. Import these in the new Stoa version file

### 2.6 What NOT to Change

- **`cwtools/ea/Ea.hs` payload generation logic** -- The `genPayloadModule` and `mkChainwebTxs` functions work correctly for any Pact code. Do NOT modify the generation engine.
- **Existing genesis payloads** -- Do NOT modify any existing `*Payload.hs` files. They are auto-generated and hash-verified.
- **The `payloadModuleCode` template** -- The Haskell code template for generated payload modules is correct as-is.

---

## 3. Gas Limit Configuration

### 3.1 Two Gas Limit Systems

**Confidence: HIGH (95%)**

There are TWO independent gas limit controls. Both must be updated:

**A. Version-level maximum (`_versionMaxBlockGasLimit`):**
Defined in the version file (e.g., `src/Chainweb/Version/Mainnet.hs`). This is a `Rule BlockHeight (Maybe Natural)` -- a height-indexed rule. For mainnet, it transitions from `Nothing` (unlimited) to `Just 180_000` at the Chainweb216Pact fork. This is the **hard ceiling** for block validation.

Enforced in `src/Chainweb/Version/Guards.hs`:
```haskell
maxBlockGasLimit :: ChainwebVersion -> BlockHeight -> Maybe Natural
```

**B. Configuration-level default (`_configBlockGasLimit`):**
Defined in `src/Chainweb/Chainweb/Configuration.hs`. Default value: `150_000`. This is the **operator-configurable** gas limit, set via CLI flag `--block-gas-limit` or config file `gasLimitOfBlock`.

The effective gas limit is the **minimum** of these two, computed in `src/Chainweb/Chainweb.hs`:
```haskell
_pactNewBlockGasLimit = maybe id min maxGasLimit (_configBlockGasLimit conf)
```

Where `maxGasLimit = fromIntegral <$> maxBlockGasLimit v maxBound`.

### 3.2 Approach: Set Both Limits

**Confidence: HIGH (95%)**

For Stoa (default 400k, max 500k):

**In the Stoa version definition:**
```haskell
_versionMaxBlockGasLimit = Bottom (minBound, Just 500_000)
```

This sets the hard ceiling at 500,000 gas from genesis (no height-based transition needed since it is a new chain).

**In `src/Chainweb/Chainweb/Configuration.hs`:**
```haskell
, _configBlockGasLimit = 400_000  -- changed from 150_000
```

This means: by default, nodes create blocks with up to 400k gas. Operators can configure up to 500k (the version max). If an operator sets `--block-gas-limit 600000`, the `min` logic caps it at 500k.

### 3.3 Mempool Gas Limit

**Confidence: HIGH (90%)**

The mempool also uses the config gas limit for transaction validation, passed via `validatingMempoolConfig` in `src/Chainweb/Chainweb.hs`:
```haskell
let mcfg = validatingMempoolConfig cid v (_configBlockGasLimit conf) (_configMinGasPrice conf)
```

No special change needed here -- it flows through from the configuration.

### 3.4 Test Gas Limit

**Confidence: MEDIUM (80%)**

The test configuration in `src/Chainweb/Pact/Types.hs` has:
```haskell
testBlockGasLimit :: Pact4.GasLimit
testBlockGasLimit = 100000
```

And test versions use `versionMaxBlockGasLimit .~ Bottom (minBound, Just 2_000_000)`.

These test values do NOT need to change for Stoa unless Stoa-specific tests are added. The test infrastructure is independent.

### 3.5 What NOT to Change

- **`src/Chainweb/Pact/Types.hs` `testBlockGasLimit`** -- This is for tests only. Changing it affects all test suites.
- **Gas limit enforcement logic** in `Pact4/ExecBlock.hs` and `Pact5/ExecBlock.hs` -- The `blockGasLimit` and `maxBlockGasLimit` functions work correctly. Do NOT modify enforcement code.
- **`src/Chainweb/Version/Guards.hs`** -- The `maxBlockGasLimit` function reads from the version config correctly. No changes needed.

---

## 4. New Version Definition

### 4.1 Approach: New Version Module

**Confidence: HIGH (95%)**

Create `src/Chainweb/Version/Stoa.hs` modeled on `src/Chainweb/Version/Development.hs` (the simplest existing version). This is the central integration point for all three changes.

Key fields:
```haskell
stoaVersion :: ChainwebVersion
stoaVersion = ChainwebVersion
    { _versionCode = ChainwebVersionCode 0x00000010  -- unique code
    , _versionName = ChainwebVersionName "stoa"
    , _versionForks = tabulateHashMap $ \case
        _ -> AllChains ForkAtGenesis  -- all forks active from genesis
    , _versionUpgrades = AllChains mempty  -- no upgrade txs needed
    , _versionGraphs = Bottom (minBound, petersenChainGraph)  -- 10 chains
    , _versionBlockDelay = BlockDelay 30_000_000  -- 30 seconds
    , _versionWindow = WindowWidth 120
    , _versionHeaderBaseSizeBytes = 318 - 110  -- same as all versions
    , _versionMaxBlockGasLimit = Bottom (minBound, Just 500_000)  -- 500k max
    , _versionBootstraps = []  -- add bootstrap nodes later
    , _versionGenesis = VersionGenesis
        { _genesisBlockTarget = AllChains $ HashTarget (maxBound `div` 100_000)
        , _genesisTime = AllChains $ BlockCreationTime [timeMicrosQQ| 2026-01-01T00:00:00.0 |]
        , _genesisBlockPayload = onChains $ concat
            [ [(unsafeChainId 0, Stoa0.payloadBlock)]
            , [(unsafeChainId i, StoaN.payloadBlock) | i <- [1..9]]
            ]
        }
    , _versionCheats = VersionCheats
        { _disablePow = False  -- real PoW
        , _fakeFirstEpochStart = False
        , _disablePact = False
        }
    , _versionDefaults = VersionDefaults
        { _disablePeerValidation = False
        , _disableMempoolSync = False
        }
    , _versionMinimumBlockHeaderHistory = Bottom (minBound, Nothing)
    , _versionVerifierPluginNames = AllChains $ Bottom (minBound, mempty)
    , _versionQuirks = noQuirks
    , _versionForkNumber = 0
    }
```

### 4.2 Version Registration

**Confidence: HIGH (95%)**

The version must be registered in `src/Chainweb/Version/Registry.hs`:

1. Add import: `import Chainweb.Version.Stoa`
2. Add to `knownVersions`: `knownVersions = [mainnet, testnet04, recapDevnet, devnet, stoaVersion]`
3. Add to `versionMap` initialization if desired, or register at startup

Also update `src/Chainweb/Chainweb/Configuration.hs` to import the Stoa version.

### 4.3 The `coin.pact` VALID_CHAIN_IDS Constant

**Confidence: HIGH (95%)**

The existing Kadena `coin.pact` hardcodes:
```pact
(defconst VALID_CHAIN_IDS (map (int-to-str 10) (enumerate 0 19)))
```

This is used only for cross-chain transfer validation (`transfer-crosschain`). Since STOA replaces the entire coin contract, the new contract must use:
```pact
(defconst VALID_CHAIN_IDS (map (int-to-str 10) (enumerate 0 9)))
```

This is a change in the STOA `.pact` file, not in any Haskell code.

---

## 5. Haskell-Specific Patterns

### 5.1 Rule Data Type for Height-Indexed Config

**Confidence: HIGH (95%)**

The `Rule h a` type in `src/Chainweb/Utils/Rule.hs` is the core pattern for height-dependent behavior:
```haskell
data Rule h a = Above (h, a) (Rule h a) | Bottom (h, a)
```

For Stoa (a fresh chain with no history), all config uses the simple `Bottom` constructor:
```haskell
Bottom (minBound, value)
```

This means "this value applies from the beginning of time." No `Above` layers needed.

### 5.2 ChainMap for Per-Chain Config

The `ChainMap a` type supports two patterns:
- `AllChains a` -- same value for every chain
- `OnChains (HashMap ChainId a)` -- per-chain values

For Stoa, most config uses `AllChains` since all 10 chains behave identically, except genesis payloads which use `onChains` (chain 0 has a different payload than chains 1-9).

### 5.3 Lazy Lenses (Critical Pattern)

**Confidence: HIGH (90%)**

The `ChainwebVersion` record uses lazy lenses generated by:
```haskell
makeLensesWith (lensRules & generateLazyPatterns .~ True) 'ChainwebVersion
```

This is essential because test versions use a self-referential fixed-point pattern:
```haskell
buildTestVersion f = ... where v = f v
```

The version definition must NOT force fields during construction. All field access should go through lenses. This pattern is already established -- follow it exactly.

### 5.4 `-Wall -Werror` Compliance

All new Haskell files must:
- Use `ImportQualifiedPost` style imports
- Have no unused imports (will cause `-Wunused-imports` error)
- Have no incomplete pattern matches
- Handle all constructors in `tabulateHashMap` for `Fork` (the function iterates all forks)
- Export all defined symbols or explicitly suppress warnings

### 5.5 Genesis Payload Hash Verification

Each auto-generated payload module contains hash verification:
```haskell
payloadBlock
    | actualHash == expectedHash = payload
    | otherwise = error "inconsistent genesis payload detected..."
```

This means regenerating payloads (via the Ea tool) will change the expected hash. The Haskell code must import the regenerated module. The hash verification is a compile-time guarantee that the payload data has not been corrupted.

---

## 6. Complete File Inventory

### Files to CREATE

| File | Purpose |
|------|---------|
| `src/Chainweb/Version/Stoa.hs` | Stoa version definition (chain graph, gas, genesis) |
| `pact/stoa-coin/stoa-coin.pact` | STOA coin contract (bundled interfaces + coin + UR-STOA + vault) |
| `pact/stoa-coin/load-stoa-coin.yaml` | YAML loader for stoa-coin.pact |
| `pact/genesis/stoa/keysets.yaml` | 7 Stoa Master keyset definitions |
| `pact/genesis/stoa/grants0.yaml` | Chain 0 genesis grants + InitialiseStoaChain call |
| `pact/genesis/stoa/grantsN.yaml` | Chains 1-9 genesis grants |
| `src/Chainweb/BlockHeader/Genesis/Stoa0Payload.hs` | Auto-generated by Ea tool |
| `src/Chainweb/BlockHeader/Genesis/Stoa1to9Payload.hs` | Auto-generated by Ea tool |

### Files to MODIFY

| File | Change |
|------|--------|
| `src/Chainweb/Version/Registry.hs` | Add Stoa to knownVersions, import |
| `src/Chainweb/Chainweb/Configuration.hs` | Change `_configBlockGasLimit` default to 400,000; import Stoa version |
| `cwtools/ea/Ea/Genesis.hs` | Add stoaChain0, stoaChainN genesis entries |
| `cwtools/ea/Ea.hs` | Add `stoa = mkPayloads [stoaChain0, stoaChainN]` to main |
| `chainweb.cabal` | Add new source files to exposed-modules |

### Files to NOT MODIFY

| File | Reason |
|------|--------|
| `src/Chainweb/Graph.hs` | Petersen graph already exists |
| `src/Chainweb/Version.hs` | Core type definitions are correct |
| `src/Chainweb/Version/Guards.hs` | Gas limit enforcement is correct |
| `src/Chainweb/BlockHeader/Internal.hs` | Header serialization is graph-agnostic |
| `src/Chainweb/Pact/PactService.hs` | Gas limit flow is correct |
| `src/Chainweb/Pact/Types.hs` | Test defaults are independent |
| `src/Chainweb/MinerReward.hs` | Reward calculation is version-independent |
| Any existing `*Payload.hs` genesis files | They are for other versions |
| Any existing version files (Mainnet, Testnet, Development) | They are for other networks |

---

## 7. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Bundled Pact file too large for genesis | Low | High | Split into multiple YAML transactions if needed |
| Pact4 vs Pact5 genesis execution mismatch | Low | High | Stoa starts with all forks at genesis; test with Ea tool first |
| Version code collision | Very Low | High | Use a code (e.g., 0x00000010) not used by mainnet (0x05), testnet (0x07), devnet (0x02), recapdev (0x04) |
| _configBlockGasLimit change affects other versions | Medium | Medium | The default only applies when no `--block-gas-limit` CLI flag is set. Consider making this version-conditional instead |
| Header size mismatch at different graph degree | N/A | N/A | Both Petersen and Twenty are degree 3; this is not a risk |

### Recommendation on _configBlockGasLimit

**Confidence: MEDIUM (70%)**

Rather than changing the global default in `Configuration.hs` (which affects all versions), consider making the default gas limit version-dependent. The cleanest approach: set `_versionMaxBlockGasLimit = Bottom (minBound, Just 500_000)` in the version, and have operators use `--block-gas-limit 400000` in their node config. This avoids modifying shared configuration code.

Alternatively, change the default only when the configured version is Stoa:
```haskell
defaultChainwebConfiguration v = ...
    { _configBlockGasLimit = case v of
        Stoa -> 400_000
        _ -> 150_000
    ...
    }
```

This approach is safer because it does not change behavior for any other version.

---

## 8. Execution Order (Dependency Chain)

1. **Write STOA coin contract** (`stoa-coin.pact`) -- no Haskell dependencies
2. **Write genesis YAML files** (keysets, grants) -- depends on coin contract design
3. **Create `src/Chainweb/Version/Stoa.hs`** -- depends on knowing chain graph, gas limits, genesis time
4. **Add genesis entries to `cwtools/ea/Ea/Genesis.hs`** -- depends on YAML files and version definition
5. **Add Ea invocation to `cwtools/ea/Ea.hs`** -- depends on genesis entries
6. **Run Ea tool** to generate `Stoa0Payload.hs` and `Stoa1to9Payload.hs` -- depends on all Pact and YAML files
7. **Update `chainweb.cabal`** to include new modules
8. **Register version** in `Registry.hs` and `Configuration.hs`
9. **Build and test**: `cabal build chainweb-node`

Steps 1-2 are pure Pact/YAML work with no Haskell compilation needed.
Steps 3-5 are Haskell edits but cannot be compiled until step 6 produces the payload modules.
Step 6 requires the Ea tool to compile and run successfully.

---

*Research completed: 2026-02-10*
*Sources: Direct codebase analysis of stoa-chain (Chainweb v2.32.0 fork)*
