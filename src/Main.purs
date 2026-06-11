module Main where

import Prelude
import Effect (Effect)
import Effect.Console (log)
import Effect.Exception (try, message)
import Node.Process (argv, setExitCode)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Node.FS.Sync (readTextFile)
import Node.Encoding (Encoding(UTF8))
import Benchmark.Statistics as Statistics
import Benchmark.Graph as Graph
import FinVM.Encoding.Json as Json

main :: Effect Unit
main = do
  args <- argv
  case Array.index args 2 of
    Just "bench" -> do
      log "--- FinVM Statistics Benchmark ---"
      Statistics.runBenchmark true 10000
      Statistics.runBenchmark false 10000

      log "\n--- FinVM Graph Benchmark ---"
      Graph.runBenchmark true 10000
      Graph.runBenchmark false 10000
    Just "run" ->
      case Array.index args 3 of
        Just path -> do
          log $ "Loading program from: " <> path
          readResult <- try (readTextFile UTF8 path)
          case readResult of
            Left err -> do
              log $ Json.errorJson (message err)
              setExitCode 1
            Right content -> do
              let res = Json.runJsonProgramResult content
              log res.output
              if res.ok then pure unit else setExitCode 1
        Nothing -> do
          log "Error: Please provide a path to a program file."
          setExitCode 1
    Just _ -> do
      usage
      setExitCode 1
    Nothing -> usage

usage :: Effect Unit
usage = do
  log "FinVM CLI"
  log "Usage: finvm run <file.json>"
  log "       finvm bench"
