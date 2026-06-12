module Test.Str (spec) where

import Prelude
import Data.BigInt as BI
import Data.Either (Either(..))
import FinVM.Builtin.Str as Str
import FinVM.Value (Value(..))
import FinVM.Vec as Vec
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

vint :: Int -> Value
vint = VInt <<< BI.fromInt

vlist :: Array String -> Value
vlist xs = VList (Vec.fromArray (map VString xs))

spec :: Spec Unit
spec = do
  describe "FinVM str.* builtins" do
    it "str.length counts UTF-16 code units" do
      Str.str_length_v1 [ VString "abc" ] `shouldEqual` Right (vint 3)
      Str.str_length_v1 [ VString "" ] `shouldEqual` Right (vint 0)
      -- "💡" is a surrogate pair: 2 code units
      Str.str_length_v1 [ VString "💡" ] `shouldEqual` Right (vint 2)

    it "str.concat" do
      Str.str_concat_v1 [ VString "ab", VString "cd" ] `shouldEqual` Right (VString "abcd")
      Str.str_concat_v1 [ VString "", VString "x" ] `shouldEqual` Right (VString "x")

    it "str.slice clamps start/len and tolerates out-of-range" do
      Str.str_slice_v1 [ VString "hello", vint 1, vint 3 ] `shouldEqual` Right (VString "ell")
      Str.str_slice_v1 [ VString "hello", vint (-2), vint 3 ] `shouldEqual` Right (VString "hel")
      Str.str_slice_v1 [ VString "hi", vint 0, vint 10 ] `shouldEqual` Right (VString "hi")
      Str.str_slice_v1 [ VString "hi", vint 5, vint 2 ] `shouldEqual` Right (VString "")
      Str.str_slice_v1 [ VString "hi", vint 0, vint (-1) ] `shouldEqual` Right (VString "")

    it "str.indexOf" do
      Str.str_indexOf_v1 [ VString "hello", VString "ll" ] `shouldEqual` Right (vint 2)
      Str.str_indexOf_v1 [ VString "hello", VString "z" ] `shouldEqual` Right (vint (-1))
      Str.str_indexOf_v1 [ VString "hello", VString "" ] `shouldEqual` Right (vint 0)

    it "str.split" do
      Str.str_split_v1 [ VString "a,b,c", VString "," ] `shouldEqual` Right (vlist ["a", "b", "c"])
      Str.str_split_v1 [ VString "abc", VString "," ] `shouldEqual` Right (vlist ["abc"])
      Str.str_split_v1 [ VString "", VString "," ] `shouldEqual` Right (vlist [""])

    it "str.toUpper / str.toLower (locale-independent)" do
      Str.str_toUpper_v1 [ VString "Hello" ] `shouldEqual` Right (VString "HELLO")
      Str.str_toLower_v1 [ VString "Hello" ] `shouldEqual` Right (VString "hello")

    it "str.trim" do
      Str.str_trim_v1 [ VString "  hi \n" ] `shouldEqual` Right (VString "hi")
      Str.str_trim_v1 [ VString "nope" ] `shouldEqual` Right (VString "nope")

    it "str.fromInt" do
      Str.str_fromInt_v1 [ vint 42 ] `shouldEqual` Right (VString "42")
      Str.str_fromInt_v1 [ vint (-7) ] `shouldEqual` Right (VString "-7")
      Str.str_fromInt_v1 [ vint 0 ] `shouldEqual` Right (VString "0")

    it "str.toInt parses strict decimals, normalizes, and returns unit on invalid" do
      Str.str_toInt_v1 [ VString "42" ] `shouldEqual` Right (vint 42)
      Str.str_toInt_v1 [ VString "007" ] `shouldEqual` Right (vint 7)
      Str.str_toInt_v1 [ VString "-0" ] `shouldEqual` Right (vint 0)
      Str.str_toInt_v1 [ VString "-5" ] `shouldEqual` Right (vint (-5))
      -- invalid -> VUnit (Option-None sentinel)
      Str.str_toInt_v1 [ VString "" ] `shouldEqual` Right VUnit
      Str.str_toInt_v1 [ VString "12a" ] `shouldEqual` Right VUnit
      Str.str_toInt_v1 [ VString "+5" ] `shouldEqual` Right VUnit
      Str.str_toInt_v1 [ VString " 5" ] `shouldEqual` Right VUnit
      Str.str_toInt_v1 [ VString "-" ] `shouldEqual` Right VUnit

    it "str.replace replaces ALL occurrences" do
      Str.str_replace_v1 [ VString "a.b.c", VString ".", VString "_" ] `shouldEqual` Right (VString "a_b_c")
      Str.str_replace_v1 [ VString "aaa", VString "a", VString "bb" ] `shouldEqual` Right (VString "bbbbbb")
      Str.str_replace_v1 [ VString "none", VString "x", VString "y" ] `shouldEqual` Right (VString "none")

    it "rejects wrong argument types/arity" do
      case Str.str_length_v1 [ vint 1 ] of
        Left _ -> pure unit
        Right _ -> "expected error" `shouldEqual` "got success"
      case Str.str_concat_v1 [ VString "a" ] of
        Left _ -> pure unit
        Right _ -> "expected error" `shouldEqual` "got success"
