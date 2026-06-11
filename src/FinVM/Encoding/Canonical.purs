module FinVM.Encoding.Canonical where

import Prelude
import Data.BigInt as BI
import Data.Map as Map
import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.Either (Either(..))
import Data.Tuple (Tuple(..))
import FinVM.Value (Value(..), NodeRef(..))
import FinVM.Vec as Vec

-- | Deterministically convert a Value to a canonical string representation for hashing.
canonicalValue :: Value -> String
canonicalValue = case _ of
  VUnit -> "unit"
  VBool b -> if b then "true" else "false"
  VInt i -> "int:" <> BI.toString i
  VFixed f -> "fixed:" <> BI.toString f.value <> "@" <> show f.scale
  VRational r -> "rational:" <> BI.toString r.numerator <> "/" <> BI.toString r.denominator
  VString s -> "string:" <> show s
  VBytes b -> "bytes:" <> show b
  VSymbol s -> "symbol:" <> s
  VList l -> "[" <> (Array.intercalate "," (canonicalValue <$> Vec.toArray l)) <> "]"
  VMap m -> "map{" <> canonicalMapEntries (Map.toUnfoldable m) <> "}"
  VRecord r -> "record{" <> canonicalEntries (Map.toUnfoldable r) <> "}"
  VVariant t p -> "variant:" <> t <> "(" <> canonicalValue p <> ")"
  VOption Nothing -> "none"
  VOption (Just v) -> "some(" <> canonicalValue v <> ")"
  VResult (Left v) -> "err(" <> canonicalValue v <> ")"
  VResult (Right v) -> "ok(" <> canonicalValue v <> ")"
  VFunctionRef f -> "fn:" <> f
  VProcessRef p -> "proc:" <> p
  VRemoteProcessRef r -> case r.node of NodeRef n -> "remote:" <> n <> ":" <> r.pid
  VStateMachineInstance mi -> "machine:" <> mi.machineId <> ":" <> mi.instanceId <> "@" <> show mi.version
  VEvent e -> "event:" <> e.type_ <> "(" <> canonicalValue e.payload <> ")"
  VEffectIntent e -> "effect:" <> e.type_ <> "(" <> canonicalValue e.payload <> ")"
  VProofValue p -> "proof:" <> p.label <> "(" <> canonicalValue p.value <> ")"

canonicalEntries :: Array (Tuple String Value) -> String
canonicalEntries entries =
  let
    sorted = Array.sortWith (\(Tuple k _) -> k) entries
    render (Tuple k v) = k <> ":" <> canonicalValue v
  in
    Array.intercalate "," (render <$> sorted)

canonicalMapEntries :: Array (Tuple Value Value) -> String
canonicalMapEntries entries =
  let
    sorted = Array.sortWith (\(Tuple k _) -> canonicalValue k) entries
    render (Tuple k v) = canonicalValue k <> ":" <> canonicalValue v
  in
    Array.intercalate "," (render <$> sorted)

foreign import sha256String :: String -> String

hashValue :: Value -> String
hashValue v = sha256String (canonicalValue v)
