module FinVM.Program where

import Prelude
import Data.Map (Map)
import FinVM.Value (Value, FunctionId)
import FinVM.Function (Function)
import FinVM.Type (VMType)
import FinVM.StateMachine.Transition (StateMachine)

type ProgramMetadata = { description :: String }
type TypeTable = Map String VMType
type Capability = String
type VerificationMetadata = { verified :: Boolean }

type Program =
  { version :: String
  , constants :: Array Value
  , functions :: Map FunctionId Function
  , stateMachines :: Map String StateMachine
  , entrypoint :: FunctionId
  , exports :: Map String FunctionId
  , metadata :: ProgramMetadata
  , typeTable :: TypeTable
  , capabilities :: Array Capability
  , verification :: VerificationMetadata
  }
