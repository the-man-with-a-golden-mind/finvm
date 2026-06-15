module Test.StateMachine (spec) where

import Prelude
import Data.Map as Map
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Tuple (Tuple(..))
import Data.List as List
import Data.Array as Array
import FinVM.Interpreter as Interpreter
import FinVM.Value (Value(..))
import FinVM.Instruction (Instruction(..))
import FinVM.Program (Program)
import FinVM.Machine (Machine)
import FinVM.Process (Process, ProcessStatus(..))
import FinVM.Process.Scheduler (initialScheduler)
import FinVM.StateMachine.Transition (StateMachine, StateTarget(..))
import FinVM.Type (VMType(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, fail)

spec :: Spec Unit
spec = do
  describe "FinVM.StateMachine Engine" do
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
      
      sm :: StateMachine
      sm =
        { id: "draft_workflow"
        , states: Map.fromFoldable [ Tuple "Draft" "Initial", Tuple "Submitted" "Waiting" ]
        , initialState: "Draft"
        , transitions: 
            [ { name: "submit", from: ["Draft"], event: "SUBMIT", guard: Nothing, action: "noop", to: StaticState "Submitted", priority: Nothing }
            ]
        , invariants: []
        }

      program :: Program
      program =
        { version: "1.0", constants: [], functions: Map.fromFoldable [ Tuple "noop" { id: "noop", arity: 0, registerCount: 1, parameterTypes: [], returnType: TUnit, instructions: [ RETURN 0 ], debug: { name: "noop" }, proof: { isInvariant: false } } ]
        , stateMachines: Map.fromFoldable [ Tuple "draft_workflow" sm ]
        , entrypoint: "noop", exports: Map.empty, metadata: { description: "" }, typeTable: Map.empty, capabilities: [], verification: { verified: true }
        }

      machine :: Machine
      machine =
        { program: program, scheduler: initialScheduler, state: Map.empty, input: Map.empty, config: { limits: limits, externalBuiltins: Map.empty, performanceMode: false }, trace: List.Nil, proofTrace: List.Nil, outbox: List.Nil, events: List.Nil, counters: { steps: 0 }, labelCache: Map.empty }

      process :: Process
      process =
        { pid: "p1", status: ProcessReady, function: "noop", frame: { function: "noop", pc: 0, registers: Array.replicate 10 VUnit, returnRegister: Nothing, caller: Nothing }
        , callStack: [], mailbox: [], links: mempty, remoteLinks: mempty, monitors: Map.empty, parent: Nothing, children: mempty, trapExit: false, metadata: { name: "p1" }, result: Nothing, error: Nothing, createdSequence: 0, stepsExecuted: 0 }

    it "creates and transitions a machine instance" do
      -- 1. Create instance: MACHINE_NEW dst machineId dataReg
      let regs = fromMaybe (Array.replicate 10 VUnit) (Array.updateAt 0 (VRecord Map.empty) (Array.replicate 10 VUnit))
          p_init = process { frame = { function: "noop", pc: 0, registers: regs, returnRegister: Nothing, caller: Nothing } }
          func = case Map.lookup "noop" program.functions of
            Just f -> f
            Nothing -> { id: "dummy", arity: 0, registerCount: 0, parameterTypes: [], returnType: TUnit, instructions: [], debug: { name: "" }, proof: { isInvariant: false } }
      case Interpreter.evalInstruction machine p_init func (MACHINE_NEW 1 "draft_workflow" 0) of
        Left err -> fail $ show err
        Right (Tuple m1 p1) -> do
          case Array.index p1.frame.registers 1 of
            Just (VStateMachineInstance mi) -> do
              mi.currentState `shouldEqual` "Draft"
              -- 2. Transition: MACHINE_TRANSITION dst machineReg event
              case Interpreter.evalInstruction m1 p1 func (MACHINE_TRANSITION 2 1 "SUBMIT") of
                Left err -> fail $ show err
                Right (Tuple _ p2) -> do
                  case Array.index p2.frame.registers 2 of
                    Just (VStateMachineInstance mi') -> mi'.currentState `shouldEqual` "Submitted"
                    _ -> fail "Expected StateMachineInstance after transition"
            _ -> fail "Expected StateMachineInstance after NEW"

    it "runs transition guards, computed targets, actions, and history hashes" do
      let guardedSm =
            { id: "approval"
            , states: Map.fromFoldable [ Tuple "Draft" "Initial", Tuple "Approved" "Approved" ]
            , initialState: "Draft"
            , transitions:
                [ { name: "approve", from: ["Draft"], event: "APPROVE", guard: Just "guard", action: "action", to: ComputedState "target", priority: Just 1 }
                ]
            , invariants: []
            }
          guardedProgram = program
            { constants = [ VBool true, VString "Approved" ]
            , functions = Map.fromFoldable
                [ Tuple "noop" { id: "noop", arity: 0, registerCount: 1, parameterTypes: [], returnType: TUnit, instructions: [ RETURN 0 ], debug: { name: "noop" }, proof: { isInvariant: false } }
                , Tuple "guard" { id: "guard", arity: 1, registerCount: 1, parameterTypes: [TAny], returnType: TBool, instructions: [ LOAD_CONST 0 0, RETURN 0 ], debug: { name: "guard" }, proof: { isInvariant: false } }
                , Tuple "target" { id: "target", arity: 1, registerCount: 1, parameterTypes: [TAny], returnType: TString, instructions: [ LOAD_CONST 0 1, RETURN 0 ], debug: { name: "target" }, proof: { isInvariant: false } }
                , Tuple "action" { id: "action", arity: 1, registerCount: 2, parameterTypes: [TAny], returnType: TRecord [], instructions: [ RECORD_NEW 1, LOAD_CONST 0 0, RECORD_SET 1 1 "approved" 0, RETURN 1 ], debug: { name: "action" }, proof: { isInvariant: false } }
                ]
            , stateMachines = Map.singleton "approval" guardedSm
            }
          guardedMachine = machine { program = guardedProgram }
          regs = fromMaybe (Array.replicate 10 VUnit) (Array.updateAt 0 (VRecord Map.empty) (Array.replicate 10 VUnit))
          pInit = process { frame = { function: "noop", pc: 0, registers: regs, returnRegister: Nothing, caller: Nothing } }
          func = case Map.lookup "noop" guardedProgram.functions of
            Just f -> f
            Nothing -> { id: "dummy", arity: 0, registerCount: 0, parameterTypes: [], returnType: TUnit, instructions: [], debug: { name: "" }, proof: { isInvariant: false } }
      case Interpreter.evalInstruction guardedMachine pInit func (MACHINE_NEW 1 "approval" 0) of
        Left err -> fail $ show err
        Right (Tuple m1 p1) -> do
          case Interpreter.evalInstruction m1 p1 func (MACHINE_TRANSITION 2 1 "APPROVE") of
            Left err -> fail $ show err
            Right (Tuple _ p2) ->
              case Array.index p2.frame.registers 2 of
                Just (VStateMachineInstance mi') -> do
                  mi'.currentState `shouldEqual` "Approved"
                  Map.lookup "approved" mi'.data_ `shouldEqual` Just (VBool true)
                  (mi'.historyHash /= "") `shouldEqual` true
                _ -> fail "Expected StateMachineInstance after guarded transition"
