module Test.Monitor (spec) where

import Prelude
import Data.BigInt as BI
import Data.Map as Map
import Data.Set as Set
import Data.List as List
import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import FinVM.Eval as Eval
import FinVM.Value (Value(..))
import FinVM.Machine (Machine)
import FinVM.Process (Process, ProcessStatus(..), WaitCondition(..), MonitorTarget(..))
import FinVM.Process.Scheduler (initialScheduler, spawnProcess)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, fail)

limits =
  { maxSteps: 100, maxCallDepth: 10, maxProcesses: 10, maxProcessStepsPerSlice: 10
  , maxRegistersPerFrame: 10, maxFrames: 10, maxListLength: 10, maxMapSize: 10
  , maxRecordFields: 10, maxValueDepth: 10, maxStateEntries: 10, maxTraceEvents: 10
  , maxProofEvents: 10, maxMailboxSize: 10, maxRemoteNodes: 10, maxEventsEmitted: 10
  , maxEffectsRequested: 10
  }

mkProcess :: String -> ProcessStatus -> Map.Map String MonitorTarget -> Process
mkProcess pid status monitors =
  { pid
  , status
  , function: "main"
  , frame: { function: "main", pc: 0, registers: Array.replicate 4 VUnit, returnRegister: Nothing, caller: Nothing }
  , callStack: []
  , mailbox: []
  , links: Set.empty
  , monitors
  , parent: Nothing
  , children: Set.empty
  , trapExit: false
  , metadata: { name: pid }
  , result: Nothing
  , error: Nothing
  , createdSequence: 0
  , stepsExecuted: 0
  }

spec :: Spec Unit
spec = do
  describe "FinVM.Eval monitor cleanup" do
    let
      -- observer (p2) monitors target (p1) via ref "mon0:p1", and is blocked
      -- waiting for a message. p1 has completed.
      target = mkProcess "p1" (ProcessCompleted (VInt (BI.fromInt 7))) Map.empty
      observer = mkProcess "p2" (ProcessWaiting WaitingForMessage)
                   (Map.fromFoldable [ Tuple "mon0:p1" (MonitorLocal "p1") ])
      scheduler0 = spawnProcess (spawnProcess initialScheduler target) observer
      machine :: Machine
      machine =
        { program: { version: "1.0", constants: [], functions: Map.empty, stateMachines: Map.empty
                   , entrypoint: "main", exports: Map.empty, metadata: { description: "" }
                   , typeTable: Map.empty, capabilities: [], verification: { verified: true } }
        , scheduler: scheduler0
        , state: Map.empty, input: Map.empty
        , config: { limits, externalBuiltins: Map.empty, performanceMode: false }
        , trace: List.Nil, proofTrace: List.Nil, outbox: List.Nil, events: List.Nil
        , counters: { steps: 0 }, labelCache: Map.empty
        }
      result = Eval.notifyMonitorsOfDeath "p1" (ProcessCompleted (VInt (BI.fromInt 7))) machine

    it "delivers a DOWN message to a monitoring process when the target dies" do
      case Map.lookup "p2" result.scheduler.processes of
        Nothing -> fail "observer process missing"
        Just obs ->
          case Array.head obs.mailbox of
            Just (VVariant "DOWN" (VRecord fields)) -> do
              Map.lookup "pid" fields `shouldEqual` Just (VString "p1")
              Map.lookup "reason" fields `shouldEqual` Just (VString "normal")
              Map.lookup "ref" fields `shouldEqual` Just (VString "mon0:p1")
            _ -> fail "expected a DOWN message in the observer mailbox"

    it "removes the stale monitor entry after notifying" do
      case Map.lookup "p2" result.scheduler.processes of
        Nothing -> fail "observer process missing"
        Just obs -> Map.isEmpty obs.monitors `shouldEqual` true

    it "wakes a monitor that was waiting for a message" do
      case Map.lookup "p2" result.scheduler.processes of
        Nothing -> fail "observer process missing"
        Just obs -> obs.status `shouldEqual` ProcessReady

    it "is a no-op for a non-terminal status" do
      let noop = Eval.notifyMonitorsOfDeath "p1" ProcessRunning machine
      case Map.lookup "p2" noop.scheduler.processes of
        Nothing -> fail "observer process missing"
        Just obs -> Map.size obs.monitors `shouldEqual` 1
