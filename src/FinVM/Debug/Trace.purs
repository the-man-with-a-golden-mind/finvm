module FinVM.Debug.Trace where

import Prelude
import Data.Maybe (Maybe)
import Data.List (List)
import FinVM.Value (Value, ProcessId, NodeRef, FunctionId)
import FinVM.Instruction (Register, Instruction)

data TraceMode
  = TraceOff
  | TraceErrors
  | TraceCalls
  | TraceProcesses
  | TraceState
  | TraceStateMachines
  | TraceRemote
  | TraceProof
  | TraceFull

derive instance eqTraceMode :: Eq TraceMode
derive instance ordTraceMode :: Ord TraceMode

data TraceEvent
  = InstructionExecuted Instruction
  | RegisterChanged Register Value
  | FunctionEntered FunctionId
  | FunctionReturned FunctionId
  | StateRead String Value
  | StateWritten String Value
  | EventEmitted Value
  | EffectRequested Value
  | ProcessCreated ProcessId
  | ProcessScheduled ProcessId
  | ProcessYielded ProcessId
  | ProcessWaiting ProcessId
  | ProcessResumed ProcessId
  | ProcessCompleted ProcessId Value
  | ProcessFailed ProcessId String
  | ProcessCancelled ProcessId String
  | MessageSent ProcessId Value
  | MessageReceived ProcessId Value
  | ProcessLinked ProcessId
  | ProcessMonitored ProcessId String
  | SupervisorStarted String
  | ChildRestarted ProcessId
  | RemoteNodeRegistered NodeRef
  | RemoteNodeStatusChanged NodeRef String
  | RemoteSendIntentCreated Value
  | RemoteMessageReceived Value
  | MachineTransitionStarted String
  | MachineTransitionSelected String
  | MachineGuardEvaluated String Boolean
  | MachineActionExecuted String
  | MachineInvariantChecked String Boolean
  | MachineTransitionCompleted String String
  | ProofMark String Value
  | ProofScopeStarted String
  | ProofScopeEnded String
  | ErrorRaised String

derive instance eqTraceEvent :: Eq TraceEvent
derive instance ordTraceEvent :: Ord TraceEvent

instance showTraceEvent :: Show TraceEvent where
  show = case _ of
    InstructionExecuted inst -> "InstructionExecuted " <> show inst
    RegisterChanged r v -> "RegisterChanged " <> show r <> " " <> show v
    FunctionEntered f -> "FunctionEntered " <> f
    FunctionReturned f -> "FunctionReturned " <> f
    StateRead p v -> "StateRead " <> p <> " " <> show v
    StateWritten p v -> "StateWritten " <> p <> " " <> show v
    EventEmitted v -> "EventEmitted " <> show v
    EffectRequested v -> "EffectRequested " <> show v
    ProcessCreated p -> "ProcessCreated " <> p
    ProcessScheduled p -> "ProcessScheduled " <> p
    ProcessYielded p -> "ProcessYielded " <> p
    ProcessWaiting p -> "ProcessWaiting " <> p
    ProcessResumed p -> "ProcessResumed " <> p
    ProcessCompleted p v -> "ProcessCompleted " <> p <> " " <> show v
    ProcessFailed p e -> "ProcessFailed " <> p <> " " <> e
    ProcessCancelled p r -> "ProcessCancelled " <> p <> " " <> r
    MessageSent p v -> "MessageSent " <> p <> " " <> show v
    MessageReceived p v -> "MessageReceived " <> p <> " " <> show v
    ProcessLinked p -> "ProcessLinked " <> p
    ProcessMonitored p r -> "ProcessMonitored " <> p <> " " <> r
    SupervisorStarted s -> "SupervisorStarted " <> s
    ChildRestarted p -> "ChildRestarted " <> p
    RemoteNodeRegistered n -> "RemoteNodeRegistered " <> show n
    RemoteNodeStatusChanged n s -> "RemoteNodeStatusChanged " <> show n <> " " <> s
    RemoteSendIntentCreated v -> "RemoteSendIntentCreated " <> show v
    RemoteMessageReceived v -> "RemoteMessageReceived " <> show v
    MachineTransitionStarted s -> "MachineTransitionStarted " <> s
    MachineTransitionSelected s -> "MachineTransitionSelected " <> s
    MachineGuardEvaluated s b -> "MachineGuardEvaluated " <> s <> " " <> show b
    MachineActionExecuted s -> "MachineActionExecuted " <> s
    MachineInvariantChecked s b -> "MachineInvariantChecked " <> s <> " " <> show b
    MachineTransitionCompleted s n -> "MachineTransitionCompleted " <> s <> " " <> n
    ProofMark l v -> "ProofMark " <> l <> " " <> show v
    ProofScopeStarted s -> "ProofScopeStarted " <> s
    ProofScopeEnded s -> "ProofScopeEnded " <> s
    ErrorRaised e -> "ErrorRaised " <> e


type Trace = List TraceEvent
