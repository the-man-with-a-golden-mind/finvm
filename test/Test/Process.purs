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
import FinVM.Process (Process, ProcessStatus(..))
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

