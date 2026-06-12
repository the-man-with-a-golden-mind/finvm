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

    it "PROC_SELF returns the running process's own pid (root process)" do
      let output = Encoding.Json.runJsonProgram selfProgram
      case parseObject output of
        Left err -> fail err
        Right object -> do
          fieldString "status" object `shouldEqual` Just "completed"
          -- root process pid is "main"; PROC_SELF yields a VProcessRef of it
          resultProcess object `shouldEqual` Just "main"
          stateProcess "me" object `shouldEqual` Just "main"

    it "PROC_SELF and PROC_SPAWN agree on pid identity (cross-process round-trip)" do
      -- parent spawns child (passing its own pid as an arg); child PROC_SELFs and
      -- sends its own pid back; parent asserts the received pid == the pid that
      -- PROC_SPAWN returned for that child.
      let output = Encoding.Json.runJsonProgram selfRoundTripProgram
      case parseObject output of
        Left err -> fail err
        Right object -> do
          fieldString "status" object `shouldEqual` Just "completed"
          stateProcess "received" object `shouldEqual` stateProcess "spawned" object
          stateProcess "received" object `shouldEqual` Just "p0"

    it "PROC_SELF is deterministic across identical runs" do
      Encoding.Json.runJsonProgram selfRoundTripProgram
        `shouldEqual` Encoding.Json.runJsonProgram selfRoundTripProgram

    it "reports unsupported opcodes as structured failures" do
      let output = Encoding.Json.runJsonProgram badProgram
      case parseObject output of
        Left err -> fail err
        Right object -> do
          fieldString "status" object `shouldEqual` Just "failed"
          case fieldString "error" object of
            Just error -> (error == "Unsupported instruction opcode: DOES_NOT_EXIST") `shouldEqual` true
            Nothing -> fail ("missing error in output: " <> output)

    it "honors a custom limit from the program JSON (maxListLength)" do
      -- LIST_FROM with 3 elements under maxListLength:2 must fail; the default
      -- (100000) would allow it, proving the limit came from the JSON.
      let output = Encoding.Json.runJsonProgram listLimitProgram
      case parseObject output of
        Left err -> fail err
        Right object -> do
          fieldString "status" object `shouldEqual` Just "failed"
          case fieldString "error" object of
            Just e -> contains (Pattern "maxListLength") e `shouldEqual` true
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

    it "runs DB builtins with deterministic in-memory round trips" do
      let output = Encoding.Json.runJsonProgram dbRoundTripProgram
      case parseObject output of
        Left err -> fail err
        Right object -> do
          fieldString "status" object `shouldEqual` Just "completed"
          stateVmString "inserted" object `shouldEqual` Just "rec0"
          stateRecordVmString "first" "name" object `shouldEqual` Just "Alice"
          stateBool "updatedOk" object `shouldEqual` Just true
          stateRecordVmString "updated" "name" object `shouldEqual` Just "Bob"
          stateListFirstRecordVmString "query" "name" object `shouldEqual` Just "Bob"
          stateIsNull "index" object `shouldEqual` true
          stateVmString "hash" object `shouldEqual` Just "ec10407abbfb8d2bf71ca8e0838f340829daeca7c19ffbfb3a6cc4cd68aba352"
          stateBool "deleted" object `shouldEqual` Just true
          stateIsNull "afterDelete" object `shouldEqual` true
          stateIsNull "missing" object `shouldEqual` true

    it "runs cache builtins with unit/null on absent keys" do
      let output = Encoding.Json.runJsonProgram cacheRoundTripProgram
      case parseObject output of
        Left err -> fail err
        Right object -> do
          fieldString "status" object `shouldEqual` Just "completed"
          stateIsNull "before" object `shouldEqual` true
          stateBool "set" object `shouldEqual` Just true
          stateVmString "hit" object `shouldEqual` Just "cached"
          stateBool "deleted" object `shouldEqual` Just true
          stateIsNull "afterDelete" object `shouldEqual` true

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

dbRoundTripProgram :: String
dbRoundTripProgram =
  """
  {
    "version": "1.0",
    "registerCount": 18,
    "constants": [
      { "string": "users" },
      { "record": { "name": { "string": "Alice" } } },
      { "record": { "name": { "string": "Bob" } } },
      { "string": "missing" },
      { "record": { "name": { "string": "Bob" } } },
      { "record": {} },
      { "string": "name" }
    ],
    "instructions": [
      ["LOAD_CONST", 0, 0],
      ["LOAD_CONST", 1, 1],
      ["CALL_BUILTIN", 2, "db.insert@1", [0, 1]],
      ["CALL_BUILTIN", 3, "db.get@1", [0, 2]],
      ["LOAD_CONST", 4, 2],
      ["CALL_BUILTIN", 5, "db.update@1", [0, 2, 4]],
      ["CALL_BUILTIN", 6, "db.get@1", [0, 2]],
      ["LOAD_CONST", 7, 4],
      ["LOAD_CONST", 8, 5],
      ["CALL_BUILTIN", 9, "db.query@1", [0, 7, 8]],
      ["LOAD_CONST", 10, 6],
      ["CALL_BUILTIN", 11, "db.createIndex@1", [0, 10]],
      ["CALL_BUILTIN", 12, "db.hash@1", [0]],
      ["CALL_BUILTIN", 13, "db.delete@1", [0, 2]],
      ["CALL_BUILTIN", 14, "db.get@1", [0, 2]],
      ["LOAD_CONST", 15, 3],
      ["CALL_BUILTIN", 16, "db.get@1", [0, 15]],
      ["STATE_SET", "inserted", 2],
      ["STATE_SET", "first", 3],
      ["STATE_SET", "updatedOk", 5],
      ["STATE_SET", "updated", 6],
      ["STATE_SET", "query", 9],
      ["STATE_SET", "index", 11],
      ["STATE_SET", "hash", 12],
      ["STATE_SET", "deleted", 13],
      ["STATE_SET", "afterDelete", 14],
      ["STATE_SET", "missing", 16],
      ["RETURN", 14]
    ]
  }
  """

cacheRoundTripProgram :: String
cacheRoundTripProgram =
  """
  {
    "version": "1.0",
    "registerCount": 9,
    "constants": [
      { "string": "session" },
      { "string": "user" },
      { "string": "cached" }
    ],
    "instructions": [
      ["LOAD_CONST", 0, 0],
      ["LOAD_CONST", 1, 1],
      ["LOAD_CONST", 2, 2],
      ["CALL_BUILTIN", 3, "cache.get@1", [0, 1]],
      ["CALL_BUILTIN", 4, "cache.set@1", [0, 1, 2]],
      ["CALL_BUILTIN", 5, "cache.get@1", [0, 1]],
      ["CALL_BUILTIN", 6, "cache.delete@1", [0, 1]],
      ["CALL_BUILTIN", 7, "cache.get@1", [0, 1]],
      ["STATE_SET", "before", 3],
      ["STATE_SET", "set", 4],
      ["STATE_SET", "hit", 5],
      ["STATE_SET", "deleted", 6],
      ["STATE_SET", "afterDelete", 7],
      ["RETURN", 7]
    ]
  }
  """

selfProgram :: String
selfProgram =
  """
  {
    "version": "1.0",
    "registerCount": 2,
    "instructions": [
      ["PROC_SELF", 0],
      ["STATE_SET", "me", 0],
      ["HALT", 0]
    ]
  }
  """

selfRoundTripProgram :: String
selfRoundTripProgram =
  """
  {
    "version": "1.0",
    "entrypoint": "main",
    "constants": [],
    "functions": {
      "main": { "arity": 0, "registerCount": 4, "instructions": [
        ["PROC_SELF", 0],
        ["PROC_SPAWN", 1, "child", [0]],
        ["PROC_RECEIVE", 2],
        ["STATE_SET", "spawned", 1],
        ["STATE_SET", "received", 2],
        ["RETURN", 1] ] },
      "child": { "arity": 1, "registerCount": 2, "instructions": [
        ["PROC_SELF", 1],
        ["PROC_SEND", 0, 1],
        ["RETURN", 1] ] }
    }
  }
  """

listLimitProgram :: String
listLimitProgram =
  """
  {
    "version": "1.0",
    "registerCount": 5,
    "limits": { "maxListLength": 2 },
    "constants": [ { "int": "1" } ],
    "instructions": [
      ["LOAD_CONST", 0, 0],
      ["LOAD_CONST", 1, 0],
      ["LOAD_CONST", 2, 0],
      ["LIST_FROM", 3, [0, 1, 2]],
      ["RETURN", 3]
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

-- Read the pid out of a VProcessRef ({ "process": "<pid>" }) at output.result.
resultProcess :: Object.Object Json.Json -> Maybe String
resultProcess object = Object.lookup "result" object >>= Json.toObject >>= Object.lookup "process" >>= Json.toString

-- Read the pid out of a VProcessRef stored at output.state.<key>.
stateProcess :: String -> Object.Object Json.Json -> Maybe String
stateProcess key object =
  Object.lookup "state" object >>= Json.toObject >>= Object.lookup key >>= Json.toObject >>= Object.lookup "process" >>= Json.toString

stateValue :: String -> Object.Object Json.Json -> Maybe Json.Json
stateValue key object =
  Object.lookup "state" object >>= Json.toObject >>= Object.lookup key

stateBool :: String -> Object.Object Json.Json -> Maybe Boolean
stateBool key object =
  stateValue key object >>= Json.toObject >>= Object.lookup "bool" >>= Json.toBoolean

stateVmString :: String -> Object.Object Json.Json -> Maybe String
stateVmString key object =
  stateValue key object >>= Json.toObject >>= Object.lookup "string" >>= Json.toString

stateIsNull :: String -> Object.Object Json.Json -> Boolean
stateIsNull key object = case stateValue key object of
  Just value -> Json.isNull value
  Nothing -> false

stateRecordVmString :: String -> String -> Object.Object Json.Json -> Maybe String
stateRecordVmString key field object =
  stateValue key object >>= Json.toObject >>= Object.lookup "record" >>= Json.toObject >>= Object.lookup field >>= Json.toObject >>= Object.lookup "string" >>= Json.toString

stateListFirstRecordVmString :: String -> String -> Object.Object Json.Json -> Maybe String
stateListFirstRecordVmString key field object = do
  listJson <- stateValue key object >>= Json.toObject >>= Object.lookup "list"
  values <- Json.toArray listJson
  first <- case values of
    [value] -> Just value
    _ -> Nothing
  Json.toObject first >>= Object.lookup "record" >>= Json.toObject >>= Object.lookup field >>= Json.toObject >>= Object.lookup "string" >>= Json.toString

maybeToEither :: forall a. String -> Maybe a -> Either String a
maybeToEither err = case _ of
  Just value -> Right value
  Nothing -> Left err
