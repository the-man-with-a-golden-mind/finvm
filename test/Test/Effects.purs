module Test.Effects (spec) where

import Prelude
import Data.Argonaut.Core as Json
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Foreign.Object as Object
import FinVM.Encoding.Json (runEffectStep)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

-- Program that builds an http.get effect intent (payload carries the "key"
-- correlation field) and requests it, then returns. Never reads input.
emitProgram :: String
emitProgram =
  """
  {
    "version": "1.0",
    "registerCount": 5,
    "constants": [ { "string": "r1" }, { "string": "http://x" } ],
    "instructions": [
      ["RECORD_NEW", 0],
      ["LOAD_CONST", 1, 0],
      ["RECORD_SET", 0, 0, "key", 1],
      ["LOAD_CONST", 2, 1],
      ["RECORD_SET", 0, 0, "url", 2],
      ["EFFECT_NEW", 3, "http.get", 0],
      ["EFFECT_REQUEST", 3],
      ["RETURN", 0]
    ]
  }
  """

-- Program that reads a result delivered via input under key "r1".
readProgram :: String
readProgram =
  """
  {
    "version": "1.0",
    "registerCount": 1,
    "constants": [],
    "instructions": [ ["LOAD_INPUT", 0, "r1"], ["RETURN", 0] ]
  }
  """

obj :: String -> Maybe (Object.Object Json.Json)
obj s = case jsonParser s of
  Right j -> Json.toObject j
  Left _ -> Nothing

spec :: Spec Unit
spec = do
  describe "FinVM effect driver contract (runEffectStep)" do
    it "exposes requested effect intents in the outbox (type_ + payload.key)" do
      let out = runEffectStep emitProgram ""
      case obj out of
        Nothing -> fail ("not an object: " <> out)
        Just o -> do
          (Object.lookup "status" o >>= Json.toString) `shouldEqual` Just "completed"
          let firstIntent = Object.lookup "outbox" o >>= Json.toArray >>= Array.head >>= Json.toObject
          (firstIntent >>= Object.lookup "type_" >>= Json.toString) `shouldEqual` Just "http.get"
          -- payload.record.key.string == "r1" (the correlation key)
          let keyField = firstIntent
                >>= Object.lookup "payload" >>= Json.toObject
                >>= Object.lookup "record" >>= Json.toObject
                >>= Object.lookup "key" >>= Json.toObject
                >>= Object.lookup "string" >>= Json.toString
          keyField `shouldEqual` Just "r1"

    it "delivers an injected input value to the program (correlation key)" do
      let out = runEffectStep readProgram """{ "input": { "r1": { "int": "42" } } }"""
      case obj out of
        Nothing -> fail ("not an object: " <> out)
        Just o -> do
          (Object.lookup "status" o >>= Json.toString) `shouldEqual` Just "completed"
          let resultInt = Object.lookup "result" o >>= Json.toObject
                >>= Object.lookup "int" >>= Json.toString
          resultInt `shouldEqual` Just "42"

    it "is deterministic: same program+overrides => identical output" do
      runEffectStep emitProgram "" `shouldEqual` runEffectStep emitProgram ""
