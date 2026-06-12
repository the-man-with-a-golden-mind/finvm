module FinVM.Builtin where

import Prelude
import Data.Maybe (Maybe(..))
import Data.Either (Either(..))
import Data.Array as Array
import Data.Foldable (foldl)
import Data.Map as Map
import FinVM.Value (Value(..))
import FinVM.Error (VMError(..), ErrorCode(..))
import FinVM.Numeric.BigInt as BI
import FinVM.Machine (EvalConfig, BuiltinFn)
import FinVM.Encoding.Canonical as Canonical
import FinVM.Builtin.Str as Str

lookupBuiltin :: EvalConfig -> String -> Int -> Either VMError BuiltinFn
lookupBuiltin config id version = 
  -- 1. Check hardcoded internal builtins
  case id, version of
    "core.identity", 1 -> Right core_identity_v1
    "bigint.add", 1 -> Right bigint_add_v1
    "bigint.mul", 1 -> Right bigint_mul_v1
    "bigint.modPow", 1 -> Right bigint_modpow_v1
    "bigint.modInv", 1 -> Right bigint_modinv_v1
    "bigint.fromBytesBE", 1 -> Right bigint_from_bytes_be_v1
    "bigint.toBytesBE", 1 -> Right bigint_to_bytes_be_v1
    "hash.sha256", 1 -> Right hash_sha256_v1
    "logic.and", 1 -> Right logic_and_v1
    "logic.or", 1 -> Right logic_or_v1
    "logic.not", 1 -> Right logic_not_v1
    "str.length", 1 -> Right Str.str_length_v1
    "str.concat", 1 -> Right Str.str_concat_v1
    "str.slice", 1 -> Right Str.str_slice_v1
    "str.indexOf", 1 -> Right Str.str_indexOf_v1
    "str.split", 1 -> Right Str.str_split_v1
    "str.toUpper", 1 -> Right Str.str_toUpper_v1
    "str.toLower", 1 -> Right Str.str_toLower_v1
    "str.trim", 1 -> Right Str.str_trim_v1
    "str.fromInt", 1 -> Right Str.str_fromInt_v1
    "str.toInt", 1 -> Right Str.str_toInt_v1
    "str.replace", 1 -> Right Str.str_replace_v1
    _, _ ->
      -- 2. Check external/dynamic builtins provided by host
      case Map.lookup id config.externalBuiltins of
        Nothing -> Left $ VMError UnknownBuiltin ("Builtin " <> id <> " v" <> show version <> " not found")
        Just versions -> case Map.lookup version versions of
          Nothing -> Left $ VMError UnknownBuiltin ("Builtin " <> id <> " v" <> show version <> " not found")
          Just fn -> Right fn

-- Core Builtins
core_identity_v1 :: BuiltinFn
core_identity_v1 args = case args of
  [v] -> Right v
  _ -> Left $ VMError ArityMismatch "core.identity/v1 expects 1 argument"

-- BigInt Builtins
bigint_add_v1 :: BuiltinFn
bigint_add_v1 args = case args of
  [VInt a, VInt b] -> Right $ VInt (a + b)
  _ -> Left $ VMError TypeMismatch "bigint.add/v1 expects 2 BigInts"

bigint_mul_v1 :: BuiltinFn
bigint_mul_v1 args = case args of
  [VInt a, VInt b] -> Right $ VInt (a * b)
  _ -> Left $ VMError TypeMismatch "bigint.mul/v1 expects 2 BigInts"

bigint_modpow_v1 :: BuiltinFn
bigint_modpow_v1 args = case args of
  [VInt b, VInt e, VInt m] -> case BI.modPow b e m of
    Nothing -> Left $ VMError NoModularInverse "bigint.modPow/v1: negative exponent requires a modular inverse that does not exist"
    Just res -> Right $ VInt res
  _ -> Left $ VMError TypeMismatch "bigint.modPow/v1 expects 3 BigInts"

bigint_modinv_v1 :: BuiltinFn
bigint_modinv_v1 args = case args of
  [VInt a, VInt m] -> case BI.modInv a m of
    Nothing -> Left $ VMError ArithmeticError "Modular inverse does not exist"
    Just res -> Right $ VInt res
  _ -> Left $ VMError TypeMismatch "bigint.modInv/v1 expects 2 BigInts"

bigint_from_bytes_be_v1 :: BuiltinFn
bigint_from_bytes_be_v1 args = case args of
  [VBytes bytes] ->
    if Array.any (\b -> b < 0 || b > 255) bytes
      then Left $ VMError InvalidInstruction "bigint.fromBytesBE/v1 expects bytes in range 0..255"
      else Right $ VInt (foldl (\acc b -> acc * BI.fromInt 256 + BI.fromInt b) (BI.fromInt 0) bytes)
  _ -> Left $ VMError TypeMismatch "bigint.fromBytesBE/v1 expects Bytes"

bigint_to_bytes_be_v1 :: BuiltinFn
bigint_to_bytes_be_v1 args = case args of
  [VInt n] ->
    if n < BI.fromInt 0
      then Left $ VMError ArithmeticError "bigint.toBytesBE/v1 expects a non-negative BigInt"
      else Right $ VBytes (toBytesBE n)
  _ -> Left $ VMError TypeMismatch "bigint.toBytesBE/v1 expects a BigInt"

toBytesBE :: BI.BigInt -> Array Int
toBytesBE n =
  if n == BI.fromInt 0 then [0]
  else go n []
  where
    go v acc =
      if v == BI.fromInt 0 then acc
      else
        let byte = BI.toInt (v `BI.rem` BI.fromInt 256)
            next = v / BI.fromInt 256
        in case byte of
          Nothing -> acc
          Just b -> go next (Array.cons b acc)

-- Logic Builtins
logic_and_v1 :: BuiltinFn
logic_and_v1 args = case args of
  [VBool a, VBool b] -> Right $ VBool (a && b)
  _ -> Left $ VMError TypeMismatch "logic.and/v1 expects 2 Booleans"

logic_or_v1 :: BuiltinFn
logic_or_v1 args = case args of
  [VBool a, VBool b] -> Right $ VBool (a || b)
  _ -> Left $ VMError TypeMismatch "logic.or/v1 expects 2 Booleans"

logic_not_v1 :: BuiltinFn
logic_not_v1 args = case args of
  [VBool a] -> Right $ VBool (not a)
  _ -> Left $ VMError TypeMismatch "logic.not/v1 expects 1 Boolean"

-- Hashing Builtins
hash_sha256_v1 :: BuiltinFn
hash_sha256_v1 args = case args of
  [v] -> Right $ VString (Canonical.hashValue v)
  _ -> Left $ VMError ArityMismatch "hash.sha256/v1 expects 1 argument"
