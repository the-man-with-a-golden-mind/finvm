module FinVM.Numeric.BigInt
  ( module Data.BigInt
  , modAdd
  , modSub
  , modMul
  , modPow
  , extGcd
  , modInv
  , bitLength
  ) where

import Prelude hiding (not)
import Data.BigInt
import Data.Maybe (Maybe(..))
import Data.Either (Either(..))

modAdd :: BigInt -> BigInt -> BigInt -> BigInt
modAdd a b m = ((a + b) `rem` m + m) `rem` m

modSub :: BigInt -> BigInt -> BigInt -> BigInt
modSub a b m = ((a - b) `rem` m + m) `rem` m

modMul :: BigInt -> BigInt -> BigInt -> BigInt
modMul a b m = ((a * b) `rem` m + m) `rem` m

-- Square and multiply.
-- Returns Nothing when a negative exponent is requested but `base` has no
-- modular inverse mod `m` (i.e. gcd(base, m) /= 1). A non-invertible result is
-- a genuine error, not the value 0, so callers can surface it explicitly.
modPow :: BigInt -> BigInt -> BigInt -> Maybe BigInt
modPow base exp m =
  if exp == fromInt 0 then Just (fromInt 1)
  else if exp < fromInt 0 then
    case modInv base m of
      Nothing -> Nothing
      Just inv -> modPow inv (-exp) m
  else
    case modPow base (exp / fromInt 2) m of
      Nothing -> Nothing
      Just halfPow ->
        let halfPowSq = modMul halfPow halfPow m
        in Just $
          if exp `rem` fromInt 2 == fromInt 0
            then halfPowSq
            else modMul halfPowSq base m

-- Extended Euclidean Algorithm
extGcd :: BigInt -> BigInt -> { gcd :: BigInt, x :: BigInt, y :: BigInt }
extGcd a b =
  if b == fromInt 0
    then { gcd: a, x: fromInt 1, y: fromInt 0 }
    else
      let
        q = a / b
        r = a `rem` b
        res = extGcd b r
      in
        { gcd: res.gcd, x: res.y, y: res.x - q * res.y }

modInv :: BigInt -> BigInt -> Maybe BigInt
modInv a m =
  let
    res = extGcd a m
  in
    if res.gcd == fromInt 1
      then Just $ ((res.x `rem` m) + m) `rem` m
      else Nothing

-- Approximate bit length
bitLength :: BigInt -> Int
bitLength n =
  let
    loop :: BigInt -> Int -> Int
    loop v acc = if v == fromInt 0 then acc else loop (v / fromInt 2) (acc + 1)
  in
    if n == fromInt 0 then 0 else loop (if n < fromInt 0 then -n else n) 0
