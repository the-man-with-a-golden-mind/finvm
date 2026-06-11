module FinVM.Eval where

import Prelude
import FinVM.Error (VMError(..), ErrorCode(ProcessDeadlock, ProcessNotFound))
import FinVM.Machine (Machine)
import FinVM.Process (Process, ProcessStatus(..), WaitCondition(..))
import FinVM.Value (Value(..))
import FinVM.Interpreter as Interpreter
import FinVM.Process.Scheduler as Scheduler
import Data.Tuple (Tuple(..))
import Data.Map as Map
import Data.Set as Set
import Data.List as List
import Data.Foldable as Foldable
import Data.Maybe (Maybe(..))
import Data.Either (Either(..))
import Data.Foldable (for_)
import Effect (Effect)
import Effect.Console (log)

import Control.Monad.Rec.Class (Step(..), tailRecM)

-- | Run the machine until all processes complete, fail, or a limit is reached.
-- | Precomputes the per-function label cache once so JUMP targets resolve in
-- | O(1) for the whole run instead of scanning instructions on every jump.
runMachine :: Machine -> Either VMError Machine
runMachine machineInit0 = tailRecM runSlice machineInit
  where
    machineInit = machineInit0 { labelCache = Interpreter.buildLabelCache machineInit0.program }
    runSlice m = 
      if m.counters.steps >= m.config.limits.maxSteps
        then Right (Done m)
        else
          case Scheduler.nextProcess m.scheduler of
            Nothing -> 
              -- Check for deadlock
              case wakeNextTick m of
                Just m' -> Right (Loop m')
                Nothing ->
                  if anyProcessWaiting m
                    then Left $ VMError ProcessDeadlock "All processes are waiting but no ready processes"
                    else Right (Done m)
            Just (Tuple pid s') -> do
              let m_current = m { scheduler = s' }
              process <- case Scheduler.findProcess m_current.scheduler pid of
                Nothing -> Left $ VMError ProcessNotFound ("Process " <> pid <> " not found")
                Just p -> pure p
              
              -- Run a slice of execution for this process
              res <- runSliceForProcess m_current process m.config.limits.maxProcessStepsPerSlice
              case res of
                Tuple m_next p_next -> do
                  let m_updated = case p_next.status of
                        ProcessRunning -> 
                          m_next { scheduler = Scheduler.yieldProcess (Scheduler.updateProcess m_next.scheduler p_next) p_next.pid }
                        ProcessReady -> 
                          m_next { scheduler = Scheduler.yieldProcess (Scheduler.updateProcess m_next.scheduler p_next) p_next.pid }
                        ProcessWaiting _ ->
                          m_next { scheduler = Scheduler.updateProcess m_next.scheduler p_next }
                        ProcessCompleted val ->
                          m_next { scheduler = Scheduler.updateProcess m_next.scheduler (p_next { result = Just val }) }
                        _ -> m_next { scheduler = Scheduler.updateProcess m_next.scheduler p_next }
                      m_woken = wakeProcessWaiters p_next.pid m_updated
                      m_final = notifyMonitorsOfDeath p_next.pid p_next.status m_woken

                  Right (Loop m_final)

-- | Executes up to 'remaining' steps for a single process.
runSliceForProcess :: Machine -> Process -> Int -> Either VMError (Tuple Machine Process)
runSliceForProcess m p remaining =
  if remaining <= 0 || p.status /= ProcessReady
    then pure $ Tuple m p
    else do
      res <- Interpreter.stepProcess m p
      case res of
        Tuple m' p' -> runSliceForProcess m' p' (remaining - 1)

-- | Debug version of runMachine that logs the trace.
debugRun :: Machine -> Effect Unit
debugRun m = do
  case runMachine m of
    Left err -> log $ "Execution Failed: " <> show err
    Right m' -> do
      log "Execution Success"
      log "Full Trace:"
      for_ m'.trace \event -> log $ "  " <> show event
      log "Proof Trace:"
      for_ m'.proofTrace \event -> log $ "  " <> show event

anyProcessWaiting :: Machine -> Boolean
anyProcessWaiting m = 
  List.any (\p -> case p.status of 
                     ProcessWaiting _ -> true
                     _ -> false) 
            (Map.values m.scheduler.processes)

wakeProcessWaiters :: String -> Machine -> Machine
wakeProcessWaiters completedPid m =
  let
    processes = Map.values m.scheduler.processes
    wakeOne scheduler p = case p.status of
      ProcessWaiting (WaitingForProcess pid) | pid == completedPid ->
        Scheduler.yieldProcess (Scheduler.updateProcess scheduler (p { status = ProcessReady })) p.pid
      _ -> scheduler
  in
    m { scheduler = List.foldl wakeOne m.scheduler processes }

wakeNextTick :: Machine -> Maybe Machine
wakeNextTick m =
  let
    processes = Map.values m.scheduler.processes
    waitingTicks = List.mapMaybe waitingTick processes
  in
    case Foldable.minimum waitingTicks of
      Nothing -> Nothing
      Just nextTick ->
        let
          wakeOne scheduler p = case p.status of
            ProcessWaiting (WaitingForTick tick) | tick <= nextTick ->
              Scheduler.yieldProcess (Scheduler.updateProcess scheduler (p { status = ProcessReady })) p.pid
            _ -> scheduler
          scheduler' = List.foldl wakeOne (m.scheduler { logicalTick = nextTick }) processes
        in Just (m { scheduler = scheduler' })

waitingTick :: Process -> Maybe Int
waitingTick p = case p.status of
  ProcessWaiting (WaitingForTick tick) -> Just tick
  _ -> Nothing

isTerminalStatus :: ProcessStatus -> Boolean
isTerminalStatus = case _ of
  ProcessCompleted _ -> true
  ProcessFailed _ -> true
  ProcessCancelled _ -> true
  ProcessExited _ -> true
  _ -> false

reasonForStatus :: ProcessStatus -> String
reasonForStatus = case _ of
  ProcessCompleted _ -> "normal"
  ProcessFailed _ -> "failed"
  ProcessCancelled _ -> "cancelled"
  ProcessExited _ -> "exited"
  _ -> "alive"

-- | A monitor "DOWN" notification, delivered to the monitoring process's mailbox
-- | when the monitored process terminates: VVariant "DOWN" { ref, pid, reason }.
downMessage :: String -> String -> String -> Value
downMessage ref pid reason =
  VVariant "DOWN" (VRecord (Map.fromFoldable
    [ Tuple "ref" (VString ref)
    , Tuple "pid" (VString pid)
    , Tuple "reason" (VString reason)
    ]))

-- | When a process reaches a terminal state, deliver a DOWN message to every
-- | process monitoring it, drop those monitor entries (so they cannot leak), and
-- | wake any monitor that was blocked waiting for a message. A no-op for
-- | non-terminal transitions and idempotent once the monitor entries are gone.
notifyMonitorsOfDeath :: String -> ProcessStatus -> Machine -> Machine
notifyMonitorsOfDeath deadPid status m =
  if not (isTerminalStatus status) then m
  else
    let
      reason = reasonForStatus status
      observers = Map.values m.scheduler.processes
      handle scheduler q =
        let
          deadRefs = Set.toUnfoldable (Map.keys (Map.filter (_ == deadPid) q.monitors)) :: Array String
        in
          case deadRefs of
            [] -> scheduler
            _ ->
              let
                downs = map (\ref -> downMessage ref deadPid reason) deadRefs
                q' = q
                  { mailbox = q.mailbox <> downs
                  , monitors = Map.filter (_ /= deadPid) q.monitors
                  , status = case q.status of
                      ProcessWaiting WaitingForMessage -> ProcessReady
                      ProcessWaiting (WaitingForMonitor _) -> ProcessReady
                      _ -> q.status
                  }
                scheduler' = Scheduler.updateProcess scheduler q'
              in case q.status of
                   ProcessWaiting WaitingForMessage -> Scheduler.yieldProcess scheduler' q.pid
                   ProcessWaiting (WaitingForMonitor _) -> Scheduler.yieldProcess scheduler' q.pid
                   _ -> scheduler'
    in m { scheduler = List.foldl handle m.scheduler observers }
