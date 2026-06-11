module Test.Numeric.Fixed (spec) where

import Prelude
import Data.Either (Either(..))
import Data.BigInt as BI
import FinVM.Numeric.Fixed as Fixed
import FinVM.Numeric.Rounding (Rounding(..))
import FinVM.Error (ErrorCode(DivisionByZero))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec = do
  describe "FinVM.Numeric.Fixed" do
    let f1 = { value: BI.fromInt 123, scale: 2 } -- 1.23
        f2 = { value: BI.fromInt 456, scale: 2 } -- 4.56
        f3 = { value: BI.fromInt 1, scale: 0 }   -- 1.00

    it "adds same-scale numbers" do
      Fixed.add f1 f2 `shouldEqual` Right { value: BI.fromInt 579, scale: 2 }

    it "adds different-scale numbers" do
      Fixed.add f1 f3 `shouldEqual` Right { value: BI.fromInt 223, scale: 2 }

    it "rescales up correctly" do
      Fixed.rescale f3 2 RoundDown `shouldEqual` Right { value: BI.fromInt 100, scale: 2 }

    it "rescales down correctly (truncates)" do
      Fixed.rescale f1 0 RoundDown `shouldEqual` Right { value: BI.fromInt 1, scale: 0 }

    it "multiplies correctly" do
      Fixed.mul f1 f3 `shouldEqual` { value: BI.fromInt 123, scale: 2 }
      Fixed.mul f1 f1 `shouldEqual` { value: BI.fromInt 15129, scale: 4 }

    it "divides correctly" do
      Fixed.div f2 f1 RoundDown `shouldEqual` Right { value: BI.fromInt 370, scale: 2 } -- (4.56 / 1.23) * 100 = 370.73... -> 3.70
      -- Actually 456 / 123 = 3.707...
      -- aScaled = 456 * 100 = 45600
      -- 45600 / 123 = 370

    describe "division scale semantics" do
      let mk v s = { value: BI.fromInt v, scale: s }

      it "returns the result at the dividend's scale (1/2 at scale 0 is 0, not 0.5)" do
        Fixed.div (mk 1 0) (mk 2 0) RoundDown `shouldEqual` Right (mk 0 0)

      it "retains precision when the dividend scale is widened first" do
        -- rescale 1 up to scale 2 -> 1.00, then / 2.00 -> 0.50
        Fixed.div (mk 100 2) (mk 2 0) RoundDown `shouldEqual` Right (mk 50 2)

      it "rejects division by zero" do
        Fixed.div f1 (mk 0 0) RoundDown `shouldEqual` Left DivisionByZero

    describe "division rounding modes (7 / 2 at scale 0)" do
      let seven = { value: BI.fromInt 7, scale: 0 }
          two = { value: BI.fromInt 2, scale: 0 }
      it "RoundTowardZero -> 3" do
        Fixed.div seven two RoundTowardZero `shouldEqual` Right { value: BI.fromInt 3, scale: 0 }
      it "RoundAwayFromZero -> 4" do
        Fixed.div seven two RoundAwayFromZero `shouldEqual` Right { value: BI.fromInt 4, scale: 0 }
      it "RoundDown -> 3" do
        Fixed.div seven two RoundDown `shouldEqual` Right { value: BI.fromInt 3, scale: 0 }
      it "RoundUp -> 4" do
        Fixed.div seven two RoundUp `shouldEqual` Right { value: BI.fromInt 4, scale: 0 }
      it "RoundHalfEven -> 4 (3.5 ties to even 4)" do
        Fixed.div seven two RoundHalfEven `shouldEqual` Right { value: BI.fromInt 4, scale: 0 }

    describe "division rounding modes with negative dividend (-7 / 2 at scale 0)" do
      let negSeven = { value: BI.fromInt (-7), scale: 0 }
          two = { value: BI.fromInt 2, scale: 0 }
      it "RoundTowardZero -> -3" do
        Fixed.div negSeven two RoundTowardZero `shouldEqual` Right { value: BI.fromInt (-3), scale: 0 }
      it "RoundAwayFromZero -> -4" do
        Fixed.div negSeven two RoundAwayFromZero `shouldEqual` Right { value: BI.fromInt (-4), scale: 0 }
      it "RoundDown (toward -inf) -> -4" do
        Fixed.div negSeven two RoundDown `shouldEqual` Right { value: BI.fromInt (-4), scale: 0 }
      it "RoundUp (toward +inf) -> -3" do
        Fixed.div negSeven two RoundUp `shouldEqual` Right { value: BI.fromInt (-3), scale: 0 }
