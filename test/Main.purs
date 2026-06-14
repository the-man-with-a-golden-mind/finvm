module Test.Main where

import Prelude
import Effect (Effect)
import Test.Spec.Reporter.Console (consoleReporter)
import Test.Spec.Runner.Node (runSpecAndExitProcess)
import Test.Numeric.BigInt as BigInt
import Test.Numeric.Fixed as Fixed
import Test.Numeric.Rational as Rational
import Test.Str as Str
import Test.Interpreter as Interpreter
import Test.InstructionSet as InstructionSet
import Test.Validate as Validate
import Test.Encoding.Canonical as Canonical
import Test.Encoding.Json as EncodingJson
import Test.Process as Process
import Test.Monitor as Monitor
import Test.StateMachine as StateMachine
import Test.Proof as Proof
import Test.Remote as Remote
import Test.Database as Database
import Test.Cache as Cache
import Test.E2E as E2E
import Test.Replay as Replay
import Test.Conformance as Conformance
import Test.Effects as Effects
import Test.Snapshot as Snapshot
import Test.Properties as Properties
import Test.PerformanceMode as PerformanceMode

main :: Effect Unit
main = runSpecAndExitProcess [consoleReporter] do
  BigInt.spec
  Fixed.spec
  Rational.spec
  Str.spec
  Interpreter.spec
  InstructionSet.spec
  Validate.spec
  Canonical.spec
  EncodingJson.spec
  Process.spec
  Monitor.spec
  StateMachine.spec
  Proof.spec
  Remote.spec
  Database.spec
  Cache.spec
  E2E.spec
  Replay.spec
  Conformance.spec
  Effects.spec
  Snapshot.spec
  PerformanceMode.spec
  Properties.spec
