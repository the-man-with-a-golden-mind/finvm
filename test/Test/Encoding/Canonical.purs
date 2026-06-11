module Test.Encoding.Canonical (spec) where

import Prelude
import Data.Map as Map
import Data.Tuple (Tuple(..))
import FinVM.Value (Value(..))
import FinVM.Encoding.Canonical as Canonical
import Data.BigInt as BI
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec = do
  describe "FinVM.Encoding.Canonical" do
    it "produces stable string for records regardless of insertion order" do
      let r1 = VRecord $ Map.fromFoldable [ Tuple "a" (VInt (BI.fromInt 1)), Tuple "b" (VInt (BI.fromInt 2)) ]
          r2 = VRecord $ Map.fromFoldable [ Tuple "b" (VInt (BI.fromInt 2)), Tuple "a" (VInt (BI.fromInt 1)) ]
      Canonical.canonicalValue r1 `shouldEqual` Canonical.canonicalValue r2
      Canonical.canonicalValue r1 `shouldEqual` "record{a:int:1,b:int:2}"

    it "produces stable string for maps regardless of insertion order" do
      let m1 = VMap $ Map.fromFoldable [ Tuple (VString "x") (VBool true), Tuple (VString "y") (VBool false) ]
          m2 = VMap $ Map.fromFoldable [ Tuple (VString "y") (VBool false), Tuple (VString "x") (VBool true) ]
      Canonical.canonicalValue m1 `shouldEqual` Canonical.canonicalValue m2

    it "distinguishes different values" do
      let v1 = VInt (BI.fromInt 42)
          v2 = VString "42"
      (Canonical.canonicalValue v1 /= Canonical.canonicalValue v2) `shouldEqual` true

    it "hashes canonical values with SHA-256" do
      Canonical.hashValue (VInt (BI.fromInt 42)) `shouldEqual` "8e5cc2a18337e30e25a6669b92076e5ce93431eefa209a68ddd13f2dd29fb36b"
