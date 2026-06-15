module Test.Effects (spec) where

import Prelude
import Data.Argonaut.Core as Json
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (any)
import Data.Maybe (Maybe(..), isJust)
import Foreign.Object as Object
import FinVM.Encoding.Json (runEffectStep, runEffectStart, runEffectResume)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

-- Program that builds an http.get effect intent (payload carries the "key"
-- correlation field) and requests it, then returns. Never reads input.
emitProgram :: String
emitProgram =
  """
  {
    "version": "1.0",
    "registerCount": 5,
    "constants": [ { "string": "r1" }, { "string": "http://x" } ],
    "instructions": [
      ["RECORD_NEW", 0],
      ["LOAD_CONST", 1, 0],
      ["RECORD_SET", 0, 0, "key", 1],
      ["LOAD_CONST", 2, 1],
      ["RECORD_SET", 0, 0, "url", 2],
      ["EFFECT_NEW", 3, "http.get", 0],
      ["EFFECT_REQUEST", 3],
      ["RETURN", 0]
    ]
  }
  """

-- Program that reads a result delivered via input under key "r1".
readProgram :: String
readProgram =
  """
  {
    "version": "1.0",
    "registerCount": 1,
    "constants": [],
    "instructions": [ ["LOAD_INPUT", 0, "r1"], ["RETURN", 0] ]
  }
  """

-- Async-effect program: build an http.get intent (key "k1"), EFFECT_AWAIT it
-- (suspends), then on resume PROC_RECEIVE the EffectReply and return reply.value.
awaitProgram :: String
awaitProgram =
  """
  {
    "version": "1.0",
    "registerCount": 6,
    "constants": [ { "string": "k1" }, { "string": "http://u" } ],
    "instructions": [
      ["RECORD_NEW", 0],
      ["LOAD_CONST", 1, 0],
      ["RECORD_SET", 0, 0, "key", 1],
      ["LOAD_CONST", 2, 1],
      ["RECORD_SET", 0, 0, "url", 2],
      ["EFFECT_NEW", 3, "http.get", 0],
      ["EFFECT_AWAIT", 3],
      ["PROC_RECEIVE", 4],
      ["VARIANT_PAYLOAD", 5, 4],
      ["RECORD_GET", 4, 5, "value"],
      ["RETURN", 4]
    ]
  }
  """

-- Main awaits an effect while a sibling process keeps making progress and
-- increments state.ticks to 3.
twoActorAwaitProgram :: String
twoActorAwaitProgram =
  """
  {
    "version": "1.0",
    "entrypoint": "main",
    "constants": [ { "int": "0" }, { "string": "k1" }, { "string": "http://u" }, { "int": "1" }, { "int": "3" } ],
    "functions": {
      "main": {
        "registerCount": 5,
        "instructions": [
          ["LOAD_CONST", 0, 0],
          ["STATE_SET", "ticks", 0],
          ["PROC_SPAWN", 1, "ticker", []],
          ["RECORD_NEW", 0],
          ["LOAD_CONST", 2, 1],
          ["RECORD_SET", 0, 0, "key", 2],
          ["LOAD_CONST", 2, 2],
          ["RECORD_SET", 0, 0, "url", 2],
          ["EFFECT_NEW", 3, "http.get", 0],
          ["EFFECT_AWAIT", 3],
          ["PROC_RECEIVE", 4],
          ["RETURN", 4]
        ]
      },
      "ticker": {
        "registerCount": 4,
        "instructions": [
          ["LABEL", "loop"],
          ["STATE_GET", 0, "ticks"],
          ["LOAD_CONST", 1, 3],
          ["ADD", 0, 0, 1],
          ["STATE_SET", "ticks", 0],
          ["PROC_YIELD"],
          ["LOAD_CONST", 2, 4],
          ["LT", 3, 0, 2],
          ["JUMP_IF", 3, "loop"],
          ["RETURN", 0]
        ]
      }
    }
  }
  """

-- Ensures snapshot/resume preserves mailbox contents that existed before await.
mailboxSurvivalProgram :: String
mailboxSurvivalProgram =
  """
  {
    "version": "1.0",
    "entrypoint": "main",
    "constants": [ { "string": "pre" }, { "string": "k1" }, { "string": "http://u" } ],
    "functions": {
      "main": {
        "registerCount": 5,
        "instructions": [
          ["PROC_SELF", 4],
          ["PROC_SPAWN", 3, "sender", [4]],
          ["RECORD_NEW", 0],
          ["LOAD_CONST", 1, 1],
          ["RECORD_SET", 0, 0, "key", 1],
          ["LOAD_CONST", 1, 2],
          ["RECORD_SET", 0, 0, "url", 1],
          ["EFFECT_NEW", 2, "http.get", 0],
          ["EFFECT_AWAIT", 2],
          ["PROC_RECEIVE", 3],
          ["RETURN", 3]
        ]
      },
      "sender": {
        "arity": 1,
        "registerCount": 2,
        "instructions": [
          ["LOAD_CONST", 1, 0],
          ["PROC_SEND", 0, 1],
          ["RETURN", 1]
        ]
      }
    }
  }
  """

-- Two processes await independently; replay remains deterministic even when
-- deliveries are supplied in reverse order.
outOfOrderReplayProgram :: String
outOfOrderReplayProgram =
  """
  {
    "version": "1.0",
    "entrypoint": "main",
    "constants": [ { "string": "k0" }, { "string": "k1" }, { "string": "u0" }, { "string": "u1" } ],
    "functions": {
      "main": {
        "registerCount": 8,
        "instructions": [
          ["PROC_SPAWN", 0, "w0", []],
          ["PROC_SPAWN", 1, "w1", []],
          ["PROC_JOIN", 5, 0],
          ["PROC_JOIN", 5, 1],
          ["PROC_JOIN_RESULT", 2, 0],
          ["PROC_JOIN_RESULT", 3, 1],
          ["RECORD_NEW", 4],
          ["RECORD_SET", 4, 4, "a", 2],
          ["RECORD_SET", 4, 4, "b", 3],
          ["RETURN", 4]
        ]
      },
      "w0": {
        "registerCount": 6,
        "instructions": [
          ["RECORD_NEW", 0],
          ["LOAD_CONST", 1, 0],
          ["RECORD_SET", 0, 0, "key", 1],
          ["LOAD_CONST", 2, 2],
          ["RECORD_SET", 0, 0, "url", 2],
          ["EFFECT_NEW", 3, "http.get", 0],
          ["EFFECT_AWAIT", 3],
          ["PROC_RECEIVE", 4],
          ["VARIANT_PAYLOAD", 5, 4],
          ["RECORD_GET", 4, 5, "value"],
          ["RETURN", 4]
        ]
      },
      "w1": {
        "registerCount": 6,
        "instructions": [
          ["RECORD_NEW", 0],
          ["LOAD_CONST", 1, 1],
          ["RECORD_SET", 0, 0, "key", 1],
          ["LOAD_CONST", 2, 3],
          ["RECORD_SET", 0, 0, "url", 2],
          ["EFFECT_NEW", 3, "http.get", 0],
          ["EFFECT_AWAIT", 3],
          ["PROC_RECEIVE", 4],
          ["VARIANT_PAYLOAD", 5, 4],
          ["RECORD_GET", 4, 5, "value"],
          ["RETURN", 4]
        ]
      }
    }
  }
  """

remoteMonitorDisconnectProgram :: String
remoteMonitorDisconnectProgram =
  """
  {
    "version": "1.0",
    "registerCount": 7,
    "constants": [ { "string": "other" }, { "string": "p42" } ],
    "instructions": [
      ["LOAD_CONST", 1, 0],
      ["LOAD_CONST", 2, 1],
      ["REMOTE_PID_NEW", 0, 1, 2],
      ["NODE_MONITOR", 3, 0],
      ["PROC_RECEIVE", 4],
      ["VARIANT_PAYLOAD", 5, 4],
      ["RECORD_GET", 6, 5, "reason"],
      ["RETURN", 6]
    ]
  }
  """

remoteDemonitorNoIntentProgram :: String
remoteDemonitorNoIntentProgram =
  """
  {
    "version": "1.0",
    "registerCount": 8,
    "constants": [ { "string": "other" }, { "string": "p42" }, { "string": "missing-ref" } ],
    "instructions": [
      ["LOAD_CONST", 1, 0],
      ["LOAD_CONST", 2, 1],
      ["REMOTE_PID_NEW", 0, 1, 2],
      ["NODE_MONITOR", 3, 0],
      ["LOAD_CONST", 4, 2],
      ["NODE_DEMONITOR", 4],
      ["PROC_RECEIVE", 5],
      ["VARIANT_PAYLOAD", 6, 5],
      ["RECORD_GET", 7, 6, "reason"],
      ["RETURN", 7]
    ]
  }
  """

nodeLifecycleDefaultsProgram :: String
nodeLifecycleDefaultsProgram =
  """
  {
    "version": "1.0",
    "registerCount": 8,
    "constants": [ { "string": "vmB" } ],
    "instructions": [
      ["LOAD_CONST", 1, 0],
      ["PROC_RECEIVE", 0],
      ["NODE_STATUS", 2, 1],
      ["NODE_LAST_SEEN_TICK", 3, 1],
      ["NODE_LAST_STATE_HASH", 4, 1],
      ["NODE_KNOWN", 5],
      ["RECORD_NEW", 6],
      ["RECORD_SET", 6, 6, "status", 2],
      ["RECORD_SET", 6, 6, "tick", 3],
      ["RECORD_SET", 6, 6, "hash", 4],
      ["RECORD_SET", 6, 6, "known", 5],
      ["RETURN", 6]
    ]
  }
  """

selectiveAwaitProgram :: String
selectiveAwaitProgram =
  """
  {
    "version": "1.0",
    "entrypoint": "main",
    "constants": [ { "string": "pre" }, { "string": "EffectReply" }, { "string": "k1" }, { "string": "http://u" } ],
    "functions": {
      "main": {
        "registerCount": 10,
        "instructions": [
          ["PROC_SELF", 9],
          ["PROC_SPAWN", 8, "sender", [9]],
          ["RECORD_NEW", 0],
          ["LOAD_CONST", 1, 2],
          ["RECORD_SET", 0, 0, "key", 1],
          ["LOAD_CONST", 1, 3],
          ["RECORD_SET", 0, 0, "url", 1],
          ["EFFECT_NEW", 3, "http.get", 0],
          ["EFFECT_AWAIT", 3],
          ["LOAD_CONST", 1, 1],
          ["PROC_RECEIVE_MATCH", 4, 1],
          ["VARIANT_PAYLOAD", 5, 4],
          ["RECORD_GET", 6, 5, "value"],
          ["PROC_RECEIVE", 7],
          ["RECORD_NEW", 0],
          ["RECORD_SET", 0, 0, "reply", 6],
          ["RECORD_SET", 0, 0, "normal", 7],
          ["RETURN", 0]
        ]
      },
      "sender": {
        "arity": 1,
        "registerCount": 2,
        "instructions": [
          ["LOAD_CONST", 1, 0],
          ["PROC_SEND", 0, 1],
          ["RETURN", 1]
        ]
      }
    }
  }
  """

receiveMatchBlockingProgram :: String
receiveMatchBlockingProgram =
  """
  {
    "version": "1.0",
    "registerCount": 4,
    "constants": [ { "string": "EffectReply" } ],
    "instructions": [
      ["LOAD_CONST", 1, 0],
      ["PROC_RECEIVE_MATCH", 0, 1],
      ["VARIANT_PAYLOAD", 2, 0],
      ["RECORD_GET", 3, 2, "value"],
      ["RETURN", 3]
    ]
  }
  """

receiveMatchOptProgram :: String
receiveMatchOptProgram =
  """
  {
    "version": "1.0",
    "registerCount": 2,
    "constants": [ { "string": "EffectReply" } ],
    "instructions": [
      ["LOAD_CONST", 1, 0],
      ["PROC_RECEIVE_MATCH_OPT", 0, 1],
      ["RETURN", 0]
    ]
  }
  """

obj :: String -> Maybe (Object.Object Json.Json)
obj s = case jsonParser s of
  Right j -> Json.toObject j
  Left _ -> Nothing

pendingKey :: Json.Json -> Maybe String
pendingKey j = Json.toObject j >>= Object.lookup "key" >>= Json.toString

pendingPid :: Json.Json -> Maybe String
pendingPid j = Json.toObject j >>= Object.lookup "pid" >>= Json.toString

spec :: Spec Unit
spec = do
  describe "FinVM effect driver contract (runEffectStep)" do
    it "exposes requested effect intents in the outbox (type_ + payload.key)" do
      let out = runEffectStep emitProgram ""
      case obj out of
        Nothing -> fail ("not an object: " <> out)
        Just o -> do
          (Object.lookup "status" o >>= Json.toString) `shouldEqual` Just "completed"
          let firstIntent = Object.lookup "outbox" o >>= Json.toArray >>= Array.head >>= Json.toObject
          (firstIntent >>= Object.lookup "type_" >>= Json.toString) `shouldEqual` Just "http.get"
          -- payload.record.key.string == "r1" (the correlation key)
          let keyField = firstIntent
                >>= Object.lookup "payload" >>= Json.toObject
                >>= Object.lookup "record" >>= Json.toObject
                >>= Object.lookup "key" >>= Json.toObject
                >>= Object.lookup "string" >>= Json.toString
          keyField `shouldEqual` Just "r1"

    it "delivers an injected input value to the program (correlation key)" do
      let out = runEffectStep readProgram """{ "input": { "r1": { "int": "42" } } }"""
      case obj out of
        Nothing -> fail ("not an object: " <> out)
        Just o -> do
          (Object.lookup "status" o >>= Json.toString) `shouldEqual` Just "completed"
          let resultInt = Object.lookup "result" o >>= Json.toObject
                >>= Object.lookup "int" >>= Json.toString
          resultInt `shouldEqual` Just "42"

    it "is deterministic: same program+overrides => identical output" do
      runEffectStep emitProgram "" `shouldEqual` runEffectStep emitProgram ""

    it "EFFECT_AWAIT suspends the process and reports the pending effect" do
      let out = runEffectStart awaitProgram ""
      case obj out of
        Nothing -> fail ("not an object: " <> out)
        Just o -> do
          (Object.lookup "status" o >>= Json.toString) `shouldEqual` Just "suspended"
          let first = Object.lookup "pending" o >>= Json.toArray >>= Array.head >>= Json.toObject
          (first >>= Object.lookup "kind" >>= Json.toString) `shouldEqual` Just "await_reply"
          (first >>= Object.lookup "pid" >>= Json.toString) `shouldEqual` Just "main"
          (first >>= Object.lookup "key" >>= Json.toString) `shouldEqual` Just "k1"
          (first >>= Object.lookup "type_" >>= Json.toString) `shouldEqual` Just "http.get"
          -- a resumable snapshot is present
          isJust (Object.lookup "snapshot" o >>= Json.toObject) `shouldEqual` true

    it "resume delivers the effect result as a mailbox message and completes" do
      let out1 = runEffectStart awaitProgram ""
      case obj out1 >>= Object.lookup "snapshot" of
        Nothing -> fail ("no snapshot in: " <> out1)
        Just snap -> do
          let snapStr = Json.stringify snap
              deliveries = """[{ "pid": "main", "key": "k1", "result": { "string": "BODY42" } }]"""
              out2 = runEffectResume awaitProgram snapStr deliveries
          case obj out2 of
            Nothing -> fail ("not an object: " <> out2)
            Just o -> do
              (Object.lookup "status" o >>= Json.toString) `shouldEqual` Just "completed"
              -- the program extracted reply.value and returned it
              let resStr = Object.lookup "result" o >>= Json.toObject >>= Object.lookup "string" >>= Json.toString
              resStr `shouldEqual` Just "BODY42"

    it "other actors keep progressing while one process is waiting on effect" do
      let out = runEffectStart twoActorAwaitProgram ""
      case obj out of
        Nothing -> fail ("not an object: " <> out)
        Just o -> do
          (Object.lookup "status" o >>= Json.toString) `shouldEqual` Just "suspended"
          let ticks = Object.lookup "state" o >>= Json.toObject
                >>= Object.lookup "ticks" >>= Json.toObject
                >>= Object.lookup "int" >>= Json.toString
          ticks `shouldEqual` Just "3"

    it "snapshot/resume preserves mailbox messages queued before await" do
      let out1 = runEffectStart mailboxSurvivalProgram ""
      case obj out1 >>= Object.lookup "snapshot" of
        Nothing -> fail ("no snapshot in: " <> out1)
        Just snap -> do
          let snapStr = Json.stringify snap
              deliveries = """[{ "pid": "main", "key": "k1", "result": { "string": "BODY42" } }]"""
              out2 = runEffectResume mailboxSurvivalProgram snapStr deliveries
          case obj out2 of
            Nothing -> fail ("not an object: " <> out2)
            Just o -> do
              (Object.lookup "status" o >>= Json.toString) `shouldEqual` Just "completed"
              -- If mailbox survives snapshot/resume, the first message is the
              -- pre-existing "pre" message (not the delivered EffectReply).
              let firstMsg = Object.lookup "result" o >>= Json.toObject
                    >>= Object.lookup "string" >>= Json.toString
              firstMsg `shouldEqual` Just "pre"

    it "out-of-order replay deliveries still produce deterministic final result" do
      let out1 = runEffectStart outOfOrderReplayProgram ""
      case obj out1 of
        Nothing -> fail ("not an object: " <> out1)
        Just o1 -> do
          (Object.lookup "status" o1 >>= Json.toString) `shouldEqual` Just "suspended"
          case Object.lookup "snapshot" o1 of
            Nothing -> fail ("no snapshot in: " <> out1)
            Just snap -> do
              let pending = Object.lookup "pending" o1 >>= Json.toArray
              case pending of
                Nothing -> fail ("no pending in: " <> out1)
                Just ps -> do
                  (Array.length ps) `shouldEqual` 2
                  let hasK0 = any (\j -> (Json.toObject j >>= Object.lookup "key" >>= Json.toString) == Just "k0") ps
                  let hasK1 = any (\j -> (Json.toObject j >>= Object.lookup "key" >>= Json.toString) == Just "k1") ps
                  hasK0 `shouldEqual` true
                  hasK1 `shouldEqual` true

                  let p0 = Array.find (\j -> pendingKey j == Just "k0") ps >>= pendingPid
                  let p1 = Array.find (\j -> pendingKey j == Just "k1") ps >>= pendingPid
                  case { p0, p1 } of
                    { p0: Just pid0, p1: Just pid1 } -> do

                      -- Deliberately reversed delivery order (k1 before k0).
                      let snapStr = Json.stringify snap
                          deliveries =
                            "[{\"pid\":\"" <> pid1 <> "\",\"key\":\"k1\",\"result\":{\"string\":\"V1\"}}"
                            <> ",{\"pid\":\"" <> pid0 <> "\",\"key\":\"k0\",\"result\":{\"string\":\"V0\"}}]"
                          out2 = runEffectResume outOfOrderReplayProgram snapStr deliveries
                      case obj out2 of
                        Nothing -> fail ("not an object: " <> out2)
                        Just o2 -> do
                          (Object.lookup "status" o2 >>= Json.toString) `shouldEqual` Just "completed"
                          let aVal = Object.lookup "result" o2 >>= Json.toObject
                                >>= Object.lookup "record" >>= Json.toObject
                                >>= Object.lookup "a" >>= Json.toObject
                                >>= Object.lookup "option" >>= Json.toObject
                                >>= Object.lookup "string" >>= Json.toString
                          let bVal = Object.lookup "result" o2 >>= Json.toObject
                                >>= Object.lookup "record" >>= Json.toObject
                                >>= Object.lookup "b" >>= Json.toObject
                                >>= Object.lookup "option" >>= Json.toObject
                                >>= Object.lookup "string" >>= Json.toString
                          aVal `shouldEqual` Just "V0"
                          bVal `shouldEqual` Just "V1"
                    _ -> fail ("missing pid for k0/k1 in pending: " <> out1)

    it "remote disconnect emits DOWN-like mailbox message for NODE_MONITOR refs" do
      let out1 = runEffectStart remoteMonitorDisconnectProgram ""
      case obj out1 of
        Nothing -> fail ("not an object: " <> out1)
        Just o1 -> do
          (Object.lookup "status" o1 >>= Json.toString) `shouldEqual` Just "suspended"
          let firstPending = Object.lookup "pending" o1 >>= Json.toArray >>= Array.head >>= Json.toObject
          (firstPending >>= Object.lookup "kind" >>= Json.toString) `shouldEqual` Just "transport"
          (firstPending >>= Object.lookup "type_" >>= Json.toString) `shouldEqual` Just "RemoteMonitorIntent"
          case Object.lookup "snapshot" o1 of
            Nothing -> fail ("no snapshot in: " <> out1)
            Just snap -> do
              let snapStr = Json.stringify snap
                  deliveries = """[{ "disconnect": { "node": "other", "reason": "net-split" } }]"""
                  out2 = runEffectResume remoteMonitorDisconnectProgram snapStr deliveries
              case obj out2 of
                Nothing -> fail ("not an object: " <> out2)
                Just o2 -> do
                  (Object.lookup "status" o2 >>= Json.toString) `shouldEqual` Just "completed"
                  let reason = Object.lookup "result" o2 >>= Json.toObject
                        >>= Object.lookup "string" >>= Json.toString
                  reason `shouldEqual` Just "net-split"

    it "disconnect replay is deterministic for same snapshot and deliveries" do
      let out1 = runEffectStart remoteMonitorDisconnectProgram ""
      case obj out1 >>= Object.lookup "snapshot" of
        Nothing -> fail ("no snapshot in: " <> out1)
        Just snap -> do
          let snapStr = Json.stringify snap
              deliveries = """[{ "disconnect": { "node": "other", "reason": "noconnection" } }]"""
              out2 = runEffectResume remoteMonitorDisconnectProgram snapStr deliveries
              out3 = runEffectResume remoteMonitorDisconnectProgram snapStr deliveries
          out2 `shouldEqual` out3

    it "NODE_DEMONITOR with unknown ref does not emit transport intent or drop real monitor" do
      let out1 = runEffectStart remoteDemonitorNoIntentProgram ""
      case obj out1 of
        Nothing -> fail ("not an object: " <> out1)
        Just o1 -> do
          (Object.lookup "status" o1 >>= Json.toString) `shouldEqual` Just "suspended"
          case Object.lookup "pending" o1 >>= Json.toArray of
            Nothing -> fail ("no pending in: " <> out1)
            Just pending -> do
              Array.length pending `shouldEqual` 1
              let firstPending = Array.head pending >>= Json.toObject
              (firstPending >>= Object.lookup "type_" >>= Json.toString) `shouldEqual` Just "RemoteMonitorIntent"
              case Object.lookup "snapshot" o1 of
                Nothing -> fail ("no snapshot in: " <> out1)
                Just snap -> do
                  let snapStr = Json.stringify snap
                      deliveries = """[{ "disconnect": { "node": "other", "reason": "after-demonitor" } }]"""
                      out2 = runEffectResume remoteDemonitorNoIntentProgram snapStr deliveries
                  case obj out2 of
                    Nothing -> fail ("not an object: " <> out2)
                    Just o2 -> do
                      (Object.lookup "status" o2 >>= Json.toString) `shouldEqual` Just "completed"
                      let reason = Object.lookup "result" o2 >>= Json.toObject
                            >>= Object.lookup "string" >>= Json.toString
                      reason `shouldEqual` Just "after-demonitor"

    it "node status delivery normalizes unsupported status and leaves absent metadata optional" do
      let out1 = runEffectStart nodeLifecycleDefaultsProgram ""
      case obj out1 >>= Object.lookup "snapshot" of
        Nothing -> fail ("no snapshot in: " <> out1)
        Just snap -> do
          let snapStr = Json.stringify snap
              deliveries =
                """[
                  { "nodeStatus": { "node": "vmB", "status": "degraded" } },
                  { "pid": "main", "message": { "string": "wake" } }
                ]"""
              out2 = runEffectResume nodeLifecycleDefaultsProgram snapStr deliveries
          case obj out2 of
            Nothing -> fail ("not an object: " <> out2)
            Just o2 -> do
              (Object.lookup "status" o2 >>= Json.toString) `shouldEqual` Just "completed"
              let rec = Object.lookup "result" o2 >>= Json.toObject >>= Object.lookup "record" >>= Json.toObject
              let status = rec >>= Object.lookup "status" >>= Json.toObject >>= Object.lookup "string" >>= Json.toString
              let tickOpt = rec >>= Object.lookup "tick" >>= Json.toObject >>= Object.lookup "option"
              let hashOpt = rec >>= Object.lookup "hash" >>= Json.toObject >>= Object.lookup "option"
              let known = rec >>= Object.lookup "known" >>= Json.toObject >>= Object.lookup "list" >>= Json.toArray
              let tickIsNull = case tickOpt of
                    Just j -> j == Json.jsonNull
                    Nothing -> false
              let hashIsNull = case hashOpt of
                    Just j -> j == Json.jsonNull
                    Nothing -> false
              status `shouldEqual` Just "unknown"
              tickIsNull `shouldEqual` true
              hashIsNull `shouldEqual` true
              case known of
                Nothing -> fail "NODE_KNOWN list missing"
                Just ks -> do
                  let hasVmB = any (\j -> (Json.toObject j >>= Object.lookup "string" >>= Json.toString) == Just "vmB") ks
                  hasVmB `shouldEqual` true

    it "PROC_RECEIVE_MATCH picks EffectReply without draining earlier normal messages" do
      let out1 = runEffectStart selectiveAwaitProgram ""
      case obj out1 >>= Object.lookup "snapshot" of
        Nothing -> fail ("no snapshot in: " <> out1)
        Just snap -> do
          let snapStr = Json.stringify snap
              deliveries = """[{ "pid": "main", "key": "k1", "result": { "string": "BODY42" } }]"""
              out2 = runEffectResume selectiveAwaitProgram snapStr deliveries
          case obj out2 of
            Nothing -> fail ("not an object: " <> out2)
            Just o2 -> do
              (Object.lookup "status" o2 >>= Json.toString) `shouldEqual` Just "completed"
              let rec = Object.lookup "result" o2 >>= Json.toObject >>= Object.lookup "record" >>= Json.toObject
              let reply = rec >>= Object.lookup "reply" >>= Json.toObject >>= Object.lookup "string" >>= Json.toString
              let normal = rec >>= Object.lookup "normal" >>= Json.toObject >>= Object.lookup "string" >>= Json.toString
              reply `shouldEqual` Just "BODY42"
              normal `shouldEqual` Just "pre"

    it "PROC_RECEIVE_MATCH blocks until matching variant and ignores non-matching delivery" do
      let out1 = runEffectStart receiveMatchBlockingProgram ""
      case obj out1 of
        Nothing -> fail ("not an object: " <> out1)
        Just o1 -> do
          (Object.lookup "status" o1 >>= Json.toString) `shouldEqual` Just "deadlock"
          case Object.lookup "snapshot" o1 of
            Nothing -> fail ("no snapshot in: " <> out1)
            Just snap1 -> do
              let snap1Str = Json.stringify snap1
                  nonMatching =
                    """[
                      {
                        "pid": "main",
                        "message": { "variant": { "tag": "Other", "payload": { "string": "noise" } } }
                      }
                    ]"""
                  out2 = runEffectResume receiveMatchBlockingProgram snap1Str nonMatching
              case obj out2 of
                Nothing -> fail ("not an object: " <> out2)
                Just o2 -> do
                  (Object.lookup "status" o2 >>= Json.toString) `shouldEqual` Just "deadlock"
                  case Object.lookup "snapshot" o2 of
                    Nothing -> fail ("no snapshot in: " <> out2)
                    Just snap2 -> do
                      let snap2Str = Json.stringify snap2
                          matching =
                            """[
                              {
                                "pid": "main",
                                "message": {
                                  "variant": {
                                    "tag": "EffectReply",
                                    "payload": {
                                      "record": {
                                        "key": { "string": "k1" },
                                        "value": { "string": "HIT" }
                                      }
                                    }
                                  }
                                }
                              }
                            ]"""
                          out3 = runEffectResume receiveMatchBlockingProgram snap2Str matching
                      case obj out3 of
                        Nothing -> fail ("not an object: " <> out3)
                        Just o3 -> do
                          (Object.lookup "status" o3 >>= Json.toString) `shouldEqual` Just "completed"
                          let value = Object.lookup "result" o3 >>= Json.toObject >>= Object.lookup "string" >>= Json.toString
                          value `shouldEqual` Just "HIT"

    it "PROC_RECEIVE_MATCH_OPT returns None when no matching message exists and never blocks" do
      let out = runEffectStart receiveMatchOptProgram ""
      case obj out of
        Nothing -> fail ("not an object: " <> out)
        Just o -> do
          (Object.lookup "status" o >>= Json.toString) `shouldEqual` Just "completed"
          let noneOpt = Object.lookup "result" o >>= Json.toObject >>= Object.lookup "option"
          let isNone = case noneOpt of
                Just j -> j == Json.jsonNull
                Nothing -> false
          isNone `shouldEqual` true

    it "selective receive replay is deterministic with interleaved normal messages and replies" do
      let out1 = runEffectStart selectiveAwaitProgram ""
      case obj out1 >>= Object.lookup "snapshot" of
        Nothing -> fail ("no snapshot in: " <> out1)
        Just snap -> do
          let snapStr = Json.stringify snap
              deliveries =
                """[
                  { "pid": "main", "message": { "string": "host-msg" } },
                  { "pid": "main", "key": "k1", "result": { "string": "R1" } }
                ]"""
              out2 = runEffectResume selectiveAwaitProgram snapStr deliveries
              out3 = runEffectResume selectiveAwaitProgram snapStr deliveries
          out2 `shouldEqual` out3
