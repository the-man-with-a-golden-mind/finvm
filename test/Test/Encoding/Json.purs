module Test.Encoding.Json (spec) where

import Prelude
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.BigInt as BI
import Data.Map as Map
import Data.Tuple (Tuple(..))
import FinVM.Value (Value(..))
import FinVM.Vec as Vec
import FinVM.Encoding.Json (valueToJson, decodeValue)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)
import Test.QuickCheck (Result, (===))
import Test.QuickCheck.Arbitrary (class Arbitrary, arbitrary)
import Test.QuickCheck.Gen (Gen, chooseInt, vectorOf)
import Test.Spec.QuickCheck (quickCheck)

-- Bounded-depth generator over the value types that are expressible as program
-- constants / state (i.e. the types `decodeValue` is meant to accept).
genValue :: Int -> Gen Value
genValue depth = do
  tag <- chooseInt 0 (if depth <= 0 then 6 else 9)
  case tag of
    0 -> (VInt <<< BI.fromInt) <$> arbitrary
    1 -> VBool <$> arbitrary
    2 -> VString <$> arbitrary
    3 -> (\v s -> VFixed { value: BI.fromInt v, scale: (s `mod` 6) }) <$> arbitrary <*> arbitrary
    4 -> (\n d -> VRational { numerator: BI.fromInt n, denominator: BI.fromInt d }) <$> arbitrary <*> arbitrary
    5 -> VSymbol <$> arbitrary
    6 -> do
      n <- chooseInt 0 6
      VBytes <$> vectorOf n (chooseInt 0 255)
    7 -> do
      n <- chooseInt 0 4
      (VList <<< Vec.fromArray) <$> vectorOf n (genValue (depth - 1))
    8 -> do
      n <- chooseInt 0 4
      (VMap <<< Map.fromFoldable) <$> vectorOf n (Tuple <$> genValue (depth - 1) <*> genValue (depth - 1))
    _ -> do
      n <- chooseInt 0 4
      (VRecord <<< Map.fromFoldable) <$> vectorOf n (Tuple <$> arbitrary <*> genValue (depth - 1))

newtype RtValue = RtValue Value
instance arbitraryRtValue :: Arbitrary RtValue where
  arbitrary = RtValue <$> genValue 3

prop_roundtrip :: RtValue -> Result
prop_roundtrip (RtValue v) = decodeValue (valueToJson v) === Right v

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
      let v = VList (Vec.fromArray [ VInt (BI.fromInt 1), VFixed { value: BI.fromInt 50, scale: 1 } ])
      roundTrip v `shouldEqual` Right v

    it "round-trips a VRecord containing a VRational" do
      let v = VRecord (Map.fromFoldable
                [ Tuple "ratio" (VRational { numerator: BI.fromInt 1, denominator: BI.fromInt 3 })
                , Tuple "name" (VString "pi-ish")
                ])
      roundTrip v `shouldEqual` Right v

    it "round-trips a VMap (regression: previously decoded as VRecord)" do
      let v = VMap (Map.fromFoldable
                [ Tuple (VInt (BI.fromInt 1)) (VString "one")
                , Tuple (VString "k") (VBool true)
                ])
      roundTrip v `shouldEqual` Right v

    it "round-trips arbitrary nested values (QuickCheck fuzz)" do
      quickCheck prop_roundtrip
