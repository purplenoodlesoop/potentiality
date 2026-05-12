{-# LANGUAGE QuasiQuotes #-}

-- | Render a 'Task' to its on-disk form and write it into the vault.
--
-- The format is the inverse of 'Potentiality.Task.Parse.splitFrontmatter':
-- @---\\n\<yaml\>---\\n\<body\>@. Writes are atomic: bytes go to a sibling
-- @.tmp@ file then renamed over the target so a crash never leaves a
-- half-written task.
module Potentiality.Task.Write
  ( renderTask
  , writeTaskFile
  ) where

import Control.Exception (bracketOnError)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text.Encoding qualified as TE
import Data.Yaml qualified as Yaml
import Path (Path, Abs, File, filename, parent, parseRelFile, toFilePath, (</>))
import Path.IO (ensureDir, renameFile)
import Potentiality.Task (Task (..))
import Potentiality.Vault (Vault, taskFile)
import System.IO (Handle, IOMode (WriteMode), hClose, openBinaryFile)

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

-- | Atomically write a task to its location in the vault. Creates the
-- task's directory if needed.
writeTaskFile :: Vault -> Task -> IO ()
writeTaskFile vault task = do
  target <- taskFile vault (taskId task)
  ensureDir (parent target)
  tmp <- siblingTmp target
  bracketOnError
    (openBinaryFile (toFilePath tmp) WriteMode)
    (\h -> hClose h)
    ( \h -> do
        BS.hPut h (renderTask task)
        hClose h
    )
  renameFile tmp target

-- Compose a sibling @\<name\>.tmp@ for a given file path. Used for the
-- write-then-rename atomic-write dance.
siblingTmp :: Path Abs File -> IO (Path Abs File)
siblingTmp p = do
  let dir = parent p
      stem = toFilePath (filename p)
  rel <- parseRelFile (stem <> ".tmp")
  pure (dir </> rel)
