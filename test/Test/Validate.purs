module Test.Validate (spec) where

import Prelude
import Data.Map as Map
import Data.Either (Either(..))
import Data.Tuple (Tuple(..))
import FinVM.Program (Program)
import FinVM.Type (VMType(..))
import FinVM.Instruction (Instruction(..))
import FinVM.Validate as Validate
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec = do
  describe "FinVM.Validate" do
    let
      validProgram :: Program
      validProgram =
        { version: "1.0"
        , constants: []
        , functions: Map.fromFoldable
            [ Tuple "main"
                { id: "main", arity: 0, registerCount: 1, parameterTypes: [], returnType: TUnit
                , instructions: [ LABEL "start", NOOP, JUMP "start", RETURN 0 ]
                , debug: { name: "main" }, proof: { isInvariant: false }
                }
            ]
        , stateMachines: Map.empty
        , entrypoint: "main"
        , exports: Map.empty
        , metadata: { description: "" }, typeTable: Map.empty, capabilities: [], verification: { verified: true }
        }

    it "accepts a valid program" do
      Validate.validateProgram validProgram `shouldEqual` Right unit

    it "rejects missing entrypoint" do
      let p = validProgram { entrypoint = "missing" }
      case Validate.validateProgram p of
        Left _ -> pure unit
        Right _ -> shouldEqual "Left error" "Right unit"

    it "rejects out of bounds register" do
      let p = validProgram { functions = Map.fromFoldable
            [ Tuple "main"
                { id: "main", arity: 0, registerCount: 1, parameterTypes: [], returnType: TUnit
                , instructions: [ MOVE 1 0 ] -- Register 1 is OOB
                , debug: { name: "main" }, proof: { isInvariant: false }
                }
            ]
          }
      case Validate.validateProgram p of
        Left _ -> pure unit
        Right _ -> shouldEqual "Left error" "Right unit"

    it "rejects unknown jump label" do
      let p = validProgram { functions = Map.fromFoldable
            [ Tuple "main"
                { id: "main", arity: 0, registerCount: 1, parameterTypes: [], returnType: TUnit
                , instructions: [ JUMP "nowhere" ]
                , debug: { name: "main" }, proof: { isInvariant: false }
                }
            ]
          }
      case Validate.validateProgram p of
        Left _ -> pure unit
        Right _ -> shouldEqual "Left error" "Right unit"

    it "rejects arity mismatch in call" do
      let p = validProgram { functions = Map.fromFoldable
            [ Tuple "main"
                { id: "main", arity: 0, registerCount: 1, parameterTypes: [], returnType: TUnit
                , instructions: [ CALL 0 "helper" [] ] -- expects 0, but helper has 1
                , debug: { name: "main" }, proof: { isInvariant: false }
                }
            , Tuple "helper"
                { id: "helper", arity: 1, registerCount: 1, parameterTypes: [TInt], returnType: TUnit
                , instructions: [ RETURN 0 ]
                , debug: { name: "helper" }, proof: { isInvariant: false }
                }
            ]
          }
      case Validate.validateProgram p of
        Left _ -> pure unit
        Right _ -> shouldEqual "Left error" "Right unit"

    it "rejects registerCount < arity (arguments would be dropped)" do
      let p = validProgram { functions = Map.fromFoldable
            [ Tuple "main"
                { id: "main", arity: 3, registerCount: 1, parameterTypes: [TInt, TInt, TInt], returnType: TUnit
                , instructions: [ RETURN 0 ]
                , debug: { name: "main" }, proof: { isInvariant: false }
                }
            ]
          }
      case Validate.validateProgram p of
        Left _ -> pure unit
        Right _ -> shouldEqual "Left error" "Right unit"

    it "accepts TAIL_CALL now that it is implemented by the interpreter" do
      let p = validProgram { functions = Map.fromFoldable
            [ Tuple "main"
                { id: "main", arity: 0, registerCount: 1, parameterTypes: [], returnType: TUnit
                , instructions: [ TAIL_CALL "main" [] ]
                , debug: { name: "main" }, proof: { isInvariant: false }
                }
            ]
          }
      Validate.validateProgram p `shouldEqual` Right unit
