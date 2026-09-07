{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NumericUnderscores #-}

-- |
-- Module: Chainweb.Test.Stoa.GasFloor
-- License: MIT
-- Stability: experimental
--
-- Tests for the StoaChain protocol minimum gas price -- the "Yin engine".
--
-- Two things are under test here, and the second one matters more than it
-- looks:
--
--   1. 'stoaMinGasPriceAnu' itself, against a fixed vector list. That same list
--      is the contract for the on-chain Pact mirror
--      (@coin.UC_MinimumGasPriceANU@) and for the client libraries, so these
--      numbers must not be "corrected" -- if one of them fails, an
--      implementation has drifted, and the fix belongs in the implementation.
--
--   2. The fork table. @Chainweb.Version.Stoa@ ends its fork table with a
--      @_ -> AllChains ForkAtGenesis@ wildcard, so a 'Fork' constructor that is
--      not listed explicitly silently becomes active AT GENESIS. For a
--      consensus-changing fork that retroactively rewrites the rules for every
--      block ever mined: replay recomputes their gas, payload hashes move, and
--      the node rejects its own history. Mainnet\/Testnet04\/RecapDevelopment
--      enumerate their tables exhaustively so @-Wall -Werror@ forces a decision
--      there; stoa and development do not. These assertions are the substitute
--      for the compiler check that stoa does not get.
--
module Chainweb.Test.Stoa.GasFloor
( tests
) where

import Chainweb.BlockHeight
import Chainweb.Pact5.Transaction qualified as Pact5
import Chainweb.Pact5.Validations
import Chainweb.Test.Pact5.CmdBuilder
import Chainweb.Version
import Chainweb.Version.Development
import Chainweb.Version.Guards
import Chainweb.Version.Mainnet
import Chainweb.Version.RecapDevelopment
import Chainweb.Version.Stoa
import Chainweb.Version.Stoa.GasFloor
import Chainweb.Version.Testnet04

import Control.Lens

import Data.Decimal (DecimalRaw(..))

import Pact.Core.ChainData (TxCreationTime(..))
import Pact.Core.Gas.Types (GasPrice(..))

import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

tests :: TestTree
tests = testGroup "Stoa minimum gas price (Yin engine)"
    [ testGroup "floor vectors" vectorTests
    , testGroup "fork table" forkTableTests
    , testGroup "consensus check (assertMinGasPrice)" gasPriceTests
    , testGroup "properties" propertyTests
    ]

-- -------------------------------------------------------------------------- --
-- The consensus check itself

-- | A reference creation time and the floor at that instant.
refTime :: Integer
refTime = 1_788_696_000     -- 2026-09-06T12:00:00Z

refFloor :: Integer
refFloor = 11_558

-- | Build a REAL signed transaction priced at @anu@ whole ANU with the given
-- creation time, and run the consensus predicate over it at height @h@.
--
-- Uses the same CmdBuilder the Pact5 tests use, so this exercises the actual
-- lens paths and the actual PublicMeta encoding -- not a hand-assembled record.
checkAt :: ChainwebVersion -> BlockHeight -> Integer -> Integer -> IO Bool
checkAt v h anu ct = do
    tx <- buildCwCmd v $ defaultCmd (unsafeChainId 0)
        & cbGasPrice .~ GasPrice (Decimal 12 anu)
        & cbCreationTime ?~ TxCreationTime ct
    return $ assertMinGasPrice v (unsafeChainId 0) h (view Pact5.payloadObj <$> tx)

gasPriceTests :: [TestTree]
gasPriceTests =
    [ testCase "before the fork height, even a zero gas price is accepted" $
        checkAt stoa (BlockHeight 599_999) 0 refTime
            >>= assertBool "must be vacuously true pre-fork"

    -- The row that matters most: a correct client emits EXACTLY the floor, so
    -- an off-by-one here (`>` instead of `>=`) would reject every honest
    -- transaction on the chain.
    , testCase "at the fork height, paying EXACTLY the floor is accepted" $
        checkAt stoa (BlockHeight 600_000) refFloor refTime
            >>= assertBool "exact floor must pass"

    , testCase "at the fork height, one ANU below the floor is REJECTED" $
        checkAt stoa (BlockHeight 600_000) (refFloor - 1) refTime
            >>= assertBool "underpaying by 1 ANU must fail" . not

    , testCase "at the fork height, paying above the floor is accepted" $
        checkAt stoa (BlockHeight 600_000) (refFloor + 5000) refTime
            >>= assertBool "overpaying must pass"

    , testCase "the floor is taken from the transaction's OWN creationTime" $ do
        -- Same price, two creation times either side of a tick boundary: the
        -- earlier one is fine, the later one is one ANU short.
        let tickStart = 1_771_880_400   -- first second of tick 1, floor 10001
        checkAt stoa (BlockHeight 600_000) 10_000 (tickStart - 1)
            >>= assertBool "10000 ANU at end of tick 0 passes"
        checkAt stoa (BlockHeight 600_000) 10_000 tickStart
            >>= assertBool "10000 ANU at start of tick 1 fails" . not

    , testCase "no other version is affected, at any height" $
        mapM_ (\v -> checkAt v (BlockHeight 9_999_999) 0 refTime
                        >>= assertBool "must be vacuously true")
            [mainnet, testnet04, devnet, recapDevnet]
    ]

-- -------------------------------------------------------------------------- --
-- Vectors

-- | (creation time in unix seconds, expected ANU, description).
--
-- This list is the CONTRACT shared by all three implementations of the floor.
-- The same instants and the same expected ANU values appear in:
--
--   * @pact\/stoa-xchain\/min-gas-price-pinning.repl@ -- asserts the on-chain
--     Pact mirror @coin.UC_MinimumGasPriceANU@ agrees. Run it under pact 5.4.1
--     from the OuroNet sandbox; see that file's header. Last run 2026-09-07:
--     PASS, and verified falsifiable.
--   * @docs\/stoa\/yin-engine-client-handoff.md@ §6 -- the client libraries.
--
-- If a row here changes, it must change in both of those too, and that is a
-- consensus-affecting change requiring a coordinated coin upgrade and fork.
--
-- Do not delete rows for looking boring: the tick-boundary rows catch
-- off-by-one errors and the pre-genesis rows catch the wrong rounding mode
-- (@floor@ vs @truncate@, and spurious lower clamping).
vectors :: [(Integer, Integer, String)]
vectors =
    [ (1_771_869_600,      10_000, "genesis exactly")
    , (1_771_869_601,      10_000, "genesis + 1s")
    , (1_771_880_399,      10_000, "last second of tick 0")
    , (1_771_880_400,      10_001, "first second of tick 1")
    , (1_788_696_000,      11_558, "2026-09-06T12:00:00Z")
    , (12_463_869_600, 1_000_000, "cap reached, 2364-12-18T18:00:00Z")
    , (14_000_000_000, 1_000_000, "well past the cap")
    , (1_771_869_599,       9_999, "1s BEFORE genesis: no lower clamp")
    , (1_771_858_799,       9_998, "10801s before genesis")
    ]

vectorTests :: [TestTree]
vectorTests =
    [ testCase (show t <> " -> " <> show expected <> " (" <> lbl <> ")") $
        assertEqual lbl expected (stoaMinGasPriceAnu t)
    | (t, expected, lbl) <- vectors
    ]
    <>
    [ testCase "constants match the deployed coin module" $ do
        assertEqual "GENESIS-TIME (2026-02-23T18:00:00Z)" 1_771_869_600 stoaGasFloorGenesis
        assertEqual "GENESIS-MIN-GAS-PRICE"                      10_000 stoaGasFloorMin
        assertEqual "MAX-GAS-PRICE"                           1_000_000 stoaGasFloorMax
        assertEqual "GAS-PRICE-INTERVAL"                         10_800 stoaGasFloorInterval
        assertEqual "ANU per STOA"                   1_000_000_000_000 anuPerStoa
    ]

-- -------------------------------------------------------------------------- --
-- Fork table

-- | The height the Yin engine activates on stoa.
stoaActivation :: BlockHeight
stoaActivation = BlockHeight 600_000

forkOf :: ChainwebVersion -> ForkHeight
forkOf v = v ^?! versionForks . at StoaMinGasPrice . _Just . atChain (unsafeChainId 0)

forkTableTests :: [TestTree]
forkTableTests =
    [ testCase "stoa: activates at a FUTURE block height, never at genesis" $ do
        assertEqual "fork height" (ForkAtBlockHeight stoaActivation) (forkOf stoa)
        assertBool "must not be ForkAtGenesis -- the wildcard hazard"
            (forkOf stoa /= ForkAtGenesis)

    , testCase "no other version enables it" $
        mapM_ (\(n, v) -> assertEqual n ForkNever (forkOf v))
            [ ("mainnet01", mainnet)
            , ("testnet04", testnet04)
            , ("development", devnet)
            , ("recap-development", recapDevnet)
            ]

    , testCase "guard is off before the height and on at/after it" $ do
        let g h = enforceStoaMinGasPrice stoa (unsafeChainId 0) (BlockHeight h)
        assertBool "genesis"    (not (g 0))
        assertBool "h-1"        (not (g 599_999))
        assertBool "h (atOrAfter, not after)" (g 600_000)
        assertBool "h+1"        (g 600_001)

    , testCase "guard is off on every other version at any height" $ do
        let g v h = enforceStoaMinGasPrice v (unsafeChainId 0) (BlockHeight h)
        mapM_ (\v -> assertBool "should be off" (not (g v 9_999_999)))
            [mainnet, testnet04, devnet, recapDevnet]
    ]

-- -------------------------------------------------------------------------- --
-- Properties

propertyTests :: [TestTree]
propertyTests =
    [ testProperty "non-decreasing in time" $ \a b ->
        let (lo, hi) = if a <= b then (a, b) else (b, a)
        in stoaMinGasPriceAnu lo <= stoaMinGasPriceAnu hi

    , testProperty "never exceeds the cap" $ \t ->
        stoaMinGasPriceAnu t <= stoaGasFloorMax

    -- Generate the offset from genesis directly rather than filtering with
    -- (==>): QuickCheck's default Integer generator produces values near zero,
    -- so an implication on `t >= genesis` discards every candidate and gives up.
    , testProperty "at or after genesis, never below the genesis minimum" $
        forAll (choose (0, 2 * stoaGasFloorMax * stoaGasFloorInterval)) $ \d ->
            stoaMinGasPriceAnu (stoaGasFloorGenesis + d) >= stoaGasFloorMin

    , testProperty "rises by exactly 1 ANU per interval, below the cap" $ \n ->
        let k = abs n `mod` 100_000
            t = stoaGasFloorGenesis + k * stoaGasFloorInterval
        in stoaMinGasPriceAnu t == stoaGasFloorMin + k

    , testProperty "constant within an interval" $ \n o ->
        let k      = abs n `mod` 100_000
            offset = abs o `mod` stoaGasFloorInterval
            t0     = stoaGasFloorGenesis + k * stoaGasFloorInterval
        in stoaMinGasPriceAnu t0 == stoaMinGasPriceAnu (t0 + offset)
    ]
