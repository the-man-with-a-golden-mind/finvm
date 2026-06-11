module Test.InstructionSet (spec) where

import Prelude
import Data.BigInt as BI
import Data.Map as Map
import Data.Set as Set
import Data.Tuple (Tuple(..))
import Data.List as List
import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.Either (Either(..))
import FinVM.Eval as Eval
import FinVM.Value (Value(..))
import FinVM.Instruction (Instruction(..))
import FinVM.Program (Program)
import FinVM.Machine (Machine)
import FinVM.Limits (EvalLimits)
import FinVM.Process (Process, ProcessStatus(..))
import FinVM.Process.Scheduler (initialScheduler, spawnProcess)
import FinVM.Type (VMType(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, fail)

spec :: Spec Unit
spec = do
  describe "FinVM.InstructionSet expanded coverage" do
    it "executes collection, variant, input, event, and effect instructions" do
      case Eval.runMachine collectionMachine of
        Left err -> fail $ show err
        Right m' -> do
          Map.lookup "input" m'.state `shouldEqual` Just (VString "ctx")
          Map.lookup "opt" m'.state `shouldEqual` Just (VOption (Just (VInt (BI.fromInt 1))))
          Map.lookup "has" m'.state `shouldEqual` Just (VBool true)
          Map.lookup "keys" m'.state `shouldEqual` Just (VList [VString "a"])
          Map.lookup "removed" m'.state `shouldEqual` Just (VRecord Map.empty)
          Map.lookup "len" m'.state `shouldEqual` Just (VInt (BI.fromInt 2))
          Map.lookup "tag" m'.state `shouldEqual` Just (VString "Some")
          List.length m'.events `shouldEqual` 1
          List.length m'.outbox `shouldEqual` 1

    it "executes TAIL_CALL without growing the call stack" do
      case Eval.runMachine tailCallMachine of
        Left err -> fail $ show err
        Right m' ->
          case Map.lookup "main" m'.scheduler.processes of
            Just p -> p.result `shouldEqual` Just (VInt (BI.fromInt 42))
            Nothing -> fail "main process missing"

    it "wakes sleeping processes and join waiters deterministically" do
      case Eval.runMachine joinSleepMachine of
        Left err -> fail $ show err
        Right m' -> do
          Map.lookup "joined" m'.state `shouldEqual` Just (VBool true)
          Map.lookup "result" m'.state `shouldEqual` Just (VOption (Just (VInt (BI.fromInt 7))))
          m'.scheduler.logicalTick `shouldEqual` 2

limits :: EvalLimits
limits =
  { maxSteps: 1000, maxCallDepth: 10, maxProcesses: 10, maxProcessStepsPerSlice: 10, maxRegistersPerFrame: 20
  , maxFrames: 10, maxListLength: 20, maxMapSize: 20, maxRecordFields: 20, maxValueDepth: 20
  , maxStateEntries: 20, maxTraceEvents: 20, maxProofEvents: 20, maxMailboxSize: 20, maxRemoteNodes: 20
  , maxEventsEmitted: 20, maxEffectsRequested: 20
  }

baseMachine :: Program -> Process -> Machine
baseMachine program process =
  { program
  , scheduler: spawnProcess initialScheduler process
  , state: Map.empty
  , input: Map.singleton "ctx" (VString "ctx")
  , config: { limits, externalBuiltins: Map.empty, performanceMode: false }
  , trace: List.Nil
  , proofTrace: List.Nil
  , outbox: List.Nil
  , events: List.Nil
  , counters: { steps: 0 }
  }

processFor :: String -> Process
processFor fn =
  { pid: "main"
  , status: ProcessReady
  , function: fn
  , frame: { function: fn, pc: 0, registers: Array.replicate 20 VUnit, returnRegister: Nothing, caller: Nothing }
  , callStack: []
  , mailbox: []
  , links: Set.empty
  , monitors: Map.empty
  , parent: Nothing
  , children: Set.empty
  , trapExit: false
  , metadata: { name: "main" }
  , result: Nothing
  , error: Nothing
  , createdSequence: 0
  , stepsExecuted: 0
  }

collectionMachine :: Machine
collectionMachine = baseMachine program (processFor "main")
  where
    program =
      { version: "1.0"
      , constants: [ VInt (BI.fromInt 1), VInt (BI.fromInt 2), VString "payload" ]
      , functions: Map.singleton "main"
          { id: "main", arity: 0, registerCount: 20, parameterTypes: [], returnType: TUnit
          , instructions:
              [ LOAD_INPUT 19 "ctx"
              , STATE_SET "input" 19
              , LOAD_CONST 0 0
              , RECORD_NEW 1
              , RECORD_SET 1 1 "a" 0
              , RECORD_GET_OPT 2 1 "a"
              , RECORD_HAS 3 1 "a"
              , RECORD_KEYS 4 1
              , RECORD_REMOVE 5 1 "a"
              , LIST_FROM 6 [0, 0]
              , LIST_LENGTH 7 6
              , VARIANT_NEW 8 "Some" 0
              , VARIANT_TAG 9 8
              , EVENT_NEW 10 "Created" 0
              , EVENT_EMIT 10
              , EFFECT_NEW 11 "WriteIntent" 0
              , EFFECT_REQUEST 11
              , STATE_SET "opt" 2
              , STATE_SET "has" 3
              , STATE_SET "keys" 4
              , STATE_SET "removed" 5
              , STATE_SET "len" 7
              , STATE_SET "tag" 9
              , HALT 0
              ]
          , debug: { name: "main" }, proof: { isInvariant: false }
          }
      , stateMachines: Map.empty, entrypoint: "main", exports: Map.empty
      , metadata: { description: "" }, typeTable: Map.empty, capabilities: [], verification: { verified: true }
      }

tailCallMachine :: Machine
tailCallMachine = baseMachine program (processFor "main")
  where
    program =
      { version: "1.0"
      , constants: [ VInt (BI.fromInt 42) ]
      , functions: Map.fromFoldable
          [ Tuple "main"
              { id: "main", arity: 0, registerCount: 2, parameterTypes: [], returnType: TInt
              , instructions: [ LOAD_CONST 0 0, TAIL_CALL "id" [0] ]
              , debug: { name: "main" }, proof: { isInvariant: false }
              }
          , Tuple "id"
              { id: "id", arity: 1, registerCount: 1, parameterTypes: [TInt], returnType: TInt
              , instructions: [ RETURN 0 ]
              , debug: { name: "id" }, proof: { isInvariant: false }
              }
          ]
      , stateMachines: Map.empty, entrypoint: "main", exports: Map.empty
      , metadata: { description: "" }, typeTable: Map.empty, capabilities: [], verification: { verified: true }
      }

joinSleepMachine :: Machine
joinSleepMachine = baseMachine program (processFor "main")
  where
    program =
      { version: "1.0"
      , constants: [ VInt (BI.fromInt 7) ]
      , functions: Map.fromFoldable
          [ Tuple "main"
              { id: "main", arity: 0, registerCount: 5, parameterTypes: [], returnType: TUnit
              , instructions:
                  [ PROC_SPAWN 0 "worker" []
                  , PROC_JOIN 1 0
                  , PROC_JOIN_RESULT 2 0
                  , STATE_SET "joined" 1
                  , STATE_SET "result" 2
                  , HALT 2
                  ]
              , debug: { name: "main" }, proof: { isInvariant: false }
              }
          , Tuple "worker"
              { id: "worker", arity: 0, registerCount: 1, parameterTypes: [], returnType: TInt
              , instructions: [ LOAD_CONST 0 0, PROC_SLEEP_TICKS 2, RETURN 0 ]
              , debug: { name: "worker" }, proof: { isInvariant: false }
              }
          ]
      , stateMachines: Map.empty, entrypoint: "main", exports: Map.empty
      , metadata: { description: "" }, typeTable: Map.empty, capabilities: [], verification: { verified: true }
      }
