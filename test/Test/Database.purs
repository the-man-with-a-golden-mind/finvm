module Test.Database (spec) where

import Prelude
import Data.Map as Map
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Data.BigInt as BI
import FinVM.Value (Value(..))
import FinVM.Builtin.Database as DB
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, fail)

spec :: Spec Unit
spec = do
  describe "FinVM.Database FFI Security & Queries" do
    let 
      -- Simulated host logic for testing (would be real JS in production)
      mockInsert t v = Right (VString "rec1")
      mockGet t k = Right (VRecord (Map.singleton "id" (VString k)))
      mockUpdate t k v = Right (VBool true)
      mockDelete t k = Right (VBool true)
      mockCreateIndex t f = Right VUnit
      mockQuery t q o = Right (VList [VRecord (Map.singleton "name" (VString "Alice"))])
      mockHash t = Right "abcd123"

      registry = DB.createDbRegistry 
        { insert: mockInsert
        , get: mockGet
        , update: mockUpdate
        , delete: mockDelete
        , createIndex: mockCreateIndex
        , query: mockQuery
        , hashTable: mockHash
        }

    it "exposes secure insert through builtins" do
      case Map.lookup "db.insert" registry of
        Nothing -> fail "db.insert not found"
        Just versions -> case Map.lookup 1 versions of
          Nothing -> fail "v1 not found"
          Just fn -> do
            let res = fn [VString "users", VRecord (Map.singleton "name" (VString "Bob"))]
            res `shouldEqual` Right (VString "rec1")

    it "exposes update, delete, and createIndex through builtins" do
      case Map.lookup "db.update" registry, Map.lookup "db.delete" registry, Map.lookup "db.createIndex" registry of
        Just v1, Just v2, Just v3 -> case Map.lookup 1 v1, Map.lookup 1 v2, Map.lookup 1 v3 of
          Just fnUpdate, Just fnDelete, Just fnIndex -> do
            let resUpdate = fnUpdate [VString "users", VString "rec1", VRecord (Map.singleton "name" (VString "Charlie"))]
            resUpdate `shouldEqual` Right (VBool true)
            let resDelete = fnDelete [VString "users", VString "rec1"]
            resDelete `shouldEqual` Right (VBool true)
            let resIndex = fnIndex [VString "users", VString "role"]
            resIndex `shouldEqual` Right VUnit
          _, _, _ -> fail "v1 functions not found"
        _, _, _ -> fail "functions not found"

    it "supports MongoDB-style query parameters" do
       case Map.lookup "db.query" registry of
        Nothing -> fail "db.query not found"
        Just versions -> case Map.lookup 1 versions of
          Just fn -> do
            let query = VRecord (Map.singleton "performance" (VRecord (Map.singleton "$gt" (VFixed {value: BI.fromInt 75, scale: 2}))))
                options = VRecord (Map.singleton "sort" (VRecord (Map.fromFoldable [Tuple "field" (VString "performance"), Tuple "order" (VString "ASC")])))
                res = fn [VString "strategies", query, options]
            case res of
              Right (VList [VRecord fields]) -> Map.lookup "name" fields `shouldEqual` Just (VString "Alice")
              _ -> fail "Query failed to return expected list"
          _ -> fail "v1 query not found"
