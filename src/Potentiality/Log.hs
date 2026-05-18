-- | Single-line structured event logging to stderr. Each call emits
-- one JSON object terminated by a newline; the systemd journal
-- captures the daemon's stderr automatically so each event becomes
-- one journal entry. Volume is bounded: only major lifecycle events
-- (task claim, agent spawn, question ask, answer receive, status
-- transition, task close) — never per-tool-call or per-write.
--
-- Operator's view: @journalctl --user -u potentiality.service@ shows
-- one line per event, parseable with @jq@.
module Potentiality.Log
  ( logEvent
  ) where

import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Text (Text)
import Data.Time (getCurrentTime)
import System.IO (stderr)

-- | Emit a structured one-line JSON event to stderr.
--
-- > logEvent "task_claimed" [("task", toJSON tid)]
--
-- Output (one line):
--
-- > {"ts":"2026-05-18T19:04:17.123456Z","event":"task_claimed","task":"01XYZ..."}
logEvent :: Text -> [(Text, Value)] -> IO ()
logEvent event fields = do
  now <- getCurrentTime
  let payload =
        object $
          [ "ts" .= now
          , "event" .= event
          ]
            <> map (uncurry (.=)) fields
  BL.hPut stderr (encode payload)
  BL8.hPutStr stderr "\n"
