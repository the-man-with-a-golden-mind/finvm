module Test.Replay (spec) where

import Prelude
import Data.BigInt as BI
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.List as List
import Data.Array as Array
import Data.Set as Set
import Data.Tuple (Tuple(..))
import FinVM.Machine (Machine)
import FinVM.Instruction (Instruction(..))
import FinVM.Type (VMType(..))
import FinVM.Value (Value(..))
import FinVM.Process (ProcessStatus(..))
import FinVM.Process.Scheduler (initialScheduler, spawnProcess)
import FinVM.Encoding.Snapshot as Snapshot
import FinVM.Encoding.Replay as Replay
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec = do
  describe "FinVM.Replay and Snapshot" do
    let 
      snapshotLimits =
        { maxSteps: 100, maxCallDepth: 10, maxProcesses: 10, maxProcessStepsPerSlice: 10, maxRegistersPerFrame: 10
        , maxFrames: 10, maxListLength: 10, maxMapSize: 10, maxRecordFields: 10, maxValueDepth: 10
        , maxStateEntries: 10, maxTraceEvents: 10, maxProofEvents: 10, maxMailboxSize: 10, maxRemoteNodes: 10
        , maxEventsEmitted: 10, maxEffectsRequested: 10
        }
      
      program =
        { version: "1.0", constants: [], functions: Map.empty, stateMachines: Map.empty, entrypoint: "main", exports: Map.empty
        , metadata: { description: "" }, typeTable: Map.empty, capabilities: [], verification: { verified: true }
        }

      machine :: Machine
      machine =
        { program: program, scheduler: initialScheduler, state: Map.empty, input: Map.empty, config: { limits: snapshotLimits, externalBuiltins: Map.empty, performanceMode: false }
        , trace: List.Nil, proofTrace: List.Nil, outbox: List.Nil, events: List.Nil, counters: { steps: 0 }, labelCache: Map.empty
        }

    it "produces identical snapshots for the same machine state" do
      let s1 = Snapshot.createSnapshot machine
          s2 = Snapshot.createSnapshot machine
      s1 `shouldEqual` s2

    it "verifies matching replay state and output hashes" do
      Replay.verifyReplay replayMachine { expectedStateHash: "dbfb9442e65cb62b9c60395ee3e10aae5039bc801a21dd0026ef1fabbe04cf22", expectedOutputHash: "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a" }
        `shouldEqual` Replay.ReplaySuccess

    it "rejects mismatched replay state hashes" do
      case Replay.verifyReplay replayMachine { expectedStateHash: "wrong", expectedOutputHash: "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a" } of
        Replay.ReplayMismatch _ -> pure unit
        other -> other `shouldEqual` Replay.ReplayMismatch "expected mismatch"
  where
    limits =
      { maxSteps: 100, maxCallDepth: 10, maxProcesses: 10, maxProcessStepsPerSlice: 10, maxRegistersPerFrame: 10
      , maxFrames: 10, maxListLength: 10, maxMapSize: 10, maxRecordFields: 10, maxValueDepth: 10
      , maxStateEntries: 10, maxTraceEvents: 10, maxProofEvents: 10, maxMailboxSize: 10, maxRemoteNodes: 10
      , maxEventsEmitted: 10, maxEffectsRequested: 10
      }

    replayProgram =
      { version: "1.0"
      , constants: [ VInt (BI.fromInt 42) ]
      , functions: Map.fromFoldable
          [ Tuple "main"
              { id: "main", arity: 0, registerCount: 1, parameterTypes: [], returnType: TInt
              , instructions: [ LOAD_CONST 0 0, STATE_SET "answer" 0, HALT 0 ]
              , debug: { name: "main" }, proof: { isInvariant: false }
              }
          ]
      , stateMachines: Map.empty
      , entrypoint: "main"
      , exports: Map.empty
      , metadata: { description: "replay" }
      , typeTable: Map.empty
      , capabilities: []
      , verification: { verified: true }
      }

    replayProcess =
      { pid: "main"
      , status: ProcessReady
      , function: "main"
      , frame: { function: "main", pc: 0, registers: Array.replicate 1 VUnit, returnRegister: Nothing, caller: Nothing }
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

    replayMachine :: Machine
    replayMachine =
      { program: replayProgram
      , scheduler: spawnProcess initialScheduler replayProcess
      , state: Map.empty
      , input: Map.empty
      , config: { limits: limits, externalBuiltins: Map.empty, performanceMode: false }
      , trace: List.Nil
      , proofTrace: List.Nil
      , outbox: List.Nil
      , events: List.Nil
      , counters: { steps: 0 }, labelCache: Map.empty
      }
