module Test.Proof (spec) where

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
import FinVM.Process (Process, ProcessStatus(..))
import FinVM.Process.Scheduler (initialScheduler, spawnProcess)
import FinVM.Proof.ProofTrace as ProofTrace
import FinVM.Type (VMType(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, fail)

spec :: Spec Unit
spec = do
  describe "FinVM.Proof System" do
    let 
      limits =
        { maxSteps: 100
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
      
      program :: Program
      program =
        { version: "1.0"
        , constants: [ VInt (BI.fromInt 1), VBool true ]
        , functions: Map.fromFoldable
            [ Tuple "main" 
                { id: "main", arity: 0, registerCount: 5, parameterTypes: [], returnType: TInt
                , instructions: 
                    [ LOAD_CONST 0 1 -- r0 = true
                    , ASSUME 0 "x > 0"
                    , LOAD_CONST 1 0 -- r1 = 1
                    , MOVE 2 1 -- r2 = x (using const 1 as x)
                    , ADD 3 2 1 -- r3 = x + 1
                    , GT 4 3 2 -- r4 = (x + 1) > x
                    , ASSERT 4 101 -- error code 101
                    , PROOF_MARK "y" 3
                    , RETURN 3
                    ]
                , debug: { name: "main" }, proof: { isInvariant: false }
                }
            ]
        , stateMachines: Map.empty
        , entrypoint: "main"
        , exports: Map.empty
        , metadata: { description: "proof-test" }, typeTable: Map.empty, capabilities: [], verification: { verified: true }
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

    it "records assumptions, assertions and proof marks" do
      case Eval.runMachine machine of
        Left err -> fail $ show err
        Right m' -> do
          let pt = List.reverse m'.proofTrace
          pt `shouldEqual` List.fromFoldable
            [ ProofTrace.ProofAssumption "x > 0"
            , ProofTrace.ProofAssertion true 101
            , ProofTrace.ProofValueMarked "y" (VInt (BI.fromInt 2))
            ]
