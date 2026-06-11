module FinVM.Error where

import Prelude

data ErrorCode
  = InvalidProgram
  | InvalidInstruction
  | InvalidRegister
  | InvalidJump
  | UnknownFunction
  | UnknownBuiltin
  | ArityMismatch
  | TypeMismatch
  | DivisionByZero
  | ArithmeticOverflow
  | ArithmeticError
  | NoModularInverse
  | InvalidRoundingMode
  | MissingInput
  | MissingContext
  | MissingState
  | StatePathInvalid
  | ProcessNotFound
  | ProcessDeadlock
  | ProcessCancelled
  | MailboxTooLarge
  | RemoteNodeUnknown
  | RemoteProcessUnknown
  | AmbiguousTransition
  | NoTransition
  | GuardRejected
  | InvariantFailed
  | ProofAssertionFailed
  | StepLimitExceeded
  | TraceLimitExceeded
  | UnsupportedVersion
  | CustomErrorCode Int

derive instance eqErrorCode :: Eq ErrorCode
derive instance ordErrorCode :: Ord ErrorCode
instance showErrorCode :: Show ErrorCode where
  show = case _ of
    InvalidProgram -> "InvalidProgram"
    InvalidInstruction -> "InvalidInstruction"
    InvalidRegister -> "InvalidRegister"
    InvalidJump -> "InvalidJump"
    UnknownFunction -> "UnknownFunction"
    UnknownBuiltin -> "UnknownBuiltin"
    ArityMismatch -> "ArityMismatch"
    TypeMismatch -> "TypeMismatch"
    DivisionByZero -> "DivisionByZero"
    ArithmeticOverflow -> "ArithmeticOverflow"
    ArithmeticError -> "ArithmeticError"
    NoModularInverse -> "NoModularInverse"
    InvalidRoundingMode -> "InvalidRoundingMode"
    MissingInput -> "MissingInput"
    MissingContext -> "MissingContext"
    MissingState -> "MissingState"
    StatePathInvalid -> "StatePathInvalid"
    ProcessNotFound -> "ProcessNotFound"
    ProcessDeadlock -> "ProcessDeadlock"
    ProcessCancelled -> "ProcessCancelled"
    MailboxTooLarge -> "MailboxTooLarge"
    RemoteNodeUnknown -> "RemoteNodeUnknown"
    RemoteProcessUnknown -> "RemoteProcessUnknown"
    AmbiguousTransition -> "AmbiguousTransition"
    NoTransition -> "NoTransition"
    GuardRejected -> "GuardRejected"
    InvariantFailed -> "InvariantFailed"
    ProofAssertionFailed -> "ProofAssertionFailed"
    StepLimitExceeded -> "StepLimitExceeded"
    TraceLimitExceeded -> "TraceLimitExceeded"
    UnsupportedVersion -> "UnsupportedVersion"
    CustomErrorCode c -> "CustomErrorCode " <> show c

data VMError = VMError ErrorCode String

derive instance eqVMError :: Eq VMError
derive instance ordVMError :: Ord VMError
instance showVMError :: Show VMError where
  show (VMError code msg) = "VMError " <> show code <> ": " <> msg
