{-# language LambdaCase #-}
{-# language NumericUnderscores #-}
{-# language OverloadedStrings #-}
{-# language PatternSynonyms #-}
{-# language QuasiQuotes #-}
{-# language ViewPatterns #-}

-- | Stoa chain version definition.

module Chainweb.Version.Stoa(stoa, pattern Stoa) where

import qualified Data.Set as Set

import Chainweb.BlockCreationTime
import Chainweb.BlockHeight
import Chainweb.ChainId
import Chainweb.Difficulty
import Chainweb.Graph
import Chainweb.HostAddress
import Chainweb.Time
import Chainweb.Utils
import Chainweb.Utils.Rule
import Chainweb.Version
import Chainweb.Pact5.InitialGasModel

import Pact.Types.Verifier

import qualified Chainweb.BlockHeader.Genesis.Stoa0Payload as S0
import qualified Chainweb.BlockHeader.Genesis.Stoa1to9Payload as SN

pattern Stoa :: ChainwebVersion
pattern Stoa <- ((== stoa) -> True) where
    Stoa = stoa

stoa :: ChainwebVersion
stoa = ChainwebVersion
    { _versionCode = ChainwebVersionCode 0x0000_000A
    , _versionName = ChainwebVersionName "stoa"
    -- WARNING: this wildcard puts EVERY fork at genesis, including any new
    -- Fork constructor a future upstream port introduces. That is correct
    -- for StoaChain's history, but it is NOT safe for consensus-changing
    -- forks: ForkAtGenesis is `minBound`, so such a guard reads as
    -- always-true and retroactively rewrites our entire history.
    -- Any future fork that changes execution semantics must be listed
    -- explicitly above the wildcard, as Chainweb32 is.
    , _versionForks = tabulateHashMap $ \case
        -- Chainweb32 gates the Pact 5.4.1 security fixes: issue #1 (identity
        -- forgery -- a WebAuthn signer with a forged `addr` impersonating any
        -- ED25519 keyset holder) and issue #2 (capability theft via
        -- compose-capability across module boundaries).
        --
        -- ACTIVATION HEIGHT 516,500, brought forward 2026-08-26 from the
        -- original 525,000 to close issue #2 (capability theft via
        -- compose-capability) sooner. Chain tip was 516,149 at 20:25 UTC, so
        -- this is 351 blocks -- about 3 hours at our 30 s block delay. Every
        -- node must be on v3.2.1-stoa.2 before this height or it will stall.
        --
        -- The height MUST stay ahead of the live tip. A fork height in the
        -- past is not "activate immediately" -- it retroactively rewrites the
        -- rules for blocks that already exist, so replay recomputes their gas,
        -- their payload hashes move, and the node rejects our own history.
        -- Same failure as gating at genesis, smaller window.
        --
        -- Must NOT be at genesis: ForkAtGenesis is minBound, so the guard
        -- would read as always-true and retroactively apply 5.4.1 semantics
        -- to our whole history, breaking replay.
        Chainweb32 -> AllChains (ForkAtBlockHeight $ BlockHeight 516_500)
        _ -> AllChains ForkAtGenesis
    , _versionUpgrades = AllChains mempty
    , _versionGraphs = Bottom (minBound, petersenChainGraph)
    , _versionBlockDelay = BlockDelay 30_000_000
    , _versionWindow = WindowWidth 120
    , _versionHeaderBaseSizeBytes = 318 - 110
    , _versionBootstraps = domainAddr2PeerInfo
        [ unsafeHostAddressFromText "node1.stoachain.com:1789"
        , unsafeHostAddressFromText "node2.stoachain.com:1789"
        ]
    , _versionGenesis = VersionGenesis
        { _genesisBlockTarget = AllChains $ HashTarget (maxBound `div` 100_000)
        , _genesisTime = AllChains $ BlockCreationTime [timeMicrosQQ| 2026-02-23T18:00:00.000000 |]
        , _genesisBlockPayload = onChains $ concat
            [ [(unsafeChainId 0, S0.payloadBlock)]
            , [(unsafeChainId i, SN.payloadBlock) | i <- [1..9]]
            ]
        }

    -- Hard cap at 2M gas per block (GAS-01)
    , _versionMaxBlockGasLimit = Bottom (minBound, Just 2_000_000)
    -- pre31GasModel for all history: StoaChain has always billed with the
    -- original formula, and changing it retroactively would recompute gas
    -- for every past transaction, move payload hashes and break replay.
    --
    -- post32GasModel activates at 516,500, the SAME height as Chainweb32,
    -- so one fork turns on every remaining fix at once. It closes issue #3
    -- (unmetered signature size), #4 (unmetered verification CPU) and #7
    -- (unmetered SPV continuation-proof size, via proofSizeFactor).
    --
    -- These two heights must never diverge. Splitting them would create a
    -- window where Pact runs 5.4.1 semantics while gas is still billed by the
    -- old model, or vice versa -- a second consensus boundary nobody tested.
    , _versionInitialGasModel = AllChains $
        (ForkAtBlockHeight (BlockHeight 516_500), post32GasModel) `Above`
        Bottom (minBound, pre31GasModel)
    , _versionSpvProofRootValidWindow = Bottom (minBound, Nothing)
    , _versionCheats = VersionCheats
        { _disablePow = False
        , _fakeFirstEpochStart = True
        , _disablePact = False
        }
    , _versionDefaults = VersionDefaults
        { _disablePeerValidation = True
        , _disableMempoolSync = False
        }
    , _versionVerifierPluginNames = AllChains $ Bottom
        (minBound, Set.fromList $ map VerifierName ["hyperlane_v3_message", "allow", "signed_list"])
    , _versionQuirks = noQuirks
    , _versionForkNumber = 0
    -- Fork-vote epoch: 120 * 119 casting blocks + 120 counting = 14,400
    -- blocks. At our 30 s block delay that is exactly 5 days, matching
    -- every upstream version. Reproduces the pre-wave-4 hardcoded
    -- forkEpochLength = 120 * 120 bit-for-bit.
    , _versionForkVoteCastingLength = 120 * 119
    }
