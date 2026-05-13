{-# LANGUAGE QuasiQuotes #-}

-- | Spawn @claude -p --output-format=stream-json@ for one task; pipe its
-- events into the task's @transcript.md@ \/ @transcript.jsonl@; update
-- @meta.yaml@ on init and result; flip @status@ on exit. Mirrors
-- @spec\/06-claude-code-backend.md@.
module Potentiality.ClaudeCode
  ( runClaude
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Exception (IOException, catch)
import Control.Monad (unless)
import Data.Aeson (eitherDecodeStrict)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BSC
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (getCurrentTime)
import Path (Abs, File, Path, toFilePath)
import Path.IO (doesFileExist, ensureDir)
import Potentiality.Kind (KindSpec (..), basePromptPreamble, kindSpec)
import Potentiality.Meta (Meta (..), Tokens (..), mutateMeta)
import Potentiality.Preferences (loadPreferences, prefsToSystemPrompt)
import Potentiality.StreamJson
  ( Event (..)
  , InitInfo (..)
  , ResultInfo (..)
  , Usage (..)
  , isContinuation
  , parseEvent
  , renderEvent
  )
import Potentiality.Task (Frontmatter (..), Mode (..), Status (..), Task (..), TaskId (..), permissionModeText)
import Potentiality.Task.Write (mutateFrontmatter)
import Potentiality.Vault (Vault (..), cancelFile, taskDir, transcriptFile, transcriptJsonlFile)
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory)
import System.IO (Handle, hIsEOF)
import System.Process.Typed qualified as P

-- | Drive Claude Code for a single task to completion.
runClaude :: Vault -> Task -> IO ()
runClaude vault task = do
  let tid = taskId task
      fm = taskFrontmatter task
      kind = fmKind fm
      ks = kindSpec kind
      mode = maybe (ksDefaultMode ks) id (fmMode fm)
      permMode = maybe (ksDefaultPermission ks) id (fmPermissionMode fm)
      tools = maybe (ksTools ks) id (fmAllowedTools fm)

  prefs <- loadPreferences vault
  let prefSection = prefsToSystemPrompt prefs
      systemAppend =
        basePromptPreamble
          <> "\n"
          <> ksPromptAddendum ks
          <> "\nMode: "
          <> modeTextOf mode
          <> "\n"
          <> prefSection

  td <- taskDir vault tid
  let workdir = maybe (toFilePath td) id (fmRepo fm)

  envBase <- getEnvironment
  selfPath <- getExecutablePath
  let selfDir = takeDirectory selfPath
      oldPath = maybe "" id (lookup "PATH" envBase)
      newPath = selfDir <> ":" <> oldPath
      envExtras =
        [ ("POTENTIALITY_TASK_DIR", toFilePath td)
        , ("POTENTIALITY_SESSION", T.unpack (unTaskId tid))
        , ("PATH", newPath)
        ]
      envFinal = envExtras <> filter (\(k, _) -> k `notElem` map fst envExtras) envBase

      modelArgs = case fmModel fm of
        Nothing -> []
        Just m -> ["--model", T.unpack m]

      -- NOTE: deliberately no `--bare`; see spec/06 / LIMITATIONS.md.
      args =
        modelArgs
          <> [ "-p"
             , "--output-format"
             , "stream-json"
             , "--include-partial-messages"
             , "--append-system-prompt"
             , T.unpack systemAppend
             , "--allowedTools"
             , T.unpack (T.intercalate "," tools)
             , "--permission-mode"
             , T.unpack (permissionModeText permMode)
             , "--disallowedTools"
             , "ScheduleWakeup"
             ]
          <> budgetArgs (fmBudgetUsd fm)
          <> ["--", T.unpack (taskBody task)]

  ensureDir =<< taskDir vault tid
  startedAt <- getCurrentTime
  mutateFrontmatter vault tid (\f -> f {fmStatus = InProgress})
  mutateMeta vault tid (\m -> m {metaStartedAt = Just startedAt})

  cancelFp <- cancelFile vault tid

  let cfg =
        -- Close stdin so claude doesn't wait 3s for piped input that
        -- never comes. The task body is passed via argv (after `--`),
        -- so claude has no use for stdin.
        P.setStdin P.closed $
          P.setStdout P.createPipe $
            P.setStderr P.inherit $
              P.setWorkingDir workdir $
                P.setEnv envFinal $
                  P.proc "claude" args

  exitCode <-
    P.withProcessWait cfg $ \p ->
      -- Run streamLoop AND a CANCEL watcher concurrently. withAsync
      -- cancels the watcher when streamLoop returns (claude exited
      -- naturally). If the watcher trips first (CANCEL appeared), it
      -- sends SIGTERM via stopProcess; claude's stdout closes;
      -- streamLoop sees EOF and returns; everything unwinds.
      withAsync (cancelWatcher cancelFp p) $ \_ -> do
        streamLoop vault tid (P.getStdout p)
        P.waitExitCode p

  finishedAt <- getCurrentTime
  case exitCode of
    ExitSuccess -> do
      mutateMeta vault tid (\m -> m {metaFinishedAt = Just finishedAt})
      mutateFrontmatter vault tid $ \f -> case fmStatus f of
        InProgress -> f {fmStatus = Done}
        _ -> f
    ExitFailure code -> do
      mutateFrontmatter vault tid (\f -> f {fmStatus = Blocked})
      mutateMeta vault tid (\m -> m {metaFinishedAt = Just finishedAt})
      transcriptFp <- transcriptFile vault tid
      BS.appendFile (toFilePath transcriptFp) $
        TE.encodeUtf8 ("\n## claude exited with code " <> T.pack (show code) <> "\n")

-- | Poll for the CANCEL file every 200 ms. On first appearance, send
-- SIGTERM via 'P.stopProcess' (which also escalates to SIGKILL after
-- 5 s if the process doesn't oblige). Loops forever; 'withAsync' kills
-- this thread when the main work finishes.
cancelWatcher :: Path Abs File -> P.Process stdin stdout stderr -> IO ()
cancelWatcher cancelFp p = loop
  where
    loop = do
      e <- doesFileExist cancelFp
      if e
        then P.stopProcess p
        else do
          threadDelay 200_000
          loop

modeTextOf :: Mode -> Text
modeTextOf = \case
  Ask -> "ask"
  Delegate -> "delegate"

budgetArgs :: Maybe Double -> [String]
budgetArgs Nothing = []
budgetArgs (Just b) = ["--max-budget-usd", show b]

streamLoop :: Vault -> TaskId -> Handle -> IO ()
streamLoop vault tid h =
  -- When the parent stopProcess closes the read pipe (CANCEL path),
  -- a mid-read hGetLine throws an IOException. Treat that as EOF so
  -- the caller still reaches waitExitCode and the ExitFailure branch
  -- can flip status to Blocked. We don't lose any data — anything
  -- claude wrote before being killed has already been flushed to
  -- transcript.md / transcript.jsonl.
  loop `catch` \(_ :: IOException) -> pure ()
  where
    loop = do
      eof <- hIsEOF h
      unless eof $ do
        line <- BSC.hGetLine h
        transcriptFp <- transcriptFile vault tid
        jsonlFp <- transcriptJsonlFile vault tid
        BS.appendFile (toFilePath jsonlFp) (line <> "\n")
        case eitherDecodeStrict line of
          Left err ->
            BS.appendFile (toFilePath transcriptFp) $
              TE.encodeUtf8 ("\n## parse error: " <> T.pack err <> "\n")
          Right val -> do
            let ev = parseEvent val
                rendered = renderEvent ev
                suffix = if isContinuation ev then "" else "\n"
            unless (T.null rendered) $
              BS.appendFile (toFilePath transcriptFp) (TE.encodeUtf8 (rendered <> suffix))
            handleSideEffects vault tid ev
        loop

handleSideEffects :: Vault -> TaskId -> Event -> IO ()
handleSideEffects vault tid = \case
  EInit ii -> mutateMeta vault tid (\m -> m {metaClaudeSessionId = Just (iiSessionId ii)})
  EResult ri ->
    mutateMeta vault tid $ \m ->
      m
        { metaTotalCostUsd = riCostUsd ri
        , metaTokens = (\u -> Tokens (uInput u) (uOutput u) (uCacheRead u)) <$> riUsage ri
        }
  _ -> pure ()
