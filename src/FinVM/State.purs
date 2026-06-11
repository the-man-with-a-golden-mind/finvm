module FinVM.State where

import Prelude
import Data.Map (Map)
import FinVM.Value (Value)

-- A canonical representation of the VM's state, mapping string paths to Values
type VMState = Map String Value

-- Data passed to the VM externally
type VMInput = Map String Value

-- Data produced by the VM
type VMOutput = Map String Value
