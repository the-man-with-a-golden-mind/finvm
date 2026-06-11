module FinVM.Frame where

import Prelude
import Data.Maybe (Maybe)
import FinVM.Value (FunctionId)
import FinVM.Registers (Registers)
import FinVM.Instruction (Register)

newtype FrameRef = FrameRef Int
derive newtype instance eqFrameRef :: Eq FrameRef
derive newtype instance ordFrameRef :: Ord FrameRef

type Frame =
  { function :: FunctionId
  , pc :: Int
  , registers :: Registers
  , returnRegister :: Maybe Register
  , caller :: Maybe FrameRef
  }
