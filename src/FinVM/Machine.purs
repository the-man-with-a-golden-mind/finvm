module FinVM.Machine where

import Prelude
import FinVM.Program (Program)
import FinVM.Process.Scheduler (Scheduler)
import FinVM.State (VMState, VMInput, VMOutput)
import FinVM.Value (Value, Event, EffectIntent)
import FinVM.Debug.Trace (Trace)
import FinVM.Proof.ProofTrace (ProofTrace)
import FinVM.Limits (EvalLimits)
import Data.Map (Map)
import Data.Either (Either)
import Data.List (List)

import FinVM.Error (VMError)

type BuiltinFn = Array Value -> Either VMError Value


type EvalConfig =
  { limits :: EvalLimits
  , externalBuiltins :: Map String (Map Int BuiltinFn) -- Map "id" to Map "version" to "function"
  , performanceMode :: Boolean -- If true, disables tracing and proofs for maximum speed
  }

type ExecutionCounters =
  { steps :: Int
  }

type Machine =
  { program :: Program
  , scheduler :: Scheduler
  , state :: VMState
  , input :: VMInput
  , config :: EvalConfig
  , trace :: Trace
  , proofTrace :: ProofTrace
  , outbox :: List EffectIntent
  , events :: List Event
  , counters :: ExecutionCounters
  }

type ExecutionCertificate =
  { stepCount :: Int
  , programHash :: String
  , finalStatus :: String
  }

type VMResult =
  { output :: VMOutput
  , newState :: VMState
  , emittedEvents :: Array Event
  , requestedEffects :: Array EffectIntent
  , certificate :: ExecutionCertificate
  }
