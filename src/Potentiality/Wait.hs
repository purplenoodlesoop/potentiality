-- | Block until a file appears, a cancel file appears, or a timeout fires.
--
-- v1 uses 100 ms polling rather than @fsnotify@. The latency a human
-- notices when answering a question is many seconds; an extra 100 ms is
-- invisible. Polling avoids a dependency, has fewer cross-platform
-- gotchas, and is trivial to reason about under crash\/restart.
--
-- 'pot do watch' (phase 7) DOES need fsnotify because the daemon must
-- claim tasks immediately; that's where we'll introduce it.
module Potentiality.Wait
  ( WaitResult (..)
  , waitForFile
  , waitForCondition
  , pollIntervalMicros
  ) where

import Control.Concurrent (threadDelay)
import Path (Abs, File, Path, toFilePath)
import Path.IO (doesFileExist)

data WaitResult a
  = Found a
  | Cancelled
  | TimedOut
  deriving stock (Show, Eq)

-- | Polling interval in microseconds. Tuned for human-perception
-- latency, not throughput; bumping this changes how snappy
-- @pot agent ask@ feels when an answer lands.
pollIntervalMicros :: Int
pollIntervalMicros = 100_000

pollIntervalMs :: Int
pollIntervalMs = pollIntervalMicros `div` 1_000

-- | Wait until @target@ exists, OR any of @cancels@ exists, OR @timeoutSec@
-- elapses. Existence is checked first so the function returns immediately
-- when the file is already there.
waitForFile
  :: Path Abs File
  -> [Path Abs File]
  -> Maybe Int
  -> IO (WaitResult ())
waitForFile target cancels timeoutSec =
  waitForCondition check cancels timeoutSec
  where
    check = do
      e <- doesFileExist target
      pure (if e then Just () else Nothing)

-- | Generalized 'waitForFile': re-runs an arbitrary 'IO (Maybe a)' until
-- it returns @Just@. Used for @pot agent plan@ where the success
-- condition is content-based (a field inside meta.yaml).
waitForCondition
  :: IO (Maybe a)
  -> [Path Abs File]
  -> Maybe Int
  -> IO (WaitResult a)
waitForCondition check cancels timeoutSec = go 0
  where
    deadlineMs = fmap (* 1000) timeoutSec
    go elapsedMs = do
      r <- check
      case r of
        Just a -> pure (Found a)
        Nothing -> do
          cancelled <- anyExists cancels
          if cancelled
            then pure Cancelled
            else case deadlineMs of
              Just lim | elapsedMs >= lim -> pure TimedOut
              _ -> do
                threadDelay pollIntervalMicros
                go (elapsedMs + pollIntervalMs)

anyExists :: [Path Abs File] -> IO Bool
anyExists [] = pure False
anyExists (p : ps) = do
  e <- doesFileExist p
  if e then pure True else anyExists ps

-- Re-export for callers that want to convert paths.
_toFilePath :: Path Abs File -> FilePath
_toFilePath = toFilePath
