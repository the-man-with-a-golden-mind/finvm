module Test.Remote (spec) where

import Prelude
import Data.Map as Map
import Data.Set as Set
import Data.Tuple (Tuple(..))
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.List as List
import FinVM.Eval as Eval
import FinVM.Value (Value(..), NodeRef(..))
import FinVM.Instruction (Instruction(..))
import FinVM.Program (Program)
import FinVM.Machine (Machine)
import FinVM.Process (ProcessStatus(..))
import FinVM.Process.Scheduler (initialScheduler, spawnProcess)
import FinVM.Type (VMType(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, fail)

spec :: Spec Unit
spec = do
  describe "FinVM.Remote Tracking" do
    let 
      limits =
        { maxSteps: 100, maxCallDepth: 10, maxProcesses: 10, maxProcessStepsPerSlice: 10, maxRegistersPerFrame: 10
        , maxFrames: 10, maxListLength: 10, maxMapSize: 10, maxRecordFields: 10, maxValueDepth: 10
        , maxStateEntries: 10, maxTraceEvents: 10, maxProofEvents: 10, maxMailboxSize: 10, maxRemoteNodes: 10
        , maxEventsEmitted: 10, maxEffectsRequested: 10
        }
      
      program =
        { version: "1.0", constants: [ VString "hello", VString "other", VString "p42" ], functions: Map.fromFoldable
            [ Tuple "main" 
                { id: "main", arity: 0, registerCount: 5, parameterTypes: [], returnType: TUnit
                , instructions: 
                    [ LOAD_CONST 1 1 -- "other"
                    , LOAD_CONST 2 2 -- "p42"
                    , REMOTE_PID_NEW 0 1 2 
                    , LOAD_CONST 1 0 -- "hello"
                    , NODE_SEND 0 1
                    , HALT 1
                    ]
                , debug: { name: "main" }, proof: { isInvariant: false }
                }
            ]
        , stateMachines: Map.empty
        , entrypoint: "main", exports: Map.empty
        , metadata: { description: "" }, typeTable: Map.empty, capabilities: [], verification: { verified: true }
        }

      initialProcess =
        { pid: "main", status: ProcessReady, function: "main", frame: { function: "main", pc: 0, registers: Array.replicate 10 VUnit, returnRegister: Nothing, caller: Nothing }
        , callStack: [], mailbox: [], links: Set.empty, monitors: Map.empty, parent: Nothing, children: Set.empty, trapExit: false, metadata: { name: "main" }, result: Nothing, error: Nothing, createdSequence: 0, stepsExecuted: 0 }

      machine :: Machine
      machine =
        { program: program, scheduler: spawnProcess initialScheduler initialProcess, state: Map.empty, input: Map.empty, config: { limits: limits, externalBuiltins: Map.empty, performanceMode: false }
        , trace: List.Nil, proofTrace: List.Nil, outbox: List.Nil, events: List.Nil, counters: { steps: 0 }
        }

    it "creates a RemoteSendIntent in the outbox" do
      case Eval.runMachine machine of
        Left err -> fail $ show err
        Right m' -> do
          let intents = m'.outbox
          (case intents of
            List.Cons intent List.Nil -> do
              intent.type_ `shouldEqual` "RemoteSendIntent"
              -- Check payload structure
              case intent.payload of
                VRecord fields -> do
                  Map.lookup "pid" fields `shouldEqual` Just (VString "p42")
                  Map.lookup "node" fields `shouldEqual` Just (VString "other")
                  Map.lookup "message" fields `shouldEqual` Just (VString "hello")
                _ -> fail "Expected VRecord payload"
            _ -> fail "Expected exactly one intent")

