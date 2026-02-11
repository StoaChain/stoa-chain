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
import Chainweb.Time
import Chainweb.Utils
import Chainweb.Utils.Rule
import Chainweb.Version

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
    , _versionForks = tabulateHashMap $ \case
        _ -> AllChains ForkAtGenesis
    , _versionUpgrades = AllChains mempty
    , _versionGraphs = Bottom (minBound, petersenChainGraph)
    , _versionBlockDelay = BlockDelay 30_000_000
    , _versionWindow = WindowWidth 120
    , _versionHeaderBaseSizeBytes = 318 - 110
    , _versionBootstraps = []
    , _versionGenesis = VersionGenesis
        { _genesisBlockTarget = AllChains $ HashTarget (maxBound `div` 100_000)
        , _genesisTime = AllChains $ BlockCreationTime [timeMicrosQQ| 2026-02-01T00:00:00.000000 |]
        , _genesisBlockPayload = onChains $ concat
            [ [(unsafeChainId 0, S0.payloadBlock)]
            , [(unsafeChainId i, SN.payloadBlock) | i <- [1..9]]
            ]
        }

    -- Hard cap at 500k gas per block (GAS-01)
    , _versionMaxBlockGasLimit = Bottom (minBound, Just 500_000)
    , _versionMinimumBlockHeaderHistory = Bottom (minBound, Nothing)
    , _versionCheats = VersionCheats
        { _disablePow = True
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
    }
