module Test.Interpreter (spec) where

import Prelude
import Data.BigInt as BI
import Data.Map as Map
import Data.Set as Set
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Data.Array as Array
import Data.Set as Set
import Data.List as List
import FinVM.Interpreter as Interpreter
import FinVM.Value (Value(..))
import FinVM.Instruction (Instruction(..))
import FinVM.Program (Program)
import FinVM.Machine (Machine)
import FinVM.Process (Process, ProcessStatus(..))
import FinVM.Process.Scheduler (initialScheduler)
import FinVM.Type (VMType(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, fail)

spec :: Spec Unit
spec = do
  describe "FinVM.Interpreter" do
    let 
      emptyLimits =
        { maxSteps: 100
        , maxCallDepth: 10
        , maxProcesses: 10
        , maxProcessStepsPerSlice: 10
        , maxRegistersPerFrame: 10
        , maxFrames: 10
        , maxListLength: 10
        , maxMapSize: 10
        , maxRecordFields: 10
        , maxValueDepth: 10
        , maxStateEntries: 10
        , maxTraceEvents: 10
        , maxProofEvents: 10
        , maxMailboxSize: 10
        , maxRemoteNodes: 10
        , maxEventsEmitted: 10
        , maxEffectsRequested: 10
        }
      
      program :: Program
      program =
        { version: "1.0"
        , constants: [ VInt (BI.fromInt 42) ]
        , functions: Map.fromFoldable
            [ Tuple "main" 
                { id: "main"
                , arity: 0
                , registerCount: 2
                , parameterTypes: []
                , returnType: TInt
                , instructions: 
                    [ LOAD_CONST 0 0
                    , HALT 0
                    ]
                , debug: { name: "main" }
                , proof: { isInvariant: false }
                }
            , Tuple "jumper"
                { id: "jumper"
                , arity: 0
                , registerCount: 1
                , parameterTypes: []
                , returnType: TUnit
                , instructions: 
                    [ LABEL "start"
                    , JUMP "end"
                    , LABEL "middle"
                    , ABORT 99 -- Should never be hit
                    , LABEL "end"
                    , RETURN 0
                    ]
                , debug: { name: "jumper" }
                , proof: { isInvariant: false }
                }
            , Tuple "caller"
                { id: "caller"
                , arity: 0
                , registerCount: 1
                , parameterTypes: []
                , returnType: TInt
                , instructions: 
                    [ CALL 0 "callee" []
                    , HALT 0
                    ]
                , debug: { name: "caller" }
                , proof: { isInvariant: false }
                }
            , Tuple "callee"
                { id: "callee"
                , arity: 0
                , registerCount: 1
                , parameterTypes: []
                , returnType: TInt
                , instructions: 
                    [ LOAD_CONST 0 0 -- load 42
                    , RETURN 0
                    ]
                , debug: { name: "callee" }
                , proof: { isInvariant: false }
                }
            ]
        , stateMachines: Map.empty
        , entrypoint: "main"
        , exports: Map.empty
        , metadata: { description: "test" }
        , typeTable: Map.empty
        , capabilities: []
        , verification: { verified: true }
        }

      machine :: Machine
      machine =
        { program: program
        , scheduler: initialScheduler
        , state: Map.empty
        , input: Map.empty
        , config: { limits: emptyLimits, externalBuiltins: Map.empty, performanceMode: false }
        , trace: List.Nil
        , proofTrace: List.Nil
        , outbox: List.Nil
        , events: List.Nil
        , counters: { steps: 0 }
        }

      process :: Process
      process =
        { pid: "p1"
        , status: ProcessReady
        , function: "main"
        , frame: { function: "main", pc: 0, registers: Array.replicate 10 VUnit, returnRegister: Nothing, caller: Nothing }
        , callStack: []
        , mailbox: []
        , links: Set.empty
        , monitors: Map.empty
        , parent: Nothing
        , children: Set.empty
        , trapExit: false
        , metadata: { name: "p1" }
        , result: Nothing
        , error: Nothing
        , createdSequence: 0
        , stepsExecuted: 0
        }

    it "executes LOAD_CONST and HALT correctly" do
      case Interpreter.stepProcess machine process of
        Left err -> fail $ show err
        Right (Tuple m' p') -> do
          p'.frame.pc `shouldEqual` 1
          Array.index p'.frame.registers 0 `shouldEqual` Just (VInt (BI.fromInt 42))
          case Interpreter.stepProcess m' p' of
            Left err -> fail $ show err
            Right (Tuple _ p'') -> do
              p''.status `shouldEqual` ProcessCompleted (VInt (BI.fromInt 42))

    it "executes JUMP correctly" do
      let p_jump = process { function = "jumper", frame = { function: "jumper", pc: 0, registers: Array.replicate 10 VUnit, returnRegister: Nothing, caller: Nothing } }
      -- pc 0: LABEL "start"
      case Interpreter.stepProcess machine p_jump of
        Left err -> fail $ show err
        Right (Tuple m1 p1) -> do
          -- pc 1: JUMP "end"
          case Interpreter.stepProcess m1 p1 of
            Left err -> fail $ show err
            Right (Tuple m2 p2) -> do
              -- Should be at LABEL "end", which is index 4
              p2.frame.pc `shouldEqual` 4
              case Interpreter.stepProcess m2 p2 of
                 Left err -> fail $ show err
                 Right (Tuple _ p3) -> do
                   -- pc 5: RETURN 0
                   p3.frame.pc `shouldEqual` 5

    it "executes CALL and RETURN correctly" do
      let p_call = process { function = "caller", frame = { function: "caller", pc: 0, registers: Array.replicate 10 VUnit, returnRegister: Nothing, caller: Nothing } }
      -- pc 0: CALL 0 "callee" []
      case Interpreter.stepProcess machine p_call of
        Left err -> fail $ show err
        Right (Tuple m1 p1) -> do
          p1.frame.function `shouldEqual` "callee"
          p1.frame.pc `shouldEqual` 0
          Array.length p1.callStack `shouldEqual` 1
          -- pc 0: LOAD_CONST 0 0
          case Interpreter.stepProcess m1 p1 of
            Left err -> fail $ show err
            Right (Tuple m2 p2) -> do
              -- pc 1: RETURN 0
              case Interpreter.stepProcess m2 p2 of
                Left err -> fail $ show err
                Right (Tuple _ p3) -> do
                  p3.frame.function `shouldEqual` "caller"
                  p3.frame.pc `shouldEqual` 1 -- Increment of the CALL instruction
                  Array.index p3.frame.registers 0 `shouldEqual` Just (VInt (BI.fromInt 42))
