module FinVM.Process where

import Prelude
import Data.Maybe (Maybe(..))
import Data.Set as Set
import Data.Map as Map
import FinVM.Value (Value, ProcessId, MonitorRef, FunctionId, NodeRef, RemoteProcessRef)
import FinVM.Frame (Frame)
import FinVM.Error (VMError)

data WaitCondition
  = WaitingForMessage
  | WaitingForProcess ProcessId
  | WaitingForMonitor MonitorRef
  | WaitingForTick Int
  | WaitingForRemoteNode NodeRef
  | WaitingForRemoteProcess RemoteProcessRef
  -- Suspended on an async host effect (correlation key). The host fulfils the
  -- effect and delivers the result to this process's mailbox, waking it.
  | WaitingOnEffect String

derive instance eqWaitCondition :: Eq WaitCondition
derive instance ordWaitCondition :: Ord WaitCondition

data CancelReason = CancelReason String
derive instance eqCancelReason :: Eq CancelReason
derive instance ordCancelReason :: Ord CancelReason

data ExitReason = ExitReason String
derive instance eqExitReason :: Eq ExitReason
derive instance ordExitReason :: Ord ExitReason

data ProcessStatus
  = ProcessReady
  | ProcessRunning
  | ProcessWaiting WaitCondition
  | ProcessCompleted Value
  | ProcessFailed VMError
  | ProcessCancelled CancelReason
  | ProcessExited ExitReason

derive instance eqProcessStatus :: Eq ProcessStatus
derive instance ordProcessStatus :: Ord ProcessStatus

data MonitorTarget
  = MonitorLocal ProcessId
  | MonitorRemote { node :: String, pid :: String }

derive instance eqMonitorTarget :: Eq MonitorTarget
derive instance ordMonitorTarget :: Ord MonitorTarget

instance showMonitorTarget :: Show MonitorTarget where
  show = case _ of
    MonitorLocal pid -> "(MonitorLocal " <> pid <> ")"
    MonitorRemote r -> "(MonitorRemote " <> r.node <> ":" <> r.pid <> ")"

instance showWaitCondition :: Show WaitCondition where
  show = case _ of
    WaitingForMessage -> "WaitingForMessage"
    WaitingForProcess pid -> "WaitingForProcess " <> pid
    WaitingForMonitor ref -> "WaitingForMonitor " <> ref
    WaitingForTick t -> "WaitingForTick " <> show t
    WaitingForRemoteNode ref -> "WaitingForRemoteNode " <> show ref
    WaitingForRemoteProcess ref -> "WaitingForRemoteProcess " <> ref.pid
    WaitingOnEffect key -> "WaitingOnEffect " <> key

instance showCancelReason :: Show CancelReason where
  show (CancelReason r) = "CancelReason " <> r

instance showExitReason :: Show ExitReason where
  show (ExitReason r) = "ExitReason " <> r

instance showProcessStatus :: Show ProcessStatus where
  show = case _ of
    ProcessReady -> "ProcessReady"
    ProcessRunning -> "ProcessRunning"
    ProcessWaiting cond -> "ProcessWaiting (" <> show cond <> ")"
    ProcessCompleted val -> "ProcessCompleted (" <> show val <> ")"
    ProcessFailed err -> "ProcessFailed (" <> show err <> ")"
    ProcessCancelled reason -> "ProcessCancelled (" <> show reason <> ")"
    ProcessExited reason -> "ProcessExited (" <> show reason <> ")"

type Message = Value
type ProcessMetadata = { name :: String }

type Process =
  { pid :: ProcessId
  , status :: ProcessStatus
  , function :: FunctionId
  , frame :: Frame
  , callStack :: Array Frame
  , mailbox :: Array Message
  , links :: Set.Set ProcessId
  , monitors :: Map.Map MonitorRef MonitorTarget
  , parent :: Maybe ProcessId
  , children :: Set.Set ProcessId
  , trapExit :: Boolean
  , metadata :: ProcessMetadata
  , result :: Maybe Value
  , error :: Maybe VMError
  , createdSequence :: Int
  , stepsExecuted :: Int
  }
