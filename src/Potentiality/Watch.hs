-- | Long-running watcher: claim any @status: ready@ task with no
-- @agent_owner@, spawn a claude run, retire the slot, repeat. fsnotify
-- triggers a rescan on every event under @tasks\/@; the scan is cheap
-- (a directory listing plus one frontmatter parse per task), so we
-- accept some redundant work in exchange for guaranteed liveness.
--
-- Single-writer invariant: only one @pot do watch@ per vault. Multiple
-- watchers would race on claim. We document the constraint instead of
-- enforcing a lockfile.
module Potentiality.Watch
  ( watchVault
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, writeTVar)
import Control.Exception (SomeException, catch)
import Control.Monad (forM_, forever, void, when)
import Data.Aeson (toJSON)
import Data.Text (Text)
import Data.Text qualified as T
import Path (toFilePath)
import Path.IO (ensureDir)
import Potentiality.ClaudeCode (runClaude)
import Potentiality.Log (logEvent)
import Potentiality.Task (Frontmatter (..), Status (..), Task (..), TaskId)
import Potentiality.Task.Write (mutateFrontmatter, readTaskMaybe)
import Potentiality.Vault (Vault, tasksDir)
import Potentiality.Vault.Scan (listTaskIds)
import System.FSNotify (withManager, watchTree)
import System.IO (hPutStrLn, stderr)
import System.Posix.Process (getProcessID)

-- | Watch a vault forever. 'maxConcurrent' caps how many claude
-- subprocesses can be in flight at once; ready tasks queue up
-- implicitly via subsequent fsnotify events.
watchVault :: Vault -> Int -> IO ()
watchVault vault maxConcurrent = do
  ensureDir (tasksDir vault)
  logEvent "watch_started" [("max_concurrent", toJSON maxConcurrent)]
  slots <- newTVarIO 0
  scanAndClaim vault slots maxConcurrent
  withManager $ \mgr -> do
    _stop <-
      watchTree
        mgr
        (toFilePath (tasksDir vault))
        (const True)
        (\_event -> scanAndClaim vault slots maxConcurrent)
    forever (threadDelay 3600_000_000)

scanAndClaim :: Vault -> TVar Int -> Int -> IO ()
scanAndClaim vault slots maxC = do
  tids <- listTaskIds vault
  forM_ tids $ \tid -> tryClaimAndSpawn vault tid slots maxC

tryClaimAndSpawn :: Vault -> TaskId -> TVar Int -> Int -> IO ()
tryClaimAndSpawn vault tid slots maxC = do
  reserved <- atomically $ do
    n <- readTVar slots
    if n < maxC
      then writeTVar slots (n + 1) >> pure True
      else pure False
  when reserved $ do
    claimed <- claim vault tid
    if claimed
      then void $ forkIO $ runOne vault tid slots
      else atomically (modifyTVar' slots (subtract 1))

claim :: Vault -> TaskId -> IO Bool
claim vault tid = do
  mTask <- readTaskMaybe vault tid
  case mTask of
    Just (Right task)
      | fmStatus (taskFrontmatter task) == Ready
      , fmAgentOwner (taskFrontmatter task) == Nothing -> do
          owner <- mkOwner
          mutateFrontmatter vault tid $ \f -> f {fmAgentOwner = Just owner}
          logEvent
            "task_claimed"
            [ ("task", toJSON tid)
            , ("owner", toJSON owner)
            ]
          pure True
    _ -> pure False

mkOwner :: IO Text
mkOwner = do
  pid <- getProcessID
  pure (T.pack ("pot:" <> show pid))

runOne :: Vault -> TaskId -> TVar Int -> IO ()
runOne vault tid slots = do
  mTask <- readTaskMaybe vault tid
  case mTask of
    Just (Right task) -> do
      logEvent "agent_spawned" [("task", toJSON tid)]
      runClaude vault task
        `catch` ( \(e :: SomeException) -> do
                    hPutStrLn stderr ("watch: claude run failed for " <> show tid <> ": " <> show e)
                    logEvent
                      "agent_failed"
                      [ ("task", toJSON tid)
                      , ("error", toJSON (T.pack (show e)))
                      ]
                )
      logEvent "agent_exited" [("task", toJSON tid)]
    _ -> do
      hPutStrLn stderr ("watch: could not re-read task after claim: " <> show tid)
      logEvent "claim_reread_failed" [("task", toJSON tid)]
  atomically (modifyTVar' slots (subtract 1))
