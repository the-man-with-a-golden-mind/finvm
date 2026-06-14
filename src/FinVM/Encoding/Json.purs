module FinVM.Encoding.Json
  ( decodeProgramFile
  , runJsonProgram
  , runJsonProgramResult
  , runEffectStep
  , runEffectStart
  , runEffectResume
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
import Data.Foldable (any) as Foldable
import Data.Int as Int
import Data.List as List
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as String
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
import FinVM.Process (Process, ProcessStatus(..), WaitCondition(..))
import FinVM.Process.Scheduler as Scheduler
import FinVM.Encoding.Resume (encodeMachineState, decodeMachineState)
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

-- | Rich entry point for the host EFFECT DRIVER. Runs the program once with the
-- | given input/state overrides merged on top of the program's own, and returns
-- | JSON exposing everything the driver needs to fulfil effects and resume:
-- |   { status, steps, result, state, events:[{type_,payload}], outbox:[{type_,payload}] }
-- | `events` and `outbox` are returned in emit/request order. The driver performs
-- | the outbox intents, writes each result into `input` under the intent's
-- | correlation key, carries `state` forward, and calls this again until the
-- | outbox yields no new effects. The VM core stays pure; only the driver is
-- | effectful. `overridesSource` is "" or a JSON object { "input": {..}, "state": {..} }
-- | whose values use the tagless Value encoding.
runEffectStep :: String -> String -> String
runEffectStep programSource overridesSource =
  case decodeProgramFile programSource of
    Left err -> failStr "error" err
    Right file -> case decodeOverrides overridesSource of
      Left err -> failStr "error" err
      Right ov ->
        let
          base = initialMachine file
          m0 = base { input = Map.union ov.inputOv base.input
                    , state = Map.union ov.stateOv base.state }
        in case Eval.runMachine m0 of
          Left vmErr -> failStr "failed" (renderVMError vmErr)
          Right m -> Json.stringify $ objectJson
            [ Tuple "status" (Json.fromString "completed")
            , Tuple "steps" (Json.fromNumber (Int.toNumber m.counters.steps))
            , Tuple "result" (valueToJson (mainResult m))
            , Tuple "state" (stringMapToJson m.state)
            , Tuple "events" (Json.fromArray (taggedPayloadToJson <$> orderedList m.events))
            , Tuple "outbox" (Json.fromArray (taggedPayloadToJson <$> orderedList m.outbox))
            ]
  where
    failStr status msg = Json.stringify $ objectJson
      [ Tuple "status" (Json.fromString status), Tuple "error" (Json.fromString msg) ]

-- Lists in the machine (events/outbox) are built with cons (reverse order); turn
-- them into an array in emit/request order.
orderedList :: forall a. List.List a -> Array a
orderedList = Array.reverse <<< List.toUnfoldable

-- Event and EffectIntent are both { type_ :: String, payload :: Value }.
taggedPayloadToJson :: { type_ :: String, payload :: Value } -> Json.Json
taggedPayloadToJson t = objectJson
  [ Tuple "type_" (Json.fromString t.type_)
  , Tuple "payload" (valueToJson t.payload)
  ]

decodeOverrides :: String -> Either String { inputOv :: Map String Value, stateOv :: Map String Value }
decodeOverrides s =
  if s == "" then Right { inputOv: Map.empty, stateOv: Map.empty }
  else do
    root <- jsonParser s
    obj <- asObject "overrides" root
    inputOv <- optionalObjectMap "input" obj decodeValue
    stateOv <- optionalObjectMap "state" obj decodeValue
    pure { inputOv, stateOv }

-- ===========================================================================
-- ASYNC EFFECT MODEL: suspend/resume (per-process), not whole-program re-run.
-- runEffectStart runs to quiescence; runEffectResume delivers effect results as
-- mailbox messages and continues from a snapshot. See docs/EFFECTS.md.
-- ===========================================================================

effectFail :: String -> String -> String
effectFail status msg = Json.stringify $ objectJson
  [ Tuple "status" (Json.fromString status), Tuple "error" (Json.fromString msg) ]

-- | Start a fresh async-effect run: build the machine, run to quiescence, classify.
runEffectStart :: String -> String -> String
runEffectStart programSource overridesSource =
  case decodeProgramFile programSource of
    Left err -> effectFail "error" err
    Right file -> case decodeOverrides overridesSource of
      Left err -> effectFail "error" err
      Right ov ->
        let
          base = initialMachine file
          m0 = base { input = Map.union ov.inputOv base.input, state = Map.union ov.stateOv base.state }
        in case Eval.runUntilQuiescent m0 of
          Left vmErr -> effectFail "failed" (renderVMError vmErr)
          Right m -> quiescedOutput m

-- | Resume from a snapshot, delivering effect results to processes' mailboxes,
-- | then run to quiescence again.
runEffectResume :: String -> String -> String -> String
runEffectResume programSource snapshotSource deliveriesSource =
  case decodeProgramFile programSource of
    Left err -> effectFail "error" err
    Right file -> case jsonParser snapshotSource of
      Left perr -> effectFail "error" ("snapshot parse: " <> perr)
      Right snapJson -> case decodeMachineState (initialMachine file) snapJson of
        Left derr -> effectFail "error" ("snapshot decode: " <> derr)
        Right m1 -> case decodeDeliveries deliveriesSource of
          Left err -> effectFail "error" err
          Right ds ->
            let m2 = Array.foldl applyDelivery m1 ds
            in case Eval.runUntilQuiescent m2 of
              Left vmErr -> effectFail "failed" (renderVMError vmErr)
              Right m -> quiescedOutput m

-- | Serialize a quiescent machine: status + resumable snapshot + pending effects
-- | (request order) + events + result + state.
quiescedOutput :: Machine -> String
quiescedOutput m =
  let
    pending = orderedList m.outbox
    anyAlive = Foldable.any (not <<< isTerminal <<< _.status) (Map.values m.scheduler.processes)
    status =
      if not (Array.null pending) then "suspended"
      else if anyAlive then "deadlock"
      else "completed"
  in Json.stringify $ objectJson
    [ Tuple "status" (Json.fromString status)
    , Tuple "snapshot" (encodeMachineState m)
    , Tuple "pending" (Json.fromArray (pendingEntry <$> pending))
    , Tuple "events" (Json.fromArray (taggedPayloadToJson <$> orderedList m.events))
    , Tuple "result" (valueToJson (mainResult m))
    , Tuple "state" (stringMapToJson m.state)
    ]
  where
    isTerminal s = case s of
      ProcessCompleted _ -> true
      ProcessFailed _ -> true
      ProcessCancelled _ -> true
      ProcessExited _ -> true
      _ -> false

-- An outbox effect intent is tagged { pid, key, payload } by EFFECT_AWAIT.
pendingEntry :: { type_ :: String, payload :: Value } -> Json.Json
pendingEntry e =
  let
    fields = case e.payload of
      VRecord f -> f
      _ -> Map.empty
    getStr k = case Map.lookup k fields of
      Just (VString s) -> s
      _ -> ""
    getVal k = case Map.lookup k fields of
      Just v -> v
      _ -> VUnit
    isAwaitTagged =
      case Map.lookup "key" fields, Map.lookup "payload" fields of
        Just (VString _), Just _ -> true
        _, _ -> false
    pidVal =
      if isAwaitTagged then getStr "pid"
      else case Map.lookup "pid" fields of
        Just (VString s) -> s
        _ -> ""
    keyVal =
      if isAwaitTagged then getStr "key" else ""
    payloadVal =
      if isAwaitTagged then getVal "payload" else e.payload
  in objectJson
    [ Tuple "pid" (Json.fromString pidVal)
    , Tuple "key" (Json.fromString keyVal)
    , Tuple "type_" (Json.fromString e.type_)
    , Tuple "payload" (valueToJson payloadVal)
    ]

decodeDeliveries :: String -> Either String
  (Array
    { pid :: Maybe String
    , key :: Maybe String
    , result :: Maybe Value
    , message :: Maybe Value
    , disconnect :: Maybe { node :: String, reason :: String }
    })
decodeDeliveries s =
  if s == "" then Right []
  else do
    root <- jsonParser s
    arr <- asArray "deliveries" root
    traverse decodeDelivery arr

decodeDelivery :: Json.Json -> Either String
  { pid :: Maybe String
  , key :: Maybe String
  , result :: Maybe Value
  , message :: Maybe Value
  , disconnect :: Maybe { node :: String, reason :: String }
  }
decodeDelivery j = do
  o <- asObject "delivery" j
  pid <- case Object.lookup "pid" o of
    Just p -> Just <$> asString "pid" p
    Nothing -> Right Nothing
  result <- case Object.lookup "result" o of
    Just r -> Just <$> decodeValue r
    Nothing -> Right Nothing
  message <- case Object.lookup "message" o of
    Just r -> Just <$> decodeValue r
    Nothing -> Right Nothing
  key <- case Object.lookup "key" o of
    Just k -> Just <$> asString "key" k
    Nothing -> Right Nothing
  disconnect <- case Object.lookup "disconnect" o of
    Nothing -> Right Nothing
    Just d -> do
      dobj <- asObject "disconnect" d
      node <- requiredString "node" dobj
      reason <- case Object.lookup "reason" dobj of
        Just r -> asString "disconnect.reason" r
        Nothing -> pure "noconnection"
      pure (Just { node, reason })
  pure { pid, key, result, message, disconnect }

-- Deliver an effect result to a process: append an EffectReply message to its
-- mailbox and wake it if it was parked on this effect's key.
applyDelivery :: Machine -> { pid :: Maybe String, key :: Maybe String, result :: Maybe Value, message :: Maybe Value, disconnect :: Maybe { node :: String, reason :: String } } -> Machine
applyDelivery m d = case d.disconnect of
  Just disc -> applyDisconnectDelivery m disc
  Nothing -> case d.pid of
    Nothing -> m
    Just pid -> case Scheduler.findProcess m.scheduler pid of
      Nothing -> m
      Just p -> case d.message, d.key of
        -- Generic mailbox delivery (used by cross-VM actor messaging).
        Just msg, _ ->
          let
            wokenFor = case p.status of
              ProcessWaiting WaitingForMessage -> true
              _ -> false
            p' = p
              { mailbox = Array.snoc p.mailbox msg
              , status = if wokenFor then ProcessReady else p.status
              }
            s1 = Scheduler.updateProcess m.scheduler p'
            s2 = if wokenFor then Scheduler.yieldProcess s1 pid else s1
          in m { scheduler = s2 }
        -- Effect reply delivery (existing EFFECT_AWAIT path).
        _, Just key ->
          let
            value = fromMaybe VUnit d.result
            reply = VVariant "EffectReply" (VRecord (Map.fromFoldable [ Tuple "key" (VString key), Tuple "value" value ]))
            wokenFor = case p.status of
              ProcessWaiting (WaitingOnEffect k) -> k == key
              _ -> false
            p' = p
              { mailbox = Array.snoc p.mailbox reply
              , status = if wokenFor then ProcessReady else p.status
              }
            s1 = Scheduler.updateProcess m.scheduler p'
            s2 = if wokenFor then Scheduler.yieldProcess s1 pid else s1
          in m { scheduler = s2 }
        -- Nothing to apply.
        _, _ -> m

remoteMonitorPrefix :: String
remoteMonitorPrefix = "__remote__:"

decodeRemoteMonitorTarget :: String -> Maybe { node :: String, pid :: String }
decodeRemoteMonitorTarget target = do
  rest <- String.stripPrefix (String.Pattern remoteMonitorPrefix) target
  idx <- String.lastIndexOf (String.Pattern ":") rest
  let
    node = String.take idx rest
    pid = String.drop (idx + 1) rest
  if node == "" || pid == "" then Nothing else Just { node, pid }

downMessage :: String -> String -> String -> Value
downMessage ref pid reason =
  VVariant "DOWN" (VRecord (Map.fromFoldable
    [ Tuple "ref" (VString ref)
    , Tuple "pid" (VString pid)
    , Tuple "reason" (VString reason)
    ]))

applyDisconnectDelivery :: Machine -> { node :: String, reason :: String } -> Machine
applyDisconnectDelivery m disc =
  let
    processes = Map.values m.scheduler.processes
    step scheduler p =
      let
        deadRefs = Array.mapMaybe (\(Tuple ref target) ->
          case decodeRemoteMonitorTarget target of
            Just remote | remote.node == disc.node -> Just (Tuple ref remote.pid)
            _ -> Nothing
        ) (Map.toUnfoldable p.monitors :: Array (Tuple String String))
      in case Array.null deadRefs of
        true -> scheduler
        false ->
          let
            downs = map (\(Tuple ref remotePid) -> downMessage ref remotePid disc.reason) deadRefs
            dropped = Array.foldl (\acc (Tuple ref _) -> Map.delete ref acc) p.monitors deadRefs
            wakesMailbox = case p.status of
              ProcessWaiting WaitingForMessage -> true
              ProcessWaiting (WaitingForMonitor _) -> true
              _ -> false
            p' = p
              { mailbox = p.mailbox <> downs
              , monitors = dropped
              , status = if wakesMailbox then ProcessReady else p.status
              }
            s1 = Scheduler.updateProcess scheduler p'
          in if wakesMailbox then Scheduler.yieldProcess s1 p.pid else s1
  in m { scheduler = Array.foldl step m.scheduler (Array.fromFoldable processes) }

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
    "EFFECT_AWAIT" -> I.EFFECT_AWAIT <$> intAt 1 parts
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

-- | Decode the optional top-level `limits` object. Every field is optional and
-- | falls back to its default; an absent `limits` object uses all defaults.
decodeLimits :: Object Json.Json -> Either String EvalLimits
decodeLimits object = do
  let
    limitsObj = Object.lookup "limits" object >>= Json.toObject
    lim name def = case limitsObj of
      Nothing -> pure def
      Just lo -> optionalInt name lo <#> fromMaybe def
  maxSteps <- lim "maxSteps" 10000
  maxCallDepth <- lim "maxCallDepth" 256
  maxProcesses <- lim "maxProcesses" 1024
  maxProcessStepsPerSlice <- lim "maxProcessStepsPerSlice" 100
  maxRegistersPerFrame <- lim "maxRegistersPerFrame" 1024
  maxFrames <- lim "maxFrames" 1024
  maxListLength <- lim "maxListLength" 100000
  maxMapSize <- lim "maxMapSize" 100000
  maxRecordFields <- lim "maxRecordFields" 10000
  maxValueDepth <- lim "maxValueDepth" 100
  maxStateEntries <- lim "maxStateEntries" 100000
  maxTraceEvents <- lim "maxTraceEvents" 100000
  maxProofEvents <- lim "maxProofEvents" 100000
  maxMailboxSize <- lim "maxMailboxSize" 10000
  maxRemoteNodes <- lim "maxRemoteNodes" 1024
  maxEventsEmitted <- lim "maxEventsEmitted" 10000
  maxEffectsRequested <- lim "maxEffectsRequested" 10000
  pure
    { maxSteps
    , maxCallDepth
    , maxProcesses
    , maxProcessStepsPerSlice
    , maxRegistersPerFrame
    , maxFrames
    , maxListLength
    , maxMapSize
    , maxRecordFields
    , maxValueDepth
    , maxStateEntries
    , maxTraceEvents
    , maxProofEvents
    , maxMailboxSize
    , maxRemoteNodes
    , maxEventsEmitted
    , maxEffectsRequested
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
