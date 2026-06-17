module Test.Input (spec) where

import Prelude

import Data.Argonaut.Core as Json
import Data.Argonaut.Parser (jsonParser)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String (Pattern(..), contains)
import Data.Tuple (Tuple(..))
import FinVM.Encoding.Json as Encoding.Json
import Foreign.Object (Object)
import Foreign.Object as Object
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

spec :: Spec Unit
spec = do
  describe "Input schema and input.get@1" do
    it "decodes inputs.schema + values and runs input.get@1" do
      let output = Encoding.Json.runJsonProgram inputGetProgram
      case parseObject output of
        Left err -> fail err
        Right object -> do
          fieldString "status" object `shouldEqual` Just "completed"
          fieldIntString "result" object `shouldEqual` Just "42"

    it "rejects type mismatch with validation error" do
      let result = Encoding.Json.runJsonProgramResult badInputProgram
      result.ok `shouldEqual` false
      if "Input" `containsIn` result.output then pure unit
      else fail ("Expected Input validation error in: " <> result.output)

    it "rejects encrypted inputs.values without SecureLoader" do
      case Encoding.Json.decodeProgramFile sealedInputProgram of
        Left err | "DecryptionFailed" `containsIn` err -> pure unit
        _ -> fail "Expected DecryptionFailed error"

    it "input.all@1 returns all validated inputs as a record" do
      let output = Encoding.Json.runJsonProgram inputAllProgram
      case parseObject output of
        Left err -> fail err
        Right object -> do
          fieldString "status" object `shouldEqual` Just "completed"
          case Object.lookup "result" object >>= Json.toObject >>= Object.lookup "record" >>= Json.toObject >>= Object.lookup "x" >>= Json.toObject >>= Object.lookup "int" >>= Json.toString of
            Just v -> v `shouldEqual` "42"
            Nothing -> fail ("missing x in input.all result: " <> output)
          case Object.lookup "result" object >>= Json.toObject >>= Object.lookup "record" >>= Json.toObject >>= Object.lookup "y" >>= Json.toObject >>= Object.lookup "string" >>= Json.toString of
            Just v -> v `shouldEqual` "hi"
            Nothing -> fail ("missing y in input.all result: " <> output)

inputGetProgram :: String
inputGetProgram =
  """{"version":"1.0","entrypoint":"main","constants":[{"string":"x"}],"functions":{"main":{"registerCount":8,"instructions":[["LOAD_CONST",2,0],["CALL_BUILTIN",1,"input.get@1",[2]],["RETURN",1]]}},"inputs":{"schema":[{"name":"x","type":"Int","required":true}],"values":{"x":{"int":"42"}}}}"""

badInputProgram :: String
badInputProgram =
  """{"version":"1.0","entrypoint":"main","constants":[],"functions":{"main":{"registerCount":4,"instructions":[["RETURN",0]]}},"inputs":{"schema":[{"name":"x","type":"Int","required":true}],"values":{"x":{"string":"nope"}}}}"""

sealedInputProgram :: String
sealedInputProgram =
  """{"version":"1.0","entrypoint":"main","constants":[],"functions":{"main":{"registerCount":4,"instructions":[["RETURN",0]]}},"inputs":{"schema":[{"name":"x","type":"Int","required":true}],"values":{"fenc":1,"target":"inputs","cipher":"aes-256-gcm","iv":"abc","ct":"def","aad":"finvm:inputs"}}}"""

inputAllProgram :: String
inputAllProgram =
  """{"version":"1.0","entrypoint":"main","constants":[],"functions":{"main":{"registerCount":4,"instructions":[["CALL_BUILTIN",1,"input.all@1",[]],["RETURN",1]]}},"inputs":{"schema":[{"name":"x","type":"Int","required":true},{"name":"y","type":"String","required":false}],"values":{"x":{"int":"42"},"y":{"string":"hi"}}}}"""

parseObject :: String -> Either String (Object Json.Json)
parseObject source = do
  json <- jsonParser source
  case Json.toObject json of
    Nothing -> Left "Expected JSON object"
    Just obj -> pure obj

fieldString :: String -> Object Json.Json -> Maybe String
fieldString key object = Object.lookup key object >>= Json.toString

fieldIntString :: String -> Object Json.Json -> Maybe String
fieldIntString key object =
  Object.lookup key object >>= Json.toObject >>= Object.lookup "int" >>= Json.toString

containsIn :: String -> String -> Boolean
containsIn needle haystack = (Pattern needle) `contains` haystack
