module FinVM.Numeric.Fixed where

import Prelude
import FinVM.Numeric.BigInt as BI
import FinVM.Error (ErrorCode(..))
import Data.Either (Either(..))
import FinVM.Numeric.Rounding (Rounding(..))

type Fixed =
  { value :: BI.BigInt
  , scale :: Int
  }

scaleUp :: Fixed -> Int -> Fixed
scaleUp f newScale =
  if newScale <= f.scale then f
  else
    let diff = newScale - f.scale
    in f { value = f.value * pow10 diff, scale = newScale }

pow10 :: Int -> BI.BigInt
pow10 n =
  let loop 0 acc = acc
      loop k acc = loop (k - 1) (acc * BI.fromInt 10)
  in loop n (BI.fromInt 1)

rescale :: Fixed -> Int -> Rounding -> Either ErrorCode Fixed
rescale f newScale r =
  if newScale == f.scale then pure f
  else if newScale > f.scale then
    let diff = newScale - f.scale
    in pure $ f { value = f.value * pow10 diff, scale = newScale }
  else
    let diff = f.scale - newScale
        divisor = pow10 diff
        quotient = roundedQuotient f.value divisor r
    in pure $ f { value = quotient, scale = newScale }

add :: Fixed -> Fixed -> Either ErrorCode Fixed
add a b =
  let maxScale = max a.scale b.scale
  in do
    a' <- rescale a maxScale RoundDown
    b' <- rescale b maxScale RoundDown
    pure { value: a'.value + b'.value, scale: maxScale }

sub :: Fixed -> Fixed -> Either ErrorCode Fixed
sub a b =
  let maxScale = max a.scale b.scale
  in do
    a' <- rescale a maxScale RoundDown
    b' <- rescale b maxScale RoundDown
    pure { value: a'.value - b'.value, scale: maxScale }

mul :: Fixed -> Fixed -> Fixed
mul a b =
  { value: a.value * b.value
  , scale: a.scale + b.scale
  }

-- | Fixed-point division.
-- |
-- | The result is returned at the *dividend's* scale (`a.scale`): the quotient
-- | precision is bounded by how many fractional digits the dividend carries.
-- | Mathematically `a / b = (a.value * 10^b.scale) / b.value`, rounded to
-- | `a.scale` digits using the supplied `Rounding` mode.
-- |
-- | Consequence: `1 / 2` at scale 0 is `0` (integer-scale truncation), NOT
-- | `0.5`. To retain fractional precision, widen the dividend's scale first
-- | (e.g. `rescale a 2` before dividing). Returns `DivisionByZero` when `b == 0`.
div :: Fixed -> Fixed -> Rounding -> Either ErrorCode Fixed
div a b r =
  if b.value == BI.fromInt 0 then Left DivisionByZero
  else
    -- a / b = (a.value * 10^b.scale) / b.value
    let aScaled = a.value * pow10 b.scale
        q = roundedQuotient aScaled b.value r
    in pure { value: q, scale: a.scale }

roundedQuotient :: BI.BigInt -> BI.BigInt -> Rounding -> BI.BigInt
roundedQuotient numerator denominator rounding =
  let
    -- Use the truncating pair (quot/rem), NOT Data.BigInt's `/` which is the
    -- Euclidean quotient (always-non-negative remainder). The rounding logic
    -- below assumes `q` truncates toward zero and `rem` carries the dividend's
    -- sign, so that q*denominator + rem == numerator holds for negatives too.
    q = numerator `BI.quot` denominator
    rem = numerator `BI.rem` denominator
    zero = BI.fromInt 0
    one = BI.fromInt 1
    two = BI.fromInt 2
    sign = if (numerator < zero && denominator > zero) || (numerator > zero && denominator < zero) then BI.fromInt (-1) else one
    absRem = if rem < zero then -rem else rem
    absDen = if denominator < zero then -denominator else denominator
    hasRemainder = rem /= zero
    away = q + sign
  in
    case rounding of
      RoundTowardZero -> q
      RoundAwayFromZero -> if hasRemainder then away else q
      RoundDown -> if sign < zero && hasRemainder then away else q
      RoundUp -> if sign > zero && hasRemainder then away else q
      RoundHalfEven ->
        let doubled = absRem * two
        in if doubled < absDen then q
           else if doubled > absDen then away
           else if q `BI.rem` two == zero then q
           else away
