module FinVM.Function where

import Prelude
import FinVM.Value (FunctionId)
import FinVM.Type (VMType)
import FinVM.Instruction (Instruction)

type DebugMetadata = { name :: String }
type ProofMetadata = { isInvariant :: Boolean }

type Function =
  { id :: FunctionId
  , arity :: Int
  , registerCount :: Int
  , parameterTypes :: Array VMType
  , returnType :: VMType
  , instructions :: Array Instruction
  , debug :: DebugMetadata
  , proof :: ProofMetadata
  }
