-- | Enumeration helpers over a vault. Reads the on-disk structure without
-- interpreting it; callers parse task files themselves when they need the
-- payload.
module Potentiality.Vault.Scan
  ( listTaskIds
  ) where

import Data.Text qualified as T
import Path (Abs, Dir, Path, dirname, toFilePath)
import Path.IO (doesDirExist, listDir)
import Potentiality.Task (TaskId (..))
import Potentiality.Vault (Vault, tasksDir)

-- | List the task ids present in a vault. Returns @[]@ when the tasks
-- directory does not yet exist (an empty vault).
listTaskIds :: Vault -> IO [TaskId]
listTaskIds vault = do
  let dir = tasksDir vault
  exists <- doesDirExist dir
  if not exists
    then pure []
    else do
      (dirs, _files) <- listDir dir
      pure (map dirToTaskId dirs)

-- 'dirname' returns the final path component with a trailing slash; strip it.
dirToTaskId :: Path Abs Dir -> TaskId
dirToTaskId =
  TaskId . T.dropWhileEnd (== '/') . T.pack . toFilePath . dirname
