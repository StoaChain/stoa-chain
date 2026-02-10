---
phase: 02-version-definition-and-gas-limits
plan: 01
subsystem: blockchain-version
tags: [haskell, chainweb-version, petersen-graph, gas-limits, genesis]

# Dependency graph
requires:
  - phase: 01-contract-verification
    provides: "STOA coin contract (used in future genesis payload generation)"
provides:
  - "Stoa ChainwebVersion record with unique version code 0x0000_000A"
  - "petersenChainGraph topology (10 chains, degree 3, diameter 2)"
  - "Max block gas limit hard cap at 500,000"
  - "Pattern synonym Stoa for pattern matching"
affects: [02-02, 03-genesis-payloads, 04-version-registration, 05-integration]

# Tech tracking
tech-stack:
  added: []
  patterns: ["Version definition following Development.hs template", "Wildcard fork pattern for future-proof fork coverage"]

key-files:
  created: [src/Chainweb/Version/Stoa.hs]
  modified: []

key-decisions:
  - "Version code 0x0000_000A (decimal 10) chosen -- no conflicts with existing codes (0x01, 0x02, 0x05, 0x07) or test codes (0x80000000+)"
  - "Genesis time set to 2026-03-01T00:00:00 as placeholder"
  - "PoW disabled (_disablePow = True) for Phase 2 testing; Phase 5 will enable it"
  - "Devnet genesis payloads used as temporaries until Phase 3 generates Stoa-specific ones"

patterns-established:
  - "Version definition structure: follow Development.hs template with Stoa-specific overrides"
  - "Chain range: always [0..9] for Petersen graph, never [0..19]"

# Metrics
duration: 1min
completed: 2026-02-11
---

# Phase 2 Plan 1: Stoa Version Definition Summary

**Stoa ChainwebVersion record with Petersen graph topology (10 chains), 500k gas limit hard cap, and devnet genesis temporaries**

## Performance

- **Duration:** 1 min
- **Started:** 2026-02-10T22:20:21Z
- **Completed:** 2026-02-10T22:21:34Z
- **Tasks:** 1
- **Files created:** 1

## Accomplishments
- Created complete Stoa version definition module at `src/Chainweb/Version/Stoa.hs`
- Configured Petersen graph topology (10 chains, degree 3, diameter 2) instead of Twenty chain graph
- Set max block gas limit hard cap at 500,000 (GAS-01 requirement)
- All 37 Fork constructors covered via wildcard pattern (`_ -> AllChains ForkAtGenesis`)
- Genesis payloads configured for chains 0-9 only (matching Petersen graph vertices)

## Task Commits

Each task was committed atomically:

1. **Task 1: Create src/Chainweb/Version/Stoa.hs with complete version definition** - `77a7f0b` (feat)

## Files Created/Modified
- `src/Chainweb/Version/Stoa.hs` - Stoa chain version definition with all ChainwebVersion record fields

## Decisions Made
- Version code 0x0000_000A (decimal 10) chosen after verifying no conflicts across source and test files
- Genesis time set to `2026-03-01T00:00:00.000000` as a meaningful placeholder date
- PoW disabled for Phase 2 testing (`_disablePow = True`); Phase 5 will switch to `False`
- Using devnet genesis payloads (DN0, DNN) as temporaries since Stoa-specific payloads require the Ea tool (Phase 3)
- Header base size kept at `318 - 110` (208 bytes) since Petersen graph has degree 3, same as Twenty chain graph

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Stoa version definition ready for registration in Registry.hs (Plan 02-02)
- Module exports `stoa` and `pattern Stoa` for import by other modules
- Devnet genesis payloads used temporarily; Phase 3 will generate Stoa-specific ones via the Ea tool
- `_versionHeaderBaseSizeBytes = 318 - 110` correct for Petersen graph (degree 3)

## Self-Check: PASSED

- FOUND: src/Chainweb/Version/Stoa.hs
- FOUND: commit 77a7f0b
- FOUND: 02-01-SUMMARY.md

---
*Phase: 02-version-definition-and-gas-limits*
*Completed: 2026-02-11*
