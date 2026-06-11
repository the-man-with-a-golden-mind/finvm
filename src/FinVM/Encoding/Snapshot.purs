module FinVM.Encoding.Snapshot where

import Prelude
import Data.Map as Map
import Data.Array as Array
import Data.List as List
import Data.Tuple (Tuple(..))
import FinVM.Machine (Machine)
import FinVM.Value (Value(..))
import FinVM.Process (Process)
import FinVM.Encoding.Canonical (canonicalValue)

-- | A canonical snapshot of the entire machine.
type Snapshot = String

createSnapshot :: Machine -> Snapshot
createSnapshot m = 
  "snapshot{program:" <> m.program.version <>
  ",state:" <> canonicalEntries (Map.toUnfoldable m.state) <>
  ",processes:[" <> (Array.intercalate "," (List.toUnfoldable (map canonicalProcess (Map.values m.scheduler.processes)))) <> "]" <>
  ",tick:" <> show m.scheduler.logicalTick <>
  ",steps:" <> show m.counters.steps <>
  "}"

canonicalProcess :: Process -> String
canonicalProcess p = 
  let
    regsArray = Array.mapWithIndex Tuple p.frame.registers
    stringRegs = Map.fromFoldable (map (\(Tuple i v) -> Tuple (show i) v) regsArray)
  in
  "proc{pid:" <> p.pid <>
  ",status:" <> show p.status <>
  ",pc:" <> show p.frame.pc <>
  ",registers:" <> canonicalEntries (Map.toUnfoldable stringRegs) <>
  ",mailbox:[" <> (Array.intercalate "," (canonicalValue <$> p.mailbox)) <> "]" <>
  "}"

canonicalEntries :: Array (Tuple String Value) -> String
canonicalEntries entries =
  let
    sorted = Array.sortWith (\(Tuple k _) -> k) entries
    render (Tuple k v) = k <> ":" <> canonicalValue v
  in
    Array.intercalate "," (render <$> sorted)
