module FinVM.Value where

import Prelude
import Data.Maybe (Maybe(..))
import Data.Either (Either(..))
import Data.Map (Map)
import FinVM.Numeric.BigInt (BigInt)
import FinVM.Numeric.Fixed (Fixed)
import FinVM.Numeric.Rational (Rational)
import FinVM.StateMachine.Instance (MachineInstance)

type Bytes = Array Int -- Simplified for now, or could use ArrayBuffer

type FunctionId = String
type ProcessId = String
type MonitorRef = String
type Event = { type_ :: String, payload :: Value }
type EffectIntent = { type_ :: String, payload :: Value }
type ProofValue = { label :: String, value :: Value }

newtype NodeRef = NodeRef String
derive newtype instance eqNodeRef :: Eq NodeRef
derive newtype instance ordNodeRef :: Ord NodeRef
instance showNodeRef :: Show NodeRef where
  show (NodeRef n) = "NodeRef " <> n

type RemoteProcessRef =
  { node :: NodeRef
  , pid :: ProcessId
  }

data Value
  = VUnit
  | VBool Boolean
  | VInt BigInt
  | VFixed Fixed
  | VRational Rational
  | VString String
  | VBytes Bytes
  | VSymbol String
  | VList (Array Value)
  | VMap (Map Value Value)
  | VRecord (Map String Value)
  | VVariant String Value
  | VOption (Maybe Value)
  | VResult (Either Value Value)
  | VFunctionRef FunctionId
  | VProcessRef ProcessId
  | VRemoteProcessRef RemoteProcessRef
  | VStateMachineInstance (MachineInstance Value)
  | VEvent Event
  | VEffectIntent EffectIntent
  | VProofValue ProofValue

derive instance eqValue :: Eq Value
derive instance ordValue :: Ord Value

instance showValue :: Show Value where
  show = case _ of
    VUnit -> "VUnit"
    VBool b -> "VBool " <> show b
    VInt i -> "VInt " <> show i
    VFixed f -> "VFixed " <> show f.value <> "@" <> show f.scale
    VRational r -> "VRational " <> show r.numerator <> "/" <> show r.denominator
    VString s -> "VString " <> show s
    VBytes b -> "VBytes " <> show b
    VSymbol s -> "VSymbol " <> s
    VList l -> "VList " <> show l
    VMap m -> "VMap " <> show m
    VRecord r -> "VRecord " <> show r
    VVariant t p -> "VVariant " <> t <> " " <> show p
    VOption o -> "VOption " <> show o
    VResult r -> "VResult " <> show r
    VFunctionRef f -> "VFunctionRef " <> f
    VProcessRef p -> "VProcessRef " <> p
    VRemoteProcessRef r -> "VRemoteProcessRef " <> r.pid
    VStateMachineInstance mi -> "VStateMachineInstance " <> mi.instanceId
    VEvent e -> "VEvent " <> e.type_
    VEffectIntent e -> "VEffectIntent " <> e.type_
    VProofValue p -> "VProofValue " <> p.label
