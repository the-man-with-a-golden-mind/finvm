module Test.E2E (spec) where

import Prelude
import Data.BigInt as BI
import Data.Map as Map
import Data.Set as Set
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.List as List
import Data.Tuple (Tuple(..))
import Data.Array as Array
import FinVM.Eval as Eval
import FinVM.Value (Value(..))
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
  describe "FinVM E2E Workflows" do
    let 
      limits =
        { maxSteps: 5000, maxCallDepth: 10, maxProcesses: 10, maxProcessStepsPerSlice: 10, maxRegistersPerFrame: 10
        , maxFrames: 10, maxListLength: 1000, maxMapSize: 100, maxRecordFields: 10, maxValueDepth: 10
        , maxStateEntries: 100, maxTraceEvents: 100, maxProofEvents: 100, maxMailboxSize: 100, maxRemoteNodes: 10
        , maxEventsEmitted: 100, maxEffectsRequested: 100
        }
      
      program :: Program
      program =
        { version: "1.0"
        , constants: [ VInt (BI.fromInt 10), VInt (BI.fromInt 3), VInt (BI.fromInt 0), VInt (BI.fromInt 1) ]
        , functions: Map.fromFoldable
            [ Tuple "main" 
                { id: "main", arity: 0, registerCount: 10, parameterTypes: [], returnType: TUnit
                , instructions: 
                    [ PROC_SPAWN 0 "aggregator" [] -- r0 = aggPid
                    , PROC_SPAWN 1 "worker" [0] -- worker 1
                    , PROC_SPAWN 2 "worker" [0] -- worker 2
                    , PROC_SPAWN 3 "worker" [0] -- worker 3
                    , RETURN 0
                    ]
                , debug: { name: "main" }, proof: { isInvariant: false }
                }
            , Tuple "aggregator"
                { id: "aggregator", arity: 0, registerCount: 10, parameterTypes: [], returnType: TUnit
                , instructions: 
                    [ LOAD_CONST 0 1 -- r0 = target count (3)
                    , LOAD_CONST 1 2 -- r1 = current count (0)
                    , LOAD_CONST 2 2 -- r2 = sum (0)
                    , LABEL "loop"
                    , EQ 3 1 0 -- r3 = current == target
                    , JUMP_IF 3 "done"
                    , PROC_RECEIVE 4 -- r4 = msg
                    , ADD 2 2 4 -- sum += msg
                    , LOAD_CONST 5 3 -- r5 = 1
                    , ADD 1 1 5 -- count += 1
                    , JUMP "loop"
                    , LABEL "done"
                    , STATE_SET "final_sum" 2
                    , HALT 2
                    ]
                , debug: { name: "aggregator" }, proof: { isInvariant: false }
                }
            , Tuple "worker"
                { id: "worker", arity: 1, registerCount: 5, parameterTypes: [TProcessRef], returnType: TUnit
                , instructions: 
                    [ MOVE 0 0 -- aggPid is in r0
                    , LOAD_CONST 1 0 -- default 10
                    , PROC_SEND 0 1
                    , RETURN 1
                    ]
                , debug: { name: "worker" }, proof: { isInvariant: false }
                }
            ]
        , stateMachines: Map.empty
        , entrypoint: "main", exports: Map.empty
        , metadata: { description: "e2e" }, typeTable: Map.empty, capabilities: [], verification: { verified: true }
        }

      initialProcess =
        { pid: "main", status: ProcessReady, function: "main", frame: { function: "main", pc: 0, registers: Array.replicate 10 VUnit, returnRegister: Nothing, caller: Nothing }
        , callStack: [], mailbox: [], links: Set.empty, monitors: Map.empty, parent: Nothing, children: Set.empty, trapExit: false, metadata: { name: "main" }, result: Nothing, error: Nothing, createdSequence: 0, stepsExecuted: 0 }
      
      machine =
        { program: program, scheduler: spawnProcess initialScheduler initialProcess, state: Map.empty, input: Map.empty, config: { limits: limits, externalBuiltins: Map.empty, performanceMode: false }
        , trace: List.Nil, proofTrace: List.Nil, outbox: List.Nil, events: List.Nil, counters: { steps: 0 }, labelCache: Map.empty
        }

    it "executes a multi-process aggregation workflow" do
      case Eval.runMachine machine of
        Left err -> fail $ show err
        Right m' -> do
          Map.lookup "final_sum" m'.state `shouldEqual` Just (VInt (BI.fromInt 30))
