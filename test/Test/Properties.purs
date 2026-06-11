module Test.Properties (spec) where

import Prelude
import Data.BigInt as BI
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import FinVM.Numeric.BigInt as FinBI
import FinVM.Numeric.Fixed as Fixed
import FinVM.Numeric.Rounding (Rounding(..))
import Test.QuickCheck (Result, (===))
import Test.QuickCheck.Arbitrary (class Arbitrary, arbitrary)
import Test.QuickCheck.Gen (Gen, chooseInt)
import Test.Spec (Spec, describe, it)
import Test.Spec.QuickCheck (quickCheck)

-- Simple wrapper for BigInt to provide Arbitrary instance
newtype TestBI = TestBI BI.BigInt
instance arbitraryTestBI :: Arbitrary TestBI where
  arbitrary = do
    n <- arbitrary
    pure $ TestBI (BI.fromInt n)

-- Property: (a + b) mod m === (b + a) mod m
prop_modAdd_commutative :: TestBI -> TestBI -> TestBI -> Result
prop_modAdd_commutative (TestBI a) (TestBI b) (TestBI m) =
  if m == BI.fromInt 0 then true === true
  else FinBI.modAdd a b m === FinBI.modAdd b a m

-- Property: Fixed rescale up then down returns original (if within precision)
prop_fixed_rescale_idempotent :: Int -> Int -> Result
prop_fixed_rescale_idempotent val s =
  let
    scale = (s `mod` 5) + 1
    higherScale = scale + 2
    f = { value: BI.fromInt val, scale: scale }
  in
    case Fixed.rescale f higherScale RoundDown of
      Left _ -> true === false
      Right fUp ->
        case Fixed.rescale fUp scale RoundDown of
          Left _ -> true === false
          Right fDown -> fDown.value === f.value

spec :: Spec Unit
spec = do
  describe "FinVM Properties (QuickCheck)" do
    it "modAdd is commutative" do
      quickCheck prop_modAdd_commutative
    it "Fixed point rescale up/down is idempotent" do
      quickCheck prop_fixed_rescale_idempotent
