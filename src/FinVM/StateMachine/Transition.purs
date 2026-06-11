module FinVM.StateMachine.Transition where

import Prelude
import Data.Map (Map)
import Data.Maybe (Maybe)
import FinVM.Value (Value, FunctionId)
import FinVM.StateMachine.Instance (StateId)

type EventType = String
type TransitionId = String

data StateTarget
  = StaticState StateId
  | ComputedState FunctionId
  | Stay

type TransitionDef =
  { name :: TransitionId
  , from :: Array StateId
  , event :: EventType
  , guard :: Maybe FunctionId
  , action :: FunctionId
  , to :: StateTarget
  , priority :: Maybe Int
  }

type InvariantDef =
  { name :: String
  , check :: FunctionId
  , errorCode :: Int
  }

type StateMachine =
  { id :: String
  , states :: Map StateId String -- stateId to description
  , initialState :: StateId
  , transitions :: Array TransitionDef
  , invariants :: Array InvariantDef
  }
