# Pitfalls Analysis: Stoa Chain Fork Modifications

**Research Date:** 2026-02-10
**Domain:** Chainweb blockchain fork -- chain topology, genesis contracts, gas parameters
**Codebase:** Stoa Chain (forked from Kadena Chainweb Node v2.32.0, Haskell/GHC 9.10)

---

## P1: Hardcoded `"coin"` Module Name in Pact Execution Engine

**Severity:** Critical -- will cause immediate node crash on block creation
**Relevant Changes:** Replace coin.pact with STOA contract

### Description

The Pact4 and Pact5 transaction execution engines have `ModuleName "coin" Nothing` hardcoded in at least 8 locations across two files. These references control:

- **Gas buying/selling** (`coin.GAS` capability) -- `src/Chainweb/Pact4/TransactionExec.hs:1144`, `src/Chainweb/Pact5/TransactionExec.hs:145`
- **Coinbase minting** (`coin.COINBASE`, `coin.GENESIS` capabilities) -- `src/Chainweb/Pact5/TransactionExec.hs:586-587`
- **Module admin for upgrades** (`coin` module admin capability) -- `src/Chainweb/Pact4/TransactionExec.hs:819`, `src/Chainweb/Pact5/TransactionExec.hs:706-707`
- **All magic cap construction** (`mkCoinCap` helper) -- `src/Chainweb/Pact4/TransactionExec.hs:1470-1474`
- **Remediation capability** -- `src/Chainweb/Pact5/TransactionExec.hs:706`

If the STOA coin contract is deployed under any module name other than `"coin"`, every single block will fail because the Haskell node will look for capabilities in a non-existent module.

### Warning Signs

- Node boots from genesis but immediately fails to produce block at height 1
- Error messages referencing `coin.GAS`, `coin.COINBASE`, or `coin.GENESIS` capability not found
- Transaction validation rejects all transactions (gas purchase fails)

### Prevention Strategy

The STOA contract **must** be deployed as a module named `"coin"` (i.e., `(module coin GOVERNANCE ...)` in Pact). This is a hard constraint. If the contract uses a different name like `"stoa"`, all 8+ hardcoded references must be updated in both `Pact4/TransactionExec.hs` and `Pact5/TransactionExec.hs`. Since the project philosophy is "minimal changes," the simplest path is to keep the module name as `coin` in the Pact contract itself.

### Phase

Must be resolved **before** genesis payload generation. The contract's module name is baked into the genesis payload hash at compile time.

---

## P2: Petersen Graph is the Only 10-Chain Graph, but it Has Degree 3

**Severity:** Critical -- determines header serialization size, cut validation, SPV proofs
**Relevant Changes:** Reduce from 20 to 10 chains

### Description

The codebase already defines the Petersen graph as a 10-node, degree-3 graph (`src/Chainweb/Graph.hs:343-344`). The current Kadena mainnet used Petersen for its first 10 chains before expanding to 20 with the Twenty graph (also degree 3). Using Petersen for a 10-chain Stoa network is the only viable 10-node graph already in the codebase.

However, there are several hidden dependencies on graph structure:

1. **Header serialization size** depends on `degree` of the graph. Formula: `_versionHeaderBaseSizeBytes + 36 * degree + 2` (from `src/Chainweb/BlockHeader/Internal.hs:1258`). Petersen has degree 3, same as Twenty, so the base size calculation (`318 - 110 = 208`) remains the same. **This is safe only if `_versionHeaderBaseSizeBytes` stays at `208`.**

2. **Adjacent hashes in block headers** are computed from the graph. Each block header stores hashes of its adjacent chains' latest blocks. The `blockHashRecordFromVector` function reconstructs these from the adjacency structure. A mismatch causes deserialization failures.

3. **Cut validation** (`src/Chainweb/Cut.hs:665-687`) uses `isMonotonicCutExtension` which checks braiding by looking up adjacent chain hashes. The graph must be consistent between version definition and genesis block headers.

4. **Miner reward calculation** divides the total reward by `order` (number of chains) of the graph: `divideStu s n` where `n = order $ chainGraphAt v h` (`src/Chainweb/MinerReward.hs:186`). Going from 20 to 10 chains **doubles the per-block miner reward** since the same CSV reward table is divided by 10 instead of 20.

### Warning Signs

- Block header deserialization errors ("inconsistent block header size")
- Cut validation failures ("missing adjacent parent")
- Miner reward is unexpectedly 2x the intended amount per block

### Prevention Strategy

1. Use `petersenChainGraph` directly -- it is already defined and validated
2. Set `_versionGraphs = Bottom (minBound, petersenChainGraph)` (no graph transitions needed for a new chain)
3. Explicitly verify that the per-block reward is acceptable at 2x the per-chain rate (or modify the rewards CSV/table if STOA has its own emission schedule)
4. Ensure genesis payloads are generated only for chains 0-9 (no chains 10-19)
5. Update `_genesisBlockPayload`, `_genesisBlockTarget`, and `_genesisTime` in the version definition to use `OnChains` with only chain IDs 0-9

### Phase

Chain graph selection must be finalized **before** version definition and genesis payload generation. The reward doubling decision must be addressed during tokenomics design.

---

## P3: ChainMap AllChains vs OnChains Mismatch for 10-Chain Version

**Severity:** Critical -- version registration will crash at node startup
**Relevant Changes:** Reduce from 20 to 10 chains

### Description

The `ChainMap` type (`src/Chainweb/ChainId.hs:281`) has two constructors:

- `AllChains a` -- applies to every chain in the version's graph
- `OnChains (HashMap ChainId a)` -- explicit per-chain values

The version registry's `validateVersion` function (`src/Chainweb/Version/Registry.hs:85-108`) performs strict validation at startup:

```haskell
hasAllChains (OnChains m) = HS.fromMap (void m) == chainIds v
```

This means if you use `OnChains` anywhere, it **must** contain entries for exactly the chains in the graph (chains 0-9 for Petersen). If any `OnChains` map contains chain IDs 10-19 (from copy-pasting Mainnet code), or is missing any chain 0-9, the node will crash at startup with "version does not have heights for all forks."

Similarly, `_genesisBlockPayload` must have entries for all 10 chains and only those 10 chains.

### Warning Signs

- Node crashes immediately at startup with `validateVersion` error
- Error: "genesis data is missing for some chains"
- Error: "version is missing fork heights for some forks on some chains"

### Prevention Strategy

1. Prefer `AllChains` over `OnChains` everywhere possible (it auto-covers all chains in the graph)
2. When `OnChains` is necessary (e.g., different genesis payloads for chain 0 vs chains 1-9), enumerate exactly chains 0-9:
   ```haskell
   onChains $ [(unsafeChainId 0, chain0Payload)]
           <> [(unsafeChainId i, chainNPayload) | i <- [1..9]]
   ```
3. Search the entire version definition for any hardcoded chain ID ranges and update them
4. Run `registerVersion` (which calls `validateVersion`) as the first integration test

### Phase

Must be validated during version definition authoring. Caught at compile time only if using wrong types; runtime crash at startup otherwise.

---

## P4: Genesis Payload Hash is Computed at Compile Time and is Immutable

**Severity:** Critical -- any contract change invalidates the payload hash
**Relevant Changes:** Replace coin.pact with STOA contract, new genesis transactions

### Description

Genesis payloads are generated by the `ea` tool (`cwtools/ea/Ea.hs`) which:

1. Takes YAML transaction definitions and Pact contract files
2. Executes them against a temporary Pact database
3. Computes a `PayloadWithOutputs` including a `BlockPayloadHash`
4. Generates a Haskell source file containing the serialized payload and its hash
5. The generated module includes a runtime consistency check:
   ```haskell
   | actualHash == expectedHash = payload
   | otherwise = error "inconsistent genesis payload detected. THIS IS A BUG"
   ```

This means:

- The genesis payload is a **Haskell source file** compiled into the binary
- If the STOA contract changes in any way after genesis generation, the hash will not match
- The `ea` tool currently only generates Pact4 transactions (`mkChainwebTxs` uses `Pact4.UnparsedTransaction`). If the STOA contract needs Pact5 features, the `ea` tool must be modified.
- The `ea` tool's `genPayloadModule` runs the Pact service with `testPactServiceConfig`, which has `testBlockGasLimit = 100000` (`src/Chainweb/Pact/Types.hs:595`). If the STOA genesis contract requires more gas than 100k, genesis payload generation will fail silently or produce partial results.

### Warning Signs

- `ea` tool crashes during genesis generation with "Invalid genesis txs"
- `ea` tool succeeds but node crashes at startup with "inconsistent genesis payload detected"
- Genesis contract partially executes (some tables created, others missing)

### Prevention Strategy

1. **Verify the STOA contract works in isolation first** using `pact` REPL before integrating with `ea`
2. Genesis gas limit in `ea` is effectively unlimited for Pact5 path (`GasLimit 999_999_999`) but may be constrained for Pact4 path
3. If the contract requires more gas than `testBlockGasLimit`, update the gas limit in the `ea` tool or ensure the Pact5 genesis path is used
4. After modifying the contract, **always regenerate** the genesis payload Haskell modules by running `ea`
5. Never manually edit the generated `*Payload.hs` files
6. Compile and test immediately after regeneration -- the hash check will catch inconsistencies

### Phase

Genesis payload generation is a prerequisite for all testing. Contract must be finalized and verified **before** running `ea`. Any subsequent contract change requires re-running `ea` and recompiling.

---

## P5: STOA Contract Bundled Interfaces May Exceed Genesis Gas Budget

**Severity:** High -- genesis will fail to fully initialize
**Relevant Changes:** Replace coin.pact with STOA contract (bundled interfaces)

### Description

The STOA contract bundles multiple interfaces (fungible-v2, fungible-xchain-v1, gas-payer-v1, StoaFungibleV1) in one file, plus the coin module itself with new tables (LocalSupply/UR, StoaTable/URV, UrStoaVault). The original Kadena genesis loads these interfaces as separate YAML transactions in a specific order:

```
txs = cc <> toList ns <> toList k <> toList a <> toList c
```

Where `cc` is the coin contract files (often 2-3 separate files: `fungibleAssetV1`, `coinContractV1`, `gasPayer`).

Loading everything in one transaction has implications:

1. **Gas consumption**: A single large Pact transaction deploying all interfaces + module + tables will consume significantly more gas than the original multi-transaction approach
2. **Transaction ordering**: The `ea` tool loads transactions in the order: coin contract files, then namespaces, then keysets, then allocations, then coinbase. If STOA needs keysets defined *before* the coin module (for the 7 Stoa Master keysets referenced in the module governance), the order must be reversed.
3. **Module cache**: The genesis code path uses `installCoinModuleAdmin` which specifically enables `coin` module admin. If the contract bundles other modules, those need admin capabilities too, or they must be deployed in the correct Pact namespace.

### Warning Signs

- Genesis payload generation (`ea`) fails with gas limit exceeded
- Genesis succeeds but keyset references fail ("keyset not found")
- Chain 0 initialization (`A_InitialiseStoaChain`) fails because it runs before table creation

### Prevention Strategy

1. Test the STOA contract in a Pact REPL with gas metering enabled to determine actual gas requirements
2. Structure genesis transactions so keysets are defined **before** the module that references them
3. The `ea` tool's `Genesis` record has explicit fields for `_keysets`, `_coinContract`, `_namespaces`, `_allocations`, and `_coinbase`. Ensure the STOA genesis uses the correct order.
4. For chain 0 special initialization, either include it as a separate YAML transaction after the coin contract, or include it in the contract's init logic
5. Consider whether the initialization function needs its own gas budget (separate transaction)

### Phase

Must be tested during contract development, **before** genesis payload generation.

---

## P6: Gas Limit Configuration Has Three Independent Control Points

**Severity:** High -- inconsistent values cause transaction rejection or silent cap
**Relevant Changes:** Increase gas limits (400k default, 500k max)

### Description

The block gas limit is controlled by three independent mechanisms that must be coordinated:

1. **`_versionMaxBlockGasLimit`** in `ChainwebVersion` (`src/Chainweb/Version.hs:492`): A `Rule BlockHeight (Maybe Natural)` that sets the **maximum** allowed gas limit for the version. `Nothing` means no maximum. This is checked at block execution time via `maxBlockGasLimit` (`src/Chainweb/Version/Guards.hs:300`).

2. **`_configBlockGasLimit`** in `ChainwebConfiguration` (`src/Chainweb/Chainweb/Configuration.hs:390`): The operator-configured gas limit, defaults to `150_000` (`src/Chainweb/Chainweb/Configuration.hs:455`). This is the value used in practice.

3. **Startup clamping logic** in `src/Chainweb/Chainweb.hs:402-442`:
   ```haskell
   let maxGasLimit = fromIntegral <$> maxBlockGasLimit v maxBound
   ... _pactNewBlockGasLimit = maybe id min maxGasLimit (_configBlockGasLimit conf)
   ```
   The actual gas limit is `min(configBlockGasLimit, versionMaxBlockGasLimit)`.

If you set `_configBlockGasLimit` to 400k but `_versionMaxBlockGasLimit` is still 180k (from Mainnet), the actual limit will be clamped to 180k with no warning.

Additionally, mempool validation (`src/Chainweb/Pact4/Validations.hs:103`) checks individual transaction gas limits against the block gas limit. Transactions requesting more gas than the block gas limit are rejected.

### Warning Signs

- Transactions with gas limit > 180k are rejected even after config change
- Block creation stops when remaining gas < individual transaction gas limit
- No explicit error about clamping -- the `min` silently takes the lower value

### Prevention Strategy

1. Set `_versionMaxBlockGasLimit` to `Just 500_000` (or `Nothing` for no cap) in the Stoa version definition
2. Set `_configBlockGasLimit` default to `400_000` in the configuration
3. Ensure the version's `_versionMaxBlockGasLimit >= _configBlockGasLimit` at all heights
4. Verify with a test: submit a transaction with gas limit 400k and confirm it is accepted by mempool validation
5. Consider whether `testBlockGasLimit` (currently `100_000` in `src/Chainweb/Pact/Types.hs:595`) needs to be updated for tests

### Phase

Gas limits should be set in the version definition during the same phase as chain graph and genesis. The configuration default can be changed independently but should be coordinated.

---

## P7: Miner Reward Table is Embedded at Compile Time with SHA512 Hash Check

**Severity:** High -- custom tokenomics requires either new CSV or table bypass
**Relevant Changes:** STOA tokenomics (16M genesis, declining emissions)

### Description

The miner reward schedule is loaded from an embedded CSV file (`rewards/miner_rewards.csv`) via Template Haskell (`src/Chainweb/MinerReward.hs:261`). The file is:

1. Embedded at compile time using `$(embedFile "rewards/miner_rewards.csv")`
2. Verified against a hardcoded SHA512 hash (`expectedRawMinerRewardsHash` and `expectedMinerRewardsHash`)
3. Parsed into a `Map BlockHeight Stu` (STU = smallest unit of KDA, 1e12 per KDA)

The `blockMinerReward` function divides the table value by the number of chains: `divideStu s n` where `n = order $ chainGraphAt v h`.

If STOA has its own emission schedule (16M genesis supply, declining yearly), you have two options:

- **Option A**: Replace `rewards/miner_rewards.csv` with STOA's emission table. This requires updating both `expectedRawMinerRewardsHash` and `expectedMinerRewardsHash` constants.
- **Option B**: Override `blockMinerReward` to compute STOA emissions dynamically. But this function is called from `Pact4/ExecBlock.hs:615` and `Pact5/ExecBlock.hs:103`, so changes propagate.

Critical detail: the reward is specified as the **total across all chains** at a given block height, then divided by chain count. With 10 chains instead of 20, each chain gets 2x the original per-block reward from the same table.

### Warning Signs

- Compile failure: "hash of miner rewards table does not match expected value"
- Node produces blocks but miner reward is wrong (2x too high or unexpected amount)
- Reward calculation produces 0 for block heights beyond the table's last entry

### Prevention Strategy

1. Generate a new `miner_rewards.csv` encoding STOA's emission schedule (total reward per 3-month period across all 10 chains)
2. Update both hash constants after generating the new CSV
3. Verify that `divideStu` by 10 produces the expected per-block reward at key block heights
4. Write a unit test that checks reward values at genesis, year 1, year 10, and the final entry

### Phase

Tokenomics/reward table must be finalized before compilation. Hash verification means the CSV must be exactly right.

---

## P8: SPV Cross-Chain Proofs Depend on Chain Graph Adjacency

**Severity:** Medium -- cross-chain transfers fail if topology assumptions are broken
**Relevant Changes:** Reduce from 20 to 10 chains

### Description

SPV (Simple Payment Verification) proofs allow cross-chain transactions by proving that a transaction occurred on one chain and was included in a cut visible to another chain. The proof system (`src/Chainweb/SPV/CreateProof.hs`) traverses the chain graph's adjacency structure to find proof paths.

Key dependency: `shortestPath` in `ChainGraph` (`src/Chainweb/Graph.hs:261-264`) computes the path between two chains. For the Petersen graph (diameter 2), any two chains are at most 2 hops apart. For the Twenty graph (diameter 3), it's 3 hops.

With 10 chains using Petersen, SPV proof depth is shorter (max 2 vs 3), which is actually better. However:

1. Existing SPV test vectors may hardcode chain IDs 10-19 which won't exist
2. The `OutputProof` module (`src/Chainweb/SPV/OutputProof.hs`) constructs proofs referencing specific chain IDs in the cut
3. If any test or configuration references chains 10-19, it will fail at runtime with `ChainNotInChainGraphException`

### Warning Signs

- SPV proof creation fails with "chain not in chain graph"
- Cross-chain transfers that reference non-existent target chains fail silently
- Test vectors that reference chains > 9 cause test failures

### Prevention Strategy

1. Grep the entire codebase for hardcoded chain IDs > 9 (e.g., `unsafeChainId 10`, `ChainId 19`, ranges `[10..19]`)
2. Update all test vectors and golden files that reference chains 10-19
3. Verify SPV proof creation between all pairs of chains 0-9 in integration tests
4. The Petersen graph diameter (2) means proofs are at most 2 hops -- test this explicitly

### Phase

SPV testing should be part of integration testing after chain graph change. Golden file updates may be needed.

---

## P9: Fork Heights and Version Upgrades Must All Be Set to `ForkAtGenesis`

**Severity:** High -- incorrect fork schedule causes Pact execution divergence
**Relevant Changes:** New version definition for Stoa

### Description

The `ChainwebVersion` structure requires `_versionForks` to contain entries for **every** `Fork` constructor (from `SlowEpoch` through `Chainweb232Pact`). The `validateVersion` function checks:

```haskell
HS.fromMap (void $ _versionForks v) == HS.fromList [minBound :: Fork .. maxBound :: Fork]
```

For a new genesis chain, all forks should be set to `ForkAtGenesis` (active from the start), since there is no historical chain to maintain compatibility with. However, this has subtle implications:

1. **Pact5Fork at genesis** means the chain starts with Pact 5 execution from block 0. The genesis payload generation in `ea` has separate code paths for Pact4 and Pact5. Ensure the correct path is used.
2. **Coin upgrade forks** (CoinV2, Pact4Coin3, Chainweb214Pact, etc.) trigger upgrade transactions at their fork heights. If set to `ForkAtGenesis`, the `indexByForkHeights` function will try to schedule upgrades at height 0, which conflicts with genesis. These upgrades should either:
   - Have their upgrade transactions removed (since STOA deploys the final contract version at genesis)
   - Have their entries in `_versionUpgrades` be empty
3. **`_versionUpgrades` must not have empty upgrade lists**. The validator checks: `any (any isUpgradeEmpty) (_versionUpgrades v)`. If you map a fork to an empty transaction list, validation fails.

### Warning Signs

- "errors encountered validating version" at startup
- "some pact upgrade has no transactions" error
- Wrong Pact version used for genesis execution (Pact4 instead of Pact5 or vice versa)
- Upgrade transactions from KDA coin versions running against STOA genesis state

### Prevention Strategy

1. Set all forks to `ForkAtGenesis` using `_ -> AllChains ForkAtGenesis` (see `Development.hs:35` as reference)
2. Set `_versionUpgrades = AllChains mempty` (no upgrade transactions needed since everything is at genesis)
3. Decide whether Pact4 or Pact5 is the execution engine at genesis. If Pact5, ensure the genesis payload is compatible.
4. The `Development` version (`src/Chainweb/Version/Development.hs`) is the best template to follow

### Phase

Version definition is an early phase task that blocks genesis payload generation.

---

## P10: `-Wall -Werror` Will Catch Unused Imports But Not Logic Errors

**Severity:** Medium -- false confidence from "it compiles"
**Relevant Changes:** All modifications

### Description

The codebase compiles with `-Wall -Werror -Wcompat`, which means:

1. **Incomplete pattern matches** are compile errors. If you add a new `ChainwebVersion` or `KnownGraph` variant, every pattern match must be updated. Missing any causes a compile error.
2. **Unused imports** are errors. Removing chain-specific genesis imports (e.g., `Mainnet10to19Payload`) without removing their import lines will cause compile failure.
3. **Unused variables** are errors. Removing code that references chain IDs 10-19 may leave unused variable warnings.

However, `-Wall -Werror` gives **no protection** against:

- Correct types but wrong values (e.g., gas limit set to 180k instead of 500k)
- Correct chain IDs but wrong genesis payloads mapped to them
- Hash mismatches that only show at runtime
- Cross-chain topology correctness (a graph can pass `validChainGraph` but have wrong properties)

### Warning Signs

- Builds pass but node fails at runtime with hash mismatches or version validation errors
- Tests pass but values are incorrect (e.g., wrong miner reward)

### Prevention Strategy

1. Don't trust "it compiles" as proof of correctness
2. Add property-based tests for:
   - Genesis payload hashes match version definition
   - Miner rewards at expected block heights
   - All chain IDs in version are present in graph
   - Gas limits are correctly propagated from version to execution
3. Run the existing test suites after every change -- many tests will need chain graph updates

### Phase

Testing should be continuous throughout all modification phases. Add Stoa-specific tests early.

---

## P11: Version Registration is Global Mutable State

**Severity:** Medium -- test isolation failures and startup order bugs
**Relevant Changes:** Adding a new Stoa version

### Description

The `versionMap` in `src/Chainweb/Version/Registry.hs:56-59` is a global `IORef` initialized with `unsafePerformIO`. Only `mainnet` and `testnet04` are registered by default. All other versions must be explicitly registered via `registerVersion` before use.

Key implications for Stoa:

1. If the Stoa version is based on modifying an existing version (e.g., Development), it must either replace that version in the registry or have a unique `ChainwebVersionCode`
2. Two versions with the same `ChainwebVersionCode` but different definitions will cause `registerVersion` to throw "conflicting version registered already"
3. `lookupVersionByCode` has fast paths for mainnet and testnet04 codes. If Stoa reuses one of these codes, it will always get the original version.
4. Tests that register versions can conflict with each other if run in parallel

### Warning Signs

- "conflicting version registered already" at startup
- Version lookup returns mainnet or testnet04 properties instead of Stoa
- Tests fail non-deterministically due to global state pollution

### Prevention Strategy

1. Assign a unique `ChainwebVersionCode` for Stoa (e.g., `0x00000010`)
2. Assign a unique `ChainwebVersionName` (e.g., `ChainwebVersionName "stoa"`)
3. Register the version in `knownVersions` list (line 166) and in the `versionMap` initializer
4. Add the Stoa version to `findKnownVersion`'s error message for discovery
5. Consider whether to keep mainnet/testnet04 in the registry or remove them

### Phase

Version code and name assignment is an early decision that affects all subsequent work.

---

## P12: Block Header Base Size Constant Must Match Actual Serialization

**Severity:** High -- wrong size causes mining failures and deserialization errors
**Relevant Changes:** Chain graph topology change

### Description

The `_versionHeaderBaseSizeBytes` field is set to `318 - 110 = 208` for both Mainnet and Development versions. The actual header size is computed as:

```haskell
headerSizes v = (\g -> _versionHeaderBaseSizeBytes v + 36 * degree g + 2) <$> _versionGraphs v
```

For Petersen (degree 3): `208 + 36 * 3 + 2 = 318 bytes`
For Twenty (degree 3): `208 + 36 * 3 + 2 = 318 bytes` (same degree)

Since both Petersen and Twenty are degree-3 graphs, the header size happens to be the same. **This is fortunate but coincidental.** If a different graph were chosen (e.g., Triangle with degree 2), the header size would be different and mining would break.

The `workSizeBytes` function (`src/Chainweb/BlockHeader/Internal.hs:1300`) computes the PoW work bytes as `headerSizeBytes - 32`. This is used by miners to know how much data to hash.

### Warning Signs

- Mining produces invalid blocks (wrong nonce position in header bytes)
- "inconsistent block header size" during deserialization
- PoW difficulty computation produces wrong results

### Prevention Strategy

1. Since Petersen is degree-3 (same as Twenty), `_versionHeaderBaseSizeBytes = 208` is correct. **Do not change this value.**
2. If you ever consider a non-degree-3 graph, this value and all dependent calculations must be updated
3. Add a test that computes `headerSizeBytes` for the Stoa version and verifies it matches expectations
4. Verify that the genesis block header serialization roundtrips correctly

### Phase

This is automatically correct if using Petersen graph. Only a risk if the graph choice changes.

---

## P13: The `ea` Tool Only Generates Pact4 Genesis Transactions

**Severity:** High -- STOA may need Pact5 features in genesis
**Relevant Changes:** Replace coin.pact with STOA contract

### Description

The `ea` tool in `cwtools/ea/Ea.hs` processes genesis transactions through the `mkChainwebTxs` function which produces `[Pact4.UnparsedTransaction]`. The `execNewGenesisBlock` function in `src/Chainweb/Pact/PactService.hs:579-638` has two code paths:

- **Pact4 path** (lines 585-600): Parses and executes Pact4 transactions
- **Pact5 path** (lines 601-634): Wraps Pact4 transactions as a mempool access function, processes through Pact5 execution

The genesis block execution path depends on which Pact version is active at genesis. If `Pact5Fork` is set to `ForkAtGenesis`, the Pact5 path is used, which:

1. Still accepts `Pact4.UnparsedTransaction` input (converted internally)
2. Uses `GasLimit 999_999_999` (effectively unlimited gas)
3. Does **not** use precompiled coinbase

If the STOA contract uses Pact5-only syntax or features, the Pact4 parsing step in `ea` will fail because `mkChainwebTxs` calls `Pact4.mkPayloadWithTextOldUnparsed`.

### Warning Signs

- `ea` fails with Pact parse error when processing STOA contract
- Genesis block validates but contract has unexpected behavior due to Pact version mismatch
- Tables or functions defined with Pact5-only features are missing after genesis

### Prevention Strategy

1. Write the STOA contract in Pact 4 syntax (which is forward-compatible with Pact 5)
2. If Pact5-only features are needed, modify the `ea` tool to generate Pact5 transactions
3. Test genesis execution with both the `ea` tool and a manual local node boot
4. Verify all tables and functions are present after genesis by querying the Pact database

### Phase

Contract language compatibility must be determined during contract development, before genesis generation.

---

## P14: Chain 0 Special Initialization Creates Asymmetric State

**Severity:** Medium -- cross-chain operations may fail if state assumptions differ
**Relevant Changes:** Chain 0 initialization (STOA + URSTOA + Vault)

### Description

The plan calls for chain 0 to have special initialization: full STOA + URSTOA + staking vault, while chains 1-9 have only the coin module. This creates an asymmetric state where:

1. **Different genesis payloads**: Chain 0 has additional tables and initialization data not present on chains 1-9
2. **Cross-chain SPV proofs**: If a transaction on chain 0 references URSTOA tables that don't exist on chain 5, cross-chain transfers involving those tables will fail
3. **Genesis payload hash uniqueness**: The `ea` tool uses `the` to verify all chains in a `ChainIdRange` produce the same payload hash. Chain 0 **must** be generated separately (its own `ChainIdRange`) from chains 1-9, or `the` will crash with "fromList: nonunique" error

The existing codebase handles this correctly for Kadena (chain 0 has unique allocations, chains 1-9 share payloads, chains 10-19 share a different payload). Follow the same pattern.

### Warning Signs

- `ea` crashes with "fromList: nonunique" when generating payloads
- Cross-chain transfer from chain 0 fails because target chain lacks required tables
- URSTOA operations on non-chain-0 fail with "table not found"

### Prevention Strategy

1. Create separate `Genesis` records for chain 0 and chains 1-9 (following `mainnet0`/`mainnetN` pattern)
2. Chain 0 genesis: keysets + namespaces + coin contract + URSTOA initialization
3. Chains 1-9 genesis: keysets + namespaces + coin contract only
4. Ensure cross-chain operations (SPV proofs, `defpact` continuations) only reference tables that exist on the target chain
5. Document which operations are chain-0-only in the STOA contract

### Phase

Contract architecture and genesis structure must be designed together during contract development.

---

## P15: Unverified STOA Contract is the Highest-Risk Single Point of Failure

**Severity:** Critical -- unverified contract can silently break gas, coinbase, or transfers
**Relevant Changes:** Replace coin.pact with STOA contract

### Description

The project context explicitly states: "the new coin contract has NOT been verified as working yet." The coin contract is the most critical piece of the blockchain -- every single block execution depends on it for:

1. **Gas buying and selling** (fund-tx defpact)
2. **Coinbase rewards** (coin.coinbase function)
3. **Token transfers** (coin.transfer, coin.transfer-crosschain)
4. **Account creation** (coin.create-account)
5. **Balance queries** (coin.get-balance, coin.details)

The Haskell node hardcodes calls to specific functions in the coin module:

- `coin.COINBASE` capability (Pact5: `src/Chainweb/Pact5/TransactionExec.hs:587`)
- `coin.GENESIS` capability (Pact5: `src/Chainweb/Pact5/TransactionExec.hs:586`)
- `coin.GAS` capability (Pact4: `src/Chainweb/Pact4/TransactionExec.hs:1144`)
- `coin.fund-tx` defpact (gas payment flow)
- `coin.redeem-gas` (gas redemption)

If **any** of these functions/capabilities are missing, renamed, or have different signatures in the STOA contract, the chain will halt.

### Warning Signs

- This is a pre-deployment risk. No warning signs exist until testing.
- The first sign would be genesis block creation failure or block 1 execution failure

### Prevention Strategy

1. **Verify the STOA contract before any other work**. This is the critical path item.
2. Create a comprehensive Pact REPL test file that exercises:
   - Module deployment (including all bundled interfaces)
   - `coinbase` function with correct capability
   - `fund-tx` defpact (gas payment flow start and continuation)
   - `transfer` and `transfer-crosschain` functions
   - `create-account` and `get-balance`
   - Table creation (LocalSupply, StoaTable, UrStoaVault)
   - Governance keyset operations
3. Compare the STOA contract's function signatures against the hardcoded Haskell references
4. Run the contract through the Pact gas meter to verify gas consumption
5. Test with the `ea` tool as early as possible

### Phase

Contract verification **must be the first phase** before any other modification work begins. All other changes depend on this.

---

## P16: Bootstrap Nodes and P2P Configuration for a New Network

**Severity:** Low at development time, Critical at launch
**Relevant Changes:** All (new network)

### Description

The version definition includes `_versionBootstraps` which lists bootstrap peer addresses. Mainnet has specific bootstrap hosts (`src/P2P/BootstrapNodes.hs`). For development, this can be an empty list (like `Development` version), but for production:

1. At least one bootstrap node must be running and reachable
2. The `PeerInfo` includes an optional `PeerId` (TLS certificate fingerprint)
3. `_disablePeerValidation` in `VersionDefaults` must be `True` during development or peers will be rejected

### Warning Signs

- Nodes can't discover each other
- "peer validation failed" errors in logs

### Prevention Strategy

1. Start with `_versionBootstraps = []` and `_disablePeerValidation = True` during development
2. Set up bootstrap infrastructure before production launch
3. Generate proper TLS certificates for bootstrap nodes

### Phase

P2P configuration is a late-phase concern. Development can proceed with local networking.

---

## Summary: Phase Mapping

| Pitfall | Phase | Blocking? |
|---------|-------|-----------|
| P15: Unverified STOA contract | Phase 0: Contract verification | YES -- blocks all else |
| P1: Hardcoded "coin" module name | Phase 0: Contract verification | YES -- contract design constraint |
| P5: Bundled interfaces gas budget | Phase 0: Contract verification | YES -- determines genesis feasibility |
| P9: Fork heights and upgrades | Phase 1: Version definition | YES -- blocks genesis |
| P11: Version registration | Phase 1: Version definition | YES -- blocks genesis |
| P2: Petersen graph selection | Phase 1: Version definition | YES -- blocks genesis |
| P3: ChainMap chain ID mismatch | Phase 1: Version definition | YES -- blocks genesis |
| P6: Gas limit three control points | Phase 1: Version definition | YES -- affects validation |
| P12: Header base size constant | Phase 1: Version definition | NO -- correct if using Petersen |
| P7: Miner reward table hashes | Phase 2: Tokenomics integration | YES -- blocks compilation |
| P4: Genesis payload hash immutability | Phase 3: Genesis generation | YES -- blocks testing |
| P14: Chain 0 asymmetric state | Phase 3: Genesis generation | YES -- affects genesis structure |
| P13: ea tool Pact4-only generation | Phase 3: Genesis generation | MAYBE -- depends on contract syntax |
| P8: SPV cross-chain proofs | Phase 4: Integration testing | NO -- but must be validated |
| P10: -Wall -Werror false confidence | Phase 4: Integration testing | NO -- ongoing discipline |
| P16: Bootstrap nodes | Phase 5: Production deployment | NO during development |

---

*Pitfalls analysis: 2026-02-10*
