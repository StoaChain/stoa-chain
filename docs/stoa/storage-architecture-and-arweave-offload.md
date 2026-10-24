# StoaChain storage architecture, and the plan to offload history to Arweave

**Date:** 2026-10-23
**Status:** research complete, nothing implemented.
**Implementation spec:** [`phase1-height-range-exporter-spec.md`](phase1-height-range-exporter-spec.md)

---

## 0. The problem, and the answer in one page

**The problem.** A StoaChain node's database grows with every block. Today it is
~9.4 GB. Every node in the fleet holds a full copy, so 100 nodes at a
hypothetical 1 TB would mean 100 TB of duplicated storage. Kadena's answer is to
*prune* old history, which we rejected because pruning payloads makes old
cross-chain transfers impossible to complete — the funds strand.

**The proposal.** Instead of deleting history, upload it once to Arweave, pay
once, and have every node *reference* it rather than store it. Nodes keep what
they need to operate; cold history lives on the permaweb and is fetched on
demand.

**The answer.** It works, and better than expected — but not the way the question
was framed. Three findings reshape it:

1. **The database is two databases**, roughly 50/50 by size, with completely
   different properties. Only one of them is a candidate for remote storage.
2. **The other half is ~99% garbage.** Measured: chain 0's coin table holds
   1,246,355 rows describing **48 accounts**. It is not an offload target because
   it should simply be deleted — by a tool we already ship and have never run.
3. **The offloadable half is trustless to offload**, because every byte of it is
   hash-committed in a block header the node already holds. No fork, no consensus
   change, no protocol version bump.

**The realistic end state** is a node holding block headers, a compacted live
Pact state and a hot payload cache — a small fraction of the full chain — with
cold payloads on Arweave, and *no* stranded cross-chain transfers. The
cheapest, highest-leverage step available today requires no Arweave at all.

**Growth context, so this is sized honestly.** Measured 2026-10-02 → 2026-10-22:
8.2 GB → 9.4 GB, i.e. **~60 MB/day**, ~22 GB/year, about half of which is the
redundant Pact history. So irreducible growth is ~11 GB/year and 500 GB is two
decades away at current usage. There is **no urgency** on the Arweave
engineering. There is a good case for running compaction now, and for piloting
the upload while the dataset costs lunch money.

**For the node fleet there is a separate and immediate conclusion.** Section 6
is addressed to the AncientHoldings Hub: its single “blockchain size” figure
conflates the two stores and so roughly doubles the apparent size of the chain,
its backups capture a cache that never needed backing up, and a compaction
worker would halve both. None of that waits on Arweave or on any change to
chainweb.

---

## 1. How a chainweb node stores data

The node opens exactly two stores, laid out by
[`node/src/ChainwebNode.hs:164-168`](../../node/src/ChainwebNode.hs#L164):

```haskell
getRocksDbDir conf = (\base -> base </> "0" </> "rocksDb") <$> getDbBaseDir conf
getPactDbDir  conf = (\base -> base </> "0" </> "sqlite")  <$> getDbBaseDir conf
```

Measured on a production StoaChain node, 2026-10-22:

| | size | share |
|---|---|---|
| `data/0/` total | **9.3 GB** | 100% |
| `data/0/rocksDb` — the **Chain Archive** | **4.6 GB** | 49% |
| `data/0/sqlite` — the **State Cache** | **4.7 GB** | 51% |

and within the State Cache, one file per chain:

| file | size |
|---|---|
| `pact-v1-chain-0.sqlite` | 1.15 GB |
| `pact-v1-chain-1..9.sqlite` | ~424 MB each |

**Chain 0 is bigger because OuroNet runs on it.** Not because of the coin
contract, the namespaces or the gas stations — those are deployed on *every*
chain and cost the same everywhere. Chain 0 carries essentially all of the
network's activity. From the explorer at block 684,994:

| | chain 0 | each of chains 1–9 | chain 0's share |
|---|---|---|---|
| gas used | 666,205,533 | ~625,000 | **99.2%** of 671,828,226 |
| gas wasted | 9,832,264 | 0 | **100%** |
| fees paid | 7.045480 STOA | ~0.0076 STOA | ~925× |
| STOA held | 19,517,673 | ~13,850 | **99.4%** of supply |

and in the Pact state itself, comparing the two files:

| | chain 0 | chain 1 |
|---|---|---|
| file size | 993 MB | 369 MB |
| tables | **243** | 16 |
| OuroNet tables | **227**, holding 118,419 rows | **0** |
| `coin_coin-table` rows | 1,246,355 (≈ 2× per block) | 621,613 (≈ 1× per block) |
| `TransactionIndex` rows | 3,756 | **165** |

Two things follow. Chain 0 carries 227 OuroNet tables that simply do not exist
elsewhere, and its coin table accumulates about two rows per block — the miner
reward plus a gas payer — where the idle chains accumulate exactly one.

Note what chain 1 looks like all the same: **165 transactions in its entire
history, and 369 MB of SQLite.** Over three million rows of pure
miner-reward and supply bookkeeping on a chain nobody uses. That is the clearest
possible illustration of what the second half of this database actually is.

The 50/50 split is stable, not a coincidence: between the 2026-10-02 snapshot
(4.1 + 4.1 GB) and today (4.7 + 4.7 GB) both halves grew by the same 0.6 GB.

### 1.1 The Chain Archive — RocksDB — the block history

Contents: block headers, cut hashes, block payloads, block transactions, block
outputs, and the P2P peer database.

**Immutable.** The first 100,000 blocks look identical at height 500,000 and at
height 600,000. Nothing ever rewrites them.

**Content-addressed and height-keyed.** From
[`src/Chainweb/Payload/PayloadStore/RocksDB.hs`](../../src/Chainweb/Payload/PayloadStore/RocksDB.hs):

```haskell
newBlockPayloadStore      :: RocksDbTable (BlockHeight, BlockPayloadHash)      BlockPayload
newBlockTransactionsStore :: RocksDbTable (BlockHeight, BlockTransactionsHash) BlockTransactions
newBlockOutputsTbl        :: RocksDbTable (BlockHeight, BlockOutputsHash)      BlockOutputs
newBlockPayloadHeightsStore :: RocksDbTable BlockPayloadHash BlockHeight   -- reverse index
```

Headers are keyed by `RankedBlockHash` = (height, hash).

**A subtlety that matters for tooling.** `Chainweb.Ranked` encodes the height
**big-endian**, with an explicit comment — "big endian encoding for
lexicographical order" — so the *header* table's RocksDB byte order is numeric
height order, and a height range is one contiguous scan. The three payload
tables above use plain `encodeBlockHeight`, which is **little-endian**
([`BlockHeight.hs:79`](../../src/Chainweb/BlockHeight.hs#L79)). Consequences:

- Header ranges are range-scannable; payload ranges are **not**. A height-window
  export must walk the headers and point-look-up each payload.
- You cannot prune payloads with a RocksDB `DeleteRange`; it would need per-key
  deletes.

Changing that encoding would be a database format change requiring a full
resync, so we live with it.

### 1.2 The State Cache — Pact SQLite — the world state and its row history

One file per chain. The schema that matters is the per-user-table one
([`Compaction.hs:577`](../../src/Chainweb/Pact/Backend/Compaction.hs#L577)):

```sql
CREATE TABLE IF NOT EXISTS <tbl>
  ( rowid INTEGER PRIMARY KEY AUTOINCREMENT
  , rowkey TEXT          -- the logical key, e.g. a "k:…" account
  , txid UNSIGNED BIGINT NOT NULL   -- which transaction wrote this version
  , rowdata BLOB NOT NULL           -- the serialized row
  );
CREATE UNIQUE INDEX … ON <tbl> (rowkey, txid);
CREATE INDEX        … ON <tbl> (txid DESC);
```

plus four bookkeeping tables — `BlockHistory (blockheight, hash, endingtxid)`,
`VersionedTableCreation`, `VersionedTableMutation`, `TransactionIndex`.

**Every write appends.** A read resolves "the row for `rowkey` with the highest
`txid <= endingtxid`". There is no height column in user tables at all; height is
mapped to `txid` through `BlockHistory`.

**Measured consequence.** Row counts from the 2026-10-02 snapshot of
`pact-v1-chain-0.sqlite` (992 MB):

| table | rows | distinct rowkeys | history multiplier |
|---|---|---|---|
| `coin_coin-table` | 1,246,355 | **48** | 25,966× |
| `coin_URV\|UrStoaVault` | 621,437 | **1** | 621,437× |
| `coin_LocalSupply` | 621,437 | **1** | 621,437× |
| `VersionedTableMutation` | 1,872,164 | — | — |
| `BlockHistory` | 621,437 | — | = chain-0 block height |
| `ouronet-ns.DPDC_DPNF\|T\|Nonces` | 73,213 | 15,611 | 4.7× |
| `ouronet-ns.DPDC_DPNF\|T\|AccountSupplies` | 29,428 | 22,492 | 1.3× |
| `ouronet-ns.DALOS_DALOS\|AccountTable` | 4,491 | 195 | 23.0× |
| `ouronet-ns.DPTF_DPTF\|BalanceTable` | 3,072 | 524 | 5.9× |

Three rows are rewritten on chain 0 **every single block** — the miner's coin
row, the vault, and `LocalSupply`. So roughly 1 GB of that file is ~5 million
versions of a few dozen logical rows. Chain 0's *live* state is 48 coin accounts
plus the ouronet tables: single-digit MB.

---

## 2. Why the asymmetry decides everything

### 2.1 The Chain Archive is primary data; the State Cache is derived

The State Cache is a **materialised view of the result of executing the Chain
Archive**. Replaying the Chain Archive regenerates it exactly.

This is not theory for us: the Yin engine verification replayed **all 550,567
blocks × 10 chains** read-only on real Stoa data. That run *was* the
reconstruction of the State Cache from the Chain Archive, end to end.

So the only question about the State Cache is how much of the cache must stay warm.

### 2.2 The Chain Archive is hash-committed; the State Cache is not

The complete `BlockHeader`
([`src/Chainweb/BlockHeader/Internal.hs:298`](../../src/Chainweb/BlockHeader/Internal.hs#L298)):

```
flags, creationTime, parent, adjacentHashes, target,
payloadHash, chainId, weight, height, chainwebVersion,
epochStart, nonce, hash
```

**There is no state root.** Ethereum commits a state trie root in every header;
chainweb commits only the *payload*. Therefore:

| | fetched from anywhere, verifiable against | verdict |
|---|---|---|
| `BlockPayload` | `_blockPayloadHash` in the header | ✅ |
| `BlockTransactions` | `BlockTransactionsHash` in the payload | ✅ |
| `BlockOutputs` | `BlockOutputsHash` in the payload | ✅ |
| `BlockHeader` | block hash / parent pointer | ✅ |
| **a Pact state row** | **nothing** | ❌ |

The only way to establish that a Pact state row is correct is to re-execute the
transactions that produced it. **This is the single reason the Chain Archive can have a
trustless remote tier and the State Cache cannot.**

A second, independent reason: the access pattern. Arweave answers *"give me the
blob at this address."* A Pact read asks *"give me the newest version of rowkey
`k:abc…` with `txid <= T`."* Serving that remotely needs a local index over every
rowkey in history — rebuilding the database in order to avoid storing it.

### 2.3 The State Cache's history is an undo log, not an archive

This is why the history exists at all. Rewind is implemented as
([`Pact/Backend/Utils.hs:479`](../../src/Chainweb/Pact/Backend/Utils.hs#L479)):

```sql
DELETE FROM <tbl> WHERE txid >= ?
```

Deleting the newer row versions makes the older ones current again. Pact state
stores no separate "previous value" anywhere — the old versions **are** the undo
mechanism. Keep enough versions to cover the deepest rewind you intend to
perform cheaply; everything older is dead weight nothing will ever read.

### 2.4 How little of the State Cache a node actually needs

| consumer | what it needs | how much |
|---|---|---|
| **rewind / reorg** (checkpointer) | prior row versions to delete back to | `defaultReorgLimit = RewindLimit 480` (~4 h at 30 s blocks); `initialRewindLimit = RewindLimit 1000` at startup |
| historical `/local` at a past height | row versions at that height | unbounded, if you want the feature |
| `/poll` on old transactions | the `TransactionIndex` table | compaction preserves it by default |
| replay from an arbitrary past height | the state *at* that height as a starting point | that height's versions |
| replay from genesis | **nothing** — regenerates B from A as it goes | none |

**The operational floor is on the order of 1,000 blocks. We are retaining
621,437.** A node needs roughly 0.16% of the Pact history it currently holds.

Only the two "unbounded" rows are genuinely lost by compacting, and neither is
needed for consensus or for current-state queries.

**Block explorers need none of it — they can run off the Chain Archive alone.** An explorer
builds its own index by streaming blocks: transactions come from the payloads,
results and events come from the outputs, and both are in the Chain Archive. Even current
balances are derivable there, by folding the `TRANSFER` events from genesis
forward — which is how most chain explorers compute balances anyway. So an
explorer never needs a Pact *history* row, and if it derives balances from events
it does not need the State Cache at all.

The only thing that pulls an explorer toward the State Cache is convenience: asking a node
`/local` for a balance instead of deriving it, or `/poll` for an old
transaction's result. The first reads the State Cache's *current* state, not its history,
so compaction does not affect it. The second reads `TransactionIndex`, which
compaction preserves by default precisely for that reason. Either way, nothing
an explorer does requires retained history.

**Which generalises.** Nobody needs the State Cache's history — not nodes, not explorers,
not wallets. What everybody does need is the State Cache's *tip*: a node cannot validate a
transfer without knowing the current balance. So the State Cache is not eliminable, only
its history is, and even the tip is reconstructible from the Chain Archive by replay. The Chain
Archive is the blockchain; everything else is a derived convenience.

### 2.5 Upstream already agrees about the State Cache

The compaction tool's default is `compactThese = CompactOnlyPactState`; the
opt-*out* flag `--no-compact-pact` is documented as:

> Pact state is not used by any public interface, so it is compacted by default,
> and the space savings are usually large on mainnet.

Compacting the State Cache is the intended steady state, not an exotic optimisation. We
have simply never run it.

---

## 3. What upstream does about size, and why we do not want it

Three distinct mechanisms are easy to confuse. Only the third is the one to fear.

**(a) `--prune-chain-database=none|headers|headers-checked|full` is fork garbage
collection, not history pruning.** `pruneForks` deletes blocks on *losing*
forks; `full` additionally mark-and-sweeps unreachable payloads. It never
deletes on-chain history. Our default is `GcNone`
([`Configuration.hs:233`](../../src/Chainweb/Chainweb/Configuration.hs#L233)).
Harmless.

**(b) The SPV proof root validity window is what strands cross-chain
transfers.** The mechanism, stated in our own tree in `Compaction.hs`:

> Constructing SPV proofs actually needs the payloads, but validating them does
> not.

Drop the payload at a source height and the burn half of a cross-chain transfer
can never have a proof constructed again — the funds are stranded.
**Stoa is deliberately configured the safe way:**
[`src/Chainweb/Version/Stoa.hs:130`](../../src/Chainweb/Version/Stoa.hs#L130)
sets `_versionSpvProofRootValidWindow = Bottom (minBound, Nothing)` —
*unlimited*. Mainnet shrank theirs to 6 months in 3.2. We keep every header
forever and can construct a proof at any height, forever.

**(c) PR #49 adds real history pruning.** The upstream "Chainweb Revolution" PR
([kda-community/chainweb-node#49](https://github.com/kda-community/chainweb-node/pull/49),
open 2026-10-19, 453 commits, +37.5k/−33.5k) includes "incremental block header
and payload pruning and a standalone tool for executing this pruning on demand."
*That* is the thing to stay away from, or to take only with an archive standing
behind it.

**This is the strongest argument for the Arweave design — stronger than the disk
saving.** Offloading preserves proof construction where pruning destroys it.
Same disk outcome, no stranded transfers.

---

## 4. What we already have, and what it cannot do

### 4.1 `cwtools compact`

```bash
cabal run compact -- --chainweb-version stoa \
  --from <dbdir> --to <outdir> --log-dir <logs> \
  --compact-rocksdb --parallel
```

| flag | effect |
|---|---|
| `--from` / `--to` | source and target, each `$DIR/0/{sqlite,rocksDb}` |
| `--compact-rocksdb` | also compact block data (off by default) |
| `--no-compact-pact` | do *not* compact Pact state (on by default) |
| `--compact-transaction-index` | also compact `TransactionIndex` (off by default — `/poll`) |
| `--parallel` | one thread per chain |

**The output is a live node database, not an archive.** Point
`--database-directory` at `$TO` and the node runs. No import step. This already
satisfies the "must be usable without importing" requirement for a *reduced*
database.

`doCompactRocksDb` is documented in-tree as *"Copy over all CutHashes, all
BlockHeaders, and only some Payloads"*, driven by a `minBlockHeight` cutoff. So a
height-filtered export already exists — with the polarity inverted (it keeps the
recent tail) and the cutoff computed internally rather than exposed. Upstream
even left a `TODO = Option to prune headers history to the minimum should be
enabled by flag`.

**Operational note:** compaction runs against a *snapshot*, not a live
directory — it opens its source with `withReadOnlyRocksDb`, and you do not want a
torn view across RocksDB and SQLite while the node is writing. You then swap the
output in and restart. It re-accumulates, so it is periodic. **That ops chore is
the only real reason this has not happened**, not any technical need for the
data.

### 4.2 The backup API — what we use today

`POST /make-backup` ([`src/Chainweb/Backup.hs`](../../src/Chainweb/Backup.hs))
takes a RocksDB *checkpoint* plus a per-chain SQLite copy. It is whole-database,
point-in-time at whenever it was called, with no height control and no
incrementality — exactly the limitation that prompted this work. An export at
block 663,223 is a database up to 663,223 and nothing else; a higher height means
a whole new backup.

---

## 5. The target architecture

### 5.1 Where each piece ends up

| component | fate | rough size |
|---|---|---|
| Pact SQLite (State Cache) | **compacted locally** — no Arweave involved | GB → MB |
| RocksDB block headers | **always local** — small, needed constantly for cut validation, mandatory for SPV | grows slowly |
| RocksDB payloads / transactions / outputs below a cutoff height | **Arweave** | the bulk |
| hot payload cache | local, bounded, operator-sized | operator's choice |

### 5.2 Why this is safe — the property the whole design rests on

Every byte that goes remote is hash-committed in a header the node independently
holds (§2.2). So a corrupted, substituted or truncated blob fails verification
and is discarded. The node trusts neither Arweave, nor the gateway, nor the
uploader, nor the manifest publisher. **Worst case is a failed fetch, never a
wrong answer.**

Three consequences:

1. **No fork. No consensus change. No protocol version bump.** This is purely a
   node-local decision about where bytes live. Compare the Yin engine, which
   needed a fork at block 600,000; this needs none.
2. **Per-operator opt-in.** A node that wants everything local keeps everything
   local. Nothing forces the fleet to move together, and a node with an archive
   tier is indistinguishable from a full node to the network except in latency.
3. **A bad actor cannot poison history**, only fail to serve it.

### 5.3 Arweave mechanics

- **Upload as ANS-104 bundles** — one Arweave transaction containing many
  individually addressable data items. 256 KB chunks underneath.
- **Random access without downloading the bundle.** Gateways resolve item →
  (root transaction, byte offset, size). ar.io gateways let a client skip that
  lookup entirely by supplying `X-AR-IO-Root-Transaction-Id`,
  `X-AR-IO-Data-Item-Offset` and `X-AR-IO-Data-Item-Size`
  ([ar.io fetch-data docs](https://docs.ar.io/build/access/fetch-data)). So with
  a small local index, a cold read is **one ranged HTTP GET**.
- **Immutability is not an obstacle to tranches.** Data items cannot be appended
  to, so "another 100 GB" means posting a new bundle and publishing an extended
  manifest — which is the tranche model we want anyway.
- **Index size.** A height → item-locator map covering millions of blocks is tens
  of MB: cheap to keep local or ship with the release.

### 5.4 Where it hooks into the node

[`libs/chainweb-storage/src/Chainweb/Storage/Table.hs:81`](../../libs/chainweb-storage/src/Chainweb/Storage/Table.hs#L81)
is a narrow interface:

```haskell
class ReadableTable t k v | t -> k v where
    tableLookup       :: t -> k -> IO (Maybe v)
    tableLookupBatch' :: t -> Traversal s r k (Maybe v) -> s -> IO r
```

A `TieredTable local remote` with a `ReadableTable` instance — try local, miss →
fetch remote, verify hash, optionally cache — drops straight in. The abstraction
already has alternative backends (`Table/Forgetful.hs`, `Table/HashMap.hs`), so
this is a supported move rather than a violation.

Scope of the wiring: the three bulk payload tables plus the
`BlockPayloadHash → BlockHeight` reverse index. Headers never go remote.

### 5.5 The runtime read path

1. Node starts with `--archive-manifest`, `--archive-gateways g1,g2,g3`,
   `--archive-below-height N`.
2. The manifest loads into a small local index: (chain, height) → (item id,
   offset, size).
3. `tableLookup` on a payload table becomes:
   - local RocksDB hit → return;
   - miss **below** the cutoff → index lookup → one ranged GET → **hash the
     bytes against the `BlockPayloadHash` already held** → mismatch: try the next
     gateway; match: return and insert into a bounded cache;
   - miss **at or above** the cutoff → genuinely missing data, same error as
     today.
4. **The hot path never goes remote.** Cut validation, mining and validating new
   blocks touch only local data.
5. What *does* go remote: SPV proof construction at old heights, `/poll` on
   ancient transactions, and serving catchup to a peer syncing from scratch.
   Those become slow-but-correct, and the node should decline to advertise fast
   catchup for archived ranges so peers do not select it for them.

---

## 6. What this means for the AncientHoldings Hub

This section is addressed to the agent that maintains the StoaChain node fleet.
It needs no Arweave work and no chainweb changes — it is actionable today, and it
is where most of the practical benefit in this document actually lands.

### 6.1 The names to use

"Chain Archive" and "State Cache" are this paper's scaffolding. The fleet tooling should use
real names, because the two are not two halves of one thing — they are different
kinds of object:

| directory | **name** | what it is | property |
|---|---|---|---|
| `data/0/rocksDb` | **Chain Archive** | headers, payloads, transactions, outputs | canonical, immutable, hash-committed, **irreplaceable** |
| `data/0/sqlite` | **State Cache** | Pact world state + its row history | derived, disposable, **regenerable by replay** |

The names carry the operational rule by themselves: you back up an archive, and
you evict a cache.

### 6.2 What the Hub shows today, and why it is wrong

The dashboard reports a single **"blockchain size"** of 9.3 GB. That number
treats two unlike things as one, and overstates the chain by roughly double.
4.6 GB of it is the blockchain. The other 4.7 GB is a per-node scratch file that
is ~99% stale row versions and that any node can rebuild from the first 4.6 GB.

It is also not a network property. The Chain Archive is the same on every synced
node; the State Cache is whatever that particular node has accumulated since it
was last compacted, so it differs per node and means nothing as a fleet total.

### 6.3 What to display instead

Break the single figure into two, and treat them differently:

```
Blockchain            4.6 GB            Chain Archive · identical on every synced node
State cache     avg   4.7 GB / node     derived · disposable · compactable
                max   5.1 GB  (slave-003)
                due for compaction: 3 nodes
```

- **Blockchain** = Chain Archive size. One figure for the network. This is the
  number that answers "how big is StoaChain?"
- **State cache** = the mean across the fleet, plus the max and the count of
  nodes over the compaction threshold. Per-node, not summed — summing a cache
  across nodes produces a number that describes nothing.
- Anywhere the Hub currently shows per-node disk, show both components, so an
  operator can see at a glance whether a node is large because the chain grew or
  because its cache is overdue.

### 6.4 The compaction worker to build

**Trigger:** a node's `data/0/sqlite` exceeding **1 GB**.

At the measured growth of ~30 MB/day for the Pact side, a freshly compacted node
takes roughly a month to come back to 1 GB, so this lands at a monthly cadence
per node without needing a schedule.

**The command:**

```bash
cwtools compact --chainweb-version stoa \
  --from <snapshot-dir> --to <compacted-dir> \
  --log-dir <logs> --parallel
```

> ### ⚠ Never pass `--compact-rocksdb` for routine compaction or backups
>
> Without it, `compact` touches **only** the State Cache and leaves the Chain
> Archive completely untouched — which is exactly what is wanted. With it, the
> tool also drops old payloads from the Chain Archive, which permanently
> destroys the ability to construct SPV proofs for those heights and **strands
> any cross-chain transfer that started there** (§3). That flag is only for
> deliberately building a lean node, and at least one node in the fleet must
> never have it applied.

**Two operational details that are easy to get wrong:**

1. **Compaction reads a snapshot, not a live directory.** It opens its source
   read-only, and a live node writing to RocksDB and SQLite concurrently gives a
   torn view across the two. Use the Hub's existing backup/snapshot step as the
   source, or stop the node first.
2. **A Pact-only compaction emits only `<to>/0/sqlite`.** The tool creates the
   RocksDB output directory only when `--compact-rocksdb` is passed. So to
   assemble a complete, runnable node directory the worker must place the
   original `0/rocksDb` next to the compacted `0/sqlite`:

   ```
   <compacted-dir>/0/sqlite     <- from compact
   <compacted-dir>/0/rocksDb    <- copied or hard-linked from the snapshot
   ```

**Swap-in:** stop the node, replace `data/0/sqlite` with the compacted one,
start it. Downtime is the restart, not the compaction.

**Expected result:** the State Cache should fall from GB to **tens of MB**. The
live state is small — chain 0 holds 48 coin accounts plus the OuroNet tables, and
chain 1 has had 165 transactions in its entire history. This figure is predicted,
not yet measured; the first run confirms it.

> ### ⚠ On Stoa, compaction targets the tip with no safety margin
>
> `locateLatestSafeTarget` grants a 1,000-block margin to `mainnet` and
> `testnet04` and **zero to every other version, Stoa included**:
>
> ```haskell
> let safeDepth
>       | v == mainnet || v == testnet04 = BlockHeight 1_000
>       | otherwise = BlockHeight 0
> let target = latestCommon - safeDepth
> ```
>
> So the compaction target is the snapshot's latest common height exactly, and
> `doCompactPactState` writes a single `BlockHistory` row at that height. A
> freshly compacted Stoa node therefore has Pact state at one height and **no
> rewind capability at all** until it executes forward again. The same zero also
> disables the tool's "not enough history to safely compact" guard, which
> compares against it — so the tool will never refuse, and that is the absence
> of a check rather than evidence of safety.
>
> It is survivable because the node restarts behind the live tip and rebuilds
> undo history while it catches up — but that margin is whatever the pipeline's
> latency happens to be, not a designed buffer. **Operationally:** never compact
> a snapshot taken seconds earlier, and do not call a node healthy until it has
> reached the tip and `BlockHistory` has grown past ~1,000 rows. That row count
> is the node's real rewind window and belongs on the dashboard beside the cache
> size. **Properly:** a one-line change — adding `|| v == stoa` to that guard —
> gives Stoa the same margin as mainnet, and is the recommended fix.

### 6.5 The backup mechanism should compact first

Today a backup captures all 9.3 GB, on the assumption that all of it is the
blockchain. Half of it is a rebuildable cache, and backing it up is pure waste —
the restored node would have been equally correct with a one-line cache.

**New order of operations:**

1. Snapshot the node (as now).
2. Compact the snapshot's Pact state — **without** `--compact-rocksdb`.
3. Assemble `0/rocksDb` (from the snapshot, untouched) + `0/sqlite` (compacted).
4. Archive that.

**Result: roughly 9.3 GB → ~4.7 GB**, and the saving grows every month the cache
would otherwise have accumulated.

**Yes, it still kickstarts a node from zero.** The backup keeps the complete
Chain Archive and a current, valid Pact state, so a node started on it validates
from the tip immediately, serves every historical block and header to peers, and
can construct SPV proofs at any height. Three things it cannot do, none of which
the fleet needs: answer historical state queries ("balance of X at height Y"),
rewind further back than the retained cache depth, or prove its own history
without replaying the archive.

### 6.6 The one fleet-wide invariant

> **No node may have `--compact-rocksdb` applied while the fleet holds no
> off-site archive.**

That is the property that matters, and it is worth stating as an invariant
rather than as a designated node, because the two are not equivalent.

**Pact-only compaction needs no archive node.** With `--compact-rocksdb` never
passed, full `rocksDb` on every node, `GcNone` and the unlimited SPV window, every
node still holds the complete blockchain. Consensus is unaffected (Pact state is
derived, and each node re-derives it from its own archive); serving catch-up to
peers is unaffected (it reads RocksDB); SPV proof construction is unaffected (it
needs payloads, not Pact history); and `/poll` is preserved as long as
`--compact-transaction-index` stays off. The only fleet-wide losses are
historical state queries and rewinding past the retained window — and **an
abstaining node does not help with either**, because each node must rewind its
own state and can replay its own archive to recover. So in that configuration a
never-compact node is an optional convenience for forensics, not a safety
requirement.

**What does require an archive node** is the Arweave end-state, or anyone passing
`--compact-rocksdb`. Either one takes block history off local disk, and then the
fleet needs at least one node that still holds it — otherwise no node can serve
a genesis-up sync, and the remote archive and the backups collapse into a single
point of failure. Designate the bootstrap, exempt it from the compaction worker,
and keep its backups full.

### 6.7 Summary for the Hub agent

| # | change | effort |
|---|---|---|
| 1 | Rename the concepts: **Chain Archive** and **State Cache** | labels only |
| 2 | Split "blockchain size" into Chain Archive (network figure) and State Cache (per-node mean, max, count over threshold) | display |
| 3 | Build a compaction worker triggered at 1 GB of `0/sqlite`, assembling archive + compacted cache | the main build |
| 4 | Change backup to compact first; expect ~9.3 GB → ~4.7 GB | small |
| 5 | Never pass `--compact-rocksdb` — the one invariant (§6.6) | a guard rail |
| 6 | Treat `BlockHistory` row count as the node's rewind window; do not call a node healthy below ~1,000 (§6.4) | display + health check |

The tool is not in the deployed node image, and is not built by the Dockerfile at
all — `chainweb-build-cwtool` builds only `cwtools:exe:ea`. Shipping it is a
separate `stoa-compact` image, pinned to the same tag as `stoa-node`, run as a
one-off container against a snapshot. Three container-level gotchas apply: the
source **cannot** be mounted `:ro` (SQLite opens it read-write), `--to` must not
already exist (so mount the parent and name a non-existent child), and
`0/rocksDb` must be hard-linked into the output by hand.

## 7. The roadmap

### Phase 0 — measure (half a day, no code)

Copy a node snapshot and run compaction on it; compare sizes.

```bash
cabal run compact -- --chainweb-version stoa \
  --from /path/to/snapshot --to /scratch/compacted \
  --log-dir /scratch/logs --compact-rocksdb --parallel
```

§1.2 already predicts the answer for the State Cache; this confirms it end-to-end and
tells us what a compacted node actually weighs. **Highest value per hour of any
step in this document.**

### Phase 1 — height-range exporter (1–2 weeks)

Extend `doCompactRocksDb` with explicit `--min-block-height` /
`--max-block-height`, a `--size-budget` mode that stops at N bytes and reports
the last height reached, and a canonical archive-stream output. Fully specified,
with code diffs, in
[`phase1-height-range-exporter-spec.md`](phase1-height-range-exporter-spec.md).

Worth building regardless of the Arweave decision: on its own it turns our
whole-database, uncontrollable backups into height-addressed, incremental ones.
No node changes, no consensus risk.

### Phase 2 — uploader and manifest (1–2 weeks)

Chunk each export into ANS-104 data items (recommended granularity: one chain ×
10,000 blocks ≈ 20 MB per item), upload via Turbo/ardrive, **re-fetch and hash
every item**, and only then publish a signed manifest. Pure tooling, outside the
node.

### Phase 3 — the read-through tier (4–8 weeks, the real work)

`TieredTable` in chainweb-storage; wire the three payload tables plus the reverse
index; config for manifest location, gateway list, archive cutoff, cache size and
eviction; hash verification on every fetch; metrics; and substantial testing of
the slow-fetch and failed-fetch paths, which are new failure modes for this
codebase. This is the part that touches the node, and the part PR #49 may
invalidate.

### Phase 4 — operations

Gateway selection, per-node-class cache policy, and a standing decision that at
least the bootstrap nodes keep everything local so the network always has one
fast full archive.

---

## 8. Blockers, risks and open decisions

### 8.1 Concrete blockers in the code

**A RocksDB-only export cannot run today.** `compact` calls
`locateLatestSafeTarget` *unconditionally* before branching on what was
requested; that function reads `$FROM/0/sqlite` and aborts with "Not enough
history to safely compact" when the Pact state has under 1,000 blocks of depth.
So `--compact-rocksdb` against a RocksDB-only source dies before reaching any
export code. **This must be fixed first** — §7.1 of the Phase 1 spec.

**A RocksDB directory is not content-addressable.** SST layout depends on write
order, timing and background compaction, so two exports of the same range differ
byte-for-byte. Phase 2's manifest would have nothing stable to hash. Fixed by the
canonical archive stream in the Phase 1 spec (§6 there), built on the existing
`encodePayloadWithOutputs` / `decodePayloadWithOutputs`
([`Payload.hs:673,699`](../../src/Chainweb/Payload.hs#L673)).

**Little-endian payload keys** (§1.1) mean no contiguous height scan and no
`DeleteRange` on payload tables. An export job walks headers and point-looks-up
payloads. Acceptable; just not free.

**The target RocksDB is opened `NoCompression`** — right for a database you are
about to run, wasteful for bytes you are about to pay to store forever.

### 8.2 Risks

**Latency and a new failure mode.** `tableLookup` is synchronous `IO`; today a
RocksDB read in microseconds, with a remote tier a gateway round trip of
100 ms–seconds that sometimes fails outright. Keeping it off block validation is
achievable, but SPV construction, `/poll` and peer catchup will hit it.

**Gateway liveness is a centralisation trade.** Arweave data is permanent;
availability through a given gateway is not. There is a documented case of
arweave.net serving only ~50% of a bundle's paths days after upload while
another gateway served 99%
([ArweaveTeam/arweave#981](https://github.com/ArweaveTeam/arweave/issues/981)).
Mitigation: multiple gateways, retries, optionally our own ar.io node. If every
Stoa node depends on one gateway we have traded local disk for a single point of
failure — an odd thing for a blockchain to do. Safety survives (hash checks);
liveness does not.

**Cost is one-time but denominated in a volatile token.** No authoritative 2026
per-GB figure exists; published estimates cluster around **$5–10/GB**, set by the
AR price and network load, and the bill moves between decision and upload. 500 GB
at $7/GB ≈ $3,500 one-time. Price it immediately before each upload, and pilot
now while 9.4 GB is trivial.

**Upstream is rewriting this exact layer.** PR #49's `PayloadProvider` decouples
block execution and payload storage from consensus. Two readings, both true: a
tier built against today's `PayloadStore` is discarded by that port-forward —
*and* `PayloadProvider` is a far better seam for this than `Table`, because a
remote payload provider is precisely the abstraction it introduces. **Decide
whether we follow #49 before building Phase 3**; deciding is cheaper than
building twice.

**Compaction is lossy and periodic.** A compacted node loses historical state
queries and the ability to rewind past its compaction point, so it must retain
more than the deepest plausible reorg and be re-run as history re-accumulates.

**Two independent backstops.** If the Chain Archive goes to Arweave *and* the State Cache is
compacted, the "rebuild a node from nothing" path runs through Arweave. Keep one
full local archive as well so the two backstops do not share a failure.

### 8.3 Open decisions

| # | decision | recommendation |
|---|---|---|
| 1 | Do archive chunks carry headers? | No — any node reconstructing already has the full header chain, and it is small. Format v2 if that changes. |
| 2 | Chunk granularity | One chain × 10,000 blocks ≈ 20 MB per data item. |
| 3 | `--allow-missing-payloads`? | Yes, off by default. Needed to export an old window from an already-compacted source; dangerous elsewhere. |
| 4 | May the "directly usable" output ship without Pact state? | Yes in principle — the node rebuilds state by replay — but confirm before promising it. |
| 5 | Do we follow PR #49? | Blocks Phase 3. Needs a separate decision. |

---

## 9. What was verified versus what is assumed

Being explicit, because the plan rests on these.

**Verified by reading the code or measuring:** the two-store layout and its
sizes; the per-chain SQLite sizes; the row counts and history multipliers in
§1.2; the user-table schema; the rewind mechanism; `defaultReorgLimit` and
`initialRewindLimit`; the absence of a state root in `BlockHeader`; the
big-endian header keys and little-endian payload keys; Stoa's unlimited SPV
window; that `--prune-chain-database` is fork GC only; the `compact` CLI surface
and its defaults; `doCompactRocksDb`'s structure and its one-sided filter; the
`locateLatestSafeTarget` dependency on the Pact directory; that the backup API is
a RocksDB checkpoint plus SQLite copy; the `ReadableTable` interface and its
existing alternative backends; the existence of
`encodePayloadWithOutputs`/`decodePayloadWithOutputs`; growth of 8.2 → 9.4 GB
over 20 days; the chain-0 against chain-1 Pact-state comparison (243 vs 16
tables, 227 OuroNet tables vs none, 1,246,355 vs 621,613 coin rows, 3,756 vs
165 indexed transactions); the per-chain activity figures read from the
explorer at block 684,994; PR #49's scope from its own description.

**Assumed, and worth confirming:** Arweave per-GB pricing (no authoritative 2026
source found — price it at upload time); that ar.io range reads perform
acceptably at our access patterns (untested by us); that a compacted node
database boots and serves correctly (Phase 0 / Phase 1 test); that our own explorer
does not call `/local` or `/poll` against history (§2.4 shows an explorer *can*
run off the Chain Archive alone; whether ours does is unchecked); that
~1,000 blocks of Pact history is genuinely sufficient for our reorg depth in
practice, not just per the configured limit.

**Not yet done:** nothing in this document is implemented. Phase 0 has not been
run.

---

## 10. Code reference index

| subject | location |
|---|---|
| database directory layout | [`node/src/ChainwebNode.hs:164`](../../node/src/ChainwebNode.hs#L164) |
| payload store tables and keys | [`src/Chainweb/Payload/PayloadStore/RocksDB.hs`](../../src/Chainweb/Payload/PayloadStore/RocksDB.hs) |
| height key encoding (LE vs BE) | [`src/Chainweb/BlockHeight.hs:79,91`](../../src/Chainweb/BlockHeight.hs#L79), [`src/Chainweb/Ranked.hs:54`](../../src/Chainweb/Ranked.hs#L54) |
| header table and `RankedBlockHash` | [`src/Chainweb/BlockHeaderDB/Internal.hs:150`](../../src/Chainweb/BlockHeaderDB/Internal.hs#L150) |
| `BlockHeader` fields (no state root) | [`src/Chainweb/BlockHeader/Internal.hs:298`](../../src/Chainweb/BlockHeader/Internal.hs#L298) |
| Pact SQLite schema | [`src/Chainweb/Pact/Backend/Compaction.hs:504-600`](../../src/Chainweb/Pact/Backend/Compaction.hs#L504) |
| rewind / undo mechanism | [`src/Chainweb/Pact/Backend/Utils.hs:470`](../../src/Chainweb/Pact/Backend/Utils.hs#L470) |
| reorg limits | [`src/Chainweb/Pact/Types.hs:522`](../../src/Chainweb/Pact/Types.hs#L522), [`src/Chainweb/Pact/PactService.hs:245`](../../src/Chainweb/Pact/PactService.hs#L245) |
| compaction driver and CLI | [`src/Chainweb/Pact/Backend/Compaction.hs:146,349`](../../src/Chainweb/Pact/Backend/Compaction.hs#L146) |
| `doCompactRocksDb` | [`src/Chainweb/Pact/Backend/Compaction.hs:716`](../../src/Chainweb/Pact/Backend/Compaction.hs#L716) |
| `locateLatestSafeTarget` | [`src/Chainweb/Pact/Backend/Compaction.hs:641`](../../src/Chainweb/Pact/Backend/Compaction.hs#L641) |
| fork GC modes | [`src/Chainweb/Chainweb/Configuration.hs:168,233`](../../src/Chainweb/Chainweb/Configuration.hs#L168), [`src/Chainweb/BlockHeaderDB/PruneForks.hs`](../../src/Chainweb/BlockHeaderDB/PruneForks.hs) |
| Stoa SPV window | [`src/Chainweb/Version/Stoa.hs:130`](../../src/Chainweb/Version/Stoa.hs#L130) |
| backup API | [`src/Chainweb/Backup.hs`](../../src/Chainweb/Backup.hs), [`src/Chainweb/RestAPI/Backup.hs`](../../src/Chainweb/RestAPI/Backup.hs) |
| storage `Table` interface | [`libs/chainweb-storage/src/Chainweb/Storage/Table.hs:81`](../../libs/chainweb-storage/src/Chainweb/Storage/Table.hs#L81) |
| payload canonical codecs | [`src/Chainweb/Payload.hs:673,699`](../../src/Chainweb/Payload.hs#L673) |
| SPV proof construction | [`src/Chainweb/SPV/CreateProof.hs:201`](../../src/Chainweb/SPV/CreateProof.hs#L201) |

---

## 11. Recommendation

1. **Run Phase 0 this week.** Half a day, and it is the only number that sizes
   everything else.
2. **Hand §6 to the Hub agent.** The display split, the compaction worker and
   the compact-before-backup change need no Arweave work and no chainweb
   change, and together they roughly halve both the reported size and every
   backup. This is the fastest return in the document.
3. **Compact the State Cache regardless of the Arweave decision.** It is ~99%
   redundant, upstream's tool compacts it by default, and nothing any user,
   explorer or consensus rule can observe changes.
4. **Build Phases 1–2 regardless.** They fix the backup problem on their own
   merits and carry zero consensus risk.
5. **Pilot the Arweave upload now**, at 9.4 GB, so the plumbing is proven before
   the data is large.
6. **Hold Phase 3 until the PR #49 question is settled.**
7. **Keep `GcNone` and the unlimited SPV window.** Do not take #49's pruning
   without an archive already standing behind it.

The idea is sound, the trust model is genuinely good, it needs no fork, and it is
the only way to shed disk *without* stranding cross-chain transfers. The
surprise is that the first and cheapest win — deleting half the database — needs
none of it.
