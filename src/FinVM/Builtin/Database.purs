module FinVM.Builtin.Database where

import Prelude
import Data.Maybe (Maybe(..))
import Data.Either (Either(..))
import Data.Map (Map)
import Data.Map as Map
import Data.Tuple (Tuple(..))
import FinVM.Value (Value(..))
import FinVM.Error (VMError(..), ErrorCode(..))
import FinVM.Machine (BuiltinFn)

-- This module provides the "Signatures" for the DB FFI.
-- The actual implementation is injected via EvalConfig in Main.purs

db_insert_v1 :: (String -> Value -> Either VMError Value) -> BuiltinFn
db_insert_v1 hostFn args = case args of
  [VString table, val] -> hostFn table val
  _ -> Left $ VMError TypeMismatch "db.insert/v1 expects (Table:String, Data:Value)"

db_get_v1 :: (String -> String -> Either VMError Value) -> BuiltinFn
db_get_v1 hostFn args = case args of
  [VString table, VString key] -> hostFn table key
  _ -> Left $ VMError TypeMismatch "db.get/v1 expects (Table:String, Key:String)"

db_update_v1 :: (String -> String -> Value -> Either VMError Value) -> BuiltinFn
db_update_v1 hostFn args = case args of
  [VString table, VString key, newValue] -> hostFn table key newValue
  _ -> Left $ VMError TypeMismatch "db.update/v1 expects (Table:String, Key:String, NewValue:Value)"

db_delete_v1 :: (String -> String -> Either VMError Value) -> BuiltinFn
db_delete_v1 hostFn args = case args of
  [VString table, VString key] -> hostFn table key
  _ -> Left $ VMError TypeMismatch "db.delete/v1 expects (Table:String, Key:String)"

db_create_index_v1 :: (String -> String -> Either VMError Value) -> BuiltinFn
db_create_index_v1 hostFn args = case args of
  [VString table, VString field] -> hostFn table field
  _ -> Left $ VMError TypeMismatch "db.createIndex/v1 expects (Table:String, Field:String)"

db_query_v1 :: (String -> Value -> Value -> Either VMError Value) -> BuiltinFn
db_query_v1 hostFn args = case args of
  [VString table, queryObj, options] -> hostFn table queryObj options
  _ -> Left $ VMError TypeMismatch "db.query/v1 expects (Table:String, Query:Record, Options:Record)"

db_hash_v1 :: (String -> Either VMError String) -> BuiltinFn
db_hash_v1 hostFn args = case args of
  [VString table] -> case hostFn table of
    Left err -> Left err
    Right h -> Right $ VString h
  _ -> Left $ VMError TypeMismatch "db.hash/v1 expects (Table:String)"

-- | Utility to create a full DB registry for the VM
createDbRegistry 
  :: { insert :: String -> Value -> Either VMError Value
     , get :: String -> String -> Either VMError Value
     , update :: String -> String -> Value -> Either VMError Value
     , delete :: String -> String -> Either VMError Value
     , createIndex :: String -> String -> Either VMError Value
     , query :: String -> Value -> Value -> Either VMError Value
     , hashTable :: String -> Either VMError String
     } 
  -> Map String (Map Int BuiltinFn)
createDbRegistry host =
  Map.fromFoldable
    [ Tuple "db.insert" (Map.singleton 1 (db_insert_v1 host.insert))
    , Tuple "db.get" (Map.singleton 1 (db_get_v1 host.get))
    , Tuple "db.update" (Map.singleton 1 (db_update_v1 host.update))
    , Tuple "db.delete" (Map.singleton 1 (db_delete_v1 host.delete))
    , Tuple "db.createIndex" (Map.singleton 1 (db_create_index_v1 host.createIndex))
    , Tuple "db.query" (Map.singleton 1 (db_query_v1 host.query))
    , Tuple "db.hash" (Map.singleton 1 (db_hash_v1 host.hashTable))
    ]
