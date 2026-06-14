module FinVM.Instruction where

import Prelude
import Data.Maybe (Maybe)
import FinVM.Value (Value, FunctionId, ProcessId, NodeRef, RemoteProcessRef)
import FinVM.Numeric.Rounding (Rounding)

type Register = Int
type Label = String

data Instruction
  -- Control
  = NOOP
  | HALT Register
  | ABORT Int -- Error code
  | LABEL String
  | JUMP Label
  | JUMP_IF Register Label
  | JUMP_IF_FALSE Register Label
  | CALL Register FunctionId (Array Register)
  | TAIL_CALL FunctionId (Array Register)
  | RETURN Register

  -- Movement / Constants
  | LOAD_CONST Register Int -- const index
  | LOAD_INPUT Register String -- path
  | LOAD_CONTEXT Register String
  | MOVE Register Register
  | CLEAR Register

  -- Records
  | RECORD_NEW Register
  | RECORD_GET Register Register String
  | RECORD_GET_OPT Register Register String
  | RECORD_SET Register Register String Register
  | RECORD_HAS Register Register String
  | RECORD_REMOVE Register Register String
  | RECORD_KEYS Register Register

  -- Lists
  | LIST_NEW Register
  | LIST_FROM Register (Array Register)
  | LIST_GET Register Register Register
  | LIST_SET Register Register Register Register
  | LIST_APPEND Register Register Register
  | LIST_LENGTH Register Register
  | LIST_SLICE Register Register Register Register

  -- Maps
  | MAP_NEW Register
  | MAP_GET Register Register Register
  | MAP_GET_OPT Register Register Register
  | MAP_SET Register Register Register Register
  | MAP_HAS Register Register Register
  | MAP_REMOVE Register Register Register
  | MAP_KEYS Register Register
  | MAP_VALUES Register Register
  | MAP_SIZE Register Register

  -- Variants
  | VARIANT_NEW Register String Register
  | VARIANT_TAG Register Register
  | VARIANT_PAYLOAD Register Register

  -- Arithmetic
  | ADD Register Register Register
  | SUB Register Register Register
  | MUL Register Register Register
  | DIV Register Rounding Register Register
  | MOD Register Register Register
  | NEG Register Register
  | ABS Register Register
  | MIN Register Register Register
  | MAX Register Register Register
  | CLAMP Register Register Register Register

  -- Comparison
  | EQ Register Register Register
  | NEQ Register Register Register
  | LT Register Register Register
  | LTE Register Register Register
  | GT Register Register Register
  | GTE Register Register Register
  | COMPARE Register Register Register

  -- Builtins
  | CALL_BUILTIN Register String (Array Register)

  -- State
  | STATE_GET Register String
  | STATE_GET_OPT Register String
  | STATE_SET String Register
  | STATE_DELETE String
  | STATE_EXISTS Register String
  | STATE_KEYS Register String
  | STATE_SNAPSHOT Register

  -- Events / Effects
  | EVENT_NEW Register String Register
  | EVENT_EMIT Register
  | EVENT_BATCH_NEW Register
  | EVENT_BATCH_APPEND Register Register Register
  | EFFECT_NEW Register String Register
  | EFFECT_REQUEST Register
  | EFFECT_AWAIT Register
  | EFFECT_BATCH_NEW Register
  | EFFECT_BATCH_APPEND Register Register Register

  -- Processes
  | PROC_SELF Register
  | PROC_STATUS Register Register
  | PROC_SPAWN Register FunctionId (Array Register)
  | PROC_YIELD
  | PROC_JOIN Register Register
  | PROC_JOIN_RESULT Register Register
  | PROC_CANCEL Register Register
  | PROC_EXIT Register
  | PROC_SEND Register Register
  | PROC_RECEIVE Register
  | PROC_RECEIVE_OPT Register
  | PROC_LINK Register
  | PROC_UNLINK Register
  | PROC_MONITOR Register Register
  | PROC_DEMONITOR Register
  | PROC_TRAP_EXIT Boolean
  | PROC_SLEEP_TICKS Int

  -- Nodes
  | NODE_SELF Register
  | NODE_STATUS Register Register
  | NODE_KNOWN Register
  | REMOTE_PID_NEW Register Register Register
  | REMOTE_PID_NODE Register Register
  | REMOTE_PID_LOCAL Register Register
  | NODE_SEND Register Register
  | NODE_SPAWN Register Register FunctionId (Array Register)
  | NODE_MONITOR Register Register
  | NODE_DEMONITOR Register
  | NODE_OBSERVE_STATE Register Register
  | NODE_LAST_STATE_HASH Register Register
  | NODE_LAST_SEEN_TICK Register Register
  | NODE_QUERY_STATE Register Register

  -- State Machine
  | MACHINE_NEW Register String Register -- dst, machineId, initialData
  | MACHINE_STATE Register Register -- dst, machineRef
  | MACHINE_TRANSITION Register Register String -- dst, machineRef, event

  -- Proof
  | ASSERT Register Int
  | ASSUME Register String
  | INVARIANT_CHECK FunctionId
  | PROOF_MARK String Register
  | PROOF_SCOPE_BEGIN String
  | PROOF_SCOPE_END String

derive instance eqInstruction :: Eq Instruction
derive instance ordInstruction :: Ord Instruction

instance showInstruction :: Show Instruction where
  show = case _ of
    NOOP -> "NOOP"
    HALT r -> "HALT " <> show r
    ABORT c -> "ABORT " <> show c
    LABEL l -> "LABEL " <> l
    JUMP l -> "JUMP " <> l
    JUMP_IF r l -> "JUMP_IF " <> show r <> " " <> l
    JUMP_IF_FALSE r l -> "JUMP_IF_FALSE " <> show r <> " " <> l
    CALL d f a -> "CALL " <> show d <> " " <> f <> " " <> show a
    TAIL_CALL f a -> "TAIL_CALL " <> f <> " " <> show a
    RETURN r -> "RETURN " <> show r
    LOAD_CONST d i -> "LOAD_CONST " <> show d <> " " <> show i
    LOAD_INPUT d p -> "LOAD_INPUT " <> show d <> " " <> p
    LOAD_CONTEXT d p -> "LOAD_CONTEXT " <> show d <> " " <> p
    MOVE d s -> "MOVE " <> show d <> " " <> show s
    CLEAR d -> "CLEAR " <> show d
    RECORD_NEW d -> "RECORD_NEW " <> show d
    RECORD_GET d r f -> "RECORD_GET " <> show d <> " " <> show r <> " " <> f
    RECORD_SET d r f v -> "RECORD_SET " <> show d <> " " <> show r <> " " <> f <> " " <> show v
    LIST_NEW d -> "LIST_NEW " <> show d
    LIST_APPEND d l v -> "LIST_APPEND " <> show d <> " " <> show l <> " " <> show v
    LIST_GET d l i -> "LIST_GET " <> show d <> " " <> show l <> " " <> show i
    ADD d a b -> "ADD " <> show d <> " " <> show a <> " " <> show b
    SUB d a b -> "SUB " <> show d <> " " <> show a <> " " <> show b
    MUL d a b -> "MUL " <> show d <> " " <> show a <> " " <> show b
    DIV d r a b -> "DIV " <> show d <> " " <> show r <> " " <> show a <> " " <> show b
    MOD d a b -> "MOD " <> show d <> " " <> show a <> " " <> show b
    EQ d a b -> "EQ " <> show d <> " " <> show a <> " " <> show b
    LT d a b -> "LT " <> show d <> " " <> show a <> " " <> show b
    GT d a b -> "GT " <> show d <> " " <> show a <> " " <> show b
    NEQ d a b -> "NEQ " <> show d <> " " <> show a <> " " <> show b
    LTE d a b -> "LTE " <> show d <> " " <> show a <> " " <> show b
    GTE d a b -> "GTE " <> show d <> " " <> show a <> " " <> show b
    PROC_SELF d -> "PROC_SELF " <> show d
    PROC_SPAWN d f a -> "PROC_SPAWN " <> show d <> " " <> f <> " " <> show a
    PROC_SEND p m -> "PROC_SEND " <> show p <> " " <> show m
    PROC_RECEIVE d -> "PROC_RECEIVE " <> show d
    PROC_YIELD -> "PROC_YIELD"
    MACHINE_NEW d m i -> "MACHINE_NEW " <> show d <> " " <> m <> " " <> show i
    MACHINE_STATE d m -> "MACHINE_STATE " <> show d <> " " <> show m
    MACHINE_TRANSITION d m e -> "MACHINE_TRANSITION " <> show d <> " " <> show m <> " " <> e
    ASSERT r c -> "ASSERT " <> show r <> " " <> show c
    ASSUME r n -> "ASSUME " <> show r <> " " <> n
    PROOF_MARK l r -> "PROOF_MARK " <> l <> " " <> show r
    _ -> "OTHER_INSTRUCTION"

