{-# LANGUAGE QuasiQuotes #-}

-- | Path conventions for the vault as defined in @spec/03-vault-layout.md@.
--
-- Each task lives under @\<vault\>\/tasks\/\<ulid\>\/@ with a fixed set of
-- well-known files and subdirectories. This module is the single place
-- those paths are constructed; nothing else should be hand-joining strings.
module Potentiality.Vault
  ( Vault (..)
  , tasksDir
  , taskDir
  , taskFile
  , metaFile
  , transcriptFile
  , transcriptJsonlFile
  , planFile
  , findingsFile
  , questionsDir
  , questionFile
  , answerFile
  , inboxDir
  , cancelFile
  , parseTaskId
  ) where

import Control.Monad.Catch (MonadThrow)
import Data.Text (Text)
import Data.Text qualified as T
import Path
import Potentiality.Task (TaskId (..))

-- | A vault is identified by its absolute root directory. The directory
-- need not exist on disk at the time the 'Vault' is constructed.
newtype Vault = Vault {vaultRoot :: Path Abs Dir}
  deriving stock (Show, Eq)

tasksDir :: Vault -> Path Abs Dir
tasksDir (Vault root) = root </> [reldir|tasks|]

-- | The directory for a single task. May fail in 'MonadThrow' if the id
-- contains characters disallowed by the 'Path' library; ULIDs (Crockford
-- base32) never do.
taskDir :: MonadThrow m => Vault -> TaskId -> m (Path Abs Dir)
taskDir v (TaskId t) = do
  rel <- parseRelDir (T.unpack t)
  pure (tasksDir v </> rel)

taskFile :: MonadThrow m => Vault -> TaskId -> m (Path Abs File)
taskFile v tid = (</> [relfile|task.md|]) <$> taskDir v tid

metaFile :: MonadThrow m => Vault -> TaskId -> m (Path Abs File)
metaFile v tid = (</> [relfile|meta.yaml|]) <$> taskDir v tid

transcriptFile :: MonadThrow m => Vault -> TaskId -> m (Path Abs File)
transcriptFile v tid = (</> [relfile|transcript.md|]) <$> taskDir v tid

transcriptJsonlFile :: MonadThrow m => Vault -> TaskId -> m (Path Abs File)
transcriptJsonlFile v tid = (</> [relfile|transcript.jsonl|]) <$> taskDir v tid

planFile :: MonadThrow m => Vault -> TaskId -> m (Path Abs File)
planFile v tid = (</> [relfile|plan.md|]) <$> taskDir v tid

findingsFile :: MonadThrow m => Vault -> TaskId -> m (Path Abs File)
findingsFile v tid = (</> [relfile|findings.md|]) <$> taskDir v tid

cancelFile :: MonadThrow m => Vault -> TaskId -> m (Path Abs File)
cancelFile v tid = (</> [relfile|CANCEL|]) <$> taskDir v tid

questionsDir :: MonadThrow m => Vault -> TaskId -> m (Path Abs Dir)
questionsDir v tid = (</> [reldir|questions|]) <$> taskDir v tid

inboxDir :: MonadThrow m => Vault -> TaskId -> m (Path Abs Dir)
inboxDir v tid = (</> [reldir|inbox|]) <$> taskDir v tid

-- | The on-disk name for the n-th question, zero-padded to three digits.
-- E.g. @questions\/007.md@.
questionFile :: MonadThrow m => Vault -> TaskId -> Int -> m (Path Abs File)
questionFile v tid n = do
  dir <- questionsDir v tid
  rel <- parseRelFile (zeroPad 3 n <> ".md")
  pure (dir </> rel)

-- | Companion to 'questionFile' for the answer.
answerFile :: MonadThrow m => Vault -> TaskId -> Int -> m (Path Abs File)
answerFile v tid n = do
  dir <- questionsDir v tid
  rel <- parseRelFile (zeroPad 3 n <> ".answer.md")
  pure (dir </> rel)

zeroPad :: Int -> Int -> FilePath
zeroPad width n = replicate (max 0 (width - length s)) '0' <> s
  where
    s = show n

-- | Lift a directory name into a 'TaskId'. No validation; ULID structure is
-- a convention, not a guarantee. Listing 'tasksDir' and lifting each entry
-- is the canonical way to enumerate tasks.
parseTaskId :: Text -> TaskId
parseTaskId = TaskId
