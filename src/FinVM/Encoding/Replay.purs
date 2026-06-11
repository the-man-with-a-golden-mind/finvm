module FinVM.Encoding.Replay where

import Prelude
import Data.Array as Array
import Data.Either (Either(..))
import Data.Map as Map
import Data.Tuple (Tuple(..))
import FinVM.Machine (Machine)
import FinVM.Encoding.Canonical (canonicalValue, sha256String)
import FinVM.Eval (runMachine)
import FinVM.Error (VMError)
import FinVM.State (VMState, VMOutput)
import FinVM.Value (Value)

type ReplayRecord =
  { expectedStateHash :: String
  , expectedOutputHash :: String
  -- To be expanded with trace hashes etc.
  }

data ReplayResult
  = ReplaySuccess
  | ReplayMismatch String
  | ReplayFailed VMError

derive instance eqReplayResult :: Eq ReplayResult

instance showReplayResult :: Show ReplayResult where
  show = case _ of
    ReplaySuccess -> "ReplaySuccess"
    ReplayMismatch msg -> "ReplayMismatch " <> show msg
    ReplayFailed err -> "ReplayFailed " <> show err

verifyReplay :: Machine -> ReplayRecord -> ReplayResult
verifyReplay m rec =
  case runMachine m of
    Left err -> ReplayFailed err
    Right m' -> 
      let 
        stateHash = canonicalState m'.state
        outputHash = canonicalOutput Map.empty
      in 
        if stateHash /= rec.expectedStateHash
          then ReplayMismatch ("State mismatch: expected " <> rec.expectedStateHash <> ", got " <> stateHash)
          else if outputHash /= rec.expectedOutputHash
            then ReplayMismatch ("Output mismatch: expected " <> rec.expectedOutputHash <> ", got " <> outputHash)
          else ReplaySuccess

canonicalState :: VMState -> String
canonicalState = canonicalEntries <<< Map.toUnfoldable

canonicalOutput :: VMOutput -> String
canonicalOutput = canonicalEntries <<< Map.toUnfoldable

canonicalEntries :: Array (Tuple String Value) -> String
canonicalEntries entries =
  let
    sorted = Array.sortWith (\(Tuple k _) -> k) entries
    render (Tuple k v) = k <> ":" <> canonicalValue v
  in
    sha256String ("{" <> Array.intercalate "," (render <$> sorted) <> "}")
