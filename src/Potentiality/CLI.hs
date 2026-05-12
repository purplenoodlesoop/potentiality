-- | Parser and dispatch for the @pot@ binary. Mirrors the verb tree in
-- @spec\/04-cli.md@: @pot do *@ for orchestrator\/human-side commands,
-- @pot agent *@ for agent-side commands. The subcommand split is
-- convention, not enforcement; both are reachable from any shell.
module Potentiality.CLI
  ( run
  ) where

import Control.Monad (forM, unless)
import Data.Aeson (Value, object, (.=))
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy.Char8 qualified as BL
import Data.List (sortOn)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime, getCurrentTime)
import Data.Version (showVersion)
import Options.Applicative
import Path (Abs, Dir, Path, parseAbsDir, toFilePath)
import Path.IO (doesFileExist, getCurrentDir)
import Potentiality.Atomic (atomicWriteBinaryFile)
import Potentiality.Meta
  ( Meta (..)
  , PlanDecision (..)
  , mutateMeta
  )
import Potentiality.Task
  ( Frontmatter (..)
  , Mode
  , PlanApproval (..)
  , Priority (Med)
  , Status (..)
  , Task (..)
  , TaskId (..)
  , TaskKind
  , kindText
  , parseKind
  , parseMode
  , parsePriority
  , parseStatus
  , schemaVersion
  , statusText
  )
import Potentiality.Task.Write
  ( mutateFrontmatter
  , readTask
  , readTaskMaybe
  , writeTaskFile
  )
import Potentiality.Ulid (newUlid)
import Potentiality.Vault (Vault (..), answerFile, cancelFile, transcriptFile)
import Potentiality.Vault.Scan (listTaskIds)
import Potentiality.Version (version)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- ---------------------------------------------------------------------------
-- Command tree

data Command
  = CmdDo DoCommand
  | CmdAgent AgentCommand

data DoCommand
  = DoNew DoNewOpts
  | DoList DoListOpts
  | DoShow DoShowOpts
  | DoReady IdAndVault
  | DoKill IdAndVault
  | DoAnswer DoAnswerOpts
  | DoApprove DoApproveOpts
  | DoTail DoTailOpts

data AgentCommand
  = AgentTodo

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

data ListFormat = LFTable | LFJson | LFTsv
  deriving stock (Eq)

data DoListOpts = DoListOpts
  { dlStatus :: [Text]
  , dlKind :: [Text]
  , dlVault :: Maybe FilePath
  , dlFormat :: ListFormat
  }

data ShowFormat = SFText | SFJson
  deriving stock (Eq)

data DoShowOpts = DoShowOpts
  { dsId :: Text
  , dsVault :: Maybe FilePath
  , dsTail :: Maybe Int
  , dsFormat :: ShowFormat
  }

data IdAndVault = IdAndVault
  { ivId :: Text
  , ivVault :: Maybe FilePath
  }

data DoAnswerOpts = DoAnswerOpts
  { daId :: Text
  , daNum :: Int
  , daVault :: Maybe FilePath
  , daAnswer :: Text
  }

data Approval = ApproveAcc | ApproveRevise Text | ApproveReject

data DoApproveOpts = DoApproveOpts
  { dapId :: Text
  , dapVault :: Maybe FilePath
  , dapDecision :: Approval
  }

data DoTailOpts = DoTailOpts
  { dtId :: Text
  , dtVault :: Maybe FilePath
  , dtTail :: Int
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
    ( command "new" (info (DoNew <$> doNewOpts) (progDesc "Create a new task in the vault"))
        <> command "list" (info (DoList <$> doListOpts) (progDesc "List tasks in the vault"))
        <> command "show" (info (DoShow <$> doShowOpts) (progDesc "Show a single task"))
        <> command "ready" (info (DoReady <$> idAndVault) (progDesc "Promote inbox -> ready"))
        <> command "kill" (info (DoKill <$> idAndVault) (progDesc "Cancel a running task (touch CANCEL)"))
        <> command "answer" (info (DoAnswer <$> doAnswerOpts) (progDesc "Write a question's answer"))
        <> command "approve" (info (DoApprove <$> doApproveOpts) (progDesc "Approve/revise/reject a pending plan"))
        <> command "tail" (info (DoTail <$> doTailOpts) (progDesc "Show the tail of a task's transcript"))
    )

agentParser :: Parser AgentCommand
agentParser =
  hsubparser
    (command "todo" (info (pure AgentTodo) (progDesc "Placeholder for upcoming agent verbs")))

vaultOption :: Parser (Maybe FilePath)
vaultOption =
  optional
    ( strOption
        ( long "vault"
            <> metavar "PATH"
            <> help "Vault root (defaults to $POTENTIALITY_VAULT or .)"
        )
    )

doNewOpts :: Parser DoNewOpts
doNewOpts =
  DoNewOpts
    <$> strOption (long "kind" <> metavar "KIND" <> value "general" <> showDefault <> help "code | research | design | review | general")
    <*> optional (strOption (long "title" <> metavar "TITLE" <> help "Short one-line title"))
    <*> optional (strOption (long "mode" <> metavar "MODE" <> help "ask | delegate"))
    <*> optional (strOption (long "repo" <> metavar "PATH" <> help "Working directory for the spawn"))
    <*> strOption (long "status" <> metavar "STATUS" <> value "inbox" <> showDefault <> help "Starting status; pass ready to skip triage")
    <*> optional (strOption (long "priority" <> metavar "P" <> help "low | med | high"))
    <*> vaultOption
    <*> optional (strArgument (metavar "BODY" <> help "Task body (Markdown). Quote it."))

doListOpts :: Parser DoListOpts
doListOpts =
  DoListOpts
    <$> many (strOption (long "status" <> metavar "STATUS" <> help "Filter by status (repeatable)"))
    <*> many (strOption (long "kind" <> metavar "KIND" <> help "Filter by kind (repeatable)"))
    <*> vaultOption
    <*> option
      (eitherReader parseListFormat)
      ( long "format"
          <> metavar "FORMAT"
          <> value LFTable
          <> showDefaultWith (const "table")
          <> help "table | json | tsv"
      )
  where
    parseListFormat = \case
      "table" -> Right LFTable
      "json" -> Right LFJson
      "tsv" -> Right LFTsv
      x -> Left ("unknown --format: " <> x)

doShowOpts :: Parser DoShowOpts
doShowOpts =
  DoShowOpts
    <$> strArgument (metavar "ID")
    <*> vaultOption
    <*> optional (option auto (long "tail" <> metavar "N" <> help "Include the last N lines of transcript.md"))
    <*> option
      (eitherReader parseShowFormat)
      ( long "format"
          <> metavar "FORMAT"
          <> value SFText
          <> showDefaultWith (const "text")
          <> help "text | json"
      )
  where
    parseShowFormat = \case
      "text" -> Right SFText
      "json" -> Right SFJson
      x -> Left ("unknown --format: " <> x)

idAndVault :: Parser IdAndVault
idAndVault =
  IdAndVault
    <$> strArgument (metavar "ID")
    <*> vaultOption

doAnswerOpts :: Parser DoAnswerOpts
doAnswerOpts =
  DoAnswerOpts
    <$> strArgument (metavar "ID")
    <*> argument auto (metavar "NUM" <> help "Question number")
    <*> vaultOption
    <*> strArgument (metavar "ANSWER" <> help "Answer text (quote it)")

doApproveOpts :: Parser DoApproveOpts
doApproveOpts =
  DoApproveOpts
    <$> strArgument (metavar "ID")
    <*> vaultOption
    <*> decisionOpts
  where
    decisionOpts =
      (ApproveRevise <$> strOption (long "revise" <> metavar "TEXT" <> help "Send back for revision"))
        <|> flag' ApproveReject (long "reject" <> help "Reject the plan")
        <|> pure ApproveAcc

doTailOpts :: Parser DoTailOpts
doTailOpts =
  DoTailOpts
    <$> strArgument (metavar "ID")
    <*> vaultOption
    <*> option auto (long "tail" <> short 'n' <> metavar "N" <> value 50 <> showDefault <> help "Number of trailing lines")

-- ---------------------------------------------------------------------------
-- Dispatch

run :: IO ()
run = do
  cmd <- execParser opts
  case cmd of
    CmdDo (DoNew o) -> doNew o
    CmdDo (DoList o) -> doList o
    CmdDo (DoShow o) -> doShow o
    CmdDo (DoReady iv) -> doReady iv
    CmdDo (DoKill iv) -> doKill iv
    CmdDo (DoAnswer o) -> doAnswer o
    CmdDo (DoApprove o) -> doApprove o
    CmdDo (DoTail o) -> doTail o
    CmdAgent AgentTodo -> die "pot agent: no verbs implemented yet (phase 5)"

-- ---------------------------------------------------------------------------
-- Handlers

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
      fm = blankFrontmatter now kind status title mode priority (dnRepo o)
      task = Task {taskId = tid, taskFrontmatter = fm, taskBody = body}
  writeTaskFile vault task
  TIO.putStrLn (unTaskId tid)

blankFrontmatter
  :: UTCTime
  -> TaskKind
  -> Status
  -> Text
  -> Maybe Mode
  -> Maybe Priority
  -> Maybe FilePath
  -> Frontmatter
blankFrontmatter now kind status title mode priority repo =
  Frontmatter
    { fmSchema = schemaVersion
    , fmKind = kind
    , fmStatus = status
    , fmTitle = title
    , fmCreated = now
    , fmMode = mode
    , fmRepo = repo
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

doList :: DoListOpts -> IO ()
doList o = do
  vault <- resolveVault (dlVault o)
  tids <- listTaskIds vault
  parsed <- forM tids $ \tid -> do
    r <- readTaskMaybe vault tid
    pure (tid, r)
  statusFilters <- traverse (parseEnumE "--status" parseStatus) (dlStatus o)
  kindFilters <- traverse (parseEnumE "--kind" parseKind) (dlKind o)
  let tasks =
        [ t
        | (_, Just (Right t)) <- parsed
        , null statusFilters || fmStatus (taskFrontmatter t) `elem` statusFilters
        , null kindFilters || fmKind (taskFrontmatter t) `elem` kindFilters
        ]
      errors = [tid | (tid, Just (Left _)) <- parsed]
      sorted = sortOn (Down . fmCreated . taskFrontmatter) tasks
  unless (null errors) $
    hPutStrLn stderr ("warning: " <> show (length errors) <> " unparseable task(s) skipped")
  case dlFormat o of
    LFTable -> TIO.putStr (formatTable sorted)
    LFJson -> BL.putStrLn (encodePretty (map summarize sorted))
    LFTsv -> TIO.putStr (formatTsv sorted)

formatTable :: [Task] -> Text
formatTable ts =
  let header = padCols ["ID", "KIND", "STATUS", "TITLE"]
      rows = map (padCols . taskCols) ts
   in T.unlines (header : rows)

padCols :: [Text] -> Text
padCols [a, b, c, d] =
  T.justifyLeft 28 ' ' a
    <> T.justifyLeft 11 ' ' b
    <> T.justifyLeft 14 ' ' c
    <> d
padCols _ = ""

taskCols :: Task -> [Text]
taskCols t =
  [ unTaskId (taskId t)
  , kindText (fmKind (taskFrontmatter t))
  , statusText (fmStatus (taskFrontmatter t))
  , fmTitle (taskFrontmatter t)
  ]

formatTsv :: [Task] -> Text
formatTsv = T.unlines . map (T.intercalate "\t" . taskCols)

summarize :: Task -> Value
summarize t =
  object
    [ "id" .= unTaskId (taskId t)
    , "kind" .= kindText (fmKind (taskFrontmatter t))
    , "status" .= statusText (fmStatus (taskFrontmatter t))
    , "title" .= fmTitle (taskFrontmatter t)
    , "created" .= fmCreated (taskFrontmatter t)
    ]

doShow :: DoShowOpts -> IO ()
doShow o = do
  vault <- resolveVault (dsVault o)
  let tid = TaskId (dsId o)
  task <- readTask vault tid
  case dsFormat o of
    SFText -> do
      let fm = taskFrontmatter task
      TIO.putStrLn ("# " <> fmTitle fm)
      TIO.putStrLn ("id: " <> unTaskId tid)
      TIO.putStrLn ("kind: " <> kindText (fmKind fm))
      TIO.putStrLn ("status: " <> statusText (fmStatus fm))
      TIO.putStrLn ""
      TIO.putStrLn (taskBody task)
      case dsTail o of
        Nothing -> pure ()
        Just n -> do
          TIO.putStrLn "\n--- transcript (tail) ---"
          tailContents <- readTranscriptTail vault tid n
          TIO.putStr tailContents
    SFJson -> BL.putStrLn (encodePretty (summarize task))

readTranscriptTail :: Vault -> TaskId -> Int -> IO Text
readTranscriptTail vault tid n = do
  fp <- transcriptFile vault tid
  exists <- doesFileExist fp
  if not exists
    then pure ""
    else do
      bs <- BS.readFile (toFilePath fp)
      let txt = either (const "") id (TE.decodeUtf8' bs)
          ls = T.lines txt
          tailLs = drop (max 0 (length ls - n)) ls
      pure (T.unlines tailLs)

doReady :: IdAndVault -> IO ()
doReady iv = do
  vault <- resolveVault (ivVault iv)
  let tid = TaskId (ivId iv)
  mutateFrontmatter vault tid (\fm -> fm {fmStatus = Ready})
  TIO.putStrLn ("ready: " <> unTaskId tid)

doKill :: IdAndVault -> IO ()
doKill iv = do
  vault <- resolveVault (ivVault iv)
  let tid = TaskId (ivId iv)
  fp <- cancelFile vault tid
  atomicWriteBinaryFile fp ""
  TIO.putStrLn ("cancel touched: " <> unTaskId tid)

doAnswer :: DoAnswerOpts -> IO ()
doAnswer o = do
  vault <- resolveVault (daVault o)
  let tid = TaskId (daId o)
  fp <- answerFile vault tid (daNum o)
  atomicWriteBinaryFile fp (TE.encodeUtf8 (daAnswer o <> "\n"))
  TIO.putStrLn ("answer: " <> unTaskId tid <> " #" <> T.pack (show (daNum o)))

doApprove :: DoApproveOpts -> IO ()
doApprove o = do
  vault <- resolveVault (dapVault o)
  let tid = TaskId (dapId o)
  now <- getCurrentTime
  mutateMeta vault tid (applyDecision now (dapDecision o))
  TIO.putStrLn ("approve: " <> unTaskId tid)

applyDecision :: UTCTime -> Approval -> Meta -> Meta
applyDecision now d m = case d of
  ApproveAcc ->
    m {metaPlanDecision = Just PDApproved, metaPlanRevision = Nothing, metaPlanDecidedAt = Just now}
  ApproveRevise txt ->
    m {metaPlanDecision = Just PDRevise, metaPlanRevision = Just txt, metaPlanDecidedAt = Just now}
  ApproveReject ->
    m {metaPlanDecision = Just PDRejected, metaPlanRevision = Nothing, metaPlanDecidedAt = Just now}

doTail :: DoTailOpts -> IO ()
doTail o = do
  vault <- resolveVault (dtVault o)
  let tid = TaskId (dtId o)
  txt <- readTranscriptTail vault tid (dtTail o)
  TIO.putStr txt

-- ---------------------------------------------------------------------------
-- Helpers

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
