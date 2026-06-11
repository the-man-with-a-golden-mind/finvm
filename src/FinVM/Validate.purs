module FinVM.Validate where

import Prelude
import Data.Either (Either(..))
import Data.Map as Map
import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.Foldable (for_)
import Data.Set as Set
import FinVM.Program (Program)
import FinVM.Function (Function)
import FinVM.Instruction (Instruction(..), Register)
import FinVM.Error (VMError(..), ErrorCode(..))
import FinVM.Value (FunctionId)

import Data.Tuple (Tuple(..))

validateProgram :: Program -> Either VMError Unit
validateProgram p = do
  -- 1. Entrypoint exists
  case Map.lookup p.entrypoint p.functions of
    Nothing -> Left $ VMError InvalidProgram ("Entrypoint not found: " <> p.entrypoint)
    Just _ -> pure unit

  -- 2. Exports exist
  for_ (Map.toUnfoldable p.exports :: Array (Tuple String FunctionId)) \(Tuple _ target) ->
    case Map.lookup target p.functions of
      Nothing -> Left $ VMError InvalidProgram ("Export target not found: " <> target)
      Just _ -> pure unit

  -- 3. Validate each function
  for_ (Map.values p.functions) \f -> validateFunction p f

validateFunction :: Program -> Function -> Either VMError Unit
validateFunction p f = do
  let
    labels = Array.mapMaybe getLabel f.instructions
    labelSet = Set.fromFoldable labels
    constCount = Array.length p.constants

  -- The frame allocates exactly `registerCount` registers and arguments are
  -- placed in registers 0..arity-1. If registerCount < arity, those arguments
  -- would be silently dropped at call time, so reject it up front.
  if f.arity < 0 || f.registerCount < 0
    then Left $ VMError InvalidProgram ("Negative arity/registerCount in function " <> f.id)
    else pure unit
  if f.registerCount < f.arity
    then Left $ VMError InvalidRegister ("Function " <> f.id <> " declares registerCount " <> show f.registerCount <> " < arity " <> show f.arity <> "; arguments would be dropped")
    else pure unit

  for_ f.instructions \inst -> do
    if isSupportedInstruction inst
      then pure unit
      else Left $ VMError InvalidInstruction ("Instruction is declared but not implemented by the interpreter in function " <> f.id <> ": " <> show inst)

    -- Validate registers
    let regs = extractRegisters inst
    for_ regs \r ->
      if r < 0 || r >= f.registerCount
        then Left $ VMError InvalidRegister ("Register out of bounds in function " <> f.id)
        else pure unit

    -- Validate jumps
    case inst of
      JUMP l -> checkLabel f.id labelSet l
      JUMP_IF _ l -> checkLabel f.id labelSet l
      JUMP_IF_FALSE _ l -> checkLabel f.id labelSet l
      _ -> pure unit

    -- Validate constants
    case inst of
      LOAD_CONST _ cidx ->
        if cidx < 0 || cidx >= constCount
          then Left $ VMError InvalidInstruction ("Constant index out of bounds in function " <> f.id)
          else pure unit
      _ -> pure unit

    -- Validate calls
    case extractCall inst of
      Just call ->
        case Map.lookup call.id p.functions of
          Nothing -> Left $ VMError UnknownFunction ("Unknown function " <> call.id <> " in " <> f.id)
          Just targetF ->
            if targetF.arity /= call.arity
              then Left $ VMError ArityMismatch ("Arity mismatch calling " <> call.id <> " from " <> f.id)
              else pure unit
      Nothing -> pure unit

checkLabel :: FunctionId -> Set.Set String -> String -> Either VMError Unit
checkLabel fid labels l =
  if Set.member l labels
    then pure unit
    else Left $ VMError InvalidJump ("Jump to unknown label " <> l <> " in function " <> fid)

getLabel :: Instruction -> Maybe String
getLabel (LABEL l) = Just l
getLabel _ = Nothing

extractCall :: Instruction -> Maybe { id :: FunctionId, arity :: Int }
extractCall (CALL _ fid args) = Just { id: fid, arity: Array.length args }
extractCall (TAIL_CALL fid args) = Just { id: fid, arity: Array.length args }
extractCall (PROC_SPAWN _ fid args) = Just { id: fid, arity: Array.length args }
extractCall (NODE_SPAWN _ _ fid args) = Just { id: fid, arity: Array.length args }
extractCall _ = Nothing

isSupportedInstruction :: Instruction -> Boolean
isSupportedInstruction _ = true

-- Extracts all registers read or written by an instruction
extractRegisters :: Instruction -> Array Register
extractRegisters = case _ of
  NOOP -> []
  HALT r -> [r]
  ABORT _ -> []
  LABEL _ -> []
  JUMP _ -> []
  JUMP_IF r _ -> [r]
  JUMP_IF_FALSE r _ -> [r]
  CALL r _ args -> Array.cons r args
  TAIL_CALL _ args -> args
  RETURN r -> [r]
  LOAD_CONST r _ -> [r]
  LOAD_INPUT r _ -> [r]
  LOAD_CONTEXT r _ -> [r]
  MOVE r1 r2 -> [r1, r2]
  CLEAR r -> [r]
  RECORD_NEW r -> [r]
  RECORD_GET r1 r2 _ -> [r1, r2]
  RECORD_GET_OPT r1 r2 _ -> [r1, r2]
  RECORD_SET r1 r2 _ r3 -> [r1, r2, r3]
  RECORD_HAS r1 r2 _ -> [r1, r2]
  RECORD_REMOVE r1 r2 _ -> [r1, r2]
  RECORD_KEYS r1 r2 -> [r1, r2]
  LIST_NEW r -> [r]
  LIST_FROM r args -> Array.cons r args
  LIST_GET r1 r2 r3 -> [r1, r2, r3]
  LIST_SET r1 r2 r3 r4 -> [r1, r2, r3, r4]
  LIST_APPEND r1 r2 r3 -> [r1, r2, r3]
  LIST_LENGTH r1 r2 -> [r1, r2]
  LIST_SLICE r1 r2 r3 r4 -> [r1, r2, r3, r4]
  MAP_NEW r -> [r]
  MAP_GET r1 r2 r3 -> [r1, r2, r3]
  MAP_GET_OPT r1 r2 r3 -> [r1, r2, r3]
  MAP_SET r1 r2 r3 r4 -> [r1, r2, r3, r4]
  MAP_HAS r1 r2 r3 -> [r1, r2, r3]
  MAP_REMOVE r1 r2 r3 -> [r1, r2, r3]
  MAP_KEYS r1 r2 -> [r1, r2]
  MAP_VALUES r1 r2 -> [r1, r2]
  MAP_SIZE r1 r2 -> [r1, r2]
  VARIANT_NEW r1 _ r2 -> [r1, r2]
  VARIANT_TAG r1 r2 -> [r1, r2]
  VARIANT_PAYLOAD r1 r2 -> [r1, r2]
  ADD r1 r2 r3 -> [r1, r2, r3]
  SUB r1 r2 r3 -> [r1, r2, r3]
  MUL r1 r2 r3 -> [r1, r2, r3]
  DIV r1 _ r2 r3 -> [r1, r2, r3]
  MOD r1 r2 r3 -> [r1, r2, r3]
  NEG r1 r2 -> [r1, r2]
  ABS r1 r2 -> [r1, r2]
  MIN r1 r2 r3 -> [r1, r2, r3]
  MAX r1 r2 r3 -> [r1, r2, r3]
  CLAMP r1 r2 r3 r4 -> [r1, r2, r3, r4]
  EQ r1 r2 r3 -> [r1, r2, r3]
  NEQ r1 r2 r3 -> [r1, r2, r3]
  LT r1 r2 r3 -> [r1, r2, r3]
  LTE r1 r2 r3 -> [r1, r2, r3]
  GT r1 r2 r3 -> [r1, r2, r3]
  GTE r1 r2 r3 -> [r1, r2, r3]
  COMPARE r1 r2 r3 -> [r1, r2, r3]
  CALL_BUILTIN r _ args -> Array.cons r args
  STATE_GET r _ -> [r]
  STATE_GET_OPT r _ -> [r]
  STATE_SET _ r -> [r]
  STATE_DELETE _ -> []
  STATE_EXISTS r _ -> [r]
  STATE_KEYS r _ -> [r]
  STATE_SNAPSHOT r -> [r]
  EVENT_NEW r1 _ r2 -> [r1, r2]
  EVENT_EMIT r -> [r]
  EVENT_BATCH_NEW r -> [r]
  EVENT_BATCH_APPEND r1 r2 r3 -> [r1, r2, r3]
  EFFECT_NEW r1 _ r2 -> [r1, r2]
  EFFECT_REQUEST r -> [r]
  EFFECT_BATCH_NEW r -> [r]
  EFFECT_BATCH_APPEND r1 r2 r3 -> [r1, r2, r3]
  PROC_SELF r -> [r]
  PROC_STATUS r1 r2 -> [r1, r2]
  PROC_SPAWN r _ args -> Array.cons r args
  PROC_YIELD -> []
  PROC_JOIN r1 r2 -> [r1, r2]
  PROC_JOIN_RESULT r1 r2 -> [r1, r2]
  PROC_CANCEL r1 r2 -> [r1, r2]
  PROC_EXIT r -> [r]
  PROC_SEND r1 r2 -> [r1, r2]
  PROC_RECEIVE r -> [r]
  PROC_RECEIVE_OPT r -> [r]
  PROC_LINK r -> [r]
  PROC_UNLINK r -> [r]
  PROC_MONITOR r1 r2 -> [r1, r2]
  PROC_DEMONITOR r -> [r]
  PROC_TRAP_EXIT _ -> []
  PROC_SLEEP_TICKS _ -> []
  NODE_SELF r -> [r]
  NODE_STATUS r1 r2 -> [r1, r2]
  NODE_KNOWN r -> [r]
  REMOTE_PID_NEW r1 r2 r3 -> [r1, r2, r3]
  REMOTE_PID_NODE r1 r2 -> [r1, r2]
  REMOTE_PID_LOCAL r1 r2 -> [r1, r2]
  NODE_SEND r1 r2 -> [r1, r2]
  NODE_SPAWN r1 r2 _ args -> Array.cons r1 (Array.cons r2 args)
  NODE_MONITOR r1 r2 -> [r1, r2]
  NODE_DEMONITOR r -> [r]
  NODE_OBSERVE_STATE r1 r2 -> [r1, r2]
  NODE_LAST_STATE_HASH r1 r2 -> [r1, r2]
  NODE_LAST_SEEN_TICK r1 r2 -> [r1, r2]
  NODE_QUERY_STATE r1 r2 -> [r1, r2]
  MACHINE_NEW r1 _ r2 -> [r1, r2]
  MACHINE_STATE r1 r2 -> [r1, r2]
  MACHINE_TRANSITION r1 r2 _ -> [r1, r2]
  ASSERT r _ -> [r]
  ASSUME r _ -> [r]
  INVARIANT_CHECK _ -> []
  PROOF_MARK _ r -> [r]
  PROOF_SCOPE_BEGIN _ -> []
  PROOF_SCOPE_END _ -> []
