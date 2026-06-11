module FinVM.Process.Scheduler where

import Prelude
import Data.Map (Map)
import Data.Map as Map
import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import FinVM.Value (ProcessId)
import FinVM.Process (Process, ProcessStatus(..))

type ScheduleEvent = { pid :: ProcessId, event :: String }

type Scheduler =
  { processes :: Map ProcessId Process
  , readyQueue :: Array ProcessId
  , current :: Maybe ProcessId
  , nextPidSequence :: Int
  , logicalTick :: Int
  , scheduleTrace :: Array ScheduleEvent
  }

initialScheduler :: Scheduler
initialScheduler =
  { processes: Map.empty
  , readyQueue: []
  , current: Nothing
  , nextPidSequence: 0
  , logicalTick: 0
  , scheduleTrace: []
  }

-- | Adds a new process to the scheduler
spawnProcess :: Scheduler -> Process -> Scheduler
spawnProcess s p =
  s { processes = Map.insert p.pid p s.processes
    , readyQueue = Array.snoc s.readyQueue p.pid
    }

-- | Picks the next process to run deterministically
nextProcess :: Scheduler -> Maybe (Tuple ProcessId Scheduler)
nextProcess s = case Array.uncons s.readyQueue of
  Nothing -> Nothing
  Just { head, tail } -> Just $ Tuple head (s { readyQueue = tail, current = Just head })

findProcess :: Scheduler -> ProcessId -> Maybe Process
findProcess s pid = Map.lookup pid s.processes

updateProcess :: Scheduler -> Process -> Scheduler
updateProcess s p = s { processes = Map.insert p.pid p s.processes }

nextPid :: Scheduler -> Tuple ProcessId Scheduler
nextPid s = 
  let pid = "p" <> show s.nextPidSequence
  in Tuple pid (s { nextPidSequence = s.nextPidSequence + 1 })

yieldProcess :: Scheduler -> ProcessId -> Scheduler
yieldProcess s pid = s { readyQueue = Array.snoc s.readyQueue pid }

