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
        , callStack: [], mailbox: [], links: Set.empty, remoteLinks: Set.empty, monitors: Map.empty, parent: Nothing, children: Set.empty, trapExit: false, metadata: { name: "main" }, result: Nothing, error: Nothing, createdSequence: 0, stepsExecuted: 0 }

      machine :: Machine
      machine =
        { program: program, scheduler: spawnProcess initialScheduler initialProcess, state: Map.empty, input: Map.empty, config: { limits: limits, externalBuiltins: Map.empty, performanceMode: false }
        , trace: List.Nil, proofTrace: List.Nil, outbox: List.Nil, events: List.Nil, counters: { steps: 0 }, labelCache: Map.empty
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

    it "emits RemoteMonitorIntent and RemoteDemonitorIntent and clears monitor ref" do
      let
        monitorProgram =
          { version: "1.0", constants: [ VString "other", VString "p42" ], functions: Map.fromFoldable
              [ Tuple "main"
                  { id: "main", arity: 0, registerCount: 5, parameterTypes: [], returnType: TUnit
                  , instructions:
                      [ LOAD_CONST 1 0
                      , LOAD_CONST 2 1
                      , REMOTE_PID_NEW 0 1 2
                      , NODE_MONITOR 3 0
                      , NODE_DEMONITOR 3
                      , HALT 3
                      ]
                  , debug: { name: "main" }, proof: { isInvariant: false }
                  }
              ]
          , stateMachines: Map.empty
          , entrypoint: "main", exports: Map.empty
          , metadata: { description: "" }, typeTable: Map.empty, capabilities: [], verification: { verified: true }
          }
        monitorMachine = machine { program = monitorProgram }
      case Eval.runMachine monitorMachine of
        Left err -> fail $ show err
        Right m' -> do
          case m'.outbox of
            List.Cons demonitorIntent (List.Cons monitorIntent List.Nil) -> do
              demonitorIntent.type_ `shouldEqual` "RemoteDemonitorIntent"
              monitorIntent.type_ `shouldEqual` "RemoteMonitorIntent"
              case demonitorIntent.payload, monitorIntent.payload of
                VRecord demonitorFields, VRecord monitorFields -> do
                  Map.lookup "node" monitorFields `shouldEqual` Just (VString "other")
                  Map.lookup "remotePid" monitorFields `shouldEqual` Just (VString "p42")
                  Map.lookup "node" demonitorFields `shouldEqual` Just (VString "other")
                  Map.lookup "remotePid" demonitorFields `shouldEqual` Just (VString "p42")
                _, _ -> fail "Expected VRecord payloads for monitor intents"
            _ -> fail "Expected monitor + demonitor intents"
          case Map.lookup "main" m'.scheduler.processes of
            Nothing -> fail "main process missing"
            Just p -> Map.isEmpty p.monitors `shouldEqual` true

    it "emits RemoteSpawnIntent with requester metadata for deterministic completion" do
      let
        spawnProgram =
          { version: "1.0", constants: [ VString "vmB" ], functions: Map.fromFoldable
              [ Tuple "main"
                  { id: "main", arity: 0, registerCount: 4, parameterTypes: [], returnType: TUnit
                  , instructions:
                      [ LOAD_CONST 1 0
                      , NODE_SPAWN 0 1 "worker" []
                      , HALT 0
                      ]
                  , debug: { name: "main" }, proof: { isInvariant: false }
                  }
              , Tuple "worker"
                  { id: "worker", arity: 0, registerCount: 1, parameterTypes: [], returnType: TUnit
                  , instructions: [ HALT 0 ]
                  , debug: { name: "worker" }, proof: { isInvariant: false }
                  }
              ]
          , stateMachines: Map.empty
          , entrypoint: "main", exports: Map.empty
          , metadata: { description: "" }, typeTable: Map.empty, capabilities: [], verification: { verified: true }
          }
        spawnMachine = machine { program = spawnProgram }
      case Eval.runMachine spawnMachine of
        Left err -> fail $ show err
        Right m' -> do
          case m'.outbox of
            List.Cons intent List.Nil -> do
              intent.type_ `shouldEqual` "RemoteSpawnIntent"
              case intent.payload of
                VRecord fields -> do
                  Map.lookup "node" fields `shouldEqual` Just (VString "vmB")
                  Map.lookup "requesterPid" fields `shouldEqual` Just (VString "main")
                  case Map.lookup "requestId" fields of
                    Just (VString rid) | rid /= "" -> pure unit
                    _ -> fail "expected non-empty requestId in RemoteSpawnIntent"
                _ -> fail "Expected VRecord payload for spawn intent"
            _ -> fail "Expected exactly one spawn intent"

    it "emits RemoteLinkIntent and RemoteUnlinkIntent" do
      let
        linkProgram =
          { version: "1.0", constants: [ VString "other", VString "p42" ], functions: Map.fromFoldable
              [ Tuple "main"
                  { id: "main", arity: 0, registerCount: 5, parameterTypes: [], returnType: TUnit
                  , instructions:
                      [ LOAD_CONST 1 0
                      , LOAD_CONST 2 1
                      , REMOTE_PID_NEW 0 1 2
                      , NODE_LINK 0
                      , NODE_UNLINK 0
                      , HALT 0
                      ]
                  , debug: { name: "main" }, proof: { isInvariant: false }
                  }
              ]
          , stateMachines: Map.empty
          , entrypoint: "main", exports: Map.empty
          , metadata: { description: "" }, typeTable: Map.empty, capabilities: [], verification: { verified: true }
          }
        linkMachine = machine { program = linkProgram }
      case Eval.runMachine linkMachine of
        Left err -> fail $ show err
        Right m' -> do
          case m'.outbox of
            List.Cons unlinkIntent (List.Cons linkIntent List.Nil) -> do
              unlinkIntent.type_ `shouldEqual` "RemoteUnlinkIntent"
              linkIntent.type_ `shouldEqual` "RemoteLinkIntent"
            _ -> fail "Expected link + unlink intents"

