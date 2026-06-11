module FinVM.StateMachine.Instance where

import Prelude
import Data.Map (Map)

type StateId = String
type MachineId = String
type InstanceId = String

type MachineInstance value =
  { machineId :: MachineId
  , instanceId :: InstanceId
  , currentState :: StateId
  , data_ :: Map String value
  , version :: Int
  , historyHash :: String
  }

