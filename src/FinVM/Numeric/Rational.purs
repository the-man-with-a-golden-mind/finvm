module FinVM.Numeric.Rational where

import Prelude
import FinVM.Numeric.BigInt as BI
import FinVM.Error (ErrorCode(..))
import Data.Either (Either(..))

type Rational =
  { numerator :: BI.BigInt
  , denominator :: BI.BigInt
  }

normalize :: Rational -> Either ErrorCode Rational
normalize { numerator, denominator } =
  if denominator == BI.fromInt 0 then Left DivisionByZero
  else
    let gcdVal = BI.extGcd numerator denominator
        g = gcdVal.gcd
        sign = if denominator < BI.fromInt 0 then BI.fromInt (-1) else BI.fromInt 1
    in pure
       { numerator: (numerator / g) * sign
       , denominator: (denominator / g) * sign
       }

add :: Rational -> Rational -> Either ErrorCode Rational
add a b =
  normalize { numerator: a.numerator * b.denominator + b.numerator * a.denominator
            , denominator: a.denominator * b.denominator
            }

sub :: Rational -> Rational -> Either ErrorCode Rational
sub a b =
  normalize { numerator: a.numerator * b.denominator - b.numerator * a.denominator
            , denominator: a.denominator * b.denominator
            }

mul :: Rational -> Rational -> Either ErrorCode Rational
mul a b =
  normalize { numerator: a.numerator * b.numerator
            , denominator: a.denominator * b.denominator
            }

div :: Rational -> Rational -> Either ErrorCode Rational
div a b =
  normalize { numerator: a.numerator * b.denominator
            , denominator: a.denominator * b.numerator
            }
