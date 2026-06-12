-- | Pure, deterministic string builtins (the `str.*` family), implemented over
-- | JS FFI for speed. Every function is referentially transparent — same inputs
-- | always yield the same output — so it preserves FinVM determinism. Strings
-- | are UTF-16 code-unit sequences (native JS semantics); case mapping is
-- | locale-independent. The registry wires these in `FinVM.Builtin`.
module FinVM.Builtin.Str
  ( str_length_v1
  , str_concat_v1
  , str_slice_v1
  , str_indexOf_v1
  , str_split_v1
  , str_toUpper_v1
  , str_toLower_v1
  , str_trim_v1
  , str_fromInt_v1
  , str_toInt_v1
  , str_replace_v1
  ) where

import Prelude
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import FinVM.Numeric.BigInt as BI
import FinVM.Value (Value(..))
import FinVM.Vec as Vec
import FinVM.Error (VMError(..), ErrorCode(..))
import FinVM.Machine (BuiltinFn)

foreign import strLength :: String -> Int
foreign import strConcat :: String -> String -> String
foreign import strSlice :: Int -> Int -> String -> String
foreign import strIndexOf :: String -> String -> Int
foreign import strSplit :: String -> String -> Array String
foreign import strToUpper :: String -> String
foreign import strToLower :: String -> String
foreign import strTrim :: String -> String
foreign import strReplaceAll :: String -> String -> String -> String
foreign import strIsDecimalInt :: String -> Boolean

-- Convert a BigInt index/length to an Int, clamping out-of-Int-range values
-- (negatives to 0, huge positives to a large bound) so slicing never traps.
clampInt :: BI.BigInt -> Int
clampInt n = case BI.toInt n of
  Just i -> i
  Nothing -> if n < BI.fromInt 0 then 0 else 2147483647

str_length_v1 :: BuiltinFn
str_length_v1 args = case args of
  [ VString s ] -> Right $ VInt (BI.fromInt (strLength s))
  _ -> Left $ VMError TypeMismatch "str.length/v1 expects (String)"

str_concat_v1 :: BuiltinFn
str_concat_v1 args = case args of
  [ VString a, VString b ] -> Right $ VString (strConcat a b)
  _ -> Left $ VMError TypeMismatch "str.concat/v1 expects (String, String)"

str_slice_v1 :: BuiltinFn
str_slice_v1 args = case args of
  [ VString s, VInt start, VInt len ] -> Right $ VString (strSlice (clampInt start) (clampInt len) s)
  _ -> Left $ VMError TypeMismatch "str.slice/v1 expects (String, Int, Int)"

str_indexOf_v1 :: BuiltinFn
str_indexOf_v1 args = case args of
  [ VString s, VString needle ] -> Right $ VInt (BI.fromInt (strIndexOf s needle))
  _ -> Left $ VMError TypeMismatch "str.indexOf/v1 expects (String, String)"

str_split_v1 :: BuiltinFn
str_split_v1 args = case args of
  [ VString s, VString sep ] -> Right $ VList (Vec.fromArray (map VString (strSplit s sep)))
  _ -> Left $ VMError TypeMismatch "str.split/v1 expects (String, String)"

str_toUpper_v1 :: BuiltinFn
str_toUpper_v1 args = case args of
  [ VString s ] -> Right $ VString (strToUpper s)
  _ -> Left $ VMError TypeMismatch "str.toUpper/v1 expects (String)"

str_toLower_v1 :: BuiltinFn
str_toLower_v1 args = case args of
  [ VString s ] -> Right $ VString (strToLower s)
  _ -> Left $ VMError TypeMismatch "str.toLower/v1 expects (String)"

str_trim_v1 :: BuiltinFn
str_trim_v1 args = case args of
  [ VString s ] -> Right $ VString (strTrim s)
  _ -> Left $ VMError TypeMismatch "str.trim/v1 expects (String)"

str_fromInt_v1 :: BuiltinFn
str_fromInt_v1 args = case args of
  [ VInt n ] -> Right $ VString (BI.toString n)
  _ -> Left $ VMError TypeMismatch "str.fromInt/v1 expects (Int)"

-- Parse a strict decimal integer; any invalid input yields VUnit (the
-- Option-None sentinel), never an error.
str_toInt_v1 :: BuiltinFn
str_toInt_v1 args = case args of
  [ VString s ] ->
    if strIsDecimalInt s
      then case BI.fromString s of
        Just n -> Right (VInt n)
        Nothing -> Right VUnit
      else Right VUnit
  _ -> Left $ VMError TypeMismatch "str.toInt/v1 expects (String)"

str_replace_v1 :: BuiltinFn
str_replace_v1 args = case args of
  [ VString s, VString from, VString to ] -> Right $ VString (strReplaceAll s from to)
  _ -> Left $ VMError TypeMismatch "str.replace/v1 expects (String, String, String)"
