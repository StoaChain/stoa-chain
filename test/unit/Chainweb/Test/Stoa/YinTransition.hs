{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- |
-- Module: Chainweb.Test.Stoa.YinTransition
-- License: MIT
-- Stability: experimental
--
-- Mines an in-process network ACROSS the StoaMinGasPrice activation height and
-- asserts that the behaviour actually changes at the boundary.
--
-- Every other test of the Yin engine checks a decision in isolation:
-- "Chainweb.Test.Stoa.GasFloor" checks the floor and the predicate, and the
-- read-only replay checks that existing history is unaffected. None of them run
-- a live network THROUGH the fork, which is the one thing that actually happens
-- in production at height 600,000. That is what this does.
--
-- Three assertions:
--
--   1. Before the height, a transaction priced at the legacy static minimum
--      (0.00000001 STOA = 10,000 ANU) is accepted and mined.
--   2. After the height, the identical pricing is REJECTED -- and rejected at
--      submission, because the mempool shares 'validateParsedChainwebTx' with
--      block validation.
--   3. After the height, a transaction priced at the current floor is accepted
--      and mined. This is the one that matters most: it shows the fork does not
--      simply break everything, and that a correctly updated client keeps
--      working across the boundary.
--
module Chainweb.Test.Stoa.YinTransition
( tests
) where

import Chainweb.Graph (petersenChainGraph)
import Chainweb.Storage.Table.RocksDB (RocksDb)
import Chainweb.Test.Pact5.CmdBuilder
import Chainweb.Test.Pact5.CutFixture (advanceAllChains_)
import Chainweb.Test.Pact5.RemotePactTest hiding (tests)
import Chainweb.Test.Pact5.Utils (successfulTx)
import Chainweb.Test.TestVersions (yinTransitionCpmTestVersion)
import Chainweb.Time
import Chainweb.Version
import Chainweb.Version.Stoa.GasFloor

import Control.Lens
import Control.Monad (replicateM_)
import Control.Monad.IO.Class
import Control.Monad.Trans.Resource (runResourceT)

import Data.Decimal (DecimalRaw(..))

import Pact.Core.ChainData (TxCreationTime(..))
import Pact.Core.Command.Types hiding (ChainId)
import Pact.Core.Gas

import PropertyMatchers ((?))
import PropertyMatchers qualified as P

import Servant.Client (responseBody)

import Test.Tasty
import Test.Tasty.HUnit

-- | Everything at genesis except StoaMinGasPrice, which sits at height 20.
v :: ChainwebVersion
v = yinTransitionCpmTestVersion petersenChainGraph

chain0 :: ChainId
chain0 = unsafeChainId 0

-- | The legacy static minimum: 0.00000001 STOA = 10,000 ANU. This is what every
-- StoaChain transaction paid before the Yin engine, and what an un-upgraded
-- wallet would keep paying after it.
legacyPriceAnu :: Integer
legacyPriceAnu = 10_000

-- | ANU as a Pact gas price. Built with the fixed-point constructor rather than
-- by dividing, so the value is exact.
anuPrice :: Integer -> GasPrice
anuPrice anu = GasPrice (Decimal 12 anu)

tests :: RocksDb -> TestTree
tests baseRdb = testGroup "Yin engine fork transition"
    [ testCaseSteps "behaviour changes at the activation height" $ \step ->
        runResourceT $ do
            fx <- mkFixture v baseRdb
            liftIO $ do
                now <- do
                    Time ts <- getCurrentTimeIntegral @Integer
                    pure (fromIntegral (timeSpanToSeconds ts) :: Integer)
                let floorNow = stoaMinGasPriceAnu now
                    mkTx anu = buildTextCmd v
                        $ set cbGasPrice (anuPrice anu)
                        $ set cbCreationTime (Just (TxCreationTime now))
                        $ set cbRPC (mkExec' "1")
                        $ defaultCmd chain0

                step $ "floor is " <> show floorNow <> " ANU; legacy price is "
                       <> show legacyPriceAnu <> " ANU"
                -- If the floor had not yet risen above the legacy price this test
                -- would pass vacuously, so make that a hard failure instead.
                assertBool
                    "test is vacuous unless the floor has risen above the legacy price"
                    (floorNow > legacyPriceAnu)

                -- (1) BEFORE the fork: legacy pricing is accepted.
                step "pre-fork: legacy-priced transaction is accepted and mined"
                preTx <- mkTx legacyPriceAnu
                send fx v chain0 [preTx]
                advanceAllChains_ fx
                poll fx v chain0 [cmdToRequestKey preTx]
                    >>= P.list [P.match _Just successfulTx]

                -- Cross the activation height.
                step "mining across the activation height (20)"
                replicateM_ 25 (advanceAllChains_ fx)

                -- (2) AFTER the fork: identical pricing is now rejected, at
                -- submission, by the shared validator.
                step "post-fork: legacy-priced transaction is REJECTED"
                postTx <- mkTx legacyPriceAnu
                send fx v chain0 [postTx]
                    & P.throws ? P.match _FailureResponse ? P.fun responseBody
                    ? textContains "below minimum gas price"

                -- (3) AFTER the fork: paying the floor still works.
                step "post-fork: floor-priced transaction is accepted and mined"
                okTx <- mkTx floorNow
                send fx v chain0 [okTx]
                advanceAllChains_ fx
                poll fx v chain0 [cmdToRequestKey okTx]
                    >>= P.list [P.match _Just successfulTx]
    ]
