module Potentiality (run) where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Data.Version (showVersion)
import Options.Applicative
import Path (Abs, Dir, Path, parseAbsDir)
import Path.IO (getCurrentDir)
import Potentiality.Task
  ( Frontmatter (..)
  , PlanApproval (..)
  , Priority (Med)
  , Task (..)
  , TaskId (..)
  , parseKind
  , parseMode
  , parsePriority
  , parseStatus
  , schemaVersion
  )
import Potentiality.Task.Write (writeTaskFile)
import Potentiality.Ulid (newUlid)
import Potentiality.Vault (Vault (..))
import Potentiality.Version (version)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | Top-level command tree. Mirrors the CLI grouping in
-- @spec\/04-cli.md@: @pot do *@ for orchestrator\/human verbs, @pot agent
-- *@ for agent-side verbs.
data Command
  = CmdDo DoCommand
  | CmdAgent AgentCommand

data DoCommand
  = DoNew DoNewOpts

data AgentCommand
  = AgentTodo -- placeholder; filled in once `pot agent ask` lands

data DoNewOpts = DoNewOpts
  { dnKind :: Text
  , dnTitle :: Maybe Text
  , dnMode :: Maybe Text
  , dnRepo :: Maybe FilePath
  , dnStatus :: Text
  , dnPriority :: Maybe Text
  , dnVault :: Maybe FilePath
  , dnBody :: Maybe Text
  }

-- ---------------------------------------------------------------------------
-- Parser

opts :: ParserInfo Command
opts =
  info
    (commandParser <**> versionFlag <**> helper)
    ( fullDesc
        <> progDesc "Potentiality — Haskell agent runner over a Markdown vault."
        <> header ("pot " <> showVersion version)
    )

versionFlag :: Parser (a -> a)
versionFlag =
  infoOption
    (showVersion version)
    (long "version" <> short 'V' <> help "Print version and exit")

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command "do" (info (CmdDo <$> doParser) (progDesc "Orchestrator-side commands"))
        <> command "agent" (info (CmdAgent <$> agentParser) (progDesc "Agent-side commands (invoked by claude through Bash)"))
    )

doParser :: Parser DoCommand
doParser =
  hsubparser
    (command "new" (info (DoNew <$> doNewOpts) (progDesc "Create a new task in the vault")))

doNewOpts :: Parser DoNewOpts
doNewOpts =
  DoNewOpts
    <$> strOption
      ( long "kind"
          <> metavar "KIND"
          <> value "general"
          <> showDefault
          <> help "code | research | design | review | general"
      )
    <*> optional (strOption (long "title" <> metavar "TITLE" <> help "Short one-line title"))
    <*> optional (strOption (long "mode" <> metavar "MODE" <> help "ask | delegate"))
    <*> optional (strOption (long "repo" <> metavar "PATH" <> help "Working directory for the spawn"))
    <*> strOption
      ( long "status"
          <> metavar "STATUS"
          <> value "inbox"
          <> showDefault
          <> help "Starting status; pass ready to skip triage"
      )
    <*> optional (strOption (long "priority" <> metavar "P" <> help "low | med | high"))
    <*> optional (strOption (long "vault" <> metavar "PATH" <> help "Vault root (defaults to $POTENTIALITY_VAULT or .)"))
    <*> optional (strArgument (metavar "BODY" <> help "Task body (Markdown). Quote it."))

agentParser :: Parser AgentCommand
agentParser =
  hsubparser
    (command "todo" (info (pure AgentTodo) (progDesc "Placeholder for upcoming agent verbs")))

-- ---------------------------------------------------------------------------
-- Dispatch

run :: IO ()
run = do
  cmd <- execParser opts
  case cmd of
    CmdDo (DoNew o) -> doNew o
    CmdAgent AgentTodo -> die "pot agent: no verbs implemented yet"

doNew :: DoNewOpts -> IO ()
doNew o = do
  kind <- parseEnumE "--kind" parseKind (dnKind o)
  status <- parseEnumE "--status" parseStatus (dnStatus o)
  mode <- traverse (parseEnumE "--mode" parseMode) (dnMode o)
  priority <- case dnPriority o of
    Nothing -> pure Nothing
    Just t -> Just <$> parseEnumE "--priority" parsePriority t
  now <- getCurrentTime
  vault <- resolveVault (dnVault o)
  tid <- TaskId <$> newUlid
  let body = maybe "" id (dnBody o)
      title = maybe (deriveTitleFromBody body) id (dnTitle o)
      fm =
        Frontmatter
          { fmSchema = schemaVersion
          , fmKind = kind
          , fmStatus = status
          , fmTitle = title
          , fmCreated = now
          , fmMode = mode
          , fmRepo = dnRepo o
          , fmPriority = maybe Med id priority
          , fmAgentOwner = Nothing
          , fmDependsOn = []
          , fmBudgetUsd = Nothing
          , fmPermissionMode = Nothing
          , fmAllowedTools = Nothing
          , fmPlanApproval = PARequired
          , fmTelegram = Nothing
          , fmLabels = []
          }
      task = Task {taskId = tid, taskFrontmatter = fm, taskBody = body}
  writeTaskFile vault task
  TIO.putStrLn (unTaskId tid)

deriveTitleFromBody :: Text -> Text
deriveTitleFromBody t =
  let firstLine = T.takeWhile (/= '\n') t
      stripped = T.strip firstLine
   in if T.null stripped then "(untitled)" else T.take 60 stripped

parseEnumE :: String -> (Text -> Either String a) -> Text -> IO a
parseEnumE flag p t = either (die . ((flag <> ": ") <>)) pure (p t)

resolveVault :: Maybe FilePath -> IO Vault
resolveVault (Just fp) = Vault <$> parseAbsDir' fp
resolveVault Nothing = do
  fromEnv <- lookupEnv "POTENTIALITY_VAULT"
  case fromEnv of
    Just fp -> Vault <$> parseAbsDir' fp
    Nothing -> Vault <$> getCurrentDir

parseAbsDir' :: FilePath -> IO (Path Abs Dir)
parseAbsDir' fp =
  case parseAbsDir fp of
    Just p -> pure p
    Nothing -> die ("not an absolute directory path: " <> fp)

die :: String -> IO a
die msg = do
  hPutStrLn stderr msg
  exitFailure
