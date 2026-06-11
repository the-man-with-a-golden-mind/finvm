module Test.Numeric.Rational (spec) where

import Prelude
import Data.Either (Either(..))
import Data.BigInt as BI
import FinVM.Numeric.Rational as Rational
import FinVM.Error (ErrorCode(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec = do
  describe "FinVM.Numeric.Rational" do
    let r1 = { numerator: BI.fromInt 1, denominator: BI.fromInt 2 }
        r2 = { numerator: BI.fromInt 1, denominator: BI.fromInt 3 }
        r3 = { numerator: BI.fromInt 2, denominator: BI.fromInt 4 }

    it "normalizes correctly" do
      Rational.normalize r3 `shouldEqual` Right { numerator: BI.fromInt 1, denominator: BI.fromInt 2 }
      Rational.normalize { numerator: BI.fromInt 1, denominator: BI.fromInt (-2) } `shouldEqual` Right { numerator: BI.fromInt (-1), denominator: BI.fromInt 2 }

    it "adds correctly" do
      Rational.add r1 r2 `shouldEqual` Right { numerator: BI.fromInt 5, denominator: BI.fromInt 6 }

    it "multiplies correctly" do
      Rational.mul r1 r2 `shouldEqual` Right { numerator: BI.fromInt 1, denominator: BI.fromInt 6 }

    it "divides correctly" do
      Rational.div r1 r2 `shouldEqual` Right { numerator: BI.fromInt 3, denominator: BI.fromInt 2 }

    it "handles division by zero" do
      Rational.normalize { numerator: BI.fromInt 1, denominator: BI.fromInt 0 } `shouldEqual` Left DivisionByZero
