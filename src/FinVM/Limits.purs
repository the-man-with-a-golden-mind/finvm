module FinVM.Limits where

type EvalLimits =
  { maxSteps :: Int
  , maxCallDepth :: Int
  , maxProcesses :: Int
  , maxProcessStepsPerSlice :: Int
  , maxRegistersPerFrame :: Int
  , maxFrames :: Int
  , maxListLength :: Int
  , maxMapSize :: Int
  , maxRecordFields :: Int
  , maxValueDepth :: Int
  , maxStateEntries :: Int
  , maxTraceEvents :: Int
  , maxProofEvents :: Int
  , maxMailboxSize :: Int
  , maxRemoteNodes :: Int
  , maxEventsEmitted :: Int
  , maxEffectsRequested :: Int
  }
