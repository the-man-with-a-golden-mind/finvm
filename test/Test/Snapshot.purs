module Test.Snapshot (spec) where

import Prelude
import Data.Argonaut.Core as J
import Data.BigInt as BI
import Data.Either (Either(..))
import Data.List as List
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Set as Set
import Data.Tuple (Tuple(..))
import FinVM.Encoding.Resume (encodeMachineState, decodeMachineState)
import FinVM.Frame (FrameRef(..))
import FinVM.Machine (Machine)
import FinVM.Process (Process, ProcessStatus(..), WaitCondition(..), MonitorTarget(..))
import FinVM.Process.Scheduler (initialScheduler, spawnProcess)
import FinVM.Value (Value(..))
import FinVM.Vec as Vec
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

limits =
  { maxSteps: 100, maxCallDepth: 10, maxProcesses: 10, maxProcessStepsPerSlice: 10
  , maxRegistersPerFrame: 10, maxFrames: 10, maxListLength: 10, maxMapSize: 10
  , maxRecordFields: 10, maxValueDepth: 10, maxStateEntries: 10, maxTraceEvents: 10
  , maxProofEvents: 10, maxMailboxSize: 10, maxRemoteNodes: 10, maxEventsEmitted: 10
  , maxEffectsRequested: 10
  }

mkProc :: String -> ProcessStatus -> Array Value -> Array Value -> Process
mkProc pid status regs mailbox =
  { pid
  , status
  , function: "main"
  , frame: { function: "main", pc: 3, registers: regs, returnRegister: Just 1, caller: Just (FrameRef 0) }
  , callStack: [ { function: "main", pc: 0, registers: [ VUnit ], returnRegister: Nothing, caller: Nothing } ]
  , mailbox
  , links: Set.fromFoldable [ "p9" ]
  , remoteLinks: Set.empty
  , monitors: Map.fromFoldable
      [ Tuple "mon0:p2" (MonitorLocal "p2")
      , Tuple "rmon0:p42" (MonitorRemote { node: "nodeA", pid: "p42" })
      ]
  , parent: Just "main"
  , children: Set.empty
  , trapExit: false
  , metadata: { name: pid }
  , result: Nothing
  , error: Nothing
  , createdSequence: 1
  , stepsExecuted: 7
  }

spec :: Spec Unit
spec = do
  describe "FinVM execution-state snapshot codec" do
    let
      -- Rich state: a process suspended on an effect, with a VProcessRef and
      -- nested values in registers/mailbox (exercises the full Value codec).
      waiting = mkProc "p0" (ProcessWaiting (WaitingOnEffect "px"))
        [ VProcessRef "main", VOption (Just (VInt (BI.fromInt 5))), VList (Vec.fromArray [ VString "a", VBool true ]) ]
        [ VVariant "msg" (VInt (BI.fromInt 1)) ]
      ready = mkProc "p1" ProcessReady
        [ VInt (BI.fromInt 42), VResult (Right (VString "ok")) ]
        [ VString "queued1", VString "queued2" ]
      scheduler0 = spawnProcess (spawnProcess initialScheduler waiting) ready
      machine :: Machine
      machine =
        { program: { version: "1.0", constants: [], functions: Map.empty, stateMachines: Map.empty
                   , entrypoint: "main", exports: Map.empty, metadata: { description: "" }
                   , typeTable: Map.empty, capabilities: [], verification: { verified: true } }
        , scheduler: scheduler0
        , state: Map.fromFoldable [ Tuple "counter" (VInt (BI.fromInt 3)), Tuple "name" (VString "bot") ]
        , input: Map.fromFoldable [ Tuple "px" (VString "delivered") ]
        , config: { limits, externalBuiltins: Map.empty, performanceMode: false }
        , trace: List.Nil, proofTrace: List.Nil, outbox: List.Nil, events: List.Nil
        , counters: { steps: 11 }, labelCache: Map.empty
        }

    it "round-trips the full execution state (encode -> decode -> encode is stable)" do
      let j1 = encodeMachineState machine
      case decodeMachineState machine j1 of
        Left err -> fail ("decode failed: " <> err)
        Right m2 -> J.stringify (encodeMachineState m2) `shouldEqual` J.stringify j1

    it "preserves mailboxes, statuses (WaitingOnEffect), and runtime register values" do
      let j1 = encodeMachineState machine
      case decodeMachineState machine j1 of
        Left err -> fail ("decode failed: " <> err)
        Right m2 -> do
          case Map.lookup "p0" m2.scheduler.processes of
            Nothing -> fail "p0 missing after resume"
            Just p -> do
              p.status `shouldEqual` ProcessWaiting (WaitingOnEffect "px")
              p.frame.registers `shouldEqual` [ VProcessRef "main", VOption (Just (VInt (BI.fromInt 5))), VList (Vec.fromArray [ VString "a", VBool true ]) ]
          case Map.lookup "p1" m2.scheduler.processes of
            Nothing -> fail "p1 missing after resume"
            Just p -> p.mailbox `shouldEqual` [ VString "queued1", VString "queued2" ]
          case Map.lookup "p0" m2.scheduler.processes of
            Nothing -> fail "p0 missing after resume"
            Just p -> Map.lookup "rmon0:p42" p.monitors `shouldEqual` Just (MonitorRemote { node: "nodeA", pid: "p42" })
          m2.scheduler.nextPidSequence `shouldEqual` machine.scheduler.nextPidSequence
          Map.lookup "counter" m2.state `shouldEqual` Just (VInt (BI.fromInt 3))
