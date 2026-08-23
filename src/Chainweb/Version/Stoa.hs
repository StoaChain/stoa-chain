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
    -- Fork constructor a future upstream port introduces. That is correct for
    -- StoaChain's history so far, but it is NOT safe for `Chainweb32` when
    -- that arrives: ForkAtGenesis is `minBound`, so the `chainweb32` guard
    -- would read as always-true and retroactively apply Pact 5.4.1 semantics
    -- to our entire chain, diverging replay. Set Chainweb32 explicitly to a
    -- future block height before taking waves 5 and 6.
    , _versionForks = tabulateHashMap $ \case
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
    -- Keep the pre-3.1 initial gas model at genesis: StoaChain has always
    -- billed with the original formula, and changing it retroactively would
    -- recompute gas for every historical transaction, moving payload hashes
    -- and breaking replay. Activating post32GasModel (which closes issues #3
    -- and #4 by charging signature size and verification CPU) must be done
    -- with a rule keyed at a FUTURE block height, as its own decision.
    , _versionInitialGasModel = AllChains $ Bottom (minBound, pre31GasModel)
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
