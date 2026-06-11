module FinVM.Type where

import Prelude

data VMType
  = TUnit
  | TBool
  | TInt
  | TFixed Int
  | TRational
  | TString
  | TBytes
  | TSymbol
  | TList VMType
  | TMap VMType VMType
  | TRecord (Array { key :: String, value :: VMType })
  | TVariant (Array { tag :: String, payload :: VMType })
  | TOption VMType
  | TResult VMType VMType
  | TFunction (Array VMType) VMType
  | TProcessRef
  | TRemoteProcessRef
  | TEvent
  | TEffectIntent
  | TProofValue
  | TAny

derive instance eqVMType :: Eq VMType
derive instance ordVMType :: Ord VMType
