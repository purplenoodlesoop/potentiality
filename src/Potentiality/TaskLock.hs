-- | Cross-process advisory locking on a per-task basis. Used to
-- serialize read-modify-write on @task.md@ and @meta.yaml@ — multiple
-- writers exist (the parent stream loop in 'Potentiality.ClaudeCode'
-- AND the agent-side @pot agent done@\/@status@\/@plan@ subcommands
-- that claude invokes through its Bash tool), so without a lock one
-- can clobber the other's fields.
--
-- The lock file lives at @vault\/tasks\/\<id\>\/.lock@. We use POSIX
-- fcntl advisory locks via the 'filelock' library; they're respected
-- across processes on the same host (which is the only deployment
-- topology we support — see @spec\/02-architecture.md@).
module Potentiality.TaskLock
  ( withTaskLock
  ) where

import Path (toFilePath)
import Path.IO (ensureDir)
import Potentiality.Task (TaskId)
import Potentiality.Vault (Vault, taskDir)
import System.FileLock (SharedExclusive (Exclusive), withFileLock)

-- | Run an action with an exclusive lock on a task. Blocks if another
-- process holds the lock. Releases the lock when the action returns or
-- throws.
withTaskLock :: Vault -> TaskId -> IO a -> IO a
withTaskLock vault tid action = do
  td <- taskDir vault tid
  ensureDir td
  let lockPath = toFilePath td <> ".lock"
  withFileLock lockPath Exclusive (\_ -> action)
