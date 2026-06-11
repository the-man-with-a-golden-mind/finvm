module Benchmark.Graph where

import Prelude
import Data.BigInt as BI
import Data.Map as Map
import Data.Tuple (Tuple(..))
import Data.Array as Array
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Either (Either(..))
import Data.List as List
import FinVM.Eval as Eval
import FinVM.Value (Value(..))
import FinVM.Instruction (Instruction(..))
import FinVM.Program (Program)
import FinVM.Machine (Machine)
import FinVM.Process (ProcessStatus(..))
import FinVM.Process.Scheduler (initialScheduler, spawnProcess)
import FinVM.Type (VMType(..))
import FinVM.Numeric.Rounding (Rounding(..))
import Effect (Effect)
import Effect.Console (log)
import Effect.Now (now)
import Data.DateTime.Instant (unInstant)
import Data.Newtype (unwrap)

runBenchmark :: Boolean -> Int -> Effect Unit
runBenchmark perfMode size = do
  let 
    limits =
      { maxSteps: size * 50, maxCallDepth: 10, maxProcesses: 10, maxProcessStepsPerSlice: 500, maxRegistersPerFrame: 10
      , maxFrames: 10, maxListLength: size + 100, maxMapSize: size + 100, maxRecordFields: 10, maxValueDepth: 10
      , maxStateEntries: 100, maxTraceEvents: 100, maxProofEvents: 100, maxMailboxSize: 100, maxRemoteNodes: 10
      , maxEventsEmitted: 100, maxEffectsRequested: 100
      }
    
    -- VM Program for BFS-like traversal:
    -- 1. Create a chain graph in a Map: 0 -> 1 -> 2 ... -> size
    -- 2. Traverse from 0 to size.
    program =
      { version: "1.0"
      , constants: [ VInt (BI.fromInt size), VInt (BI.fromInt 0), VInt (BI.fromInt 1) ]
      , functions: Map.fromFoldable
          [ Tuple "main" 
              { id: "main", arity: 0, registerCount: 10, parameterTypes: [], returnType: TUnit
              , instructions: 
                  [ LOAD_CONST 0 0 -- r0 = size
                  , MAP_NEW 1      -- r1 = graph (Map)
                  , LOAD_CONST 2 1 -- r2 = i (0)
                  , LOAD_CONST 3 2 -- r3 = 1
                  , LABEL "init_loop"
                  , EQ 4 2 0
                  , JUMP_IF 4 "traverse_start"
                  , ADD 5 2 3      -- r5 = i + 1
                  , MOVE 6 2       -- key = i
                  , MAP_SET 1 1 6 5 -- graph[i] = i + 1
                  , ADD 2 2 3      -- i++
                  , JUMP "init_loop"
                  , LABEL "traverse_start"
                  , LOAD_CONST 2 1 -- r2 = current (0)
                  , LABEL "traverse_loop"
                  , EQ 4 2 0       -- current == size
                  , JUMP_IF 4 "done"
                  , MAP_GET 2 1 2  -- current = graph[current]
                  , JUMP "traverse_loop"
                  , LABEL "done"
                  , HALT 2
                  ]
              , debug: { name: "main" }, proof: { isInvariant: false }
              }
          ]
      , stateMachines: Map.empty
      , entrypoint: "main", exports: Map.empty
      , metadata: { description: "graph-benchmark" }, typeTable: Map.empty, capabilities: [], verification: { verified: true }
      }

    initialProcess =
      { pid: "main", status: ProcessReady, function: "main", frame: { function: "main", pc: 0, registers: Array.replicate 10 VUnit, returnRegister: Nothing, caller: Nothing }
      , callStack: [], mailbox: [], links: mempty, monitors: Map.empty, parent: Nothing, children: mempty, trapExit: false, metadata: { name: "main" }, result: Nothing, error: Nothing, createdSequence: 0, stepsExecuted: 0 }
    
    machine =
      { program: program, scheduler: spawnProcess initialScheduler initialProcess, state: Map.empty, input: Map.empty, config: { limits: limits, externalBuiltins: Map.empty, performanceMode: perfMode }
      , trace: List.Nil, proofTrace: List.Nil, outbox: List.Nil, events: List.Nil, counters: { steps: 0 }, labelCache: Map.empty
      }

  t1 <- now
  case Eval.runMachine machine of
    Left err -> log $ "Benchmark failed: " <> show err
    Right m' -> do
      t2 <- now
      let d = (unwrap (unInstant t2)) - (unwrap (unInstant t1))
          modeStr = if perfMode then "Performance Mode" else "Proof/Trace Mode"
      log $ "FinVM Benchmark (Graph Traversal - " <> modeStr <> "): " <> show size <> " nodes"
      log $ "Time: " <> show d <> "ms"

