module Benchmark.Statistics where

import Prelude
import Data.BigInt as BI
import Data.Map as Map
import Data.Tuple (Tuple(..))
import Data.Array as Array
import Data.Maybe (Maybe(..))
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
import Data.Time.Duration (Milliseconds(..))

runBenchmark :: Boolean -> Int -> Effect Unit
runBenchmark perfMode size = do
  let 
    limits =
      { maxSteps: size * 10, maxCallDepth: 10, maxProcesses: 10, maxProcessStepsPerSlice: 100, maxRegistersPerFrame: 10
      , maxFrames: 10, maxListLength: size + 100, maxMapSize: 100, maxRecordFields: 10, maxValueDepth: 10
      , maxStateEntries: 100, maxTraceEvents: 100, maxProofEvents: 100, maxMailboxSize: 100, maxRemoteNodes: 10
      , maxEventsEmitted: 100, maxEffectsRequested: 100
      }
    
    program =
      { version: "1.0"
      , constants: [ VInt (BI.fromInt size), VInt (BI.fromInt 0), VInt (BI.fromInt 1) ]
      , functions: Map.fromFoldable
          [ Tuple "main" 
              { id: "main", arity: 0, registerCount: 10, parameterTypes: [], returnType: TUnit
              , instructions: 
                  [ LOAD_CONST 0 0 -- r0 = size
                  , LIST_NEW 1 -- r1 = list
                  , LOAD_CONST 2 1 -- r2 = i (0)
                  , LABEL "fill_loop"
                  , EQ 3 2 0
                  , JUMP_IF 3 "sum_start"
                  , LIST_APPEND 1 1 2 -- list.append(i)
                  , LOAD_CONST 4 2 -- r4 = 1
                  , ADD 2 2 4 -- i++
                  , JUMP "fill_loop"
                  , LABEL "sum_start"
                  , LOAD_CONST 5 1 -- r5 = sum (0)
                  , LOAD_CONST 6 1 -- r6 = j (0)
                  , LABEL "sum_loop"
                  , EQ 7 6 0
                  , JUMP_IF 7 "done"
                  , LIST_GET 8 1 6 -- r8 = list[j]
                  , ADD 5 5 8 -- sum += r8
                  , LOAD_CONST 9 2
                  , ADD 6 6 9 -- j++
                  , JUMP "sum_loop"
                  , LABEL "done"
                  , DIV 8 RoundDown 5 0 -- r8 = sum / size
                  , STATE_SET "sum" 5
                  , HALT 5
                  ]
              , debug: { name: "main" }, proof: { isInvariant: false }
              }
          ]
      , stateMachines: Map.empty
      , entrypoint: "main", exports: Map.empty
      , metadata: { description: "benchmark" }, typeTable: Map.empty, capabilities: [], verification: { verified: true }
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
      log $ "FinVM Benchmark (Statistics - " <> modeStr <> "): " <> show size <> " items"
      log $ "Time: " <> show d <> "ms"
      case Map.lookup "main" m'.scheduler.processes of
        Just p -> log $ "Result: " <> show p.result
        Nothing -> log "Result not found"
      case Map.lookup "sum" m'.state of
        Just v -> log $ "Sum from State: " <> show v
        Nothing -> pure unit

