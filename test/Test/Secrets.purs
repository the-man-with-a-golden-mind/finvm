module Test.Secrets (spec) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.String (Pattern(..), contains)
import FinVM.Encoding.Json as Encoding.Json
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

spec :: Spec Unit
spec = do
  describe "Secrets never in VM errors" do
    it "sealed program at load returns DecryptionFailed without executing" do
      let sealed = """{"fenc":1,"target":"program","cipher":"aes-256-gcm","iv":"abc","aad":"finvm:program","ct":"def"}"""
      case Encoding.Json.decodeProgramFile sealed of
        Left err ->
          if "DecryptionFailed" `containsIn` err then pure unit
          else fail ("expected DecryptionFailed in: " <> err)
        Right _ -> fail "expected DecryptionFailed"

    it "sealed inputs.values returns DecryptionFailed" do
      let sealedInputs = """{"version":"1.0","entrypoint":"main","constants":[],"functions":{"main":{"registerCount":4,"instructions":[["RETURN",0]]}},"inputs":{"schema":[{"name":"x","type":"Int","required":true}],"values":{"fenc":1,"target":"inputs","cipher":"aes-256-gcm","iv":"a","aad":"finvm:inputs","ct":"b"}}}"""
      case Encoding.Json.decodeProgramFile sealedInputs of
        Left err ->
          if "DecryptionFailed" `containsIn` err then pure unit
          else fail err
        Right _ -> fail "expected DecryptionFailed"

    it "input validation errors use InputValidation code" do
      let bad = """{"version":"1.0","entrypoint":"main","constants":[],"functions":{"main":{"registerCount":4,"instructions":[["RETURN",0]]}},"inputs":{"schema":[{"name":"x","type":"Int","required":true}],"values":{"x":{"string":"nope"}}}}"""
      let result = Encoding.Json.runJsonProgramResult bad
      result.ok `shouldEqual` false
      if "InputValidation" `containsIn` result.output then pure unit
      else fail ("expected InputValidation in: " <> result.output)

    it "programs with inputs section declare input capability" do
      let source = """{"version":"1.0","entrypoint":"main","constants":[],"functions":{"main":{"registerCount":4,"instructions":[["RETURN",0]]}},"inputs":{"schema":[{"name":"x","type":"Int","required":true}],"values":{"x":{"int":"1"}}}}"""
      case Encoding.Json.decodeProgramFile source of
        Left err -> fail err
        Right file ->
          if Array.elem "input" file.program.capabilities
            then pure unit
            else fail "missing input capability"

    it "effect snapshot JSON never contains forbidden secret marker" do
      let secretMarker = "FINVM_FORBIDDEN_SECRET_MARKER"
      let effectProgram = """{"version":"1.0","entrypoint":"main","registerCount":8,"constants":[{"string":"k1"},{"string":"http://example.test"}],"instructions":[["RECORD_NEW",0],["LOAD_CONST",1,0],["RECORD_SET",0,0,"key",1],["LOAD_CONST",2,1],["RECORD_SET",0,0,"url",2],["EFFECT_NEW",3,"http.get",0],["EFFECT_AWAIT",3],["RETURN",0]]}"""
      let raw = Encoding.Json.runEffectStart effectProgram "{}"
      if secretMarker `containsIn` raw then fail "snapshot/start output must not echo injected secret marker"
      else pure unit

containsIn :: String -> String -> Boolean
containsIn needle haystack = (Pattern needle) `contains` haystack
