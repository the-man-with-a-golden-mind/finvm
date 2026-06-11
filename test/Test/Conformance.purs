module Test.Conformance (spec) where

import Prelude

import Data.Argonaut.Core as Json
import Data.Argonaut.Parser (jsonParser)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String (Pattern(..), contains)
import Data.Tuple (Tuple(..))
import FinVM.Encoding.Json as Encoding.Json
import Foreign.Object as Object
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

spec :: Spec Unit
spec = do
  describe "FinVM JSON conformance" do
    it "runs a JSON bytecode program through the real VM" do
      let output = Encoding.Json.runJsonProgram goldenProgram
      case parseObject output of
        Left err -> fail err
        Right object -> do
          fieldString "status" object `shouldEqual` Just "completed"
          fieldIntString "result" object `shouldEqual` Just "42"
          case Object.lookup "state" object >>= Json.toObject >>= Object.lookup "answer" >>= Json.toObject >>= Object.lookup "int" >>= Json.toString of
            Just value -> value `shouldEqual` "42"
            Nothing -> fail ("missing answer in output: " <> output)

    it "reports unsupported opcodes as structured failures" do
      let output = Encoding.Json.runJsonProgram badProgram
      case parseObject output of
        Left err -> fail err
        Right object -> do
          fieldString "status" object `shouldEqual` Just "failed"
          case fieldString "error" object of
            Just error -> (error == "Unsupported instruction opcode: DOES_NOT_EXIST") `shouldEqual` true
            Nothing -> fail ("missing error in output: " <> output)

    it "statically validates before running (rejects an out-of-bounds register)" do
      -- Register 5 is out of bounds for registerCount 1. Without validation the VM
      -- would silently drop the write and complete; with validation it fails fast.
      let output = Encoding.Json.runJsonProgram registerOobProgram
      case parseObject output of
        Left err -> fail err
        Right object -> do
          fieldString "status" object `shouldEqual` Just "failed"
          case fieldString "error" object of
            Just e -> contains (Pattern "Register out of bounds") e `shouldEqual` true
            Nothing -> fail ("missing error in output: " <> output)

    it "runs a multi-function program with recursive CALL (factorial)" do
      let output = Encoding.Json.runJsonProgram factorialProgram
      case parseObject output of
        Left err -> fail err
        Right object -> do
          fieldString "status" object `shouldEqual` Just "completed"
          fieldIntString "result" object `shouldEqual` Just "120"

    it "honors performanceMode from the program JSON" do
      case Encoding.Json.decodeProgramFile perfProgram of
        Left err -> fail ("decode failed: " <> err)
        Right file -> file.performanceMode `shouldEqual` true

    it "produces the same result with performanceMode on as off" do
      let onOut = Encoding.Json.runJsonProgram perfProgram
          offOut = Encoding.Json.runJsonProgram goldenProgram
      -- both compute 40 + 2 = 42
      case Tuple (parseObject onOut) (parseObject offOut) of
        Tuple (Right onObj) (Right offObj) ->
          fieldIntString "result" onObj `shouldEqual` fieldIntString "result" offObj
        _ -> fail "failed to parse perf-mode outputs"

    it "enforces the step limit so an infinite loop terminates" do
      -- If the step limit were not enforced, runJsonProgram would never return
      -- and this test would hang rather than fail.
      let output = Encoding.Json.runJsonProgram infiniteLoopProgram
      case parseObject output of
        Left err -> fail err
        Right object ->
          -- The run must terminate with a parseable status (the VM stops at the
          -- step cap rather than looping forever).
          case fieldString "status" object of
            Just _ -> pure unit
            Nothing -> fail ("missing status in output: " <> output)

    it "exposes SHA-256 canonical hashing as a builtin" do
      let output = Encoding.Json.runJsonProgram hashProgram
      case parseObject output of
        Left err -> fail err
        Right object -> do
          fieldString "status" object `shouldEqual` Just "completed"
          fieldVmString "result" object `shouldEqual` Just "8e5cc2a18337e30e25a6669b92076e5ce93431eefa209a68ddd13f2dd29fb36b"

goldenProgram :: String
goldenProgram =
  """
  {
    "version": "1.0",
    "registerCount": 4,
    "constants": [
      { "int": "40" },
      { "int": "2" }
    ],
    "instructions": [
      ["LOAD_CONST", 0, 0],
      ["LOAD_CONST", 1, 1],
      ["ADD", 2, 0, 1],
      ["STATE_SET", "answer", 2],
      ["RETURN", 2]
    ]
  }
  """

badProgram :: String
badProgram =
  """
  {
    "instructions": [
      ["DOES_NOT_EXIST"]
    ]
  }
  """

hashProgram :: String
hashProgram =
  """
  {
    "version": "1.0",
    "registerCount": 2,
    "constants": [
      { "int": "42" }
    ],
    "instructions": [
      ["LOAD_CONST", 0, 0],
      ["CALL_BUILTIN", 1, "hash.sha256@1", [0]],
      ["RETURN", 1]
    ]
  }
  """

registerOobProgram :: String
registerOobProgram =
  """
  {
    "version": "1.0",
    "registerCount": 1,
    "constants": [],
    "instructions": [ ["MOVE", 5, 0], ["HALT", 0] ]
  }
  """

factorialProgram :: String
factorialProgram =
  """
  {
    "constants": [ { "int": "1" }, { "int": "5" } ],
    "entrypoint": "main",
    "functions": {
      "main": { "arity": 0, "registerCount": 2, "instructions": [
        ["LOAD_CONST", 0, 1],
        ["CALL", 1, "fact", [0]],
        ["RETURN", 1] ] },
      "fact": { "arity": 1, "registerCount": 6, "instructions": [
        ["LOAD_CONST", 1, 0],
        ["LTE", 2, 0, 1],
        ["JUMP_IF", 2, "base"],
        ["SUB", 3, 0, 1],
        ["CALL", 4, "fact", [3]],
        ["MUL", 5, 0, 4],
        ["RETURN", 5],
        ["LABEL", "base"],
        ["RETURN", 1] ] }
    }
  }
  """

perfProgram :: String
perfProgram =
  """
  {
    "version": "1.0",
    "registerCount": 4,
    "performanceMode": true,
    "constants": [
      { "int": "40" },
      { "int": "2" }
    ],
    "instructions": [
      ["LOAD_CONST", 0, 0],
      ["LOAD_CONST", 1, 1],
      ["ADD", 2, 0, 1],
      ["STATE_SET", "answer", 2],
      ["RETURN", 2]
    ]
  }
  """

infiniteLoopProgram :: String
infiniteLoopProgram =
  """
  {
    "version": "1.0",
    "registerCount": 1,
    "limits": { "maxSteps": 50 },
    "instructions": [
      ["LABEL", "start"],
      ["JUMP", "start"]
    ]
  }
  """

parseObject :: String -> Either String (Object.Object Json.Json)
parseObject text =
  case jsonParser text >>= maybeToEither "output must be an object" <<< Json.toObject of
    Right object -> Right object
    Left err -> Left ("invalid JSON output: " <> err <> " in " <> text)

fieldString :: String -> Object.Object Json.Json -> Maybe String
fieldString key object = Object.lookup key object >>= Json.toString

fieldIntString :: String -> Object.Object Json.Json -> Maybe String
fieldIntString key object = Object.lookup key object >>= Json.toObject >>= Object.lookup "int" >>= Json.toString

fieldVmString :: String -> Object.Object Json.Json -> Maybe String
fieldVmString key object = Object.lookup key object >>= Json.toObject >>= Object.lookup "string" >>= Json.toString

maybeToEither :: forall a. String -> Maybe a -> Either String a
maybeToEither err = case _ of
  Just value -> Right value
  Nothing -> Left err
