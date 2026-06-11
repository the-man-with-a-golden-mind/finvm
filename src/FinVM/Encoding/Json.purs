module FinVM.Encoding.Json
  ( decodeProgramFile
  , runJsonProgram
  , runJsonProgramResult
  , errorJson
  , valueToJson
  , decodeValue
  ) where

import Prelude

import Data.Argonaut.Core as Json
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.BigInt as BigInt
import Data.Either (Either(..))
import Data.Int as Int
import Data.List as List
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import FinVM.Error (VMError(..))
import FinVM.Eval as Eval
import FinVM.Frame (Frame)
import FinVM.Function as VMFunction
import FinVM.Instruction (Instruction)
import FinVM.Instruction as I
import FinVM.Limits (EvalLimits)
import FinVM.Machine (Machine)
import FinVM.Numeric.Rounding (Rounding(..))
import FinVM.Process (Process, ProcessStatus(..))
import FinVM.Process.Scheduler as Scheduler
import FinVM.Program (Program)
import FinVM.Validate as Validate
import FinVM.Registers (emptyRegisters)
import FinVM.State (VMInput, VMState)
import FinVM.Type (VMType(..))
import FinVM.Value (Value(..))
import FinVM.Vec as Vec
import Foreign.Object (Object)
import Foreign.Object as Object

type JsonProgramFile =
  { program :: Program
  , state :: VMState
  , input :: VMInput
  , limits :: EvalLimits
  , performanceMode :: Boolean
  }

decodeProgramFile :: String -> Either String JsonProgramFile
decodeProgramFile source = do
  root <- jsonParser source
  object <- asObject "program" root
  constants <- case Object.lookup "constants" object of
    Nothing -> pure []
    Just json -> asArray "constants" json >>= traverse decodeValue
  state <- optionalObjectMap "state" object decodeValue
  input <- optionalObjectMap "input" object decodeValue
  limits <- decodeLimits object
  performanceMode <- optionalBool "performanceMode" object <#> fromMaybe false
  version <- optionalStringWithDefault "version" "1.0" object
  Tuple functions entrypoint <- decodeFunctionSet object
  let
    program =
      { version
      , constants
      , functions
      , stateMachines: Map.empty
      , entrypoint
      , exports: Map.singleton entrypoint entrypoint
      , metadata: { description: "JSON CLI program" }
      , typeTable: Map.empty
      , capabilities: []
      , verification: { verified: false }
      }
  pure { program, state, input, limits, performanceMode }

-- | Resolve the program's functions. If a top-level `functions` object is
-- | present, each entry is a full function spec (multi-function program, so
-- | CALL / TAIL_CALL / PROC_SPAWN can target any of them). Otherwise fall back
-- | to the simplified single implicit `main` built from top-level instructions.
decodeFunctionSet :: Object Json.Json -> Either String (Tuple (Map String VMFunction.Function) String)
decodeFunctionSet object =
  case Object.lookup "functions" object >>= Json.toObject of
    Just fnsObj | not (Object.isEmpty fnsObj) -> do
      pairs <- traverse decodeNamedFunction (Object.toUnfoldable fnsObj :: Array (Tuple String Json.Json))
      entrypoint <- optionalStringWithDefault "entrypoint" "main" object
      pure (Tuple (Map.fromFoldable pairs) entrypoint)
    _ -> do
      instructions <- instructionSource object >>= traverse decodeInstruction
      registerCount <- optionalInt "registerCount" object
      pure (Tuple (Map.singleton "main" (mkMainFunction (fromMaybe 16 registerCount) instructions)) "main")

decodeNamedFunction :: Tuple String Json.Json -> Either String (Tuple String VMFunction.Function)
decodeNamedFunction (Tuple fid specJson) = do
  spec <- asObject ("function " <> fid) specJson
  arity <- optionalInt "arity" spec <#> fromMaybe 0
  registerCount <- optionalInt "registerCount" spec <#> fromMaybe (max 16 arity)
  instructions <- case Object.lookup "instructions" spec of
    Just j -> asArray ("instructions for " <> fid) j >>= traverse decodeInstruction
    Nothing -> Left ("function " <> fid <> " is missing an instructions array")
  isInvariant <- case Object.lookup "proof" spec >>= Json.toObject of
    Just proofObj -> optionalBool "isInvariant" proofObj <#> fromMaybe false
    Nothing -> pure false
  pure $ Tuple fid
    { id: fid
    , arity
    , registerCount
    , parameterTypes: []
    , returnType: TAny
    , instructions
    , debug: { name: fid }
    , proof: { isInvariant }
    }

runJsonProgram :: String -> String
runJsonProgram source = (runJsonProgramResult source).output

-- | Build a properly-escaped JSON error object string, e.g. for CLI/IO errors
-- | that occur outside the VM (such as a file that cannot be read).
errorJson :: String -> String
errorJson msg = Json.stringify $ objectJson
  [ Tuple "status" (Json.fromString "error")
  , Tuple "error" (Json.fromString msg)
  ]

-- | Run a JSON program and report both the JSON output string and whether the
-- | run succeeded. `ok` is false for decode failures and runtime VM errors so
-- | callers (e.g. the CLI) can set a non-zero exit code.
runJsonProgramResult :: String -> { ok :: Boolean, output :: String }
runJsonProgramResult source =
  case decodeProgramFile source of
    Left err -> failed err
    Right file ->
      -- Static validation before execution gives clear, up-front diagnostics
      -- (unknown function/builtin target, arity mismatch, out-of-bounds register,
      -- registerCount < arity, unknown jump label) instead of opaque runtime errors.
      case Validate.validateProgram file.program of
        Left vErr -> failed (renderVMError vErr)
        Right _ ->
          case Eval.runMachine (initialMachine file) of
            Left err -> failed (renderVMError err)
            Right machine ->
              { ok: true
              , output: Json.stringify $ objectJson
                  [ Tuple "status" (Json.fromString "completed")
                  , Tuple "steps" (Json.fromNumber (Int.toNumber machine.counters.steps))
                  , Tuple "result" (valueToJson (mainResult machine))
                  , Tuple "state" (stringMapToJson machine.state)
                  ]
              }
  where
    failed msg =
      { ok: false
      , output: Json.stringify $ objectJson
          [ Tuple "status" (Json.fromString "failed")
          , Tuple "error" (Json.fromString msg)
          ]
      }

mkMainFunction :: Int -> Array Instruction -> VMFunction.Function
mkMainFunction registerCount instructions =
  { id: "main"
  , arity: 0
  , registerCount
  , parameterTypes: []
  , returnType: TAny
  , instructions
  , debug: { name: "main" }
  , proof: { isInvariant: false }
  }

initialMachine :: JsonProgramFile -> Machine
initialMachine file =
  { program: file.program
  , scheduler: Scheduler.spawnProcess Scheduler.initialScheduler initialProcess
  , state: file.state
  , input: file.input
  , config: { limits: file.limits, externalBuiltins: Map.empty, performanceMode: file.performanceMode }
  , trace: List.Nil
  , proofTrace: List.Nil
  , outbox: List.Nil
  , events: List.Nil
  , counters: { steps: 0 }, labelCache: Map.empty
  }
  where
    entry :: String
    entry = file.program.entrypoint

    initialFrame :: Frame
    initialFrame =
      { function: entry
      , pc: 0
      , registers: emptyRegisters (fromMaybe 16 (Map.lookup entry file.program.functions <#> _.registerCount))
      , returnRegister: Nothing
      , caller: Nothing
      }

    initialProcess :: Process
    initialProcess =
      { pid: "main"
      , status: ProcessReady
      , function: entry
      , frame: initialFrame
      , callStack: []
      , mailbox: []
      , links: mempty
      , monitors: Map.empty
      , parent: Nothing
      , children: mempty
      , trapExit: false
      , metadata: { name: "main" }
      , result: Nothing
      , error: Nothing
      , createdSequence: 0
      , stepsExecuted: 0
      }

mainResult :: Machine -> Value
mainResult machine =
  case Scheduler.findProcess machine.scheduler "main" of
    Just p -> case p.status of
      ProcessCompleted value -> value
      _ -> fromMaybe VUnit p.result
    Nothing -> VUnit

instructionSource :: Object Json.Json -> Either String (Array Json.Json)
instructionSource object =
  case Object.lookup "instructions" object of
    Just json -> asArray "instructions" json
    Nothing -> case Object.lookup "functions" object >>= Json.toObject >>= Object.lookup "main" >>= Json.toObject >>= Object.lookup "instructions" of
      Just json -> asArray "functions.main.instructions" json
      Nothing -> Left "Missing instructions or functions.main.instructions"

decodeInstruction :: Json.Json -> Either String Instruction
decodeInstruction json = do
  parts <- case Json.toArray json of
    Just array -> pure array
    Nothing -> do
      object <- asObject "instruction" json
      op <- requiredString "op" object
      args <- case Object.lookup "args" object of
        Nothing -> pure []
        Just argsJson -> asArray ("args for " <> op) argsJson
      pure (Array.cons (Json.fromString op) args)
  op <- stringAt 0 parts
  case op of
    "NOOP" -> pure I.NOOP
    "HALT" -> I.HALT <$> intAt 1 parts
    "ABORT" -> I.ABORT <$> intAt 1 parts
    "LABEL" -> I.LABEL <$> stringAt 1 parts
    "JUMP" -> I.JUMP <$> stringAt 1 parts
    "JUMP_IF" -> I.JUMP_IF <$> intAt 1 parts <*> stringAt 2 parts
    "JUMP_IF_FALSE" -> I.JUMP_IF_FALSE <$> intAt 1 parts <*> stringAt 2 parts
    "CALL" -> I.CALL <$> intAt 1 parts <*> stringAt 2 parts <*> intArrayAt 3 parts
    "TAIL_CALL" -> I.TAIL_CALL <$> stringAt 1 parts <*> intArrayAt 2 parts
    "RETURN" -> I.RETURN <$> intAt 1 parts
    "LOAD_CONST" -> I.LOAD_CONST <$> intAt 1 parts <*> intAt 2 parts
    "LOAD_INPUT" -> I.LOAD_INPUT <$> intAt 1 parts <*> stringAt 2 parts
    "LOAD_CONTEXT" -> I.LOAD_CONTEXT <$> intAt 1 parts <*> stringAt 2 parts
    "MOVE" -> I.MOVE <$> intAt 1 parts <*> intAt 2 parts
    "CLEAR" -> I.CLEAR <$> intAt 1 parts
    "RECORD_NEW" -> I.RECORD_NEW <$> intAt 1 parts
    "RECORD_GET" -> I.RECORD_GET <$> intAt 1 parts <*> intAt 2 parts <*> stringAt 3 parts
    "RECORD_GET_OPT" -> I.RECORD_GET_OPT <$> intAt 1 parts <*> intAt 2 parts <*> stringAt 3 parts
    "RECORD_SET" -> I.RECORD_SET <$> intAt 1 parts <*> intAt 2 parts <*> stringAt 3 parts <*> intAt 4 parts
    "RECORD_HAS" -> I.RECORD_HAS <$> intAt 1 parts <*> intAt 2 parts <*> stringAt 3 parts
    "RECORD_REMOVE" -> I.RECORD_REMOVE <$> intAt 1 parts <*> intAt 2 parts <*> stringAt 3 parts
    "RECORD_KEYS" -> I.RECORD_KEYS <$> intAt 1 parts <*> intAt 2 parts
    "LIST_NEW" -> I.LIST_NEW <$> intAt 1 parts
    "LIST_FROM" -> I.LIST_FROM <$> intAt 1 parts <*> intArrayAt 2 parts
    "LIST_GET" -> I.LIST_GET <$> intAt 1 parts <*> intAt 2 parts <*> intAt 3 parts
    "LIST_SET" -> I.LIST_SET <$> intAt 1 parts <*> intAt 2 parts <*> intAt 3 parts <*> intAt 4 parts
    "LIST_APPEND" -> I.LIST_APPEND <$> intAt 1 parts <*> intAt 2 parts <*> intAt 3 parts
    "LIST_LENGTH" -> I.LIST_LENGTH <$> intAt 1 parts <*> intAt 2 parts
    "LIST_SLICE" -> I.LIST_SLICE <$> intAt 1 parts <*> intAt 2 parts <*> intAt 3 parts <*> intAt 4 parts
    "MAP_NEW" -> I.MAP_NEW <$> intAt 1 parts
    "MAP_GET" -> I.MAP_GET <$> intAt 1 parts <*> intAt 2 parts <*> intAt 3 parts
    "MAP_GET_OPT" -> I.MAP_GET_OPT <$> intAt 1 parts <*> intAt 2 parts <*> intAt 3 parts
    "MAP_SET" -> I.MAP_SET <$> intAt 1 parts <*> intAt 2 parts <*> intAt 3 parts <*> intAt 4 parts
    "MAP_HAS" -> I.MAP_HAS <$> intAt 1 parts <*> intAt 2 parts <*> intAt 3 parts
    "MAP_REMOVE" -> I.MAP_REMOVE <$> intAt 1 parts <*> intAt 2 parts <*> intAt 3 parts
    "MAP_KEYS" -> I.MAP_KEYS <$> intAt 1 parts <*> intAt 2 parts
    "MAP_VALUES" -> I.MAP_VALUES <$> intAt 1 parts <*> intAt 2 parts
    "MAP_SIZE" -> I.MAP_SIZE <$> intAt 1 parts <*> intAt 2 parts
    "VARIANT_NEW" -> I.VARIANT_NEW <$> intAt 1 parts <*> stringAt 2 parts <*> intAt 3 parts
    "VARIANT_TAG" -> I.VARIANT_TAG <$> intAt 1 parts <*> intAt 2 parts
    "VARIANT_PAYLOAD" -> I.VARIANT_PAYLOAD <$> intAt 1 parts <*> intAt 2 parts
    "ADD" -> I.ADD <$> intAt 1 parts <*> intAt 2 parts <*> intAt 3 parts
    "SUB" -> I.SUB <$> intAt 1 parts <*> intAt 2 parts <*> intAt 3 parts
    "MUL" -> I.MUL <$> intAt 1 parts <*> intAt 2 parts <*> intAt 3 parts
    "DIV" -> I.DIV <$> intAt 1 parts <*> roundingAt 2 parts <*> intAt 3 parts <*> intAt 4 parts
    "MOD" -> I.MOD <$> intAt 1 parts <*> intAt 2 parts <*> intAt 3 parts
    "NEG" -> I.NEG <$> intAt 1 parts <*> intAt 2 parts
    "ABS" -> I.ABS <$> intAt 1 parts <*> intAt 2 parts
    "MIN" -> I.MIN <$> intAt 1 parts <*> intAt 2 parts <*> intAt 3 parts
    "MAX" -> I.MAX <$> intAt 1 parts <*> intAt 2 parts <*> intAt 3 parts
    "CLAMP" -> I.CLAMP <$> intAt 1 parts <*> intAt 2 parts <*> intAt 3 parts <*> intAt 4 parts
    "EQ" -> I.EQ <$> intAt 1 parts <*> intAt 2 parts <*> intAt 3 parts
    "NEQ" -> I.NEQ <$> intAt 1 parts <*> intAt 2 parts <*> intAt 3 parts
    "LT" -> I.LT <$> intAt 1 parts <*> intAt 2 parts <*> intAt 3 parts
    "LTE" -> I.LTE <$> intAt 1 parts <*> intAt 2 parts <*> intAt 3 parts
    "GT" -> I.GT <$> intAt 1 parts <*> intAt 2 parts <*> intAt 3 parts
    "GTE" -> I.GTE <$> intAt 1 parts <*> intAt 2 parts <*> intAt 3 parts
    "COMPARE" -> I.COMPARE <$> intAt 1 parts <*> intAt 2 parts <*> intAt 3 parts
    "CALL_BUILTIN" -> I.CALL_BUILTIN <$> intAt 1 parts <*> stringAt 2 parts <*> intArrayAt 3 parts
    "STATE_GET" -> I.STATE_GET <$> intAt 1 parts <*> stringAt 2 parts
    "STATE_GET_OPT" -> I.STATE_GET_OPT <$> intAt 1 parts <*> stringAt 2 parts
    "STATE_SET" -> I.STATE_SET <$> stringAt 1 parts <*> intAt 2 parts
    "STATE_DELETE" -> I.STATE_DELETE <$> stringAt 1 parts
    "STATE_EXISTS" -> I.STATE_EXISTS <$> intAt 1 parts <*> stringAt 2 parts
    "STATE_KEYS" -> I.STATE_KEYS <$> intAt 1 parts <*> stringAt 2 parts
    "STATE_SNAPSHOT" -> I.STATE_SNAPSHOT <$> intAt 1 parts
    "EVENT_NEW" -> I.EVENT_NEW <$> intAt 1 parts <*> stringAt 2 parts <*> intAt 3 parts
    "EVENT_EMIT" -> I.EVENT_EMIT <$> intAt 1 parts
    "EVENT_BATCH_NEW" -> I.EVENT_BATCH_NEW <$> intAt 1 parts
    "EVENT_BATCH_APPEND" -> I.EVENT_BATCH_APPEND <$> intAt 1 parts <*> intAt 2 parts <*> intAt 3 parts
    "EFFECT_NEW" -> I.EFFECT_NEW <$> intAt 1 parts <*> stringAt 2 parts <*> intAt 3 parts
    "EFFECT_REQUEST" -> I.EFFECT_REQUEST <$> intAt 1 parts
    "EFFECT_BATCH_NEW" -> I.EFFECT_BATCH_NEW <$> intAt 1 parts
    "EFFECT_BATCH_APPEND" -> I.EFFECT_BATCH_APPEND <$> intAt 1 parts <*> intAt 2 parts <*> intAt 3 parts
    "PROC_SELF" -> I.PROC_SELF <$> intAt 1 parts
    "PROC_STATUS" -> I.PROC_STATUS <$> intAt 1 parts <*> intAt 2 parts
    "PROC_SPAWN" -> I.PROC_SPAWN <$> intAt 1 parts <*> stringAt 2 parts <*> intArrayAt 3 parts
    "PROC_YIELD" -> pure I.PROC_YIELD
    "PROC_JOIN" -> I.PROC_JOIN <$> intAt 1 parts <*> intAt 2 parts
    "PROC_JOIN_RESULT" -> I.PROC_JOIN_RESULT <$> intAt 1 parts <*> intAt 2 parts
    "PROC_CANCEL" -> I.PROC_CANCEL <$> intAt 1 parts <*> intAt 2 parts
    "PROC_EXIT" -> I.PROC_EXIT <$> intAt 1 parts
    "PROC_SEND" -> I.PROC_SEND <$> intAt 1 parts <*> intAt 2 parts
    "PROC_RECEIVE" -> I.PROC_RECEIVE <$> intAt 1 parts
    "PROC_RECEIVE_OPT" -> I.PROC_RECEIVE_OPT <$> intAt 1 parts
    "PROC_LINK" -> I.PROC_LINK <$> intAt 1 parts
    "PROC_UNLINK" -> I.PROC_UNLINK <$> intAt 1 parts
    "PROC_MONITOR" -> I.PROC_MONITOR <$> intAt 1 parts <*> intAt 2 parts
    "PROC_DEMONITOR" -> I.PROC_DEMONITOR <$> intAt 1 parts
    "PROC_TRAP_EXIT" -> I.PROC_TRAP_EXIT <$> boolAt 1 parts
    "PROC_SLEEP_TICKS" -> I.PROC_SLEEP_TICKS <$> intAt 1 parts
    "NODE_SELF" -> I.NODE_SELF <$> intAt 1 parts
    "NODE_STATUS" -> I.NODE_STATUS <$> intAt 1 parts <*> intAt 2 parts
    "NODE_KNOWN" -> I.NODE_KNOWN <$> intAt 1 parts
    "REMOTE_PID_NEW" -> I.REMOTE_PID_NEW <$> intAt 1 parts <*> intAt 2 parts <*> intAt 3 parts
    "REMOTE_PID_NODE" -> I.REMOTE_PID_NODE <$> intAt 1 parts <*> intAt 2 parts
    "REMOTE_PID_LOCAL" -> I.REMOTE_PID_LOCAL <$> intAt 1 parts <*> intAt 2 parts
    "NODE_SEND" -> I.NODE_SEND <$> intAt 1 parts <*> intAt 2 parts
    "NODE_SPAWN" -> I.NODE_SPAWN <$> intAt 1 parts <*> intAt 2 parts <*> stringAt 3 parts <*> intArrayAt 4 parts
    "NODE_MONITOR" -> I.NODE_MONITOR <$> intAt 1 parts <*> intAt 2 parts
    "NODE_DEMONITOR" -> I.NODE_DEMONITOR <$> intAt 1 parts
    "NODE_OBSERVE_STATE" -> I.NODE_OBSERVE_STATE <$> intAt 1 parts <*> intAt 2 parts
    "NODE_LAST_STATE_HASH" -> I.NODE_LAST_STATE_HASH <$> intAt 1 parts <*> intAt 2 parts
    "NODE_LAST_SEEN_TICK" -> I.NODE_LAST_SEEN_TICK <$> intAt 1 parts <*> intAt 2 parts
    "NODE_QUERY_STATE" -> I.NODE_QUERY_STATE <$> intAt 1 parts <*> intAt 2 parts
    "MACHINE_NEW" -> I.MACHINE_NEW <$> intAt 1 parts <*> stringAt 2 parts <*> intAt 3 parts
    "MACHINE_STATE" -> I.MACHINE_STATE <$> intAt 1 parts <*> intAt 2 parts
    "MACHINE_TRANSITION" -> I.MACHINE_TRANSITION <$> intAt 1 parts <*> intAt 2 parts <*> stringAt 3 parts
    "ASSERT" -> I.ASSERT <$> intAt 1 parts <*> intAt 2 parts
    "ASSUME" -> I.ASSUME <$> intAt 1 parts <*> stringAt 2 parts
    "INVARIANT_CHECK" -> I.INVARIANT_CHECK <$> stringAt 1 parts
    "PROOF_MARK" -> I.PROOF_MARK <$> stringAt 1 parts <*> intAt 2 parts
    "PROOF_SCOPE_BEGIN" -> I.PROOF_SCOPE_BEGIN <$> stringAt 1 parts
    "PROOF_SCOPE_END" -> I.PROOF_SCOPE_END <$> stringAt 1 parts
    _ -> Left ("Unsupported instruction opcode: " <> op)

decodeValue :: Json.Json -> Either String Value
decodeValue json =
  Json.caseJson
    (\_ -> Right VUnit)
    (Right <<< VBool)
    decodeNumberValue
    (Right <<< VString)
    (map (VList <<< Vec.fromArray) <<< traverse decodeValue)
    decodeObjectValue
    json

decodeNumberValue :: Number -> Either String Value
decodeNumberValue n = case Int.fromNumber n of
  Just i -> Right (VInt (BigInt.fromInt i))
  Nothing -> Left ("JSON numbers used as VM integers must be safe whole Ints: " <> show n)

decodeObjectValue :: Object Json.Json -> Either String Value
decodeObjectValue object =
  case firstTaggedKey of
    Just (Tuple key value) -> decodeTagged key value
    Nothing -> VRecord <$> traverseObject decodeValue object
  where
    -- Tags emitted by `valueToJson`, in lookup order. The first one present
    -- determines the value's type; an object with none is treated as a record.
    taggedKeys = [ "int", "fixed", "rational", "bool", "string", "symbol", "bytes", "list", "map", "record", "variant" ]

    firstTaggedKey =
      Array.findMap (\k -> Tuple k <$> Object.lookup k object) taggedKeys

    decodeTagged key value = case key of
      "int" -> decodeIntValue value
      "fixed" -> decodeFixed value
      "rational" -> decodeRational value
      "bool" -> VBool <$> asBool "bool" value
      "string" -> VString <$> asString "string" value
      "symbol" -> VSymbol <$> asString "symbol" value
      "bytes" -> VBytes <$> (asArray "bytes" value >>= traverse asByte)
      "list" -> (VList <<< Vec.fromArray) <$> (asArray "list" value >>= traverse decodeValue)
      "map" -> decodeMap value
      "record" -> VRecord <$> decodeStringMapValue "record" value
      "variant" -> decodeVariant value
      _ -> VRecord <$> traverseObject decodeValue object

decodeMap :: Json.Json -> Either String Value
decodeMap json = do
  entries <- asArray "map" json
  pairs <- traverse decodeMapEntry entries
  pure (VMap (Map.fromFoldable pairs))

decodeMapEntry :: Json.Json -> Either String (Tuple Value Value)
decodeMapEntry json = do
  obj <- asObject "map entry" json
  key <- case Object.lookup "key" obj of
    Just k -> decodeValue k
    Nothing -> Left "map entry missing key"
  value <- case Object.lookup "value" obj of
    Just v -> decodeValue v
    Nothing -> Left "map entry missing value"
  pure (Tuple key value)

decodeIntValue :: Json.Json -> Either String Value
decodeIntValue json = do
  text <- case Json.toString json of
    Just s -> pure s
    Nothing -> case Json.toNumber json >>= Int.fromNumber of
      Just i -> pure (show i)
      Nothing -> Left "int value must be a decimal string or safe integer"
  case BigInt.fromString text of
    Just value -> pure (VInt value)
    Nothing -> Left ("Invalid integer literal: " <> text)

decodeFixed :: Json.Json -> Either String Value
decodeFixed json = do
  obj <- asObject "fixed" json
  value <- requiredBigInt "value" obj
  scale <- case Object.lookup "scale" obj of
    Just s -> asInt "scale" s
    Nothing -> Left "Missing field: scale"
  pure (VFixed { value, scale })

decodeRational :: Json.Json -> Either String Value
decodeRational json = do
  obj <- asObject "rational" json
  numerator <- requiredBigInt "numerator" obj
  denominator <- requiredBigInt "denominator" obj
  pure (VRational { numerator, denominator })

requiredBigInt :: String -> Object Json.Json -> Either String BigInt.BigInt
requiredBigInt key obj = do
  text <- requiredString key obj
  case BigInt.fromString text of
    Just value -> pure value
    Nothing -> Left ("Invalid integer literal for " <> key <> ": " <> text)

decodeVariant :: Json.Json -> Either String Value
decodeVariant json = do
  object <- asObject "variant" json
  tag <- requiredString "tag" object
  payload <- case Object.lookup "payload" object of
    Just value -> decodeValue value
    Nothing -> pure VUnit
  pure (VVariant tag payload)

decodeStringMapValue :: String -> Json.Json -> Either String (Map String Value)
decodeStringMapValue label json = asObject label json >>= traverseObject decodeValue

traverseObject :: forall a. (Json.Json -> Either String a) -> Object Json.Json -> Either String (Map String a)
traverseObject f object =
  Map.fromFoldable <$> traverse decodePair (Object.toAscUnfoldable object :: Array (Tuple String Json.Json))
  where
    decodePair (Tuple key value) = Tuple key <$> f value

decodeLimits :: Object Json.Json -> Either String EvalLimits
decodeLimits object = do
  maxSteps <- optionalNestedInt "limits" "maxSteps" object <#> fromMaybe 10000
  pure
    { maxSteps
    , maxCallDepth: 256
    , maxProcesses: 1024
    , maxProcessStepsPerSlice: 100
    , maxRegistersPerFrame: 1024
    , maxFrames: 1024
    , maxListLength: 100000
    , maxMapSize: 100000
    , maxRecordFields: 10000
    , maxValueDepth: 100
    , maxStateEntries: 100000
    , maxTraceEvents: 100000
    , maxProofEvents: 100000
    , maxMailboxSize: 10000
    , maxRemoteNodes: 1024
    , maxEventsEmitted: 10000
    , maxEffectsRequested: 10000
    }

valueToJson :: Value -> Json.Json
valueToJson = case _ of
  VUnit -> Json.jsonNull
  VBool b -> objectJson [ Tuple "bool" (Json.fromBoolean b) ]
  VInt i -> objectJson [ Tuple "int" (Json.fromString (BigInt.toString i)) ]
  VFixed f -> objectJson
    [ Tuple "fixed" (objectJson [ Tuple "value" (Json.fromString (BigInt.toString f.value)), Tuple "scale" (Json.fromNumber (Int.toNumber f.scale)) ])
    ]
  VRational r -> objectJson
    [ Tuple "rational" (objectJson [ Tuple "numerator" (Json.fromString (BigInt.toString r.numerator)), Tuple "denominator" (Json.fromString (BigInt.toString r.denominator)) ])
    ]
  VString s -> objectJson [ Tuple "string" (Json.fromString s) ]
  VBytes bytes -> objectJson [ Tuple "bytes" (Json.fromArray (map (Json.fromNumber <<< Int.toNumber) bytes)) ]
  VSymbol s -> objectJson [ Tuple "symbol" (Json.fromString s) ]
  VList values -> objectJson [ Tuple "list" (Json.fromArray (map valueToJson (Vec.toArray values))) ]
  VMap values -> objectJson [ Tuple "map" (Json.fromArray (map mapEntryToJson (Map.toUnfoldable values :: Array (Tuple Value Value)))) ]
  VRecord values -> objectJson [ Tuple "record" (stringMapToJson values) ]
  VVariant tag payload -> objectJson [ Tuple "variant" (objectJson [ Tuple "tag" (Json.fromString tag), Tuple "payload" (valueToJson payload) ]) ]
  VOption Nothing -> objectJson [ Tuple "option" Json.jsonNull ]
  VOption (Just value) -> objectJson [ Tuple "option" (valueToJson value) ]
  VResult (Left value) -> objectJson [ Tuple "error" (valueToJson value) ]
  VResult (Right value) -> objectJson [ Tuple "ok" (valueToJson value) ]
  VFunctionRef id -> objectJson [ Tuple "function" (Json.fromString id) ]
  VProcessRef pid -> objectJson [ Tuple "process" (Json.fromString pid) ]
  VRemoteProcessRef ref -> objectJson [ Tuple "remoteProcess" (Json.fromString ref.pid) ]
  VStateMachineInstance instance_ -> objectJson [ Tuple "stateMachine" (Json.fromString instance_.instanceId) ]
  VEvent event -> objectJson [ Tuple "event" (objectJson [ Tuple "type" (Json.fromString event.type_), Tuple "payload" (valueToJson event.payload) ]) ]
  VEffectIntent effect -> objectJson [ Tuple "effect" (objectJson [ Tuple "type" (Json.fromString effect.type_), Tuple "payload" (valueToJson effect.payload) ]) ]
  VProofValue proof -> objectJson [ Tuple "proof" (objectJson [ Tuple "label" (Json.fromString proof.label), Tuple "value" (valueToJson proof.value) ]) ]

mapEntryToJson :: Tuple Value Value -> Json.Json
mapEntryToJson (Tuple key value) =
  objectJson [ Tuple "key" (valueToJson key), Tuple "value" (valueToJson value) ]

stringMapToJson :: Map String Value -> Json.Json
stringMapToJson values =
  objectJson (map (\(Tuple key value) -> Tuple key (valueToJson value)) (Map.toUnfoldable values :: Array (Tuple String Value)))

objectJson :: Array (Tuple String Json.Json) -> Json.Json
objectJson = Json.fromObject <<< Object.fromFoldable

optionalObjectMap :: String -> Object Json.Json -> (Json.Json -> Either String Value) -> Either String (Map String Value)
optionalObjectMap key object f = case Object.lookup key object of
  Nothing -> pure Map.empty
  Just value -> asObject key value >>= traverseObject f

optionalStringWithDefault :: String -> String -> Object Json.Json -> Either String String
optionalStringWithDefault key fallback object = case Object.lookup key object of
  Nothing -> pure fallback
  Just value -> asString key value

optionalInt :: String -> Object Json.Json -> Either String (Maybe Int)
optionalInt key object = case Object.lookup key object of
  Nothing -> pure Nothing
  Just value -> Just <$> asInt key value

optionalBool :: String -> Object Json.Json -> Either String (Maybe Boolean)
optionalBool key object = case Object.lookup key object of
  Nothing -> pure Nothing
  Just value -> Just <$> asBool key value

optionalNestedInt :: String -> String -> Object Json.Json -> Either String (Maybe Int)
optionalNestedInt objectKey key object = case Object.lookup objectKey object >>= Json.toObject of
  Nothing -> pure Nothing
  Just nested -> optionalInt key nested

requiredString :: String -> Object Json.Json -> Either String String
requiredString key object = case Object.lookup key object of
  Just value -> asString key value
  Nothing -> Left ("Missing string field: " <> key)

stringAt :: Int -> Array Json.Json -> Either String String
stringAt index values = at index values >>= asString ("argument " <> show index)

intAt :: Int -> Array Json.Json -> Either String Int
intAt index values = at index values >>= asInt ("argument " <> show index)

boolAt :: Int -> Array Json.Json -> Either String Boolean
boolAt index values = at index values >>= asBool ("argument " <> show index)

intArrayAt :: Int -> Array Json.Json -> Either String (Array Int)
intArrayAt index values = at index values >>= asArray ("argument " <> show index) >>= traverse (asInt ("argument " <> show index <> "[]"))

roundingAt :: Int -> Array Json.Json -> Either String Rounding
roundingAt index values = do
  name <- stringAt index values
  case name of
    "RoundDown" -> pure RoundDown
    "RoundUp" -> pure RoundUp
    "RoundHalfEven" -> pure RoundHalfEven
    "RoundTowardZero" -> pure RoundTowardZero
    "RoundAwayFromZero" -> pure RoundAwayFromZero
    _ -> Left ("Unknown rounding mode: " <> name)

at :: Int -> Array Json.Json -> Either String Json.Json
at index values = case Array.index values index of
  Just value -> pure value
  Nothing -> Left ("Missing argument " <> show index)

asObject :: String -> Json.Json -> Either String (Object Json.Json)
asObject label value = case Json.toObject value of
  Just object -> pure object
  Nothing -> Left (label <> " must be an object")

asArray :: String -> Json.Json -> Either String (Array Json.Json)
asArray label value = case Json.toArray value of
  Just array -> pure array
  Nothing -> Left (label <> " must be an array")

asString :: String -> Json.Json -> Either String String
asString label value = case Json.toString value of
  Just string -> pure string
  Nothing -> Left (label <> " must be a string")

asBool :: String -> Json.Json -> Either String Boolean
asBool label value = case Json.toBoolean value of
  Just bool -> pure bool
  Nothing -> Left (label <> " must be a boolean")

asInt :: String -> Json.Json -> Either String Int
asInt label value = case Json.toNumber value >>= Int.fromNumber of
  Just int -> pure int
  Nothing -> Left (label <> " must be a safe integer")

asByte :: Json.Json -> Either String Int
asByte value = do
  byte <- asInt "byte" value
  if byte >= 0 && byte <= 255 then pure byte else Left ("byte out of range: " <> show byte)

renderVMError :: VMError -> String
renderVMError (VMError code details) = show code <> ": " <> details
