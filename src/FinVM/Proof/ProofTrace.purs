module FinVM.Proof.ProofTrace where

import Prelude
import FinVM.Value (Value)
import Data.List (List)

data ProofEvent
  = ProofAssumption String
  | ProofAssertion Boolean Int
  | ProofInvariantChecked String Boolean
  | ProofValueMarked String Value
  | ProofScopeBegin String
  | ProofScopeEnd String

derive instance eqProofEvent :: Eq ProofEvent
derive instance ordProofEvent :: Ord ProofEvent

instance showProofEvent :: Show ProofEvent where
  show = case _ of
    ProofAssumption note -> "ProofAssumption " <> note
    ProofAssertion b code -> "ProofAssertion " <> show b <> " " <> show code
    ProofInvariantChecked name b -> "ProofInvariantChecked " <> name <> " " <> show b
    ProofValueMarked label val -> "ProofValueMarked " <> label <> " " <> show val
    ProofScopeBegin label -> "ProofScopeBegin " <> label
    ProofScopeEnd label -> "ProofScopeEnd " <> label


type ProofTrace = List ProofEvent
