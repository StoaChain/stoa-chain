---
phase: 03-genesis-payload-generation
plan: 01
subsystem: genesis
tags: [pact, yaml, ea-tool, genesis-payloads, ed25519, keysets]

# Dependency graph
requires:
  - phase: 01-stoa-coin-contract
    provides: "new-coin.pact (bundled STOA coin contract with 4 interfaces)"
  - phase: 02-version-definition-and-gas-limits
    provides: "Chainweb.Version.Stoa with Stoa pattern and stoa value"
provides:
  - "4 genesis YAML transaction files under pact/genesis/stoa/"
  - "stoa0 and stoaN Genesis records in Ea/Genesis.hs"
  - "stoaNet entry in Ea.hs main for payload generation"
  - "Ea tool compiles with Stoa version registered"
affects: [03-02-genesis-payload-generation, 04-version-wiring]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "STOA genesis uses single coin contract file (no separate interface YAMLs)"
    - "A_InitialiseStoaChain requires signed keyPairs for GOVERNANCE capability"
    - "Chain 0 gets full genesis (coin + ns + keysets + init), chains 1-9 get coin + ns only"

key-files:
  created:
    - "pact/genesis/stoa/load-stoa-coin.yaml"
    - "pact/genesis/stoa/ns.yaml"
    - "pact/genesis/stoa/keysets.yaml"
    - "pact/genesis/stoa/init-chain0.yaml"
  modified:
    - "cwtools/ea/Ea/Genesis.hs"
    - "cwtools/ea/Ea.hs"

key-decisions:
  - "Generated 8 Ed25519 key pairs via pact -g (7 master + 1 foundation); dev keys, replaceable before mainnet"
  - "Foundation account named 'stoa-foundation' (matches REPL test pattern)"
  - "Master key 1 reused for ns-admin and ns-operate keysets (follows devnet ns-v2.yaml pattern)"

patterns-established:
  - "STOA YAML files live under pact/genesis/stoa/ with stoa- prefixed nonces"
  - "codeFile paths use ../../ relative navigation from pact/genesis/stoa/ to pact/stoa-coin/ and pact/namespaces/"

# Metrics
duration: 3min
completed: 2026-02-11
---

# Phase 3 Plan 01: Genesis YAML and Ea Records Summary

**4 genesis YAML transaction files and Ea tool Genesis records for STOA chain 0 (full init) and chains 1-9 (coin + namespaces only), with 8 Ed25519 dev key pairs generated via pact -g**

## Performance

- **Duration:** 3 min
- **Started:** 2026-02-10T23:56:43Z
- **Completed:** 2026-02-11T00:00:17Z
- **Tasks:** 2
- **Files modified:** 6

## Accomplishments
- Created 4 genesis YAML files defining STOA chain genesis transactions
- Added stoa0 (chain 0) and stoaN (chains 1-9) Genesis records to Ea/Genesis.hs
- Registered Stoa version in Ea.hs and added stoaNet payload generation entry
- Verified cabal build ea succeeds (compilation + linking, zero warnings)

## Task Commits

Each task was committed atomically:

1. **Task 1: Create STOA genesis YAML transaction files** - `b28864c` (feat)
2. **Task 2: Add Stoa Genesis records and Ea tool entry** - `d7636b5` (feat)

## Files Created/Modified
- `pact/genesis/stoa/load-stoa-coin.yaml` - Deploys bundled STOA coin contract via codeFile reference to new-coin.pact
- `pact/genesis/stoa/ns.yaml` - Installs namespaces via ns-install.pact with master key 1 for admin/operate
- `pact/genesis/stoa/keysets.yaml` - Defines 7 Stoa Master keysets with unique Ed25519 public keys
- `pact/genesis/stoa/init-chain0.yaml` - Calls A_InitialiseStoaChain with foundation account and signing keypair
- `cwtools/ea/Ea/Genesis.hs` - Added stoa0/stoaN Genesis records, 4 FilePath constants, Stoa version import
- `cwtools/ea/Ea.hs` - Added registerVersion stoa, stoaNet entry in mapConcurrently_ list

## Decisions Made
- Generated 8 Ed25519 key pairs using `pact -g` for dev/testing; these are placeholder keys to be replaced before mainnet launch
- Foundation account named `stoa-foundation` consistent with REPL test usage
- Master key 1 used for both ns-admin-keyset and ns-operate-keyset (matches devnet ns-v2.yaml pattern of reusing sender00 key)
- init-chain0.yaml includes keyPairs with public+secret for master key 1 so GOVERNANCE capability can be satisfied during genesis execution

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- All Ea tool inputs are ready; Plan 03-02 can run `cabal run ea` to generate Stoa0Payload.hs and Stoa1to9Payload.hs
- The generated payload modules will need to be added to chainweb.cabal and wired into Stoa.hs (Plan 03-02 scope)
- Dev keys are in place; real keys can be swapped by editing YAML files and re-running Ea

## Self-Check: PASSED

All 6 files verified present on disk. Both task commits (b28864c, d7636b5) verified in git log. cabal build ea succeeded (compilation + linking).

---
*Phase: 03-genesis-payload-generation*
*Completed: 2026-02-11*
