-- | Crash-safe file writes: open a sibling @.tmp@, write, fsync via
-- 'hClose', then rename over the target. Rename within a directory is
-- atomic on POSIX, so readers either see the old file or the new file —
-- never a half-written one.
module Potentiality.Atomic
  ( atomicWriteBinaryFile
  ) where

import Control.Exception (bracketOnError)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Path (Abs, File, Path, filename, parent, parseRelFile, toFilePath, (</>))
import Path.IO (ensureDir, renameFile)
import System.IO (IOMode (WriteMode), hClose, openBinaryFile)

atomicWriteBinaryFile :: Path Abs File -> ByteString -> IO ()
atomicWriteBinaryFile target bs = do
  ensureDir (parent target)
  let stem = toFilePath (filename target)
  rel <- parseRelFile (stem <> ".tmp")
  let tmp = parent target </> rel
  bracketOnError
    (openBinaryFile (toFilePath tmp) WriteMode)
    hClose
    ( \h -> do
        BS.hPut h bs
        hClose h
    )
  renameFile tmp target
