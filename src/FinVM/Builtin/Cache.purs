module FinVM.Builtin.Cache where

import Prelude
import Data.Maybe (Maybe(..))
import Data.Either (Either(..))
import Data.Map (Map)
import Data.Map as Map
import Data.Tuple (Tuple(..))
import FinVM.Value (Value(..))
import FinVM.Error (VMError(..), ErrorCode(..))
import FinVM.Machine (BuiltinFn)

cache_set_v1 :: (String -> String -> Value -> Either VMError Value) -> BuiltinFn
cache_set_v1 hostFn args = case args of
  [VString ns, VString key, val] -> hostFn ns key val
  _ -> Left $ VMError TypeMismatch "cache.set/v1 expects (Namespace:String, Key:String, Value:Value)"

cache_get_v1 :: (String -> String -> Either VMError Value) -> BuiltinFn
cache_get_v1 hostFn args = case args of
  [VString ns, VString key] -> hostFn ns key
  _ -> Left $ VMError TypeMismatch "cache.get/v1 expects (Namespace:String, Key:String)"

cache_delete_v1 :: (String -> String -> Either VMError Value) -> BuiltinFn
cache_delete_v1 hostFn args = case args of
  [VString ns, VString key] -> hostFn ns key
  _ -> Left $ VMError TypeMismatch "cache.delete/v1 expects (Namespace:String, Key:String)"

cache_clear_v1 :: (String -> Either VMError Value) -> BuiltinFn
cache_clear_v1 hostFn args = case args of
  [VString ns] -> hostFn ns
  _ -> Left $ VMError TypeMismatch "cache.clear/v1 expects (Namespace:String)"

-- | Utility to create a full Cache registry for the VM
createCacheRegistry 
  :: { set :: String -> String -> Value -> Either VMError Value
     , get :: String -> String -> Either VMError Value
     , delete :: String -> String -> Either VMError Value
     , clear :: String -> Either VMError Value
     } 
  -> Map String (Map Int BuiltinFn)
createCacheRegistry host =
  Map.fromFoldable
    [ Tuple "cache.set" (Map.singleton 1 (cache_set_v1 host.set))
    , Tuple "cache.get" (Map.singleton 1 (cache_get_v1 host.get))
    , Tuple "cache.delete" (Map.singleton 1 (cache_delete_v1 host.delete))
    , Tuple "cache.clear" (Map.singleton 1 (cache_clear_v1 host.clear))
    ]
