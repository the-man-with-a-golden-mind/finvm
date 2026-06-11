module Test.Numeric.BigInt (spec) where

import Prelude hiding (not)
import Data.BigInt as BI
import Data.Maybe (Maybe(..))
import Data.Either (Either(..))
import FinVM.Builtin as Builtin
import FinVM.Numeric.BigInt as FinBI
import FinVM.Value (Value(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, fail)

spec :: Spec Unit
spec = do
  describe "FinVM.Numeric.BigInt" do
    describe "modPow" do
      it "matches BI.pow when m is 0 (or effectively no mod)" do
        let base = BI.fromInt 2
            exp = BI.fromInt 10
            m = BI.fromInt 1000000
        FinBI.modPow base exp m `shouldEqual` Just (BI.fromInt 1024)

      it "handles negative exponent via modular inverse" do
        -- 3^-1 mod 7 is 5, because 3*5 = 15 = 1 mod 7
        FinBI.modPow (BI.fromInt 3) (BI.fromInt (-1)) (BI.fromInt 7) `shouldEqual` Just (BI.fromInt 5)
        -- 3^-2 mod 7 is (3^-1)^2 mod 7 = 5^2 mod 7 = 25 mod 7 = 4
        FinBI.modPow (BI.fromInt 3) (BI.fromInt (-2)) (BI.fromInt 7) `shouldEqual` Just (BI.fromInt 4)

      it "returns Nothing when inverse doesn't exist for negative exponent" do
        -- 2^-1 mod 4 doesn't exist (gcd(2,4) /= 1)
        FinBI.modPow (BI.fromInt 2) (BI.fromInt (-1)) (BI.fromInt 4) `shouldEqual` Nothing

      it "surfaces a structured error through the builtin for a non-invertible negative exponent" do
        case Builtin.bigint_modpow_v1 [VInt (BI.fromInt 2), VInt (BI.fromInt (-1)), VInt (BI.fromInt 4)] of
          Left _ -> pure unit
          Right v -> fail $ "expected NoModularInverse error, got " <> show v

    describe "modInv" do
      it "finds the modular inverse correctly" do
        FinBI.modInv (BI.fromInt 3) (BI.fromInt 7) `shouldEqual` Just (BI.fromInt 5)
        FinBI.modInv (BI.fromInt 10) (BI.fromInt 17) `shouldEqual` Just (BI.fromInt 12)

      it "returns Nothing when gcd(a, m) /= 1" do
        FinBI.modInv (BI.fromInt 2) (BI.fromInt 4) `shouldEqual` Nothing
        FinBI.modInv (BI.fromInt 6) (BI.fromInt 9) `shouldEqual` Nothing

    describe "bitLength" do
      it "returns correct length for powers of 2" do
        FinBI.bitLength (BI.fromInt 0) `shouldEqual` 0
        FinBI.bitLength (BI.fromInt 1) `shouldEqual` 1
        FinBI.bitLength (BI.fromInt 2) `shouldEqual` 2
        FinBI.bitLength (BI.fromInt 4) `shouldEqual` 3
        FinBI.bitLength (BI.fromInt 8) `shouldEqual` 4

      it "handles negative numbers" do
        FinBI.bitLength (BI.fromInt (-1)) `shouldEqual` 1
        FinBI.bitLength (BI.fromInt (-8)) `shouldEqual` 4

    describe "byte conversion builtins" do
      it "converts unsigned big-endian bytes to BigInt" do
        Builtin.bigint_from_bytes_be_v1 [VBytes [1, 0, 2]] `shouldEqual` Right (VInt (BI.fromInt 65538))

      it "converts BigInt to unsigned big-endian bytes" do
        Builtin.bigint_to_bytes_be_v1 [VInt (BI.fromInt 65538)] `shouldEqual` Right (VBytes [1, 0, 2])
