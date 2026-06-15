module Test.Process (spec) where

import Prelude
import Data.BigInt as BI
import Data.Map as Map
import Data.Set as Set
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Data.List as List
import Data.Array as Array
import FinVM.Eval as Eval
import FinVM.Value (Value(..))
import FinVM.Instruction (Instruction(..))
import FinVM.Program (Program)
import FinVM.Machine (Machine)
import FinVM.Limits (EvalLimits)
import FinVM.Process (Process, ProcessStatus(..), WaitCondition(..))
import FinVM.Process.Scheduler (initialScheduler, spawnProcess)
import FinVM.Type (VMType(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, fail)

spec :: Spec Unit
spec = do
  describe "FinVM.Process System" do
    let 
      limits =
        { maxSteps: 1000
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
      
      -- main spawns worker, sends message
      program :: Program
      program =
        { version: "1.0"
        , constants: [ VString "ping", VString "pong" ]
        , functions: Map.fromFoldable
            [ Tuple "main" 
                { id: "main", arity: 0, registerCount: 5, parameterTypes: [], returnType: TUnit
                , instructions: 
                    [ PROC_SPAWN 0 "worker" [] 
                    , LOAD_CONST 1 0 -- "ping"
                    , PROC_SEND 0 1
                    , PROC_YIELD
                    , HALT 0
                    ]
                , debug: { name: "main" }, proof: { isInvariant: false }
                }
            , Tuple "worker"
                { id: "worker", arity: 0, registerCount: 5, parameterTypes: [], returnType: TUnit
                , instructions: 
                    [ PROC_RECEIVE 0
                    , RETURN 0
                    ]
                , debug: { name: "worker" }, proof: { isInvariant: false }
                }
            ]
        , stateMachines: Map.empty
        , entrypoint: "main"
        , exports: Map.empty
        , metadata: { description: "ping-pong" }, typeTable: Map.empty, capabilities: [], verification: { verified: true }
        }

      initialProcess =
        { pid: "main"
        , status: ProcessReady
        , function: "main"
        , frame: { function: "main", pc: 0, registers: Array.replicate 10 VUnit, returnRegister: Nothing, caller: Nothing }
        , callStack: []
        , mailbox: []
        , links: Set.empty
        , remoteLinks: Set.empty
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

      machine :: Machine
      machine =
        { program: program
        , scheduler: spawnProcess initialScheduler initialProcess
        , state: Map.empty
        , input: Map.empty
        , config: { limits: limits, externalBuiltins: Map.empty, performanceMode: false }
        , trace: List.Nil
        , proofTrace: List.Nil
        , outbox: List.Nil
        , events: List.Nil
        , counters: { steps: 0 }, labelCache: Map.empty
        }

    it "executes a simple spawn and message pass (ping-pong sequence)" do
      case Eval.runMachine machine of
        Left err -> fail $ show err
        Right m' -> do
          -- Check if worker received message
          case Map.lookup "p0" m'.scheduler.processes of
            Nothing -> fail "Worker process p0 not found"
            Just p0 -> do
              p0.result `shouldEqual` Just (VString "ping")

    it "wakes a blocked root receiver in a request/reply workflow" do
      case Eval.runMachine doublerMachine of
        Left err -> fail $ show err
        Right m' -> do
          case Map.lookup "main" m'.scheduler.processes of
            Nothing -> fail "main process missing"
            Just mainProcess -> do
              mainProcess.result `shouldEqual` Just (VInt (BI.fromInt 42))
              mainProcess.mailbox `shouldEqual` []
          case Map.lookup "p0" m'.scheduler.processes of
            Nothing -> fail "doubler process p0 missing"
            Just doubler -> do
              doubler.status `shouldEqual` ProcessWaiting WaitingForMessage
              doubler.mailbox `shouldEqual` []

doublerLimits :: EvalLimits
doublerLimits =
  { maxSteps: 1000
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

doublerProgram :: Program
doublerProgram =
  { version: "1.0"
  , constants: [ VInt (BI.fromInt 21), VInt (BI.fromInt 2) ]
  , functions: Map.fromFoldable
      [ Tuple "main"
          { id: "main", arity: 0, registerCount: 10, parameterTypes: [], returnType: TInt
          , instructions:
              [ PROC_SELF 0
              , PROC_SPAWN 1 "doubler" []
              , LOAD_CONST 2 0
              , RECORD_NEW 3
              , RECORD_SET 3 3 "reply_to" 0
              , RECORD_SET 3 3 "n" 2
              , PROC_SEND 1 3
              , PROC_RECEIVE 4
              , RECORD_GET 5 4 "value"
              , RETURN 5
              ]
          , debug: { name: "main" }, proof: { isInvariant: false }
          }
      , Tuple "doubler"
          { id: "doubler", arity: 0, registerCount: 10, parameterTypes: [], returnType: TUnit
          , instructions:
              [ LABEL "again"
              , PROC_RECEIVE 0
              , RECORD_GET 1 0 "reply_to"
              , RECORD_GET 2 0 "n"
              , LOAD_CONST 3 1
              , MUL 4 2 3
              , RECORD_NEW 5
              , RECORD_SET 5 5 "value" 4
              , PROC_SEND 1 5
              , JUMP "again"
              ]
          , debug: { name: "doubler" }, proof: { isInvariant: false }
          }
      ]
  , stateMachines: Map.empty
  , entrypoint: "main"
  , exports: Map.empty
  , metadata: { description: "request/reply doubler" }
  , typeTable: Map.empty
  , capabilities: []
  , verification: { verified: true }
  }

doublerInitialProcess :: Process
doublerInitialProcess =
  { pid: "main"
  , status: ProcessReady
  , function: "main"
  , frame: { function: "main", pc: 0, registers: Array.replicate 10 VUnit, returnRegister: Nothing, caller: Nothing }
  , callStack: []
  , mailbox: []
  , links: Set.empty
  , remoteLinks: Set.empty
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

doublerMachine :: Machine
doublerMachine =
  { program: doublerProgram
  , scheduler: spawnProcess initialScheduler doublerInitialProcess
  , state: Map.empty
  , input: Map.empty
  , config: { limits: doublerLimits, externalBuiltins: Map.empty, performanceMode: false }
  , trace: List.Nil
  , proofTrace: List.Nil
  , outbox: List.Nil
  , events: List.Nil
  , counters: { steps: 0 }
  , labelCache: Map.empty
  }
