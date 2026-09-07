{-# language NumericUnderscores #-}

-- | The StoaChain protocol minimum gas price -- the "Yin engine".
--
-- The minimum gas price is not a constant. It starts at 10,000 ANU at genesis
-- and rises by 1 ANU every 3 hours, capped at 400,000 ANU:
--
-- > F(t) = min( 10000 + floor( (t - GENESIS) / 10800 ), 1000000 )   [ANU]
--
-- This module is the CONSENSUS-AUTHORITATIVE implementation. It is mirrored
-- on-chain by @coin.UC_MinimumGasPriceANU@
-- (@pact\/genesis\/stoa\/stoa-genesis-4.pact:412@), which is what the
-- cross-chain gas-station guards read, and by the client libraries that
-- pre-fill @gasPrice@. All three MUST agree exactly; a node that computes a
-- different floor than its peers is a chain split. The pinning test asserts
-- Haskell == Pact over a fixed vector list.
--
-- Deliberate properties, none of which may be "tidied up":
--
--   * __Integer arithmetic only.__ No 'Double', no 'Rational', nothing whose
--     result could differ between platforms. This value gates block validation.
--
--   * __Bit-identical to the Pact mirror, including for unreachable inputs.__
--     Pact computes @10000 + floor(elapsed \/ 10800)@ and then clamps only the
--     UPPER bound. Haskell's 'div' truncates toward negative infinity, which is
--     exactly Pact's @floor@, so a pre-genesis timestamp yields a value below
--     10,000 in both. That is semantically odd but deliberately preserved:
--     matching everywhere is worth more than being tidy in a region that cannot
--     occur. (It cannot occur because @assertTxTimeRelativeToParent@ bounds a
--     transaction's creation time to within its TTL of the parent block, and
--     @defaultMaxTTLSeconds@ is 2 days.)
--
--   * __The unit is ANU, never STOA.__ 1 STOA = 1e12 ANU. Comparisons scale a
--     gas price UP into ANU by multiplying; they never divide a floor DOWN into
--     STOA. A transaction's gas price is capped at 12 decimal places by
--     @assertGasPrice@, which is exactly ANU granularity, so @gasPrice * 1e12@
--     is always a whole number and the comparison is exact. Do not relax that
--     precision check.
--
-- The four constants are duplicated at @stoa-genesis-4.pact:84-89@. They are not
-- independently tunable: changing one means an on-chain @coin@ module upgrade
-- and a new fork, together.
--
module Chainweb.Version.Stoa.GasFloor
(
-- * Constants
  stoaGasFloorGenesis
, stoaGasFloorMin
, stoaGasFloorMax
, stoaGasFloorInterval
, anuPerStoa
-- * The floor
, stoaMinGasPriceAnu
) where

-- | Unix seconds of @GENESIS-TIME@, 2026-02-23T18:00:00Z.
--
-- Identical to @_genesisTime@ of the @stoa@ 'Chainweb.Version.ChainwebVersion'
-- (@Chainweb.Version.Stoa@) and to @GENESIS-TIME@ at
-- @stoa-genesis-4.pact:84@.
stoaGasFloorGenesis :: Integer
stoaGasFloorGenesis = 1_771_869_600

-- | @GENESIS-MIN-GAS-PRICE@ -- the floor at genesis, in ANU.
stoaGasFloorMin :: Integer
stoaGasFloorMin = 10_000

-- | @MAX-GAS-PRICE@ -- the hard cap the floor never exceeds, in ANU.
--
-- 1,000,000 ANU is exactly one microSTOA per unit of gas, so this is the
-- protocol's standing promise: the minimum gas price will never exceed
-- 0.000001 STOA/gas. Reached 2364-12-18 -- 990,000 ticks, 123,750 days, ~339
-- years after genesis.
--
-- This is the hardest constant in the file to change: raising it requires an
-- on-chain @coin@ module upgrade AND a consensus fork, applied together. It was
-- set high deliberately, because the curve below the cap is bit-identical at any
-- cap value, so a distant cap costs nothing while a near one costs a fork.
--
-- Note that the cap is also the ONLY constant here whose Pact\/Haskell mismatch
-- is not immediately fatal: two implementations disagreeing about the cap still
-- agree on every value until 2159. The pinning test covers the cap region
-- anyway, and a failure there means the @coin@ upgrade has not landed yet --
-- fix the deployment, never the test.
stoaGasFloorMax :: Integer
stoaGasFloorMax = 1_000_000

-- | @GAS-PRICE-INTERVAL@ -- one tick, in seconds. Three hours.
stoaGasFloorInterval :: Integer
stoaGasFloorInterval = 10_800

-- | ANU per STOA. ANU is the smallest unit of the coin.
anuPerStoa :: Integer
anuPerStoa = 1_000_000_000_000

-- | The protocol minimum gas price, in ANU, for a transaction whose creation
-- time is the given unix-seconds value.
--
-- Total, pure, and integral. The argument is the transaction's OWN
-- @creationTime@ -- not the block time, and not "now". That choice is what makes
-- the rule raceless for clients: a client stamps @creationTime@ and derives
-- @gasPrice@ from the same value that consensus will later feed to this
-- function.
stoaMinGasPriceAnu
    :: Integer
        -- ^ creation time, unix seconds
    -> Integer
        -- ^ minimum gas price, ANU
stoaMinGasPriceAnu creationTime = min stoaGasFloorMax raw
  where
    -- 'div' truncates toward negative infinity, matching Pact's 'floor'.
    -- Only the upper bound is clamped -- see the module header.
    raw = stoaGasFloorMin
        + ((creationTime - stoaGasFloorGenesis) `div` stoaGasFloorInterval)
