module Test.Encoding.Json (spec) where

import Prelude
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.BigInt as BI
import Data.Map as Map
import Data.Tuple (Tuple(..))
import FinVM.Value (Value(..))
import FinVM.Encoding.Json (valueToJson, decodeValue)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

-- Round-trip a value through valueToJson then decodeValue.
roundTrip :: Value -> Either String Value
roundTrip v = decodeValue (valueToJson v)

spec :: Spec Unit
spec = do
  describe "FinVM.Encoding.Json round-trip" do
    it "round-trips VInt" do
      roundTrip (VInt (BI.fromInt 42)) `shouldEqual` Right (VInt (BI.fromInt 42))

    it "round-trips a large VInt beyond safe-integer range" do
      let big = case BI.fromString "123456789012345678901234567890" of
            Just b -> b
            Nothing -> BI.fromInt 0
      roundTrip (VInt big) `shouldEqual` Right (VInt big)

    it "round-trips VFixed (regression: previously decoded as VRecord)" do
      let v = VFixed { value: BI.fromInt 12345, scale: 2 }
      roundTrip v `shouldEqual` Right v

    it "round-trips a negative VFixed" do
      let v = VFixed { value: BI.fromInt (-99), scale: 4 }
      roundTrip v `shouldEqual` Right v

    it "round-trips VRational (regression: previously decoded as VRecord)" do
      let v = VRational { numerator: BI.fromInt 22, denominator: BI.fromInt 7 }
      roundTrip v `shouldEqual` Right v

    it "round-trips VString and VBool" do
      roundTrip (VString "hello") `shouldEqual` Right (VString "hello")
      roundTrip (VBool true) `shouldEqual` Right (VBool true)

    it "round-trips a VList containing a VFixed" do
      let v = VList [ VInt (BI.fromInt 1), VFixed { value: BI.fromInt 50, scale: 1 } ]
      roundTrip v `shouldEqual` Right v

    it "round-trips a VRecord containing a VRational" do
      let v = VRecord (Map.fromFoldable
                [ Tuple "ratio" (VRational { numerator: BI.fromInt 1, denominator: BI.fromInt 3 })
                , Tuple "name" (VString "pi-ish")
                ])
      roundTrip v `shouldEqual` Right v
