module Test.PerformanceMode (spec) where

import Prelude
import Data.Map as Map
import Data.Set as Set
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Data.List as List
import FinVM.Eval as Eval
import FinVM.Value (Value(..))
import FinVM.Instruction (Instruction(..))
import FinVM.Program (Program)
import FinVM.Machine (Machine)
import FinVM.Process (ProcessStatus(..))
import FinVM.Process.Scheduler (initialScheduler, spawnProcess)
import FinVM.Type (VMType(..))
import Data.BigInt as BI
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, fail)

spec :: Spec Unit
spec = do
  describe "FinVM Performance Mode" do
    let 
      limits =
        { maxSteps: 100, maxCallDepth: 10, maxProcesses: 10, maxProcessStepsPerSlice: 10, maxRegistersPerFrame: 10
        , maxFrames: 10, maxListLength: 10, maxMapSize: 10, maxRecordFields: 10, maxValueDepth: 10
        , maxStateEntries: 10, maxTraceEvents: 10, maxProofEvents: 10, maxMailboxSize: 10, maxRemoteNodes: 10
        , maxEventsEmitted: 10, maxEffectsRequested: 10
        }
      
      program =
        { version: "1.0", constants: [ VBool true ], functions: Map.fromFoldable
            [ Tuple "main" 
                { id: "main", arity: 0, registerCount: 5, parameterTypes: [], returnType: TUnit
                , instructions: 
                    [ LOAD_CONST 0 0 -- true
                    , ASSUME 0 "test assumption"
                    , ASSERT 0 100
                    , PROOF_MARK "test mark" 0
                    , HALT 0
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

      machine :: Boolean -> Machine
      machine perfMode =
        { program: program, scheduler: spawnProcess initialScheduler initialProcess, state: Map.empty, input: Map.empty, config: { limits: limits, externalBuiltins: Map.empty, performanceMode: perfMode }
        , trace: List.Nil, proofTrace: List.Nil, outbox: List.Nil, events: List.Nil, counters: { steps: 0 }
        }

    it "populates trace and proofTrace when performanceMode is false (Negative Case)" do
      case Eval.runMachine (machine false) of
        Left err -> fail $ show err
        Right m' -> do
          -- Should have executed 5 instructions
          List.length m'.trace `shouldEqual` 5
          -- Should have recorded 3 proof events (ASSUME, ASSERT, PROOF_MARK)
          List.length m'.proofTrace `shouldEqual` 3

    it "keeps trace and proofTrace empty when performanceMode is true (Positive Case)" do
      case Eval.runMachine (machine true) of
        Left err -> fail $ show err
        Right m' -> do
          -- Arrays should be completely empty, bypassing allocation
          List.length m'.trace `shouldEqual` 0
          List.length m'.proofTrace `shouldEqual` 0

