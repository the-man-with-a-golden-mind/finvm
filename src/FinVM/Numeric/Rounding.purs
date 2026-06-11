module FinVM.Numeric.Rounding where

import Prelude

data Rounding
  = RoundDown
  | RoundUp
  | RoundHalfEven
  | RoundTowardZero
  | RoundAwayFromZero

derive instance eqRounding :: Eq Rounding
derive instance ordRounding :: Ord Rounding
instance showRounding :: Show Rounding where
  show RoundDown = "RoundDown"
  show RoundUp = "RoundUp"
  show RoundHalfEven = "RoundHalfEven"
  show RoundTowardZero = "RoundTowardZero"
  show RoundAwayFromZero = "RoundAwayFromZero"
