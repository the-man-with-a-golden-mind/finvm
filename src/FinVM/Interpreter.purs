module FinVM.Interpreter where

import Prelude
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Either (Either(..))
import Data.Map as Map
import Data.Array as Array
import Data.Set as Set
import Data.List as List
import Data.Tuple (Tuple(..))
import Data.Traversable (traverse)
import Data.String as String
import Data.Int as Int
import FinVM.Builtin as Builtin
import FinVM.Encoding.Canonical as Canonical
import FinVM.Encoding.Snapshot as Snapshot
import FinVM.Numeric.BigInt as BI
import FinVM.Numeric.Fixed as Fixed
import FinVM.Machine (Machine)
import FinVM.Program (Program)
import FinVM.Process (Process, ProcessStatus(..), WaitCondition(..), CancelReason(..), ExitReason(..))
import FinVM.Process as ProcessTypes
import FinVM.Process.Scheduler as Scheduler
import FinVM.StateMachine.Instance (MachineInstance)
import FinVM.StateMachine.Transition (StateTarget(..), TransitionDef)
import FinVM.Proof.ProofTrace as ProofTrace
import FinVM.Debug.Trace as DebugTrace
import FinVM.Function as VMFunction
import FinVM.Instruction (Instruction(..))
import FinVM.Value (Value(..), NodeRef(..))
import FinVM.Vec as Vec
import FinVM.Error (VMError(..), ErrorCode(..))
import FinVM.Error as VMErrorCode

remoteMonitorPrefix :: String
remoteMonitorPrefix = "__remote__:"

-- | Executes one instruction for a given process, updating the Machine and Process state.
stepProcess :: Machine -> Process -> Either VMError (Tuple Machine Process)
stepProcess m p = do
  if p.stepsExecuted >= m.config.limits.maxSteps
    then Left $ VMError StepLimitExceeded "Process exceeded global step limit"
    else pure unit

  -- Find current function
  func <- case Map.lookup p.frame.function m.program.functions of
    Nothing -> Left $ VMError UnknownFunction ("Function not found: " <> p.frame.function)
    Just f -> pure f

  -- Fetch current instruction
  inst <- case Array.index func.instructions p.frame.pc of
    Nothing -> Left $ VMError InvalidInstruction ("PC out of bounds in function " <> func.id)
    Just i -> pure i

  -- Pre-increment steps
  let
    p' = p { stepsExecuted = p.stepsExecuted + 1 }
    -- In performance mode, we skip allocating the trace array entirely.
    m_traced = 
      if m.config.performanceMode 
      then m { counters = m.counters { steps = m.counters.steps + 1 } }
      else m { counters = m.counters { steps = m.counters.steps + 1 }
             , trace = List.Cons (DebugTrace.InstructionExecuted inst) m.trace 
             }

  -- Execute instruction
  evalInstruction m_traced p' func inst

evalInstruction :: Machine -> Process -> VMFunction.Function -> Instruction -> Either VMError (Tuple Machine Process)
evalInstruction m p func inst =
  let
    pNextPc = p { frame = p.frame { pc = p.frame.pc + 1 } }
  in case inst of
  NOOP -> pure $ Tuple m pNextPc

  HALT r -> do
    val <- readReg p r
    pure $ Tuple m (p { status = ProcessCompleted val })

  ABORT code ->
    pure $ Tuple m (p { status = ProcessFailed (VMError (CustomErrorCode code) "Aborted") })

  LABEL _ -> pure $ Tuple m pNextPc

  JUMP label -> do
    pc <- findLabel m func label
    pure $ Tuple m (p { frame = p.frame { pc = pc } })

  JUMP_IF r label -> do
    val <- readReg p r
    case val of
      VBool b ->
        if b
          then do
            pc <- findLabel m func label
            pure $ Tuple m (p { frame = p.frame { pc = pc } })
          else pure $ Tuple m pNextPc
      _ -> Left $ VMError TypeMismatch "JUMP_IF requires a Boolean register"

  JUMP_IF_FALSE r label -> do
    val <- readReg p r
    case val of
      VBool b ->
        if not b
          then do
            pc <- findLabel m func label
            pure $ Tuple m (p { frame = p.frame { pc = pc } })
          else pure $ Tuple m pNextPc
      _ -> Left $ VMError TypeMismatch "JUMP_IF_FALSE requires a Boolean register"

  MOVE dst src -> do
    val <- readReg p src
    let p' = writeReg pNextPc dst val
    pure $ Tuple m p'

  CLEAR dst -> do
    -- Resetting register to VUnit
    let p' = writeReg pNextPc dst VUnit
    pure $ Tuple m p'

  LOAD_CONST dst cidx -> do
    val <- case Array.index m.program.constants cidx of
      Nothing -> Left $ VMError InvalidInstruction "Constant index out of bounds"
      Just v -> pure v
    let p' = writeReg pNextPc dst val
    pure $ Tuple m p'

  LOAD_INPUT dst path -> do
    case Map.lookup path m.input of
      Nothing -> Left $ VMError MissingInput ("Input path not found: " <> path)
      Just v -> pure $ Tuple m (writeReg pNextPc dst v)

  LOAD_CONTEXT dst path -> do
    case Map.lookup path m.input of
      Nothing -> Left $ VMError MissingContext ("Context path not found: " <> path)
      Just v -> pure $ Tuple m (writeReg pNextPc dst v)

  ADD dst a b -> do
    vA <- readReg p a
    vB <- readReg p b
    case vA, vB of
      VInt iA, VInt iB -> pure $ Tuple m (writeReg pNextPc dst (VInt (iA + iB)))
      VFixed fA, VFixed fB -> case Fixed.add fA fB of
        Left _ -> Left $ VMError ArithmeticOverflow "Fixed add failed"
        Right res -> pure $ Tuple m (writeReg pNextPc dst (VFixed res))
      _, _ -> Left $ VMError TypeMismatch "ADD requires numeric types"

  SUB dst a b -> do
    vA <- readReg p a
    vB <- readReg p b
    case vA, vB of
      VInt iA, VInt iB -> pure $ Tuple m (writeReg pNextPc dst (VInt (iA - iB)))
      VFixed fA, VFixed fB -> case Fixed.sub fA fB of
        Left _ -> Left $ VMError ArithmeticOverflow "Fixed sub failed"
        Right res -> pure $ Tuple m (writeReg pNextPc dst (VFixed res))
      _, _ -> Left $ VMError TypeMismatch "SUB requires numeric types"

  MUL dst a b -> do
    vA <- readReg p a
    vB <- readReg p b
    case vA, vB of
      VInt iA, VInt iB -> pure $ Tuple m (writeReg pNextPc dst (VInt (iA * iB)))
      VFixed fA, VFixed fB -> pure $ Tuple m (writeReg pNextPc dst (VFixed (Fixed.mul fA fB)))
      _, _ -> Left $ VMError TypeMismatch "MUL requires numeric types"

  MOD dst a b -> do
    vA <- readReg p a
    vB <- readReg p b
    case vA, vB of
      VInt iA, VInt iB ->
        if iB == BI.fromInt 0
          then Left $ VMError DivisionByZero "BigInt modulo by zero"
          else pure $ Tuple m (writeReg pNextPc dst (VInt (iA `BI.rem` iB)))
      _, _ -> Left $ VMError TypeMismatch "MOD requires integer registers"

  NEG dst src -> do
    val <- readReg p src
    case val of
      VInt i -> pure $ Tuple m (writeReg pNextPc dst (VInt (-i)))
      VFixed f -> pure $ Tuple m (writeReg pNextPc dst (VFixed (f { value = -f.value })))
      VRational r -> pure $ Tuple m (writeReg pNextPc dst (VRational (r { numerator = -r.numerator })))
      _ -> Left $ VMError TypeMismatch "NEG requires numeric type"

  ABS dst src -> do
    val <- readReg p src
    case val of
      VInt i -> pure $ Tuple m (writeReg pNextPc dst (VInt (if i < BI.fromInt 0 then -i else i)))
      VFixed f -> pure $ Tuple m (writeReg pNextPc dst (VFixed (f { value = if f.value < BI.fromInt 0 then -f.value else f.value })))
      VRational r -> pure $ Tuple m (writeReg pNextPc dst (VRational (r { numerator = if r.numerator < BI.fromInt 0 then -r.numerator else r.numerator })))
      _ -> Left $ VMError TypeMismatch "ABS requires numeric type"

  EQ dst a b -> do
    vA <- readReg p a
    vB <- readReg p b
    pure $ Tuple m (writeReg pNextPc dst (VBool (vA == vB)))

  NEQ dst a b -> do
    vA <- readReg p a
    vB <- readReg p b
    pure $ Tuple m (writeReg pNextPc dst (VBool (vA /= vB)))

  LT dst a b -> do
    vA <- readReg p a
    vB <- readReg p b
    pure $ Tuple m (writeReg pNextPc dst (VBool (vA < vB)))

  LTE dst a b -> do
    vA <- readReg p a
    vB <- readReg p b
    pure $ Tuple m (writeReg pNextPc dst (VBool (vA <= vB)))

  GT dst a b -> do
    vA <- readReg p a
    vB <- readReg p b
    pure $ Tuple m (writeReg pNextPc dst (VBool (vA > vB)))

  GTE dst a b -> do
    vA <- readReg p a
    vB <- readReg p b
    pure $ Tuple m (writeReg pNextPc dst (VBool (vA >= vB)))

  MIN dst a b -> do
    vA <- readReg p a
    vB <- readReg p b
    pure $ Tuple m (writeReg pNextPc dst (if vA <= vB then vA else vB))

  MAX dst a b -> do
    vA <- readReg p a
    vB <- readReg p b
    pure $ Tuple m (writeReg pNextPc dst (if vA >= vB then vA else vB))

  CLAMP dst valReg minReg maxReg -> do
    val <- readReg p valReg
    minVal <- readReg p minReg
    maxVal <- readReg p maxReg
    let clamped = if val < minVal then minVal else if val > maxVal then maxVal else val
    pure $ Tuple m (writeReg pNextPc dst clamped)

  COMPARE dst a b -> do
    vA <- readReg p a
    vB <- readReg p b
    let cmp = if vA < vB then BI.fromInt (-1) else if vA > vB then BI.fromInt 1 else BI.fromInt 0
    pure $ Tuple m (writeReg pNextPc dst (VInt cmp))

  RECORD_NEW dst -> pure $ Tuple m (writeReg pNextPc dst (VRecord Map.empty))

  RECORD_GET dst r field -> do
    vR <- readReg p r
    case vR of
      VRecord fields -> case Map.lookup field fields of
        Nothing -> Left $ VMError MissingState ("Field " <> field <> " not found in record")
        Just v -> pure $ Tuple m (writeReg pNextPc dst v)
      _ -> Left $ VMError TypeMismatch "RECORD_GET requires a Record"

  RECORD_GET_OPT dst r field -> do
    vR <- readReg p r
    case vR of
      VRecord fields -> pure $ Tuple m (writeReg pNextPc dst (VOption (Map.lookup field fields)))
      _ -> Left $ VMError TypeMismatch "RECORD_GET_OPT requires a Record"

  RECORD_SET dst r field valReg -> do
    vR <- readReg p r
    vV <- readReg p valReg
    case vR of
      VRecord fields -> 
        let newFields = Map.insert field vV fields
        in pure $ Tuple m (writeReg pNextPc dst (VRecord newFields))
      _ -> Left $ VMError TypeMismatch "RECORD_SET requires a Record"

  RECORD_HAS dst r field -> do
    vR <- readReg p r
    case vR of
      VRecord fields -> pure $ Tuple m (writeReg pNextPc dst (VBool (Map.member field fields)))
      _ -> Left $ VMError TypeMismatch "RECORD_HAS requires a Record"

  RECORD_REMOVE dst r field -> do
    vR <- readReg p r
    case vR of
      VRecord fields -> pure $ Tuple m (writeReg pNextPc dst (VRecord (Map.delete field fields)))
      _ -> Left $ VMError TypeMismatch "RECORD_REMOVE requires a Record"

  RECORD_KEYS dst r -> do
    vR <- readReg p r
    case vR of
      VRecord fields -> pure $ Tuple m (writeReg pNextPc dst (VList (Vec.fromArray (VString <$> (Set.toUnfoldable (Map.keys fields) :: Array String)))))
      _ -> Left $ VMError TypeMismatch "RECORD_KEYS requires a Record"

  LIST_NEW dst -> pure $ Tuple m (writeReg pNextPc dst (VList Vec.empty))

  LIST_FROM dst regs -> do
    vals <- traverse (readReg p) regs
    if Array.length vals > m.config.limits.maxListLength
      then Left $ VMError InvalidInstruction "LIST_FROM exceeded maxListLength"
      else pure $ Tuple m (writeReg pNextPc dst (VList (Vec.fromArray vals)))

  LIST_APPEND dst l valReg -> do
    vL <- readReg p l
    vV <- readReg p valReg
    case vL of
      VList elements -> pure $ Tuple m (writeReg pNextPc dst (VList (Vec.snoc elements vV)))
      _ -> Left $ VMError TypeMismatch "LIST_APPEND requires a List"

  LIST_GET dst l idxReg -> do
    vL <- readReg p l
    vIdx <- readReg p idxReg
    case vL, vIdx of
      VList elements, VInt idx -> do
        let i = BI.toInt idx
        case i of
          Nothing -> Left $ VMError InvalidInstruction "List index out of BigInt range"
          Just idxInt -> case Vec.index elements idxInt of
            Nothing -> Left $ VMError InvalidInstruction "List index out of bounds"
            Just v -> pure $ Tuple m (writeReg pNextPc dst v)
      _, _ -> Left $ VMError TypeMismatch "LIST_GET requires a List and an Integer index"

  LIST_SET dst l idxReg valReg -> do
    vL <- readReg p l
    vIdx <- readReg p idxReg
    vVal <- readReg p valReg
    case vL, vIdx of
      VList elements, VInt idx -> do
        idxInt <- bigintToInt "List index out of BigInt range" idx
        case Vec.updateAt idxInt vVal elements of
          Nothing -> Left $ VMError InvalidInstruction "List index out of bounds"
          Just elements' -> pure $ Tuple m (writeReg pNextPc dst (VList elements'))
      _, _ -> Left $ VMError TypeMismatch "LIST_SET requires a List and an Integer index"

  LIST_LENGTH dst l -> do
    vL <- readReg p l
    case vL of
      VList elements -> pure $ Tuple m (writeReg pNextPc dst (VInt (BI.fromInt (Vec.length elements))))
      _ -> Left $ VMError TypeMismatch "LIST_LENGTH requires a List"

  LIST_SLICE dst l startReg endReg -> do
    vL <- readReg p l
    vStart <- readReg p startReg
    vEnd <- readReg p endReg
    case vL, vStart, vEnd of
      VList elements, VInt start, VInt end -> do
        startInt <- bigintToInt "List slice start out of BigInt range" start
        endInt <- bigintToInt "List slice end out of BigInt range" end
        pure $ Tuple m (writeReg pNextPc dst (VList (Vec.fromArray (Array.slice startInt endInt (Vec.toArray elements)))))
      _, _, _ -> Left $ VMError TypeMismatch "LIST_SLICE requires a List and Integer bounds"

  MAP_NEW dst -> pure $ Tuple m (writeReg pNextPc dst (VMap Map.empty))

  MAP_SET dst mapReg keyReg valReg -> do
    vM <- readReg p mapReg
    vK <- readReg p keyReg
    vV <- readReg p valReg
    case vM of
      VMap entries -> 
        let newEntries = Map.insert vK vV entries
        in pure $ Tuple m (writeReg pNextPc dst (VMap newEntries))
      _ -> Left $ VMError TypeMismatch "MAP_SET requires a Map"

  MAP_GET dst mapReg keyReg -> do
    vM <- readReg p mapReg
    vK <- readReg p keyReg
    case vM of
      VMap entries -> case Map.lookup vK entries of
        Nothing -> Left $ VMError MissingState "Key not found in map"
        Just v -> pure $ Tuple m (writeReg pNextPc dst v)
      _ -> Left $ VMError TypeMismatch "MAP_GET requires a Map"

  MAP_GET_OPT dst mapReg keyReg -> do
    vM <- readReg p mapReg
    vK <- readReg p keyReg
    case vM of
      VMap entries -> pure $ Tuple m (writeReg pNextPc dst (VOption (Map.lookup vK entries)))
      _ -> Left $ VMError TypeMismatch "MAP_GET_OPT requires a Map"

  MAP_HAS dst mapReg keyReg -> do
    vM <- readReg p mapReg
    vK <- readReg p keyReg
    case vM of
      VMap entries -> pure $ Tuple m (writeReg pNextPc dst (VBool (Map.member vK entries)))
      _ -> Left $ VMError TypeMismatch "MAP_HAS requires a Map"

  MAP_REMOVE dst mapReg keyReg -> do
    vM <- readReg p mapReg
    vK <- readReg p keyReg
    case vM of
      VMap entries -> pure $ Tuple m (writeReg pNextPc dst (VMap (Map.delete vK entries)))
      _ -> Left $ VMError TypeMismatch "MAP_REMOVE requires a Map"

  MAP_KEYS dst mapReg -> do
    vM <- readReg p mapReg
    case vM of
      VMap entries -> pure $ Tuple m (writeReg pNextPc dst (VList (Vec.fromArray (Set.toUnfoldable (Map.keys entries) :: Array Value))))
      _ -> Left $ VMError TypeMismatch "MAP_KEYS requires a Map"

  MAP_VALUES dst mapReg -> do
    vM <- readReg p mapReg
    case vM of
      VMap entries -> pure $ Tuple m (writeReg pNextPc dst (VList (Vec.fromArray (List.toUnfoldable (Map.values entries)))))
      _ -> Left $ VMError TypeMismatch "MAP_VALUES requires a Map"

  MAP_SIZE dst mapReg -> do
    vM <- readReg p mapReg
    case vM of
      VMap entries -> pure $ Tuple m (writeReg pNextPc dst (VInt (BI.fromInt (Map.size entries))))
      _ -> Left $ VMError TypeMismatch "MAP_SIZE requires a Map"

  VARIANT_NEW dst tag payloadReg -> do
    payload <- readReg p payloadReg
    pure $ Tuple m (writeReg pNextPc dst (VVariant tag payload))

  VARIANT_TAG dst variantReg -> do
    val <- readReg p variantReg
    case val of
      VVariant tag _ -> pure $ Tuple m (writeReg pNextPc dst (VString tag))
      _ -> Left $ VMError TypeMismatch "VARIANT_TAG requires a Variant"

  VARIANT_PAYLOAD dst variantReg -> do
    val <- readReg p variantReg
    case val of
      VVariant _ payload -> pure $ Tuple m (writeReg pNextPc dst payload)
      _ -> Left $ VMError TypeMismatch "VARIANT_PAYLOAD requires a Variant"

  DIV dst rounding a b -> do
    vA <- readReg p a
    vB <- readReg p b
    case vA, vB of
      VInt iA, VInt iB -> 
        if iB == BI.fromInt 0 
          then Left $ VMError DivisionByZero "BigInt division by zero"
          else pure $ Tuple m (writeReg pNextPc dst (VInt (iA / iB))) -- rounding ignored for Int
      VFixed fA, VFixed fB -> case Fixed.div fA fB rounding of
        Left err -> Left $ VMError err "Fixed division failed"
        Right res -> pure $ Tuple m (writeReg pNextPc dst (VFixed res))
      _, _ -> Left $ VMError TypeMismatch "DIV requires numeric types"

  CALL dst targetId args -> do
    targetFunc <- case Map.lookup targetId m.program.functions of
      Nothing -> Left $ VMError UnknownFunction ("Unknown function: " <> targetId)
      Just f -> pure f
    _ <- if Array.length p.callStack >= m.config.limits.maxCallDepth || Array.length p.callStack >= m.config.limits.maxFrames
      then Left $ VMError StepLimitExceeded "CALL exceeded call frame limit"
      else pure unit
    _ <- if targetFunc.registerCount > m.config.limits.maxRegistersPerFrame
      then Left $ VMError InvalidRegister "CALL target exceeded maxRegistersPerFrame"
      else pure unit
    -- Read arguments
    argVals <- traverse (readReg p) args
    -- Build new registers for the new frame (pre-allocated)
    let 
        newRegs = Array.replicate targetFunc.registerCount VUnit
        -- Fill arguments into first N registers
        newRegs' = Array.foldl (\acc (Tuple i v) -> fromMaybe acc (Array.updateAt i v acc)) newRegs (Array.mapWithIndex Tuple argVals)
        newFrame = { function: targetId, pc: 0, registers: newRegs', returnRegister: Just dst, caller: Nothing } -- caller Ref simplified
    -- Push current frame to call stack (advancing caller PC first)
    let p' = pNextPc { frame = newFrame, callStack = Array.snoc pNextPc.callStack pNextPc.frame }
    pure $ Tuple m p'

  TAIL_CALL targetId args -> do
    targetFunc <- case Map.lookup targetId m.program.functions of
      Nothing -> Left $ VMError UnknownFunction ("Unknown function: " <> targetId)
      Just f -> pure f
    argVals <- traverse (readReg p) args
    let
      newRegs = Array.replicate targetFunc.registerCount VUnit
      newRegs' = Array.foldl (\acc (Tuple i v) -> fromMaybe acc (Array.updateAt i v acc)) newRegs (Array.mapWithIndex Tuple argVals)
      newFrame = { function: targetId, pc: 0, registers: newRegs', returnRegister: p.frame.returnRegister, caller: p.frame.caller }
    pure $ Tuple m (p { frame = newFrame })

  RETURN r -> do
    retVal <- readReg p r
    let retReg = p.frame.returnRegister
    -- Pop frame
    case Array.unsnoc p.callStack of
      Nothing -> 
        -- Process entry function returned, complete process
        pure $ Tuple m (p { status = ProcessCompleted retVal, result = Just retVal })
      Just { init, last: callerFrame } -> do
        -- Write return value to caller's return register
        let p' = p { frame = callerFrame, callStack = init }
        p'' <- case retReg of
          Nothing -> pure p'
          Just dstReg -> pure $ writeReg p' dstReg retVal
        pure $ Tuple m p''

  STATE_GET dst path -> do
    case Map.lookup path m.state of
      Nothing -> Left $ VMError MissingState ("State path not found: " <> path)
      Just v -> pure $ Tuple m (writeReg pNextPc dst v)

  STATE_GET_OPT dst path ->
    pure $ Tuple m (writeReg pNextPc dst (VOption (Map.lookup path m.state)))

  STATE_SET path src -> do
    val <- readReg p src
    _ <- if not (Map.member path m.state) && Map.size m.state >= m.config.limits.maxStateEntries
      then Left $ VMError StatePathInvalid "STATE_SET exceeded maxStateEntries"
      else pure unit
    let m' = m { state = Map.insert path val m.state }
    pure $ Tuple m' pNextPc

  STATE_DELETE path ->
    pure $ Tuple (m { state = Map.delete path m.state }) pNextPc

  STATE_EXISTS dst path ->
    pure $ Tuple m (writeReg pNextPc dst (VBool (Map.member path m.state)))

  STATE_KEYS dst _prefix ->
    pure $ Tuple m (writeReg pNextPc dst (VList (Vec.fromArray (VString <$> (Set.toUnfoldable (Map.keys m.state) :: Array String)))))

  STATE_SNAPSHOT dst ->
    pure $ Tuple m (writeReg pNextPc dst (VString (Snapshot.createSnapshot m)))

  EVENT_NEW dst type_ payloadReg -> do
    payload <- readReg p payloadReg
    pure $ Tuple m (writeReg pNextPc dst (VEvent { type_: type_, payload: payload }))

  EVENT_EMIT src -> do
    val <- readReg p src
    case val of
      VEvent e ->
        if List.length m.events >= m.config.limits.maxEventsEmitted
          then Left $ VMError TraceLimitExceeded "EVENT_EMIT exceeded maxEventsEmitted"
          else pure $ Tuple (m { events = List.Cons e m.events }) pNextPc
      _ -> Left $ VMError TypeMismatch "EVENT_EMIT requires an Event"

  EVENT_BATCH_NEW dst ->
    pure $ Tuple m (writeReg pNextPc dst (VList Vec.empty))

  EVENT_BATCH_APPEND dst batchReg eventReg -> do
    batch <- readReg p batchReg
    event <- readReg p eventReg
    case batch, event of
      VList events, VEvent _ ->
        if Vec.length events >= m.config.limits.maxEventsEmitted
          then Left $ VMError TraceLimitExceeded "EVENT_BATCH_APPEND exceeded maxEventsEmitted"
          else pure $ Tuple m (writeReg pNextPc dst (VList (Vec.snoc events event)))
      _, _ -> Left $ VMError TypeMismatch "EVENT_BATCH_APPEND requires a List and Event"

  EFFECT_NEW dst type_ payloadReg -> do
    payload <- readReg p payloadReg
    pure $ Tuple m (writeReg pNextPc dst (VEffectIntent { type_: type_, payload: payload }))

  EFFECT_REQUEST src -> do
    val <- readReg p src
    case val of
      VEffectIntent e ->
        if List.length m.outbox >= m.config.limits.maxEffectsRequested
          then Left $ VMError TraceLimitExceeded "EFFECT_REQUEST exceeded maxEffectsRequested"
          else pure $ Tuple (m { outbox = List.Cons e m.outbox }) pNextPc
      _ -> Left $ VMError TypeMismatch "EFFECT_REQUEST requires an EffectIntent"

  -- Async effect: suspend ONLY this process on the effect's correlation key and
  -- record the request (tagged with pid + key) in the outbox for the host driver.
  -- pc is advanced, so on resume (woken by the reply message) the process
  -- continues after the await and reads the reply via PROC_RECEIVE.
  EFFECT_AWAIT intentReg -> do
    v <- readReg p intentReg
    case v of
      VEffectIntent e -> case awaitKey e.payload of
        Nothing -> Left $ VMError TypeMismatch "EFFECT_AWAIT payload must be a record with a string 'key'"
        Just key ->
          if List.length m.outbox >= m.config.limits.maxEffectsRequested
            then Left $ VMError TraceLimitExceeded "EFFECT_AWAIT exceeded maxEffectsRequested"
            else
              let
                tagged =
                  { type_: e.type_
                  , payload: VRecord (Map.fromFoldable
                      [ Tuple "pid" (VString p.pid)
                      , Tuple "key" (VString key)
                      , Tuple "payload" e.payload
                      ])
                  }
                m' = m { outbox = List.Cons tagged m.outbox }
              in pure $ Tuple m' (pNextPc { status = ProcessWaiting (WaitingOnEffect key) })
      _ -> Left $ VMError TypeMismatch "EFFECT_AWAIT requires an EffectIntent"

  EFFECT_BATCH_NEW dst ->
    pure $ Tuple m (writeReg pNextPc dst (VList Vec.empty))

  EFFECT_BATCH_APPEND dst batchReg effectReg -> do
    batch <- readReg p batchReg
    effect <- readReg p effectReg
    case batch, effect of
      VList effects, VEffectIntent _ ->
        if Vec.length effects >= m.config.limits.maxEffectsRequested
          then Left $ VMError TraceLimitExceeded "EFFECT_BATCH_APPEND exceeded maxEffectsRequested"
          else pure $ Tuple m (writeReg pNextPc dst (VList (Vec.snoc effects effect)))
      _, _ -> Left $ VMError TypeMismatch "EFFECT_BATCH_APPEND requires a List and EffectIntent"

  PROC_SELF dst -> pure $ Tuple m (writeReg pNextPc dst (VProcessRef p.pid))

  PROC_STATUS dst pidReg -> do
    vPid <- readReg p pidReg
    case vPid of
      VProcessRef pid -> case Scheduler.findProcess m.scheduler pid of
        Nothing -> Left $ VMError ProcessNotFound ("Process " <> pid <> " not found")
        Just targetP -> pure $ Tuple m (writeReg pNextPc dst (VString (show targetP.status)))
      _ -> Left $ VMError TypeMismatch "PROC_STATUS requires a ProcessRef"

  PROC_SPAWN dst targetId args -> do
    -- Create new process
    targetFunc <- case Map.lookup targetId m.program.functions of
      Nothing -> Left $ VMError UnknownFunction ("Unknown function: " <> targetId)
      Just f -> pure f
    _ <- if Map.size m.scheduler.processes >= m.config.limits.maxProcesses
      then Left $ VMError InvalidInstruction "PROC_SPAWN exceeded maxProcesses"
      else pure unit
    let (Tuple newPid s') = Scheduler.nextPid m.scheduler
    argVals <- traverse (readReg p) args
    let newRegs = Array.replicate targetFunc.registerCount VUnit
        newRegsFilled = Array.foldl (\acc (Tuple i v) -> fromMaybe acc (Array.updateAt i v acc)) newRegs (Array.mapWithIndex Tuple argVals)
        newProcess = 
          { pid: newPid
          , status: ProcessReady
          , function: targetId
          , frame: { function: targetId, pc: 0, registers: newRegsFilled, returnRegister: Nothing, caller: Nothing }
          , callStack: []
          , mailbox: []
          , links: Set.empty
          , monitors: Map.empty
          , parent: Just p.pid
          , children: Set.empty
          , trapExit: false
          , metadata: { name: newPid }
          , result: Nothing
          , error: Nothing
          , createdSequence: s'.nextPidSequence
          , stepsExecuted: 0
          }
        m' = m { scheduler = Scheduler.spawnProcess s' newProcess }
    pure $ Tuple m' (writeReg pNextPc dst (VProcessRef newPid))

  PROC_SEND pidReg msgReg -> do
    vPid <- readReg p pidReg
    vMsg <- readReg p msgReg
    case vPid of
      VProcessRef targetPid -> do
        case Scheduler.findProcess m.scheduler targetPid of
          Nothing -> Left $ VMError ProcessNotFound ("Process " <> targetPid <> " not found")
          Just targetP -> do
            _ <- if Array.length targetP.mailbox >= m.config.limits.maxMailboxSize
              then Left $ VMError MailboxTooLarge ("Process " <> targetPid <> " mailbox is full")
              else pure unit
            let m' = m { scheduler = Scheduler.deliverMessage m.scheduler targetPid vMsg }
            pure $ Tuple m' pNextPc
      _ -> Left $ VMError TypeMismatch "PROC_SEND requires a ProcessRef"

  PROC_RECEIVE dst -> do
    case Array.uncons p.mailbox of
      Nothing ->
        -- Block process at the SAME PC so it retries when woken up
        pure $ Tuple m (p { status = ProcessWaiting WaitingForMessage })
      Just { head, tail } -> 
        -- Advance PC only on success
        pure $ Tuple m (writeReg (pNextPc { mailbox = tail }) dst head)

  PROC_RECEIVE_OPT dst -> do
    case Array.uncons p.mailbox of
      Nothing -> pure $ Tuple m (writeReg pNextPc dst (VOption Nothing))
      Just { head, tail } -> pure $ Tuple m (writeReg (pNextPc { mailbox = tail }) dst (VOption (Just head)))

  PROC_YIELD -> pure $ Tuple m (pNextPc { status = ProcessReady })

  PROC_JOIN dst pidReg -> do
    vPid <- readReg p pidReg
    case vPid of
      VProcessRef targetPid -> case Scheduler.findProcess m.scheduler targetPid of
        Nothing -> Left $ VMError ProcessNotFound ("Process " <> targetPid <> " not found")
        Just targetP -> case processTerminalValue targetP of
          Just _ -> pure $ Tuple m (writeReg pNextPc dst (VBool true))
          Nothing -> pure $ Tuple m (p { status = ProcessWaiting (WaitingForProcess targetPid) })
      _ -> Left $ VMError TypeMismatch "PROC_JOIN requires a ProcessRef"

  PROC_JOIN_RESULT dst pidReg -> do
    vPid <- readReg p pidReg
    case vPid of
      VProcessRef targetPid -> case Scheduler.findProcess m.scheduler targetPid of
        Nothing -> Left $ VMError ProcessNotFound ("Process " <> targetPid <> " not found")
        Just targetP -> pure $ Tuple m (writeReg pNextPc dst (VOption (processTerminalValue targetP)))
      _ -> Left $ VMError TypeMismatch "PROC_JOIN_RESULT requires a ProcessRef"

  PROC_CANCEL dst pidReg -> do
    vPid <- readReg p pidReg
    case vPid of
      VProcessRef targetPid -> case Scheduler.findProcess m.scheduler targetPid of
        Nothing -> Left $ VMError ProcessNotFound ("Process " <> targetPid <> " not found")
        Just targetP ->
          let cancelled = targetP { status = ProcessTypes.ProcessCancelled (CancelReason "cancelled") }
              m' = m { scheduler = Scheduler.updateProcess m.scheduler cancelled }
          in pure $ Tuple m' (writeReg pNextPc dst (VBool true))
      _ -> Left $ VMError TypeMismatch "PROC_CANCEL requires a ProcessRef"

  PROC_EXIT reasonReg -> do
    reason <- readReg p reasonReg
    pure $ Tuple m (p { status = ProcessExited (ExitReason (show reason)) })

  PROC_LINK pidReg -> do
    vPid <- readReg p pidReg
    case vPid of
      VProcessRef targetPid -> case Scheduler.findProcess m.scheduler targetPid of
        Nothing -> Left $ VMError ProcessNotFound ("Process " <> targetPid <> " not found")
        Just targetP ->
          let
            p' = pNextPc { links = Set.insert targetPid p.links }
            targetP' = targetP { links = Set.insert p.pid targetP.links }
            m' = m { scheduler = Scheduler.updateProcess m.scheduler targetP' }
          in pure $ Tuple m' p'
      _ -> Left $ VMError TypeMismatch "PROC_LINK requires a ProcessRef"

  PROC_UNLINK pidReg -> do
    vPid <- readReg p pidReg
    case vPid of
      VProcessRef targetPid -> case Scheduler.findProcess m.scheduler targetPid of
        Nothing -> Left $ VMError ProcessNotFound ("Process " <> targetPid <> " not found")
        Just targetP ->
          let
            p' = pNextPc { links = Set.delete targetPid p.links }
            targetP' = targetP { links = Set.delete p.pid targetP.links }
            m' = m { scheduler = Scheduler.updateProcess m.scheduler targetP' }
          in pure $ Tuple m' p'
      _ -> Left $ VMError TypeMismatch "PROC_UNLINK requires a ProcessRef"

  PROC_MONITOR dst pidReg -> do
    vPid <- readReg p pidReg
    case vPid of
      VProcessRef targetPid -> case Scheduler.findProcess m.scheduler targetPid of
        Nothing -> Left $ VMError ProcessNotFound ("Process " <> targetPid <> " not found")
        Just _ ->
          let ref = "mon" <> show m.counters.steps <> ":" <> targetPid
          in pure $ Tuple m (writeReg (pNextPc { monitors = Map.insert ref targetPid p.monitors }) dst (VString ref))
      _ -> Left $ VMError TypeMismatch "PROC_MONITOR requires a ProcessRef"

  PROC_DEMONITOR refReg -> do
    ref <- readReg p refReg
    case ref of
      VString monitorRef -> pure $ Tuple m (pNextPc { monitors = Map.delete monitorRef p.monitors })
      _ -> Left $ VMError TypeMismatch "PROC_DEMONITOR requires a String monitor reference"

  PROC_TRAP_EXIT trap ->
    pure $ Tuple m (pNextPc { trapExit = trap })

  PROC_SLEEP_TICKS ticks ->
    if ticks <= 0
      then pure $ Tuple m pNextPc
      else pure $ Tuple m (pNextPc { status = ProcessWaiting (WaitingForTick (m.scheduler.logicalTick + ticks)) })

  NODE_SELF dst -> pure $ Tuple m (writeReg pNextPc dst (VString "local"))

  NODE_STATUS dst nodeReg -> do
    node <- readReg p nodeReg
    case node of
      VString n -> pure $ Tuple m (writeReg pNextPc dst (VString (if n == "local" then "online" else "unknown")))
      _ -> Left $ VMError TypeMismatch "NODE_STATUS requires a node String"

  NODE_KNOWN dst ->
    pure $ Tuple m (writeReg pNextPc dst (VList (Vec.fromArray [ VString "local" ])))

  REMOTE_PID_NEW dst nodeReg pidReg -> do
    vNode <- readReg p nodeReg
    vPid <- readReg p pidReg
    case vNode, vPid of
      VString n, VString pid -> 
        pure $ Tuple m (writeReg pNextPc dst (VRemoteProcessRef { node: NodeRef n, pid: pid }))
      _, _ -> Left $ VMError TypeMismatch "REMOTE_PID_NEW requires Strings for node and pid"

  REMOTE_PID_NODE dst remotePidReg -> do
    vPid <- readReg p remotePidReg
    case vPid of
      VRemoteProcessRef r -> case r.node of
        NodeRef n -> pure $ Tuple m (writeReg pNextPc dst (VString n))
      _ -> Left $ VMError TypeMismatch "REMOTE_PID_NODE requires a RemoteProcessRef"

  REMOTE_PID_LOCAL dst remotePidReg -> do
    vPid <- readReg p remotePidReg
    case vPid of
      VRemoteProcessRef r -> pure $ Tuple m (writeReg pNextPc dst (VString r.pid))
      _ -> Left $ VMError TypeMismatch "REMOTE_PID_LOCAL requires a RemoteProcessRef"

  NODE_SEND remotePidReg msgReg -> do
    vPid <- readReg p remotePidReg
    vMsg <- readReg p msgReg
    case vPid of
      VRemoteProcessRef r -> 
        let 
          intent = { type_: "RemoteSendIntent", payload: VRecord (Map.fromFoldable [ Tuple "node" (VString (case r.node of NodeRef n -> n)), Tuple "pid" (VString r.pid), Tuple "message" vMsg ]) }
          m' = m { outbox = List.Cons intent m.outbox }
        in pure $ Tuple m' pNextPc
      _ -> Left $ VMError TypeMismatch "NODE_SEND requires a RemoteProcessRef"

  NODE_SPAWN dst nodeReg targetId args -> do
    vNode <- readReg p nodeReg
    argVals <- traverse (readReg p) args
    case vNode of
      VString nodeName -> do
        _ <- case Map.lookup targetId m.program.functions of
          Nothing -> Left $ VMError UnknownFunction ("Unknown function: " <> targetId)
          Just f -> pure f
        let remotePid = "remote:" <> nodeName <> ":" <> targetId <> ":" <> show m.counters.steps
            intent = { type_: "RemoteSpawnIntent", payload: VRecord (Map.fromFoldable [ Tuple "node" (VString nodeName), Tuple "function" (VString targetId), Tuple "args" (VList (Vec.fromArray argVals)), Tuple "pid" (VString remotePid) ]) }
            m' = m { outbox = List.Cons intent m.outbox }
        pure $ Tuple m' (writeReg pNextPc dst (VRemoteProcessRef { node: NodeRef nodeName, pid: remotePid }))
      _ -> Left $ VMError TypeMismatch "NODE_SPAWN requires a node String"

  NODE_MONITOR dst remotePidReg -> do
    remotePid <- readReg p remotePidReg
    case remotePid of
      VRemoteProcessRef r ->
        let
          ref = "rmon" <> show m.counters.steps <> ":" <> r.pid
          node = case r.node of
            NodeRef n -> n
          target = encodeRemoteMonitorTarget node r.pid
          intent =
            { type_: "RemoteMonitorIntent"
            , payload: VRecord (Map.fromFoldable
                [ Tuple "pid" (VString p.pid)
                , Tuple "ref" (VString ref)
                , Tuple "node" (VString node)
                , Tuple "remotePid" (VString r.pid)
                ])
            }
          m' = m { outbox = List.Cons intent m.outbox }
          p' = pNextPc { monitors = Map.insert ref target p.monitors }
        in pure $ Tuple m' (writeReg p' dst (VString ref))
      _ -> Left $ VMError TypeMismatch "NODE_MONITOR requires a RemoteProcessRef"

  NODE_DEMONITOR refReg -> do
    ref <- readReg p refReg
    case ref of
      VString monitorRef ->
        let
          previousTarget = Map.lookup monitorRef p.monitors
          p' = pNextPc { monitors = Map.delete monitorRef p.monitors }
        in case previousTarget >>= decodeRemoteMonitorTarget of
          Just remote ->
            let
              intent =
                { type_: "RemoteDemonitorIntent"
                , payload: VRecord (Map.fromFoldable
                    [ Tuple "pid" (VString p.pid)
                    , Tuple "ref" (VString monitorRef)
                    , Tuple "node" (VString remote.node)
                    , Tuple "remotePid" (VString remote.pid)
                    ])
                }
              m' = m { outbox = List.Cons intent m.outbox }
            in pure $ Tuple m' p'
          Nothing -> pure $ Tuple m p'
      _ -> Left $ VMError TypeMismatch "NODE_DEMONITOR requires a String monitor reference"

  NODE_OBSERVE_STATE dst nodeReg -> do
    node <- readReg p nodeReg
    case node of
      VString nodeName -> pure $ Tuple m (writeReg pNextPc dst (VEffectIntent { type_: "NodeObserveStateIntent", payload: VString nodeName }))
      _ -> Left $ VMError TypeMismatch "NODE_OBSERVE_STATE requires a node String"

  NODE_LAST_STATE_HASH dst nodeReg -> do
    node <- readReg p nodeReg
    case node of
      VString "local" -> pure $ Tuple m (writeReg pNextPc dst (VString (Snapshot.createSnapshot m)))
      VString _ -> pure $ Tuple m (writeReg pNextPc dst (VOption Nothing))
      _ -> Left $ VMError TypeMismatch "NODE_LAST_STATE_HASH requires a node String"

  NODE_LAST_SEEN_TICK dst nodeReg -> do
    node <- readReg p nodeReg
    case node of
      VString "local" -> pure $ Tuple m (writeReg pNextPc dst (VInt (BI.fromInt m.scheduler.logicalTick)))
      VString _ -> pure $ Tuple m (writeReg pNextPc dst (VOption Nothing))
      _ -> Left $ VMError TypeMismatch "NODE_LAST_SEEN_TICK requires a node String"

  NODE_QUERY_STATE dst nodeReg -> do
    node <- readReg p nodeReg
    case node of
      VString nodeName -> pure $ Tuple m (writeReg pNextPc dst (VEffectIntent { type_: "NodeQueryStateIntent", payload: VString nodeName }))
      _ -> Left $ VMError TypeMismatch "NODE_QUERY_STATE requires a node String"

  MACHINE_NEW dst machineId dataReg -> do
    vData <- readReg p dataReg
    case vData of
      VRecord fields -> do
        sm <- case Map.lookup machineId m.program.stateMachines of
          Nothing -> Left $ VMError InvalidInstruction ("State machine " <> machineId <> " not found")
          Just s -> pure s
        let mi = 
              { machineId: machineId
              , instanceId: "mi" <> show m.counters.steps -- Simplified unique id
              , currentState: sm.initialState
              , data_: fields
              , version: 1
              , historyHash: ""
              }
        pure $ Tuple m (writeReg pNextPc dst (VStateMachineInstance mi))
      _ -> Left $ VMError TypeMismatch "MACHINE_NEW requires a Record for initial data"

  MACHINE_STATE dst machineReg -> do
    vMI <- readReg p machineReg
    case vMI of
      VStateMachineInstance mi -> pure $ Tuple m (writeReg pNextPc dst (VString mi.currentState))
      _ -> Left $ VMError TypeMismatch "MACHINE_STATE requires a StateMachineInstance"

  MACHINE_TRANSITION dst machineReg event -> do
    vMI <- readReg p machineReg
    case vMI of
      VStateMachineInstance mi -> do
        sm <- case Map.lookup mi.machineId m.program.stateMachines of
          Nothing -> Left $ VMError InvalidInstruction ("State machine " <> mi.machineId <> " not found")
          Just s -> pure s
        let matches = Array.filter (\t -> Array.elem mi.currentState t.from && t.event == event) sm.transitions
        t <- selectTransition mi.currentState event matches
        Tuple mAfterGuard guardOk <- case t.guard of
          Nothing -> pure $ Tuple m true
          Just guardFn -> do
            Tuple mGuard guardResult <- runFunctionValue m p.pid guardFn [VStateMachineInstance mi]
            case guardResult of
              VBool b -> pure $ Tuple mGuard b
              _ -> Left $ VMError TypeMismatch "State-machine guard must return Boolean"
        if not guardOk
          then Left $ VMError GuardRejected ("Guard rejected transition " <> t.name)
          else pure unit
        Tuple mAfterTarget nextState <- case t.to of
          StaticState state -> pure $ Tuple mAfterGuard state
          Stay -> pure $ Tuple mAfterGuard mi.currentState
          ComputedState fn -> do
            Tuple mComputed computed <- runFunctionValue mAfterGuard p.pid fn [VStateMachineInstance mi]
            case computed of
              VString state -> pure $ Tuple mComputed state
              _ -> Left $ VMError TypeMismatch "Computed state target must return String"
        let miTransitioned = mi
              { currentState = nextState
              , version = mi.version + 1
              , historyHash = Canonical.hashValue (VRecord (Map.fromFoldable
                  [ Tuple "machineId" (VString mi.machineId)
                  , Tuple "from" (VString mi.currentState)
                  , Tuple "event" (VString event)
                  , Tuple "to" (VString nextState)
                  , Tuple "version" (VInt (BI.fromInt (mi.version + 1)))
                  ]))
              }
        Tuple mAfterAction miFinal <- runTransitionAction mAfterTarget p.pid t.action miTransitioned
        pure $ Tuple mAfterAction (writeReg pNextPc dst (VStateMachineInstance miFinal))
      _ -> Left $ VMError TypeMismatch "MACHINE_TRANSITION requires a StateMachineInstance"

  CALL_BUILTIN dst builtinSpec args -> do
    -- builtinSpec format: "id@version"
    let parts = String.split (String.Pattern "@") builtinSpec
    case parts of
      [id, versionStr] -> do
        version <- case Int.fromString versionStr of
          Nothing -> Left $ VMError InvalidInstruction ("Invalid builtin version: " <> versionStr)
          Just v -> pure v
        argVals <- traverse (readReg p) args
        case runStatefulBuiltin m id version argVals of
          Just result -> do
            Tuple m' res <- result
            pure $ Tuple m' (writeReg pNextPc dst res)
          Nothing -> do
            builtinFn <- Builtin.lookupBuiltin m.config id version
            res <- builtinFn argVals
            pure $ Tuple m (writeReg pNextPc dst res)
      _ -> Left $ VMError InvalidInstruction ("Invalid builtin spec: " <> builtinSpec)

  ASSERT condReg errorCode -> do
    vCond <- readReg p condReg
    case vCond of
      VBool b ->
        let 
          m' = if m.config.performanceMode 
               then m
               else m { proofTrace = List.Cons (ProofTrace.ProofAssertion b errorCode) m.proofTrace }
        in if b
           then pure $ Tuple m' pNextPc
           else Left $ VMError ProofAssertionFailed ("Assertion failed with code " <> show errorCode)
      _ -> Left $ VMError TypeMismatch "ASSERT requires a Boolean register"

  INVARIANT_CHECK functionId -> do
    _ <- case Map.lookup functionId m.program.functions of
      Nothing -> Left $ VMError UnknownFunction ("Invariant function not found: " <> functionId)
      Just f -> pure f
    let m' = if m.config.performanceMode
             then m
             else m { proofTrace = List.Cons (ProofTrace.ProofInvariantChecked functionId true) m.proofTrace }
    pure $ Tuple m' pNextPc

  ASSUME condReg note -> do
    vCond <- readReg p condReg
    case vCond of
      VBool _ ->
        let 
          m' = if m.config.performanceMode 
               then m
               else m { proofTrace = List.Cons (ProofTrace.ProofAssumption note) m.proofTrace }
        in pure $ Tuple m' pNextPc
      _ -> Left $ VMError TypeMismatch "ASSUME requires a Boolean register"

  PROOF_MARK label valReg -> do
    val <- readReg p valReg
    let m' = if m.config.performanceMode 
             then m
             else m { proofTrace = List.Cons (ProofTrace.ProofValueMarked label val) m.proofTrace }
    pure $ Tuple m' pNextPc

  PROOF_SCOPE_BEGIN label -> do
    let m' = if m.config.performanceMode then m else m { proofTrace = List.Cons (ProofTrace.ProofScopeBegin label) m.proofTrace }
    pure $ Tuple m' pNextPc

  PROOF_SCOPE_END label -> do
    let m' = if m.config.performanceMode then m else m { proofTrace = List.Cons (ProofTrace.ProofScopeEnd label) m.proofTrace }
    pure $ Tuple m' pNextPc


-- Helper to read a register
readReg :: Process -> Int -> Either VMError Value
readReg p r = case Array.index p.frame.registers r of
  Nothing -> Left $ VMError InvalidRegister ("Register " <> show r <> " out of bounds")
  Just v -> pure v

-- The correlation key from an effect intent payload (a record with a string "key").
awaitKey :: Value -> Maybe String
awaitKey = case _ of
  VRecord fields -> case Map.lookup "key" fields of
    Just (VString k) -> Just k
    _ -> Nothing
  _ -> Nothing

encodeRemoteMonitorTarget :: String -> String -> String
encodeRemoteMonitorTarget node pid = remoteMonitorPrefix <> node <> ":" <> pid

decodeRemoteMonitorTarget :: String -> Maybe { node :: String, pid :: String }
decodeRemoteMonitorTarget target = do
  rest <- String.stripPrefix (String.Pattern remoteMonitorPrefix) target
  case String.lastIndexOf (String.Pattern ":") rest of
    Nothing -> Nothing
    Just idx ->
      let
        node = String.take idx rest
        pid = String.drop (idx + 1) rest
      in
        if node == "" || pid == "" then Nothing else Just { node, pid }

-- Helper to write a register.
-- The Nothing branch is unreachable for validated programs: Validate ensures
-- every destination register is in [0, registerCount) and registerCount >= arity,
-- and the frame is allocated with exactly registerCount registers. The fallback
-- preserves totality without crashing the pure VM core.
writeReg :: Process -> Int -> Value -> Process
writeReg p r v = case Array.updateAt r v p.frame.registers of
  Nothing -> p
  Just regs' -> p { frame = p.frame { registers = regs' } }

runStatefulBuiltin :: Machine -> String -> Int -> Array Value -> Maybe (Either VMError (Tuple Machine Value))
runStatefulBuiltin m id version args =
  if version /= 1 then Nothing
  else case id of
    "db.insert" -> Just (dbInsert m args)
    "db.get" -> Just (dbGet m args)
    "db.update" -> Just (dbUpdate m args)
    "db.delete" -> Just (dbDelete m args)
    "db.query" -> Just (dbQuery m args)
    "db.createIndex" -> Just (dbCreateIndex m args)
    "db.hash" -> Just (dbHash m args)
    "cache.set" -> Just (cacheSet m args)
    "cache.get" -> Just (cacheGet m args)
    "cache.delete" -> Just (cacheDelete m args)
    _ -> Nothing

dbStateKey :: String
dbStateKey = "__finvm.db"

cacheStateKey :: String
cacheStateKey = "__finvm.cache"

type DbTable =
  { nextId :: Int
  , rows :: Map.Map String Value
  , indexes :: Map.Map String Value
  }

emptyDbTable :: DbTable
emptyDbTable = { nextId: 0, rows: Map.empty, indexes: Map.empty }

dbInsert :: Machine -> Array Value -> Either VMError (Tuple Machine Value)
dbInsert m args = case args of
  [VString table, record] -> do
    tableState <- readDbTable table m
    let id = "rec" <> show tableState.nextId
        tableState' = tableState { nextId = tableState.nextId + 1, rows = Map.insert id record tableState.rows }
    pure $ Tuple (writeDbTable table tableState' m) (VString id)
  _ -> Left $ VMError TypeMismatch "db.insert/v1 expects (Table:String, Record:Value)"

dbGet :: Machine -> Array Value -> Either VMError (Tuple Machine Value)
dbGet m args = case args of
  [VString table, VString id] -> do
    tableState <- readDbTable table m
    pure $ Tuple m (fromMaybe VUnit (Map.lookup id tableState.rows))
  _ -> Left $ VMError TypeMismatch "db.get/v1 expects (Table:String, ID:String)"

dbUpdate :: Machine -> Array Value -> Either VMError (Tuple Machine Value)
dbUpdate m args = case args of
  [VString table, VString id, record] -> do
    tableState <- readDbTable table m
    let existed = Map.member id tableState.rows
        rows' = if existed then Map.insert id record tableState.rows else tableState.rows
    pure $ Tuple (writeDbTable table (tableState { rows = rows' }) m) (VBool existed)
  _ -> Left $ VMError TypeMismatch "db.update/v1 expects (Table:String, ID:String, Record:Value)"

dbDelete :: Machine -> Array Value -> Either VMError (Tuple Machine Value)
dbDelete m args = case args of
  [VString table, VString id] -> do
    tableState <- readDbTable table m
    let existed = Map.member id tableState.rows
        rows' = Map.delete id tableState.rows
    pure $ Tuple (writeDbTable table (tableState { rows = rows' }) m) (VBool existed)
  _ -> Left $ VMError TypeMismatch "db.delete/v1 expects (Table:String, ID:String)"

dbQuery :: Machine -> Array Value -> Either VMError (Tuple Machine Value)
dbQuery m args = case args of
  [VString table, VRecord query, _options] -> do
    tableState <- readDbTable table m
    let rows = Map.toUnfoldable tableState.rows :: Array (Tuple String Value)
        matched = map (\(Tuple _ row) -> row) (Array.filter (\(Tuple _ row) -> rowMatchesQuery query row) rows)
    pure $ Tuple m (VList (Vec.fromArray matched))
  _ -> Left $ VMError TypeMismatch "db.query/v1 expects (Table:String, Query:Record, Options:Record)"

dbCreateIndex :: Machine -> Array Value -> Either VMError (Tuple Machine Value)
dbCreateIndex m args = case args of
  [VString table, VString field] -> do
    tableState <- readDbTable table m
    pure $ Tuple (writeDbTable table (tableState { indexes = Map.insert field (VBool true) tableState.indexes }) m) VUnit
  _ -> Left $ VMError TypeMismatch "db.createIndex/v1 expects (Table:String, Field:String)"

dbHash :: Machine -> Array Value -> Either VMError (Tuple Machine Value)
dbHash m args = case args of
  [VString table] -> do
    tableState <- readDbTable table m
    pure $ Tuple m (VString (Canonical.hashValue (VRecord tableState.rows)))
  _ -> Left $ VMError TypeMismatch "db.hash/v1 expects (Table:String)"

cacheSet :: Machine -> Array Value -> Either VMError (Tuple Machine Value)
cacheSet m args = case args of
  [VString ns, VString key, val] ->
    pure $ Tuple (writeCacheNamespace ns (Map.insert key val (readCacheNamespace ns m)) m) (VBool true)
  _ -> Left $ VMError TypeMismatch "cache.set/v1 expects (Namespace:String, Key:String, Value:Value)"

cacheGet :: Machine -> Array Value -> Either VMError (Tuple Machine Value)
cacheGet m args = case args of
  [VString ns, VString key] ->
    pure $ Tuple m (fromMaybe VUnit (Map.lookup key (readCacheNamespace ns m)))
  _ -> Left $ VMError TypeMismatch "cache.get/v1 expects (Namespace:String, Key:String)"

cacheDelete :: Machine -> Array Value -> Either VMError (Tuple Machine Value)
cacheDelete m args = case args of
  [VString ns, VString key] ->
    let entries = readCacheNamespace ns m
        existed = Map.member key entries
    in pure $ Tuple (writeCacheNamespace ns (Map.delete key entries) m) (VBool existed)
  _ -> Left $ VMError TypeMismatch "cache.delete/v1 expects (Namespace:String, Key:String)"

rowMatchesQuery :: Map.Map String Value -> Value -> Boolean
rowMatchesQuery query row = case row of
  VRecord fields -> Array.all (\(Tuple key expected) -> Map.lookup key fields == Just expected) (Map.toUnfoldable query :: Array (Tuple String Value))
  _ -> Map.isEmpty query

readDbTable :: String -> Machine -> Either VMError DbTable
readDbTable table m = case Map.lookup table (readRecordState dbStateKey m) of
  Nothing -> pure emptyDbTable
  Just (VRecord fields) -> do
    nextId <- case Map.lookup "nextId" fields of
      Just (VInt i) -> bigintToInt "db table nextId out of Int range" i
      Nothing -> pure 0
      _ -> Left $ VMError TypeMismatch "Malformed db table: nextId must be Int"
    rows <- case Map.lookup "rows" fields of
      Just (VRecord rows) -> pure rows
      Nothing -> pure Map.empty
      _ -> Left $ VMError TypeMismatch "Malformed db table: rows must be Record"
    indexes <- case Map.lookup "indexes" fields of
      Just (VRecord indexes) -> pure indexes
      Nothing -> pure Map.empty
      _ -> Left $ VMError TypeMismatch "Malformed db table: indexes must be Record"
    pure { nextId, rows, indexes }
  Just _ -> Left $ VMError TypeMismatch "Malformed db store: table must be Record"

writeDbTable :: String -> DbTable -> Machine -> Machine
writeDbTable table tableState m =
  let
    db = readRecordState dbStateKey m
    tableValue = VRecord (Map.fromFoldable
      [ Tuple "nextId" (VInt (BI.fromInt tableState.nextId))
      , Tuple "rows" (VRecord tableState.rows)
      , Tuple "indexes" (VRecord tableState.indexes)
      ])
  in m { state = Map.insert dbStateKey (VRecord (Map.insert table tableValue db)) m.state }

readCacheNamespace :: String -> Machine -> Map.Map String Value
readCacheNamespace ns m = case Map.lookup ns (readRecordState cacheStateKey m) of
  Just (VRecord entries) -> entries
  _ -> Map.empty

writeCacheNamespace :: String -> Map.Map String Value -> Machine -> Machine
writeCacheNamespace ns entries m =
  let cache = readRecordState cacheStateKey m
  in m { state = Map.insert cacheStateKey (VRecord (Map.insert ns (VRecord entries) cache)) m.state }

readRecordState :: String -> Machine -> Map.Map String Value
readRecordState key m = case Map.lookup key m.state of
  Just (VRecord fields) -> fields
  _ -> Map.empty

bigintToInt :: String -> BI.BigInt -> Either VMError Int
bigintToInt msg i = case BI.toInt i of
  Nothing -> Left $ VMError InvalidInstruction msg
  Just n -> Right n

processTerminalValue :: Process -> Maybe Value
processTerminalValue p = case p.status of
  ProcessCompleted val -> Just val
  ProcessFailed err -> Just (VString (show err))
  ProcessTypes.ProcessCancelled reason -> Just (VString (show reason))
  ProcessExited reason -> Just (VString (show reason))
  _ -> Nothing

selectTransition :: String -> String -> Array TransitionDef -> Either VMError TransitionDef
selectTransition currentState event matches =
  case Array.sortWith (\t -> negate (fromMaybe 0 t.priority)) matches of
    [] -> Left $ VMError NoTransition ("No transition from " <> currentState <> " on event " <> event)
    [t] -> Right t
    sorted -> case Array.index sorted 0, Array.index sorted 1 of
      Just first, Just second | fromMaybe 0 first.priority == fromMaybe 0 second.priority ->
        Left $ VMError AmbiguousTransition ("Ambiguous transition from " <> currentState <> " on event " <> event)
      Just first, _ -> Right first
      _, _ -> Left $ VMError NoTransition ("No transition from " <> currentState <> " on event " <> event)

runTransitionAction :: Machine -> String -> String -> MachineInstance Value -> Either VMError (Tuple Machine (MachineInstance Value))
runTransitionAction m callerPid actionFn mi = do
  action <- case Map.lookup actionFn m.program.functions of
    Nothing -> Left $ VMError UnknownFunction ("Transition action not found: " <> actionFn)
    Just f -> pure f
  let args = if action.arity == 0 then [] else [VStateMachineInstance mi]
  Tuple mAction result <- runFunctionValue m callerPid actionFn args
  case result of
    VStateMachineInstance mi' -> pure $ Tuple mAction mi'
    VRecord fields -> pure $ Tuple mAction (mi { data_ = fields })
    VUnit -> pure $ Tuple mAction mi
    _ -> pure $ Tuple mAction mi

runFunctionValue :: Machine -> String -> String -> Array Value -> Either VMError (Tuple Machine Value)
runFunctionValue m callerPid functionId args = do
  targetFunc <- case Map.lookup functionId m.program.functions of
    Nothing -> Left $ VMError UnknownFunction ("Function not found: " <> functionId)
    Just f -> pure f
  let
    newRegs = Array.replicate targetFunc.registerCount VUnit
    newRegs' = Array.foldl (\acc (Tuple i v) -> fromMaybe acc (Array.updateAt i v acc)) newRegs (Array.mapWithIndex Tuple args)
    localPid = callerPid <> ":call:" <> functionId <> ":" <> show m.counters.steps
    localProcess =
      { pid: localPid
      , status: ProcessReady
      , function: functionId
      , frame: { function: functionId, pc: 0, registers: newRegs', returnRegister: Nothing, caller: Nothing }
      , callStack: []
      , mailbox: []
      , links: Set.empty
      , monitors: Map.empty
      , parent: Just callerPid
      , children: Set.empty
      , trapExit: false
      , metadata: { name: localPid }
      , result: Nothing
      , error: Nothing
      , createdSequence: m.scheduler.nextPidSequence
      , stepsExecuted: 0
      }
  runLocal targetFunc.registerCount m localProcess m.config.limits.maxSteps
  where
    runLocal _ currentMachine currentProcess remaining =
      if remaining <= 0 then Left $ VMError StepLimitExceeded ("Function " <> functionId <> " exceeded step limit")
      else case currentProcess.status of
        ProcessReady -> do
          Tuple m' p' <- stepProcess currentMachine currentProcess
          runLocal 0 m' p' (remaining - 1)
        ProcessCompleted value -> Right $ Tuple currentMachine value
        ProcessFailed err -> Left err
        ProcessWaiting _ -> Left $ VMError ProcessDeadlock ("Function " <> functionId <> " blocked during synchronous evaluation")
        ProcessExited reason -> Left $ VMError VMErrorCode.ProcessCancelled ("Function " <> functionId <> " exited: " <> show reason)
        ProcessTypes.ProcessCancelled reason -> Left $ VMError VMErrorCode.ProcessCancelled ("Function " <> functionId <> " cancelled: " <> show reason)
        ProcessRunning -> runLocal 0 currentMachine (currentProcess { status = ProcessReady }) (remaining - 1)

-- Helper to find a label's PC.
-- Uses the machine's precomputed per-function label cache for O(1) lookup when
-- present, falling back to a linear scan of the instruction array otherwise
-- (so callers that have not populated `labelCache` still work correctly).
findLabel :: Machine -> VMFunction.Function -> String -> Either VMError Int
findLabel m func label =
  case Map.lookup func.id m.labelCache >>= Map.lookup label of
    Just pc -> pure pc
    Nothing -> scanLabel func label

scanLabel :: VMFunction.Function -> String -> Either VMError Int
scanLabel func label =
  let
    findIdx acc arr = case Array.uncons arr of
      Nothing -> Left $ VMError InvalidJump ("Label not found: " <> label)
      Just { head: LABEL l } | l == label -> pure acc
      Just { tail } -> findIdx (acc + 1) tail
  in findIdx 0 func.instructions

-- | Build the label -> instruction-index map for one function.
labelsForFunction :: VMFunction.Function -> Map.Map String Int
labelsForFunction func =
  Array.foldl step Map.empty (Array.mapWithIndex Tuple func.instructions)
  where
    step acc (Tuple idx inst) = case inst of
      LABEL l -> Map.insert l idx acc
      _ -> acc

-- | Build the whole-program label cache: functionId -> (label -> index).
buildLabelCache :: Program -> Map.Map String (Map.Map String Int)
buildLabelCache program = map labelsForFunction program.functions
