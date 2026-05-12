-- | Render a 'Task' to its on-disk form and write it into the vault, plus
-- helpers for higher-level mutations (read-modify-write on a single
-- task).
--
-- The on-disk format is the inverse of
-- 'Potentiality.Task.Parse.splitFrontmatter':
-- @---\\n\<yaml\>---\\n\<body\>@. Writes go through
-- 'Potentiality.Atomic.atomicWriteBinaryFile' so a crash never leaves a
-- half-written task.
module Potentiality.Task.Write
  ( renderTask
  , writeTaskFile
  , readTask
  , readTaskMaybe
  , mutateTask
  , mutateFrontmatter
  , TaskReadError (..)
  ) where

import Control.Exception (Exception, throwIO)
import Data.ByteString (ByteString)
import Data.Text.Encoding qualified as TE
import Data.Yaml qualified as Yaml
import Path (toFilePath)
import Path.IO (doesFileExist)
import Potentiality.Atomic (atomicWriteBinaryFile)
import Potentiality.Task (Frontmatter, Task (..), TaskId)
import Potentiality.Task.Parse (ParseError, parseTaskFile)
import Potentiality.Vault (Vault, taskFile)

-- | Pure rendering of a 'Task' into the canonical on-disk byte sequence.
renderTask :: Task -> ByteString
renderTask task =
  mconcat
    [ openFence
    , Yaml.encode (taskFrontmatter task)
    , closeFence
    , TE.encodeUtf8 (taskBody task)
    ]
  where
    openFence = "---\n"
    closeFence = "---\n"

-- | Crash-safe write of a task to its location in the vault. Creates the
-- task's directory if needed.
writeTaskFile :: Vault -> Task -> IO ()
writeTaskFile vault task = do
  target <- taskFile vault (taskId task)
  atomicWriteBinaryFile target (renderTask task)

data TaskReadError
  = TaskNotFound TaskId
  | TaskParseError TaskId ParseError
  deriving stock (Show)

instance Exception TaskReadError

-- | Read a 'Task' from the vault; throws 'TaskReadError' on missing
-- file or parse failure.
readTask :: Vault -> TaskId -> IO Task
readTask vault tid = do
  fp <- taskFile vault tid
  exists <- doesFileExist fp
  if not exists
    then throwIO (TaskNotFound tid)
    else do
      result <- parseTaskFile tid (toFilePath fp)
      either (throwIO . TaskParseError tid) pure result

-- | Read a 'Task'; returns @Nothing@ if the file is missing, @Just (Left
-- err)@ if it parses badly, @Just (Right t)@ on success. Useful for
-- 'pot do list' which must keep going past one broken task.
readTaskMaybe :: Vault -> TaskId -> IO (Maybe (Either ParseError Task))
readTaskMaybe vault tid = do
  fp <- taskFile vault tid
  exists <- doesFileExist fp
  if not exists
    then pure Nothing
    else Just <$> parseTaskFile tid (toFilePath fp)

-- | Atomically read, transform, and re-write a 'Task'.
mutateTask :: Vault -> TaskId -> (Task -> Task) -> IO ()
mutateTask vault tid f = readTask vault tid >>= writeTaskFile vault . f

-- | Mutate just the frontmatter, preserving the body verbatim.
mutateFrontmatter :: Vault -> TaskId -> (Frontmatter -> Frontmatter) -> IO ()
mutateFrontmatter vault tid f =
  mutateTask vault tid $ \t ->
    t {taskFrontmatter = f (taskFrontmatter t)}
