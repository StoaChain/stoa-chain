---
phase: 04-tokenomics
verified: 2026-02-11T08:15:00Z
status: passed
score: 4/4 must-haves verified
re_verification: false
---

# Phase 4: Tokenomics Verification Report

**Phase Goal:** STOA-specific miner rewards are defined with a declining emission schedule that correctly divides by 10 chains, and the 90/10 miner/vault split operates correctly

**Verified:** 2026-02-11T08:15:00Z
**Status:** PASSED
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| #   | Truth                                                                                         | Status     | Evidence                                                                                                  |
| --- | --------------------------------------------------------------------------------------------- | ---------- | --------------------------------------------------------------------------------------------------------- |
| 1   | STOA miner rewards CSV exists with declining emission schedule covering 120+ years            | ✓ VERIFIED | `rewards/miner_rewards.csv` has 1482 entries, year 0 = 4.604 STOA/block, declining to 1.324 at year 120 |
| 2   | SHA512 hash constants match the new CSV (raw file hash and parsed table hash)                 | ✓ VERIFIED | Both hashes updated in `MinerReward.hs` (commits 35ccd3f, 1baa57d)                                       |
| 3   | blockMinerReward divides by 10 (Petersen graph order) producing correct per-chain values      | ✓ VERIFIED | Test `test_stoaBlockRewardDividesByTen` verifies CSV total / 10 = per-chain reward                       |
| 4   | 90/10 emission split verified at years 0, 1, and 10 with correct ratios and declining values | ✓ VERIFIED | REPL tests verify exact emission values and 90/10 ratio within 0.01% tolerance at all checkpoints        |
| 5   | Chain 0 coinbase mints to miner and injects 10% to UrStoa vault at multiple time points      | ✓ VERIFIED | REPL tests verify vault balance increases by urv-emission at years 0 and 1                               |
| 6   | Chains 1-9 coinbase mints only block-emission to miner with no vault interaction             | ✓ VERIFIED | REPL test on chain 5 verifies miner gets block-emission only, vault operations restricted to chain 0     |

**Score:** 6/6 truths verified

### Required Artifacts

| Artifact                                     | Expected                                                                 | Status     | Details                                                                                       |
| -------------------------------------------- | ------------------------------------------------------------------------ | ---------- | --------------------------------------------------------------------------------------------- |
| `rewards/miner_rewards.csv`                  | STOA emission schedule in block_height,total_reward format               | ✓ VERIFIED | 1482 entries, covers genesis through year 120+, contains "87600," marker, ends with ",0"     |
| `src/Chainweb/MinerReward.hs`                | Updated SHA512 hash constants for new CSV                                | ✓ VERIFIED | Contains expectedRawMinerRewardsHash and expectedMinerRewardsHash (128-char hex strings)      |
| `test/unit/Chainweb/Test/MinerReward.hs`     | Tests updated for Stoa version and new reward values                     | ✓ VERIFIED | Imports Chainweb.Version.Stoa, contains test_stoaBlockRewardDividesByTen                      |
| `pact/stoa-coin/stoa-coin.repl`              | Extended REPL tests with multi-year emission verification               | ✓ VERIFIED | Contains 5 new test transactions (lines 415-598) verifying TOKN-04 and TOKN-05 at 3 years    |
| `pact/stoa-coin/new-coin.pact` (URC_Emissions) | Emission formula computing block-emission and urv-emission               | ✓ VERIFIED | Function at line 535, used in coinbase at line 988, implements 90/10 split logic             |

**All artifacts:** VERIFIED

### Key Link Verification

| From                             | To                                   | Via                                            | Status  | Details                                                                          |
| -------------------------------- | ------------------------------------ | ---------------------------------------------- | ------- | -------------------------------------------------------------------------------- |
| `rewards/miner_rewards.csv`      | `src/Chainweb/MinerReward.hs`       | TH embedFile at compile time + SHA512 validation | ✓ WIRED | embedFile at line 261, hash validation at line 258                               |
| `src/Chainweb/MinerReward.hs`    | `src/Chainweb/Miner/Pact.hs`        | Both embed same CSV file path                  | ✓ WIRED | embedFile in Miner/Pact.hs at line 174                                           |
| `src/Chainweb/MinerReward.hs`    | Pact5/ExecBlock.hs                   | blockMinerReward used in minerReward function  | ✓ WIRED | Used at line 103 in ExecBlock.hs                                                 |
| `pact/stoa-coin/stoa-coin.repl`  | `pact/stoa-coin/new-coin.pact`       | Pact REPL loads and tests contract functions   | ✓ WIRED | REPL calls URC_Emissions (lines 430, 465, 499), coinbase (lines 545, 582)       |
| `new-coin.pact` URC_Emissions    | coinbase function                    | Emission values computed and used in minting   | ✓ WIRED | URC_Emissions called at line 988, values used at lines 989-990                  |

**All key links:** WIRED

### Requirements Coverage

| Requirement                                                          | Status        | Evidence                                                                              |
| -------------------------------------------------------------------- | ------------- | ------------------------------------------------------------------------------------- |
| TOKN-01: STOA miner rewards CSV created with declining emission schedule | ✓ SATISFIED   | CSV exists with 1482 entries covering 120+ years, commit 35ccd3f                      |
| TOKN-02: SHA512 hash constants updated for new rewards CSV              | ✓ SATISFIED   | Both hashes updated in MinerReward.hs, commit 1baa57d                                 |
| TOKN-03: Reward calculation correctly divides by 10-chain count         | ✓ SATISFIED   | Test verifies blockMinerReward Stoa 0 == CSV total / 10                              |
| TOKN-04: 90/10 miner/vault emission split operates correctly             | ✓ SATISFIED   | REPL tests verify 90/10 ratio within 0.01% at years 0, 1, 10, commit 6d36c42         |
| TOKN-05: UR-STOA vault receives 10% of emissions via coinbase           | ✓ SATISFIED   | REPL tests verify vault balance increases by urv-emission on chain 0 at years 0 and 1 |

**All requirements:** SATISFIED

### Anti-Patterns Found

| File                                        | Line | Pattern | Severity | Impact |
| ------------------------------------------- | ---- | ------- | -------- | ------ |
| None found                                  |      |         |          |        |

No TODO, FIXME, placeholder comments, empty implementations, or stub patterns detected in modified files.

### Human Verification Required

None. All verifications are automated and deterministic:
- CSV structure and values verified via file parsing
- Hash constants verified via compilation and tests
- REPL tests executed successfully (Load successful output)
- Commit hashes verified in git history
- Wiring verified via grep for imports and usage patterns

### Summary

Phase 04 goal **ACHIEVED**:

1. **Miner Rewards CSV (TOKN-01, TOKN-02, TOKN-03):** A valid STOA miner rewards CSV exists with 1482 entries covering genesis through year 120+. Both SHA512 hash constants are updated and validated. The blockMinerReward function correctly divides the CSV total by 10 (Petersen graph order) as verified by test_stoaBlockRewardDividesByTen.

2. **Emission Formula Integration:** The STOA emission formula UC_YearEmission is implemented in the Pact contract, computing yearly supply as `floor((500000*t^2 + 99500000*t + 47916000000) / ((t+99)*(t+100)), 12)`. The formula produces declining emissions from year 0 (4.604 STOA/block total) through year 120+ (1.324 STOA/block total).

3. **90/10 Split (TOKN-04):** The URC_Emissions function computes block-emission (90% to miners) and urv-emission (10% aggregated across chains to vault). REPL tests verify the 90/10 ratio is maintained within 0.01% tolerance at years 0, 1, and 10. Emission values decline monotonically over time as expected.

4. **Vault Injection (TOKN-05):** Chain 0 coinbase correctly mints block-emission to the miner and transfers urv-emission to the UrStoa vault, verified at years 0 and 1 via REPL tests that track vault balance changes. Non-zero chains (verified on chain 5) mint only block-emission to miners with no vault interaction, and vault operations are restricted to chain 0.

5. **Wiring Complete:** All key links are verified:
   - CSV embedded in MinerReward.hs and Miner/Pact.hs via Template Haskell
   - SHA512 validation at compile time and runtime
   - blockMinerReward used in Pact5/ExecBlock.hs minerReward calculation
   - URC_Emissions called by coinbase function and values used in minting logic
   - REPL tests exercise the complete flow from emission computation to vault injection

**No gaps found. All success criteria met. Phase ready to proceed.**

---

_Verified: 2026-02-11T08:15:00Z_
_Verifier: Claude (gsd-verifier)_
