module Test.Cache (spec) where

import Prelude
import Data.Map as Map
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import FinVM.Value (Value(..))
import FinVM.Builtin.Cache as Cache
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, fail)

spec :: Spec Unit
spec = do
  describe "FinVM.Cache FFI High-Speed Storage" do
    let 
      mockSet ns k v = Right (VBool true)
      mockGet ns k = Right (VString "fast_data")
      mockDelete ns k = Right (VBool true)
      mockClear ns = Right (VBool true)

      registry = Cache.createCacheRegistry 
        { set: mockSet
        , get: mockGet
        , delete: mockDelete
        , clear: mockClear
        }

    it "exposes fast set and get operations" do
      case Map.lookup "cache.set" registry, Map.lookup "cache.get" registry of
        Just v1, Just v2 -> case Map.lookup 1 v1, Map.lookup 1 v2 of
          Just fnSet, Just fnGet -> do
            let resSet = fnSet [VString "session", VString "user_1", VString "data"]
            resSet `shouldEqual` Right (VBool true)
            
            let resGet = fnGet [VString "session", VString "user_1"]
            resGet `shouldEqual` Right (VString "fast_data")
          _, _ -> fail "v1 functions not found"
        _, _ -> fail "cache builtins not found"

    it "exposes fast delete and clear operations" do
      case Map.lookup "cache.delete" registry, Map.lookup "cache.clear" registry of
        Just v1, Just v2 -> case Map.lookup 1 v1, Map.lookup 1 v2 of
          Just fnDelete, Just fnClear -> do
            let resDelete = fnDelete [VString "session", VString "user_1"]
            resDelete `shouldEqual` Right (VBool true)
            
            let resClear = fnClear [VString "session"]
            resClear `shouldEqual` Right (VBool true)
          _, _ -> fail "v1 functions not found"
        _, _ -> fail "cache builtins not found"
