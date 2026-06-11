module FinVM.Registers where

import Prelude
import Data.Array as Array
import Data.Maybe (fromMaybe)
import FinVM.Value (Value(..))

-- Registers are modeled as an array of values for O(1) access.
type Registers = Array Value

emptyRegisters :: Int -> Registers
emptyRegisters size = Array.replicate size VUnit

getReg :: Registers -> Int -> Value
getReg regs r = fromMaybe VUnit (Array.index regs r)

setReg :: Registers -> Int -> Value -> Registers
setReg regs r v = fromMaybe regs (Array.updateAt r v regs)
