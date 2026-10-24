# Phase 1 — height-range block exporter: implementation spec

**Scope:** extend `cwtools compact` so it can export an arbitrary block-height
window of RocksDB block data, or as many blocks as fit a byte budget, and report
what it wrote. No Arweave, no node changes, no consensus changes, no fork.

**Deliverables:**
1. `--min-block-height` / `--max-block-height` — export payloads for an explicit
   inclusive window.
2. `--size-budget` — export from a start height until N bytes are written, and
   report the last height reached.
3. Output remains a **directly usable** `$TO/0/{sqlite,rocksDb}` — no import step.
4. A second, **canonical archive stream** output, because a RocksDB directory is
   not content-addressable and Phase 2's Arweave manifest needs stable hashes.

Companion to [`storage-architecture-and-arweave-offload.md`](storage-architecture-and-arweave-offload.md),
which carries the research this spec is built on.

---

## 1. Where we are starting from

All line numbers are `src/Chainweb/Pact/Backend/Compaction.hs` unless stated.

| thing | location | current behaviour |
|---|---|---|
| `Config` record | `:146` | 8 fields, no height control |
| CLI parser | `:185` | `--chainweb-version --from --to --parallel --log-dir --compact-rocksdb --no-compact-pact --compact-transaction-index` |
| `compact` driver | `:349` | derives one target height, then branches |
| `locateLatestSafeTarget` | `:641` | reads **`$FROM/0/sqlite`**, returns `latestCommon - 1000` |
| `blockHeightKeepDepth` | `:346` | `2_000` |
| `doCompactRocksDb` | `:716` | `… -> BlockHeight -> RocksDb -> RocksDb -> IO ()` |
| the payload filter | `:832` | `when (blkHeight >= minBlockHeight) $ do …` |

The export loop is already almost exactly what we need. It walks the header table
in ascending height order (`RankedBlockHash` keys are big-endian-height, so
RocksDB order *is* height order), copies every header and rank-table entry
unconditionally, and copies the payload only when the one-sided filter passes:

```haskell
when (blkHeight >= minBlockHeight) $ do
  let payloadHash = blkHeader ^. blockPayloadHash
  lookupPayloadWithHeight srcPayloads (Just blkHeight) payloadHash >>= \case
    Nothing -> exitLog logger "Missing payload: This is likely due to a corrupted database."
    Just payloadWithOutputs -> addNewPayload targetPayloads blkHeight payloadWithOutputs
```

## 2. Six problems to solve

1. **The filter is one-sided.** `>=` only; no upper bound.
2. **`minBlockHeight` is derived, not chosen.** It is always
   `targetBlockHeight - blockHeightKeepDepth`.
3. **A RocksDB-only export still requires the Pact directory.** `compact` calls
   `locateLatestSafeTarget` *unconditionally* at `:360`, before branching on
   `_compactThese`. That function reads `$FROM/0/sqlite` and aborts with
   "Not enough history to safely compact" when the Pact state has under 1,000
   blocks of depth. So `--compact-rocksdb` alone cannot run against a
   RocksDB-only source today. **This blocks the whole use case** and is the one
   non-trivial fix in Phase 1.
4. **The header walk always starts at `iterFirst`.** On Stoa
   `minimumBlockHeaderHistory` returns `Nothing` (our
   `_versionSpvProofRootValidWindow` is `Bottom (minBound, Nothing)`), so the
   `Nothing` branch at `:784` seeks to the first entry and walks all ~621k
   headers even to export a 10k window.
5. **A RocksDB directory is not content-addressable.** SST file layout depends on
   write order, timing and background compaction, so two exports of the same
   range produce different bytes. Phase 2 cannot build a verifiable manifest
   from it. → §6.
6. **The target RocksDB is opened `NoCompression`** (`:394`). Correct for a node
   database you are about to run; wasteful for bytes you are about to pay
   Arweave to store forever.

## 3. CLI surface

```
  --min-block-height N        Inclusive lower bound of the payload window.
  --max-block-height N        Inclusive upper bound of the payload window.
  --size-budget BYTES         Export from --min-block-height upward until this
                              many payload bytes have been written, then stop
                              and report the last height included.
  --chain N                   Restrict to this chain. Repeatable. Default: all.
  --archive-stream DIR        Also write the canonical archive stream (§6) to
                              DIR, one file per chain.
  --archive-only              Write only the archive stream; skip the RocksDB
                              output entirely. Implies --compact-rocksdb.
  --allow-missing-payloads    Warn and continue instead of aborting when a
                              payload is absent from the source.
  --archive-compression       Enable compression on the target RocksDB.
```

Semantics:

- **Defaults preserve today's behaviour exactly.** With none of the new flags,
  the window is `WindowDefault` and the code path is byte-for-byte the current
  one. This must be covered by a golden test (§9).
- `--size-budget` and `--max-block-height` are **mutually exclusive**; passing
  both is a usage error.
- `--size-budget` without `--min-block-height` starts at genesis height.
- The budget is checked *between* records, so the output may exceed the budget by
  at most one payload. Documented, not fixed — a payload is atomic.
- `--chain` lets the caller produce one output per chain, which maps directly
  onto Arweave data items and parallelises trivially.

## 4. `Config` diff

```haskell
 data Config = Config
   { chainwebVersion :: ChainwebVersion
   , fromDir :: FilePath
   , toDir :: FilePath
   , concurrent :: ConcurrentChains
   , logDir :: FilePath
   , compactRocksDb :: Bool
   , compactPactState :: Bool
   , compactTransactionIndex :: Bool
+  , payloadWindow :: PayloadWindow
+  , chainFilter :: Maybe (NonEmpty ChainId)
+  , archiveStreamDir :: Maybe FilePath
+  , archiveOnly :: Bool
+  , allowMissingPayloads :: Bool
+  , archiveCompression :: Bool
   }
+
+-- | How to choose which payloads to export.
+data PayloadWindow
+  = WindowDefault
+    -- ^ Today's behaviour: @locateLatestSafeTarget - blockHeightKeepDepth@
+    -- upward, unbounded above.
+  | WindowHeights !BlockHeight !(Maybe BlockHeight)
+    -- ^ Explicit inclusive window; 'Nothing' means unbounded above.
+  | WindowBudget !BlockHeight !Word64
+    -- ^ Start height and a payload-byte budget.
+  deriving stock (Eq, Show)
```

Keep `chainFilter` as `Maybe (NonEmpty ChainId)` rather than `[ChainId]` so
"no filter" and "empty filter" cannot be confused.

## 5. `doCompactRocksDb` diff

### 5.1 Signature

```haskell
 doCompactRocksDb :: (Logger logger)
   => logger
   -> ChainwebVersion
   -> [ChainId]
-  -> BlockHeight -- ^ minBlockHeight for payload copying
+  -> PayloadRange
+  -> ExportOpts
   -> RocksDb -- ^ source db, should be opened read-only
   -> RocksDb -- ^ target db
-  -> IO ()
+  -> IO ExportReport
```

### 5.2 New types

```haskell
-- | Resolved payload selection. 'prMax' is 'maxBound' for "no upper bound".
data PayloadRange = PayloadRange
  { prMin :: !BlockHeight
  , prMax :: !BlockHeight
  , prBudget :: !(Maybe Word64)
  }

data ExportOpts = ExportOpts
  { eoAllowMissing :: !Bool
  , eoArchiveSink :: !(Maybe (ChainId -> IO ArchiveWriter))
  , eoCopyHeaders :: !Bool
    -- ^ False for --archive-only: skip the header/rank-table copy and seek
    -- straight to 'prMin', which is the fix for problem 4.
  , eoWritePayloadDb :: !Bool
    -- ^ False for --archive-only: do not populate the target payload db.
    -- At least one of 'eoWritePayloadDb' and 'eoArchiveSink' must be set;
    -- the CLI layer rejects the combination that writes nothing.
  }

data ChainExportReport = ChainExportReport
  { cerFirstHeight :: !(Maybe BlockHeight)
  , cerLastHeight :: !(Maybe BlockHeight)
  , cerPayloads :: !Word64
  , cerPayloadBytes :: !Word64
  , cerMissing :: !Word64
  }
  deriving stock (Eq, Show)

newtype ExportReport = ExportReport (HM.HashMap ChainId ChainExportReport)
  deriving stock (Eq, Show)
```

`ExportReport` is what satisfies deliverable 2 — "tell me how many blocks you
backed up". Render it to stdout as a table and to the log as JSON.

### 5.3 Body: the seek

Replace the `minimumBlockHeaderHistory` case at `:784`. Today both branches exist
to decide how far back to start; add the archive case in front:

```haskell
+      -- Archive-only: payloads are all we write, so start at the window.
+      if not opts.eoCopyHeaders
+        then iterSeek it $ RankedBlockHash pr.prMin nullBlockHash
+        else case minimumBlockHeaderHistory cwVersion (latestHeader ^. blockForkNumber) (latestHeader ^. blockHeight) of
               Nothing -> iterFirst it
               Just minBlockHeaderHistory -> …    -- unchanged
```

When headers *are* being copied the walk must still start at the beginning —
they are mandatory for a runnable database and for SPV, exactly as the existing
comment says ("We migrate all BlockHeaders, for now. They are needed for SPV").

### 5.4 Body: the filter, accounting and early exit

```haskell
               Just rankedBlockHeader -> do
                 let blkHeader = _getRankedBlockHeader rankedBlockHeader
                 let blkHeight = view blockHeight blkHeader
                 let blkHash   = view blockHash blkHeader

-                log' LL.Debug $ "Copying over BlockHeader " <> toText blkHash
-                tableInsert (_chainDbCas targetBlockHeaderDb) (RankedBlockHash blkHeight blkHash) rankedBlockHeader
-                tableInsert (_chainDbRankTable targetBlockHeaderDb) blkHash blkHeight
+                when opts.eoCopyHeaders $ do
+                  log' LL.Debug $ "Copying over BlockHeader " <> toText blkHash
+                  tableInsert (_chainDbCas targetBlockHeaderDb) (RankedBlockHash blkHeight blkHash) rankedBlockHeader
+                  tableInsert (_chainDbRankTable targetBlockHeaderDb) blkHash blkHeight

-                when (blkHeight >= minBlockHeight) $ do
+                spent <- readIORef bytesRef
+                let inWindow = blkHeight >= pr.prMin && blkHeight <= pr.prMax
+                    budgetOk = maybe True (spent <) pr.prBudget
+                when (inWindow && budgetOk) $ do
                   let payloadHash = blkHeader ^. blockPayloadHash
                   log' LL.Info $ "Migrating block payload " <> sshow payloadHash <> " for BlockHeight " <> sshow blkHeight
                   lookupPayloadWithHeight srcPayloads (Just blkHeight) payloadHash >>= \case
-                    Nothing -> do
-                      exitLog logger "Missing payload: This is likely due to a corrupted database."
-                    Just payloadWithOutputs -> do
-                      addNewPayload targetPayloads blkHeight payloadWithOutputs
+                    Nothing
+                      | opts.eoAllowMissing -> do
+                          log' LL.Warn $ "Missing payload at height " <> sshow blkHeight <> "; continuing"
+                          modifyIORef' statsRef (bumpMissing blkHeight)
+                      | otherwise ->
+                          exitLog logger "Missing payload: This is likely due to a corrupted database."
+                    Just payloadWithOutputs -> do
+                      let encoded = encodePayloadWithOutputs payloadWithOutputs
+                      when opts.eoWritePayloadDb $
+                        addNewPayload targetPayloads blkHeight payloadWithOutputs
+                      forM_ mArchiveWriter $ \w ->
+                        archiveWrite w blkHeight payloadHash encoded
+                      modifyIORef' bytesRef (+ fromIntegral (B.length encoded))
+                      modifyIORef' statsRef (bumpWritten blkHeight (B.length encoded))

                 logHeaderProgress blkHeight

-                iterNext it
-                go
+                -- Early exit: past the window, or budget spent. Only safe
+                -- because the iterator is in ascending height order.
+                spent' <- readIORef bytesRef
+                let doneByHeight = blkHeight >= pr.prMax
+                    doneByBudget = maybe False (spent' >=) pr.prBudget
+                if (doneByHeight || doneByBudget) && not opts.eoCopyHeaders
+                  then log' LL.Info "Reached end of requested range"
+                  else iterNext it >> go
```

Note the `not opts.eoCopyHeaders` guard on the early exit: when headers are being
copied we must keep walking to the tip even after the payload window closes,
because the header copy is unconditional. Only the archive-only path can stop
early. That is the honest trade and it is why `--archive-only` exists.

`encodePayloadWithOutputs` (`src/Chainweb/Payload.hs:673`) is reused for both the
byte accounting and the archive record, so the budget counts exactly the bytes
the archive will contain.

## 6. The canonical archive stream

Problem 5 again: a RocksDB directory cannot be hashed into a stable identity, so
Phase 2 has nothing to verify against. Fix it with a flat, deterministic format
in a new module `src/Chainweb/Payload/Archive.hs`.

```
file: $DIR/stoa-archive-<version>-chain<N>-<minH>-<maxH>.bin

header (40 bytes):
  magic                "STOAARC1"            8 bytes
  chainwebVersionCode  le32                  4
  chainId              le32                  4
  minHeight            le64                  8
  maxHeight            le64                  8
  recordCount          le64                  8

records, ascending height, no padding:
  height               le64                  8
  payloadHash          raw                  32
  length               le32                  4
  payload              encodePayloadWithOutputs
```

Properties, each one load-bearing for Phase 2:

- **Reproducible.** Two exports of the same range from any correct node produce
  identical bytes — the record order is header-table order, which is height
  order, and `encodePayloadWithOutputs` is canonical. So the manifest hash is
  independently checkable by anyone with a node.
- **Verifiable.** A reader checks each record's `payloadHash` against the block
  header it already holds, and `decodePayloadWithOutputs`
  (`src/Chainweb/Payload.hs:699`) re-derives the Merkle structure. This is the
  property the whole Arweave design rests on.
- **Chunkable.** Record boundaries are discoverable by scanning, so a stream
  splits at arbitrary points into Arweave data items.
- **Self-describing.** The header pins version, chain and range, so a misfiled
  chunk is detected rather than silently misread.

API:

```haskell
data ArchiveWriter
withArchiveWriter :: FilePath -> ChainwebVersion -> ChainId -> BlockHeight -> BlockHeight -> (ArchiveWriter -> IO a) -> IO a
archiveWrite     :: ArchiveWriter -> BlockHeight -> BlockPayloadHash -> ByteString -> IO ()

data ArchiveReader
withArchiveReader :: FilePath -> (ArchiveReader -> IO a) -> IO a
archiveRecords    :: ArchiveReader -> Stream (Of (BlockHeight, BlockPayloadHash, PayloadWithOutputs)) IO ()
```

`recordCount` is unknown until the end, so the writer seeks back and patches the
header on close. `withArchiveWriter` must therefore write to a `.part` file and
rename on success, so a crashed export never leaves a plausible-looking archive.

## 7. `compact` driver diff

### 7.1 Stop requiring the Pact state (problem 3)

```haskell
-  targetBlockHeight <- withDefaultLogger LL.Debug $ \logger -> do
-    targetBlockHeight <- locateLatestSafeTarget logger cfg.chainwebVersion (pactDir cfg.fromDir) cids
+  -- Only consult the Pact state when something actually needs a derived
+  -- target: the default window, or Pact-state compaction itself.
+  let needsDerivedTarget = cfg.payloadWindow == WindowDefault || cfg.compactPactState
+  mTargetBlockHeight <- withDefaultLogger LL.Debug $ \logger -> do
+    mTarget <- if needsDerivedTarget
+      then Just <$> locateLatestSafeTarget logger cfg.chainwebVersion (pactDir cfg.fromDir) cids
+      else pure Nothing
```

and resolve the range:

```haskell
+resolvePayloadRange :: ChainwebVersion -> Maybe BlockHeight -> PayloadWindow -> PayloadRange
+resolvePayloadRange v mTarget = \case
+  WindowDefault -> case mTarget of
+    Just t  -> PayloadRange (t - blockHeightKeepDepth) maxBound Nothing
+    Nothing -> error "resolvePayloadRange: WindowDefault without a derived target"
+  WindowHeights lo mHi -> PayloadRange lo (fromMaybe maxBound mHi) Nothing
+  WindowBudget lo b    -> PayloadRange lo maxBound (Just b)
```

### 7.2 Chain filter and compression

```haskell
-  let cids = allChains cfg.chainwebVersion
+  let allCids = allChains cfg.chainwebVersion
+  cids <- case cfg.chainFilter of
+    Nothing -> pure allCids
+    Just sel -> do
+      let bad = NE.filter (`notElem` allCids) sel
+      unless (null bad) $ error $ "unknown chain ids: " <> show bad
+      pure (NE.toList sel)
```

```haskell
-        withRocksDb (rocksDir cfg.toDir) (modernDefaultOptions { compression = NoCompression }) $ \targetRocksDb -> do
+        let targetOpts
+              | cfg.archiveCompression = modernDefaultOptions
+              | otherwise = modernDefaultOptions { compression = NoCompression }
+        withRocksDb (rocksDir cfg.toDir) targetOpts $ \targetRocksDb -> do
```

### 7.3 Output directory

`initDir` (`:369`) aborts when `--to` exists. Keep that for the single-window
case. For `--size-budget` producing a sequence of chunks, require `--to` to be
absent and create `$TO/chunk-000001/0/rocksDb` per chunk, so one invocation can
emit a whole tranche. The chunk index also names the archive files, which keeps
the Phase 2 manifest trivial to assemble.

## 8. Decisions needed before coding

1. **Headers in the archive stream?** The spec above carries payloads only, on
   the grounds that any node reconstructing from an archive already has the full
   header chain (it is mandatory and small). *Recommendation: payloads only.*
   If we ever want a chunk to be restorable in isolation, that is a format v2.
2. **Chunk granularity.** *Recommendation: one chain × 10,000 blocks.* At Stoa's
   current ~2 KB/block that is ~20 MB per item — comfortable for an ANS-104 data
   item and fine for a ranged GET.
3. **`--allow-missing-payloads` at all?** *Recommendation: yes, but off by
   default.* It is needed to export an old window from a source that has already
   been compacted, and dangerous everywhere else.
4. **Does the RocksDB output need the Pact state copied too?** For "give me a
   runnable node db for blocks x..y" the answer is no — the node rebuilds Pact
   state by replay. Worth confirming that is acceptable before we promise
   "directly usable".

## 9. Tests

New module `test/unit/Chainweb/Test/Pact/Backend/Export.hs`. Must obey the
unit-test invariants at [`chainweb.cabal:604`](../../chainweb.cabal#L604) — fast,
parallel-safe, no own RocksDB initialisation.

| test | asserts |
|---|---|
| `defaultsUnchanged` | with no new flags, output is identical to the current implementation (golden) |
| `windowInclusive` | `[x,y]` includes exactly heights x..y; x−1 and y+1 absent |
| `windowEmpty` | `[y,x]` with y>x writes a valid empty archive, exits 0, reports 0 blocks |
| `windowBelowGenesis` | a window entirely below genesis height is a clean no-op |
| `budgetHonoured` | budget mode overshoots by at most one payload and reports the correct last height |
| `budgetReportMatches` | `cerPayloadBytes` equals the archive file size minus the header |
| `archiveRoundTrip` | export → read back → every payload hash matches the source |
| `archiveDeterminism` | two exports of the same range are byte-identical |
| `archiveRejectsWrongChain` | reader refuses a chunk whose header chain id disagrees |
| `missingPayloadAborts` | default policy exits non-zero on a hole |
| `missingPayloadWarns` | `--allow-missing-payloads` continues and counts it |
| `rocksDbOutputBoots` | the `$TO/0/rocksDb` output opens and serves `/header` (integration, not unit) |

## 10. Files and estimate

| file | change | rough size |
|---|---|---|
| `src/Chainweb/Pact/Backend/Compaction.hs` | `Config`, CLI, `compact`, `doCompactRocksDb`, new types, report rendering | ~300 lines net |
| `src/Chainweb/Payload/Archive.hs` | **new** — format, writer, reader | ~180 lines |
| `chainweb.cabal` | register `Chainweb.Payload.Archive`; add the test module | ~4 lines |
| `test/unit/.../Export.hs` | **new** — the table in §9 | ~250 lines |
| `cwtools/compact/Main.hs` | none (it only calls `Compact.main`) | — |

**Estimate: 1–2 weeks including tests.** The library and node build with
`-Wall -Werror`, so all of this must compile warning-clean.

**Order of work:** §7.1 first (the Pact-state dependency) — until that is fixed
nothing else can be exercised against a RocksDB-only source. Then §5 (the
filter and report), then §6 (the archive stream), then tests.
