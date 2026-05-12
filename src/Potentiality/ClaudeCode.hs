{-# LANGUAGE QuasiQuotes #-}

-- | Spawn @claude -p --output-format=stream-json@ for one task; pipe its
-- events into the task's @transcript.md@ \/ @transcript.jsonl@; update
-- @meta.yaml@ on init and result; flip @status@ on exit. Mirrors
-- @spec\/06-claude-code-backend.md@.
module Potentiality.ClaudeCode
  ( runClaude
  ) where

import Control.Monad (unless)
import Data.Aeson (eitherDecodeStrict)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BSC
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (getCurrentTime)
import Path (Abs, Dir, Path, parent, parseAbsDir, toFilePath)
import Path.IO (ensureDir)
import Potentiality.Atomic (atomicWriteBinaryFile)
import Potentiality.Kind (KindSpec (..), basePromptPreamble, kindSpec)
import Potentiality.Meta (Meta (..), Tokens (..), mutateMeta)
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
import Potentiality.Vault (Vault (..), taskDir, transcriptFile, transcriptJsonlFile)
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory)
import System.IO (Handle, hIsEOF)
import System.Process.Typed qualified as P

-- | Drive Claude Code for a single task to completion.
--
-- - working dir = @fmRepo@ when set, otherwise the task directory itself
-- - flags driven by 'kindSpec' \+ frontmatter overrides
-- - status: @InProgress@ on entry, @Done@\/@Blocked@ on exit
runClaude :: Vault -> Task -> IO ()
runClaude vault task = do
  let tid = taskId task
      fm = taskFrontmatter task
      kind = fmKind fm
      ks = kindSpec kind
      mode = maybe (ksDefaultMode ks) id (fmMode fm)
      permMode = maybe (ksDefaultPermission ks) id (fmPermissionMode fm)
      tools = maybe (ksTools ks) id (fmAllowedTools fm)
      systemAppend =
        basePromptPreamble
          <> "\n"
          <> ksPromptAddendum ks
          <> "\nMode: "
          <> modeTextOf mode
          <> "\n"

  td <- taskDir vault tid
  let workdir = maybe (toFilePath td) id (fmRepo fm)

  envBase <- getEnvironment
  selfPath <- getExecutablePath
  -- Prepend our own binary's directory so the spawned claude (and the
  -- bash subcommands it invokes) finds the same `pot` we are.
  let selfDir = takeDirectory selfPath
      oldPath = maybe "" id (lookup "PATH" envBase)
      newPath = selfDir <> ":" <> oldPath
      envExtras =
        [ ("POTENTIALITY_TASK_DIR", toFilePath td)
        , ("POTENTIALITY_SESSION", T.unpack (unTaskId tid))
        , ("PATH", newPath)
        ]
      envFinal = envExtras <> filter (\(k, _) -> k `notElem` map fst envExtras) envBase

      -- NOTE: We intentionally do NOT pass `--bare`. It skips credential
      -- discovery as well as hook/MCP/CLAUDE.md auto-discovery, so the
      -- spawn ends up "Not logged in" even when the user has a working
      -- subscription. We rely on --allowedTools instead to constrain the
      -- tool surface. The cost is that the user's CLAUDE.md / hooks /
      -- MCPs leak into spawns; for a single-user setup that's fine.
      args =
        [ "-p"
        , "--output-format"
        , "stream-json"
        , "--include-partial-messages"
        , "--append-system-prompt"
        , T.unpack systemAppend
        , "--allowedTools"
        , T.unpack (T.intercalate "," tools)
        , "--permission-mode"
        , T.unpack (permissionModeText permMode)
        ]
          <> budgetArgs (fmBudgetUsd fm)
          <> ["--", T.unpack (taskBody task)]

  ensureDir =<< taskDir vault tid
  startedAt <- getCurrentTime
  mutateFrontmatter vault tid (\f -> f {fmStatus = InProgress})
  mutateMeta vault tid (\m -> m {metaStartedAt = Just startedAt})

  let cfg =
        P.setStdout P.createPipe $
          P.setStderr P.inherit $
            P.setWorkingDir workdir $
              P.setEnv envFinal $
                P.proc "claude" args

  exitCode <-
    P.withProcessWait cfg $ \p -> do
      streamLoop vault tid (P.getStdout p)
      P.waitExitCode p

  finishedAt <- getCurrentTime
  case exitCode of
    ExitSuccess -> do
      mutateMeta vault tid (\m -> m {metaFinishedAt = Just finishedAt})
      -- Default-flip to Done if the agent didn't call `pot agent done`
      -- or `pot agent blocked`; respect any explicit terminal status.
      mutateFrontmatter vault tid $ \f -> case fmStatus f of
        InProgress -> f {fmStatus = Done}
        _ -> f
    ExitFailure code -> do
      mutateFrontmatter vault tid (\f -> f {fmStatus = Blocked})
      mutateMeta vault tid (\m -> m {metaFinishedAt = Just finishedAt})
      transcriptFp <- transcriptFile vault tid
      BS.appendFile (toFilePath transcriptFp) $
        TE.encodeUtf8 ("\n## claude exited with code " <> T.pack (show code) <> "\n")

-- 'pot agent done' will normally have flipped to Done already, but
-- guard against tasks where the agent didn't call it: if status is
-- still InProgress after a clean exit, mark Done here.
-- (handled inline above for simplicity by only mutating to Blocked
-- on failure; clean exit keeps whatever the agent set)

modeTextOf :: Mode -> Text
modeTextOf = \case
  Ask -> "ask"
  Delegate -> "delegate"

budgetArgs :: Maybe Double -> [String]
budgetArgs Nothing = []
budgetArgs (Just b) = ["--max-budget-usd", show b]

streamLoop :: Vault -> TaskId -> Handle -> IO ()
streamLoop vault tid h = loop
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

-- Silence unused warnings for symbols intended for phase 7 (workspaces,
-- cancel handling).
_unusedAbsDir :: Maybe (Path Abs Dir)
_unusedAbsDir = parseAbsDir "/tmp/"

_unusedAtomic :: Path Abs Dir -> IO ()
_unusedAtomic _ = pure ()

_unusedParent :: Path Abs Dir -> Path Abs Dir
_unusedParent = parent

_unusedAtomicWrite :: Path Abs Dir -> IO ()
_unusedAtomicWrite _ = pure ()
