-- | Round-trippable codec for a Machine's EXECUTION STATE, so a run can be
-- | suspended and later resumed (not re-run from scratch). The program/config
-- | are NOT serialized (constant; re-supplied via a base Machine on decode);
-- | only the scheduler (processes, frames, registers, mailboxes, statuses,
-- | ready queue, nextPid, tick), global state, input, and counters are.
-- |
-- | This needs a FULL Value codec — unlike Encoding.Json.decodeValue (which only
-- | covers the data subset), actor registers/mailboxes routinely hold runtime
-- | values (VProcessRef, VOption, VResult, …). encVal/decVal here are mutually
-- | inverse over every Value variant, with unambiguous internal tags (the
-- | snapshot is internal, not the public program format).
module FinVM.Encoding.Resume
  ( encodeMachineState
  , decodeMachineState
  ) where

import Prelude
import Data.Argonaut.Core as J
import Data.Array as Array
import Data.BigInt as BI
import Data.Either (Either(..))
import Data.Int as Int
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Set as Set
import Data.String (Pattern(..), stripPrefix)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Foreign.Object as Object
import FinVM.Error as E
import FinVM.Frame (FrameRef(..), Frame)
import FinVM.Machine (Machine)
import FinVM.Process (Process, ProcessStatus(..), WaitCondition(..), CancelReason(..), ExitReason(..), MonitorTarget(..))
import FinVM.Value (Value(..), NodeRef(..), RemoteProcessRef)
import FinVM.Vec as Vec

-- ---- small helpers ------------------------------------------------------
obj :: Array (Tuple String J.Json) -> J.Json
obj = J.fromObject <<< Object.fromFoldable

jint :: Int -> J.Json
jint = J.fromNumber <<< Int.toNumber

field :: String -> Object.Object J.Json -> Either String J.Json
field k o = case Object.lookup k o of
  Just v -> Right v
  Nothing -> Left ("missing field: " <> k)

asObj :: J.Json -> Either String (Object.Object J.Json)
asObj j = case J.toObject j of
  Just o -> Right o
  Nothing -> Left "expected object"

asStr :: J.Json -> Either String String
asStr j = case J.toString j of
  Just s -> Right s
  Nothing -> Left "expected string"

asInt :: J.Json -> Either String Int
asInt j = case J.toNumber j >>= Int.fromNumber of
  Just i -> Right i
  Nothing -> Left "expected int"

asBool :: J.Json -> Either String Boolean
asBool j = case J.toBoolean j of
  Just b -> Right b
  Nothing -> Left "expected bool"

asArr :: J.Json -> Either String (Array J.Json)
asArr j = case J.toArray j of
  Just a -> Right a
  Nothing -> Left "expected array"

strField :: String -> Object.Object J.Json -> Either String String
strField k o = field k o >>= asStr

intField :: String -> Object.Object J.Json -> Either String Int
intField k o = field k o >>= asInt

bigField :: String -> Object.Object J.Json -> Either String BI.BigInt
bigField k o = do
  s <- strField k o
  case BI.fromString s of
    Just n -> Right n
    Nothing -> Left ("bad bigint: " <> s)

-- ---- Value (full, lossless) --------------------------------------------
encVal :: Value -> J.Json
encVal = case _ of
  VUnit -> J.jsonNull
  VBool b -> obj [ Tuple "bool" (J.fromBoolean b) ]
  VInt i -> obj [ Tuple "int" (J.fromString (BI.toString i)) ]
  VFixed f -> obj [ Tuple "fixed" (obj [ Tuple "value" (J.fromString (BI.toString f.value)), Tuple "scale" (jint f.scale) ]) ]
  VRational r -> obj [ Tuple "rational" (obj [ Tuple "num" (J.fromString (BI.toString r.numerator)), Tuple "den" (J.fromString (BI.toString r.denominator)) ]) ]
  VString s -> obj [ Tuple "string" (J.fromString s) ]
  VSymbol s -> obj [ Tuple "symbol" (J.fromString s) ]
  VBytes bs -> obj [ Tuple "bytes" (J.fromArray (jint <$> bs)) ]
  VList vec -> obj [ Tuple "list" (J.fromArray (encVal <$> Vec.toArray vec)) ]
  VMap mp -> obj [ Tuple "vmap" (J.fromArray (encPair <$> (Map.toUnfoldable mp :: Array (Tuple Value Value)))) ]
  VRecord mp -> obj [ Tuple "record" (J.fromArray (encSPair <$> (Map.toUnfoldable mp :: Array (Tuple String Value)))) ]
  VVariant t p -> obj [ Tuple "variant" (obj [ Tuple "tag" (J.fromString t), Tuple "payload" (encVal p) ]) ]
  VOption Nothing -> obj [ Tuple "none" (J.fromBoolean true) ]
  VOption (Just v) -> obj [ Tuple "some" (encVal v) ]
  VResult (Left v) -> obj [ Tuple "err" (encVal v) ]
  VResult (Right v) -> obj [ Tuple "ok" (encVal v) ]
  VFunctionRef id -> obj [ Tuple "fn" (J.fromString id) ]
  VProcessRef pid -> obj [ Tuple "proc" (J.fromString pid) ]
  VRemoteProcessRef r -> obj [ Tuple "rproc" (obj [ Tuple "node" (J.fromString (nodeStr r.node)), Tuple "pid" (J.fromString r.pid) ]) ]
  VStateMachineInstance mi -> obj [ Tuple "sm" (obj
    [ Tuple "machineId" (J.fromString mi.machineId)
    , Tuple "instanceId" (J.fromString mi.instanceId)
    , Tuple "currentState" (J.fromString mi.currentState)
    , Tuple "version" (jint mi.version)
    , Tuple "historyHash" (J.fromString mi.historyHash)
    , Tuple "data" (J.fromArray (encSPair <$> (Map.toUnfoldable mi.data_ :: Array (Tuple String Value))))
    ]) ]
  VEvent e -> obj [ Tuple "event" (obj [ Tuple "type" (J.fromString e.type_), Tuple "payload" (encVal e.payload) ]) ]
  VEffectIntent e -> obj [ Tuple "effect" (obj [ Tuple "type" (J.fromString e.type_), Tuple "payload" (encVal e.payload) ]) ]
  VProofValue p -> obj [ Tuple "proof" (obj [ Tuple "label" (J.fromString p.label), Tuple "value" (encVal p.value) ]) ]
  where
    nodeStr (NodeRef n) = n
    encPair (Tuple k v) = obj [ Tuple "k" (encVal k), Tuple "v" (encVal v) ]
    encSPair (Tuple k v) = obj [ Tuple "k" (J.fromString k), Tuple "v" (encVal v) ]

-- {k:Value,v:Value} | {k:String,v:Value} | {k:String,v:String}
decVPair :: J.Json -> Either String (Tuple Value Value)
decVPair x = do
  p <- asObj x
  k <- field "k" p >>= decVal
  v <- field "v" p >>= decVal
  pure (Tuple k v)

decSV :: J.Json -> Either String (Tuple String Value)
decSV x = do
  p <- asObj x
  k <- strField "k" p
  v <- field "v" p >>= decVal
  pure (Tuple k v)

encMonitorTarget :: MonitorTarget -> J.Json
encMonitorTarget = case _ of
  MonitorLocal pid -> obj [ Tuple "k" (J.fromString "local"), Tuple "pid" (J.fromString pid) ]
  MonitorRemote r -> obj
    [ Tuple "k" (J.fromString "remote")
    , Tuple "node" (J.fromString r.node)
    , Tuple "pid" (J.fromString r.pid)
    ]

decMonitorTarget :: J.Json -> Either String MonitorTarget
decMonitorTarget j = do
  o <- asObj j
  -- Backward-compat: older snapshots encoded monitor target as plain string pid.
  case Object.lookup "k" o of
    Nothing -> MonitorLocal <$> strField "v" o
    Just kjson -> do
      k <- asStr kjson
      case k of
        "local" -> MonitorLocal <$> strField "pid" o
        "remote" -> do
          node <- strField "node" o
          pid <- strField "pid" o
          pure (MonitorRemote { node, pid })
        _ -> Left ("unknown monitor target kind: " <> k)

encRemoteLink :: RemoteProcessRef -> J.Json
encRemoteLink r = obj
  [ Tuple "node" (J.fromString (case r.node of NodeRef n -> n))
  , Tuple "pid" (J.fromString r.pid)
  ]

decRemoteLink :: J.Json -> Either String RemoteProcessRef
decRemoteLink j = do
  o <- asObj j
  node <- strField "node" o
  pid <- strField "pid" o
  pure { node: NodeRef node, pid }

decFixedV :: Object.Object J.Json -> Either String Value
decFixedV o = do
  v <- bigField "value" o
  s <- intField "scale" o
  pure (VFixed { value: v, scale: s })

decRationalV :: Object.Object J.Json -> Either String Value
decRationalV o = do
  n <- bigField "num" o
  d <- bigField "den" o
  pure (VRational { numerator: n, denominator: d })

decVariantV :: Object.Object J.Json -> Either String Value
decVariantV o = do
  t <- strField "tag" o
  p <- field "payload" o >>= decVal
  pure (VVariant t p)

decRprocV :: Object.Object J.Json -> Either String Value
decRprocV o = do
  n <- strField "node" o
  pid <- strField "pid" o
  pure (VRemoteProcessRef { node: NodeRef n, pid })

decTaggedV :: (String -> Value -> Value) -> Object.Object J.Json -> Either String Value
decTaggedV mk o = do
  t <- strField "type" o
  p <- field "payload" o >>= decVal
  pure (mk t p)

decSmV :: Object.Object J.Json -> Either String Value
decSmV o = do
  d <- field "data" o >>= asArr >>= traverse decSV
  mid <- strField "machineId" o
  iid <- strField "instanceId" o
  cs <- strField "currentState" o
  ver <- intField "version" o
  hh <- strField "historyHash" o
  pure (VStateMachineInstance { machineId: mid, instanceId: iid, currentState: cs, data_: Map.fromFoldable d, version: ver, historyHash: hh })

decVal :: J.Json -> Either String Value
decVal j =
  if J.isNull j then Right VUnit
  else do
    o <- asObj j
    let has k = Object.member k o
    if has "bool" then VBool <$> (field "bool" o >>= asBool)
    else if has "int" then VInt <$> bigField "int" o
    else if has "fixed" then field "fixed" o >>= asObj >>= decFixedV
    else if has "rational" then field "rational" o >>= asObj >>= decRationalV
    else if has "string" then VString <$> strField "string" o
    else if has "symbol" then VSymbol <$> strField "symbol" o
    else if has "bytes" then VBytes <$> (field "bytes" o >>= asArr >>= traverse asInt)
    else if has "list" then (VList <<< Vec.fromArray) <$> (field "list" o >>= asArr >>= traverse decVal)
    else if has "vmap" then (VMap <<< Map.fromFoldable) <$> (field "vmap" o >>= asArr >>= traverse decVPair)
    else if has "record" then (VRecord <<< Map.fromFoldable) <$> (field "record" o >>= asArr >>= traverse decSV)
    else if has "variant" then field "variant" o >>= asObj >>= decVariantV
    else if has "none" then Right (VOption Nothing)
    else if has "some" then (VOption <<< Just) <$> (field "some" o >>= decVal)
    else if has "err" then (VResult <<< Left) <$> (field "err" o >>= decVal)
    else if has "ok" then (VResult <<< Right) <$> (field "ok" o >>= decVal)
    else if has "fn" then VFunctionRef <$> strField "fn" o
    else if has "proc" then VProcessRef <$> strField "proc" o
    else if has "rproc" then field "rproc" o >>= asObj >>= decRprocV
    else if has "sm" then field "sm" o >>= asObj >>= decSmV
    else if has "event" then field "event" o >>= asObj >>= decTaggedV (\t p -> VEvent { type_: t, payload: p })
    else if has "effect" then field "effect" o >>= asObj >>= decTaggedV (\t p -> VEffectIntent { type_: t, payload: p })
    else if has "proof" then do
      e <- field "proof" o >>= asObj
      l <- strField "label" e
      v <- field "value" e >>= decVal
      pure (VProofValue { label: l, value: v })
    else Left "unknown Value tag in snapshot"

-- ---- WaitCondition / ProcessStatus / VMError ----------------------------
encWait :: WaitCondition -> J.Json
encWait = case _ of
  WaitingForMessage -> obj [ Tuple "w" (J.fromString "message") ]
  WaitingOnMatch tag -> obj [ Tuple "w" (J.fromString "match"), Tuple "tag" (J.fromString tag) ]
  WaitingForProcess pid -> obj [ Tuple "w" (J.fromString "process"), Tuple "pid" (J.fromString pid) ]
  WaitingForMonitor ref -> obj [ Tuple "w" (J.fromString "monitor"), Tuple "ref" (J.fromString ref) ]
  WaitingForTick t -> obj [ Tuple "w" (J.fromString "tick"), Tuple "tick" (jint t) ]
  WaitingForRemoteNode (NodeRef n) -> obj [ Tuple "w" (J.fromString "rnode"), Tuple "node" (J.fromString n) ]
  WaitingForRemoteProcess r -> obj [ Tuple "w" (J.fromString "rproc"), Tuple "node" (J.fromString (case r.node of NodeRef n -> n)), Tuple "pid" (J.fromString r.pid) ]
  WaitingOnEffect key -> obj [ Tuple "w" (J.fromString "effect"), Tuple "key" (J.fromString key) ]

decWait :: Object.Object J.Json -> Either String WaitCondition
decWait o = do
  w <- strField "w" o
  case w of
    "message" -> Right WaitingForMessage
    "match" -> WaitingOnMatch <$> strField "tag" o
    "process" -> WaitingForProcess <$> strField "pid" o
    "monitor" -> WaitingForMonitor <$> strField "ref" o
    "tick" -> WaitingForTick <$> intField "tick" o
    "rnode" -> (WaitingForRemoteNode <<< NodeRef) <$> strField "node" o
    "rproc" -> do
      n <- strField "node" o
      pid <- strField "pid" o
      pure (WaitingForRemoteProcess { node: NodeRef n, pid })
    "effect" -> WaitingOnEffect <$> strField "key" o
    _ -> Left ("unknown wait condition: " <> w)

encStatus :: ProcessStatus -> J.Json
encStatus = case _ of
  ProcessReady -> obj [ Tuple "s" (J.fromString "ready") ]
  ProcessRunning -> obj [ Tuple "s" (J.fromString "running") ]
  ProcessWaiting c -> obj [ Tuple "s" (J.fromString "waiting"), Tuple "cond" (encWait c) ]
  ProcessCompleted v -> obj [ Tuple "s" (J.fromString "completed"), Tuple "value" (encVal v) ]
  ProcessFailed e -> obj [ Tuple "s" (J.fromString "failed"), Tuple "error" (encErr e) ]
  ProcessCancelled (CancelReason r) -> obj [ Tuple "s" (J.fromString "cancelled"), Tuple "reason" (J.fromString r) ]
  ProcessExited (ExitReason r) -> obj [ Tuple "s" (J.fromString "exited"), Tuple "reason" (J.fromString r) ]

decStatus :: J.Json -> Either String ProcessStatus
decStatus j = do
  o <- asObj j
  s <- strField "s" o
  case s of
    "ready" -> Right ProcessReady
    "running" -> Right ProcessRunning
    "waiting" -> (ProcessWaiting) <$> (field "cond" o >>= asObj >>= decWait)
    "completed" -> ProcessCompleted <$> (field "value" o >>= decVal)
    "failed" -> ProcessFailed <$> (field "error" o >>= decErr)
    "cancelled" -> (ProcessCancelled <<< CancelReason) <$> strField "reason" o
    "exited" -> (ProcessExited <<< ExitReason) <$> strField "reason" o
    _ -> Left ("unknown status: " <> s)

encErr :: E.VMError -> J.Json
encErr (E.VMError code msg) = obj [ Tuple "code" (J.fromString (show code)), Tuple "msg" (J.fromString msg) ]

decErr :: J.Json -> Either String E.VMError
decErr j = do
  o <- asObj j
  code <- strField "code" o
  msg <- strField "msg" o
  pure (E.VMError (errorCodeFromString code) msg)

errorCodeFromString :: String -> E.ErrorCode
errorCodeFromString s = case s of
  "InvalidProgram" -> E.InvalidProgram
  "InvalidInstruction" -> E.InvalidInstruction
  "InvalidRegister" -> E.InvalidRegister
  "InvalidJump" -> E.InvalidJump
  "UnknownFunction" -> E.UnknownFunction
  "UnknownBuiltin" -> E.UnknownBuiltin
  "ArityMismatch" -> E.ArityMismatch
  "TypeMismatch" -> E.TypeMismatch
  "DivisionByZero" -> E.DivisionByZero
  "ArithmeticOverflow" -> E.ArithmeticOverflow
  "ArithmeticError" -> E.ArithmeticError
  "NoModularInverse" -> E.NoModularInverse
  "InvalidRoundingMode" -> E.InvalidRoundingMode
  "MissingInput" -> E.MissingInput
  "MissingContext" -> E.MissingContext
  "MissingState" -> E.MissingState
  "StatePathInvalid" -> E.StatePathInvalid
  "ProcessNotFound" -> E.ProcessNotFound
  "ProcessDeadlock" -> E.ProcessDeadlock
  "ProcessCancelled" -> E.ProcessCancelled
  "MailboxTooLarge" -> E.MailboxTooLarge
  "RemoteNodeUnknown" -> E.RemoteNodeUnknown
  "RemoteProcessUnknown" -> E.RemoteProcessUnknown
  "AmbiguousTransition" -> E.AmbiguousTransition
  "NoTransition" -> E.NoTransition
  "GuardRejected" -> E.GuardRejected
  "InvariantFailed" -> E.InvariantFailed
  "ProofAssertionFailed" -> E.ProofAssertionFailed
  "StepLimitExceeded" -> E.StepLimitExceeded
  "TraceLimitExceeded" -> E.TraceLimitExceeded
  "UnsupportedVersion" -> E.UnsupportedVersion
  _ -> case stripPrefix (Pattern "CustomErrorCode ") s >>= Int.fromString of
    Just n -> E.CustomErrorCode n
    Nothing -> E.CustomErrorCode 0

-- ---- Frame / Process / Scheduler ---------------------------------------
encFrame :: Frame -> J.Json
encFrame f = obj
  [ Tuple "function" (J.fromString f.function)
  , Tuple "pc" (jint f.pc)
  , Tuple "registers" (J.fromArray (encVal <$> f.registers))
  , Tuple "returnRegister" (maybeJ jint f.returnRegister)
  , Tuple "caller" (maybeJ (\(FrameRef n) -> jint n) f.caller)
  ]

decFrame :: J.Json -> Either String Frame
decFrame j = do
  o <- asObj j
  fn <- strField "function" o
  pc <- intField "pc" o
  regs <- field "registers" o >>= asArr >>= traverse decVal
  rr <- decMaybe asInt (Object.lookup "returnRegister" o)
  caller <- decMaybe (\x -> FrameRef <$> asInt x) (Object.lookup "caller" o)
  pure { function: fn, pc, registers: regs, returnRegister: rr, caller }

maybeJ :: forall a. (a -> J.Json) -> Maybe a -> J.Json
maybeJ f = case _ of
  Just a -> f a
  Nothing -> J.jsonNull

decMaybe :: forall a. (J.Json -> Either String a) -> Maybe J.Json -> Either String (Maybe a)
decMaybe f = case _ of
  Nothing -> Right Nothing
  Just j -> if J.isNull j then Right Nothing else Just <$> f j

encProc :: Process -> J.Json
encProc p = obj
  [ Tuple "pid" (J.fromString p.pid)
  , Tuple "status" (encStatus p.status)
  , Tuple "function" (J.fromString p.function)
  , Tuple "frame" (encFrame p.frame)
  , Tuple "callStack" (J.fromArray (encFrame <$> p.callStack))
  , Tuple "mailbox" (J.fromArray (encVal <$> p.mailbox))
  , Tuple "links" (J.fromArray (J.fromString <$> (Set.toUnfoldable p.links :: Array String)))
  , Tuple "remoteLinks" (J.fromArray (encRemoteLink <$> (Set.toUnfoldable p.remoteLinks :: Array RemoteProcessRef)))
  , Tuple "monitors" (J.fromArray ((\(Tuple k v) -> obj [ Tuple "k" (J.fromString k), Tuple "v" (encMonitorTarget v) ]) <$> (Map.toUnfoldable p.monitors :: Array (Tuple String MonitorTarget))))
  , Tuple "parent" (maybeJ J.fromString p.parent)
  , Tuple "children" (J.fromArray (J.fromString <$> (Set.toUnfoldable p.children :: Array String)))
  , Tuple "trapExit" (J.fromBoolean p.trapExit)
  , Tuple "name" (J.fromString p.metadata.name)
  , Tuple "result" (maybeJ encVal p.result)
  , Tuple "error" (maybeJ encErr p.error)
  , Tuple "createdSequence" (jint p.createdSequence)
  , Tuple "stepsExecuted" (jint p.stepsExecuted)
  ]

decProc :: J.Json -> Either String Process
decProc j = do
  o <- asObj j
  pid <- strField "pid" o
  status <- field "status" o >>= decStatus
  fn <- strField "function" o
  frame <- field "frame" o >>= decFrame
  callStack <- field "callStack" o >>= asArr >>= traverse decFrame
  mailbox <- field "mailbox" o >>= asArr >>= traverse decVal
  links <- field "links" o >>= asArr >>= traverse asStr
  remoteLinks <- case Object.lookup "remoteLinks" o of
    Just rl -> asArr rl >>= traverse decRemoteLink
    Nothing -> pure []
  monitors <- field "monitors" o >>= asArr >>= traverse decMonitorKV
  parent <- decMaybe asStr (Object.lookup "parent" o)
  children <- field "children" o >>= asArr >>= traverse asStr
  trapExit <- field "trapExit" o >>= asBool
  name <- strField "name" o
  result <- decMaybe decVal (Object.lookup "result" o)
  err <- decMaybe decErr (Object.lookup "error" o)
  cseq <- intField "createdSequence" o
  steps <- intField "stepsExecuted" o
  pure
    { pid, status, function: fn, frame, callStack, mailbox
    , links: Set.fromFoldable links
    , remoteLinks: Set.fromFoldable remoteLinks
    , monitors: Map.fromFoldable monitors
    , parent, children: Set.fromFoldable children
    , trapExit, metadata: { name }, result, error: err
    , createdSequence: cseq, stepsExecuted: steps
    }
  where
    decMonitorKV x = do
      p <- asObj x
      k <- strField "k" p
      -- Prefer structured monitor target in field `v`; older snapshots had `v` string.
      mv <- field "v" p
      v <- case J.toString mv of
        Just s -> pure (MonitorLocal s)
        Nothing -> decMonitorTarget mv
      pure (Tuple k v)

-- ---- top level ----------------------------------------------------------
encStringMap :: Map String Value -> J.Json
encStringMap m = J.fromArray ((\(Tuple k v) -> obj [ Tuple "k" (J.fromString k), Tuple "v" (encVal v) ]) <$> (Map.toUnfoldable m :: Array (Tuple String Value)))

decStringMap :: J.Json -> Either String (Map String Value)
decStringMap j = Map.fromFoldable <$> (asArr j >>= traverse decSV)

-- | Serialize a Machine's execution state (resumable; program/config excluded).
encodeMachineState :: Machine -> J.Json
encodeMachineState m = obj
  [ Tuple "v" (jint 1)
  , Tuple "processes" (J.fromArray (encProc <$> (Map.values m.scheduler.processes # Array.fromFoldable)))
  , Tuple "readyQueue" (J.fromArray (J.fromString <$> m.scheduler.readyQueue))
  , Tuple "current" (maybeJ J.fromString m.scheduler.current)
  , Tuple "nextPidSequence" (jint m.scheduler.nextPidSequence)
  , Tuple "logicalTick" (jint m.scheduler.logicalTick)
  , Tuple "state" (encStringMap m.state)
  , Tuple "input" (encStringMap m.input)
  , Tuple "steps" (jint m.counters.steps)
  ]

-- | Restore execution state onto a base Machine (which supplies program/config).
-- | Resets transient fields (trace/proofTrace/outbox/events); runMachine rebuilds
-- | the label cache.
decodeMachineState :: Machine -> J.Json -> Either String Machine
decodeMachineState base j = do
  o <- asObj j
  procsArr <- field "processes" o >>= asArr >>= traverse decProc
  readyQueue <- field "readyQueue" o >>= asArr >>= traverse asStr
  current <- decMaybe asStr (Object.lookup "current" o)
  nextPid <- intField "nextPidSequence" o
  tick <- intField "logicalTick" o
  state <- field "state" o >>= decStringMap
  input <- field "input" o >>= decStringMap
  steps <- intField "steps" o
  let processes = Map.fromFoldable ((\p -> Tuple p.pid p) <$> procsArr)
  pure base
    { scheduler = base.scheduler
        { processes = processes
        , readyQueue = readyQueue
        , current = current
        , nextPidSequence = nextPid
        , logicalTick = tick
        , scheduleTrace = []
        }
    , state = state
    , input = input
    , counters = base.counters { steps = steps }
    , trace = mempty
    , proofTrace = mempty
    , outbox = mempty
    , events = mempty
    }
