-- | Parser and dispatch for the @pot@ binary. Mirrors the verb tree in
-- @spec\/04-cli.md@: @pot do *@ for orchestrator\/human-side commands,
-- @pot agent *@ for agent-side commands. The subcommand split is
-- convention, not enforcement; both are reachable from any shell.
module Potentiality.CLI
  ( run
  ) where

import Control.Monad (forM, unless, when)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.Char (isDigit)
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy.Char8 qualified as BL
import Data.List (sortOn)
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime, getCurrentTime)
import Data.Version (showVersion)
import Data.Yaml qualified as Yaml
import Options.Applicative
import Path (Abs, Dir, File, Path, Rel, filename, parent, parseAbsDir, parseAbsFile, parseRelFile, toFilePath, (</>))
import Path qualified
import Path.IO (doesDirExist, doesFileExist, ensureDir, getCurrentDir, listDir)
import Potentiality.Atomic (atomicWriteBinaryFile)
import Potentiality.ClaudeCode (runClaude)
import Potentiality.Log (logEvent)
import Potentiality.Meta
  ( Meta (..)
  , PlanDecision (..)
  , applyBinds
  , mutateMeta
  , readMetaOrEmpty
  )
import Potentiality.Preferences (readPreferencesList, writePreferencesList)
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
import Potentiality.Vault
  ( Vault (..)
  , answerFile
  , cancelFile
  , findingsFile
  , planFile
  , planNotifiedFile
  , preferencesFile
  , questionFile
  , questionsDir
  , transcriptFile
  )
import Potentiality.Vault.Scan (listTaskIds)
import Potentiality.Version (version)
import Potentiality.Wait (WaitResult (..), waitForCondition, waitForFile)
import Potentiality.Watch (watchVault)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitFailure, exitSuccess, exitWith)
import System.IO (hPutStrLn, stderr)
import System.Process.Typed (closed, readProcess, setStdin, shell)

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
  | DoRun DoRunOpts
  | DoWatch DoWatchOpts
  | DoRetry DoRetryOpts
  | DoDrop IdAndVault
  | DoPref DoPrefOpts

data DoPrefOpts = DoPrefOpts
  { dpVault :: Maybe FilePath
  , dpVerb :: DoPrefVerb
  }

data DoPrefVerb
  = PrefSet Text
  | PrefList
  | PrefClear Int

data DoRetryOpts = DoRetryOpts
  { dretId :: Text
  , dretModel :: Maybe Text
  , dretVault :: Maybe FilePath
  }

data AgentCommand
  = AgentAsk AgentAskOpts
  | AgentStatus Text
  | AgentNote Text
  | AgentFinding Text
  | AgentPlan Text
  | AgentDone (Maybe Text)
  | AgentBlocked Text

data DoNewOpts = DoNewOpts
  { dnKind :: Text
  , dnTitle :: Maybe Text
  , dnMode :: Maybe Text
  , dnRepo :: Maybe FilePath
  , dnStatus :: Text
  , dnPriority :: Maybe Text
  , dnModel :: Maybe Text
  , dnVault :: Maybe FilePath
  , dnBinds :: [Text]
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

data DoRunOpts = DoRunOpts
  { drTaskFile :: FilePath
  , drVault :: Maybe FilePath
  }

data DoWatchOpts = DoWatchOpts
  { dwVault :: Maybe FilePath
  , dwMaxConcurrent :: Int
  }

data AgentAskOpts = AgentAskOpts
  { aaQuestion :: Text
  , aaOptions :: Maybe Text
  , aaUrgency :: Text
  , aaTimeout :: Maybe Int
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
        <> command "run" (info (DoRun <$> doRunOpts) (progDesc "Run a task to completion (spawns claude)"))
        <> command "watch" (info (DoWatch <$> doWatchOpts) (progDesc "Watch the vault and run ready tasks"))
        <> command "retry" (info (DoRetry <$> doRetryOpts) (progDesc "Clear blocked status and re-queue for the daemon"))
        <> command "drop" (info (DoDrop <$> idAndVault) (progDesc "Mark a task abandoned (status: dropped)"))
        <> command "pref" (info (DoPref <$> doPrefOpts) (progDesc "Manage persistent agent preferences"))
    )

agentParser :: Parser AgentCommand
agentParser =
  hsubparser
    ( command "ask" (info (AgentAsk <$> agentAskOpts) (progDesc "Block until the human answers a question"))
        <> command "status" (info (AgentStatus <$> bodyArg) (progDesc "Set meta.yaml#current_step"))
        <> command "note" (info (AgentNote <$> bodyArg) (progDesc "Append to transcript.md"))
        <> command "finding" (info (AgentFinding <$> bodyArg) (progDesc "Append to findings.md"))
        <> command "plan" (info (AgentPlan <$> bodyArg) (progDesc "Propose a plan; block on approval"))
        <> command "done" (info (AgentDone <$> doneOpts) (progDesc "Mark the task done"))
        <> command "blocked" (info (AgentBlocked <$> reasonOpt) (progDesc "Mark the task blocked"))
    )

bodyArg :: Parser Text
bodyArg = strArgument (metavar "TEXT" <> help "Text payload (quote it)")

doneOpts :: Parser (Maybe Text)
doneOpts = optional (strOption (long "message" <> metavar "TEXT" <> help "Optional closing message"))

reasonOpt :: Parser Text
reasonOpt = strOption (long "reason" <> metavar "TEXT" <> help "Why is the task blocked?")

agentAskOpts :: Parser AgentAskOpts
agentAskOpts =
  AgentAskOpts
    <$> strArgument (metavar "QUESTION" <> help "Question text (quote it)")
    <*> optional (strOption (long "options" <> metavar "A,B,C" <> help "Comma-separated options, rendered as inline-keyboard buttons by Horizon"))
    <*> strOption (long "urgency" <> metavar "URGENCY" <> value "normal" <> showDefault <> help "normal | high")
    <*> optional (option auto (long "timeout" <> metavar "SECONDS" <> help "Exit 124 if no answer within N seconds"))

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
    <*> optional (strOption (long "model" <> metavar "MODEL" <> help "Claude model to use (e.g. claude-opus-4-7)"))
    <*> vaultOption
    <*> many (strOption (long "bind" <> metavar "KEY=VAL" <> help "Set meta.yaml field. KEY is a dotted path (e.g. telegram.chat_id). VAL is JSON-coerced (numbers, bools, null) or treated as string. Repeatable."))
    <*> optional (strArgument (metavar "BODY" <> help "Task body (Markdown). Quote it."))

doRetryOpts :: Parser DoRetryOpts
doRetryOpts =
  DoRetryOpts
    <$> strArgument (metavar "ID")
    <*> optional (strOption (long "model" <> metavar "MODEL" <> help "Override claude model for the retry"))
    <*> vaultOption

doPrefOpts :: Parser DoPrefOpts
doPrefOpts =
  DoPrefOpts
    <$> vaultOption
    <*> hsubparser
      ( command "set" (info (PrefSet <$> strArgument (metavar "RULE" <> help "Preference rule text")) (progDesc "Append a preference rule"))
          <> command "list" (info (pure PrefList) (progDesc "List all preference rules"))
          <> command "clear" (info (PrefClear <$> argument auto (metavar "N" <> help "1-based index to remove")) (progDesc "Remove preference rule by index"))
      )

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

doRunOpts :: Parser DoRunOpts
doRunOpts =
  DoRunOpts
    <$> strArgument (metavar "TASK_FILE" <> help "Path to a task.md file inside a vault")
    <*> vaultOption

doWatchOpts :: Parser DoWatchOpts
doWatchOpts =
  DoWatchOpts
    <$> vaultOption
    <*> option auto (long "max-concurrent" <> metavar "N" <> value 3 <> showDefault <> help "Concurrent task limit")

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
    CmdDo (DoRun o) -> doRun o
    CmdDo (DoWatch o) -> doWatch o
    CmdDo (DoRetry o) -> doRetry o
    CmdDo (DoDrop iv) -> doDrop iv
    CmdDo (DoPref po) -> doPref po
    CmdAgent (AgentAsk o) -> agentAsk o
    CmdAgent (AgentStatus t) -> agentStatus t
    CmdAgent (AgentNote t) -> agentNote t
    CmdAgent (AgentFinding t) -> agentFinding t
    CmdAgent (AgentPlan t) -> agentPlan t
    CmdAgent (AgentDone mt) -> agentDone mt
    CmdAgent (AgentBlocked t) -> agentBlocked t

-- ---------------------------------------------------------------------------
-- Handlers: pot do *

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
      model = case dnModel o of { Just "" -> Nothing; x -> x }
      fm = blankFrontmatter now kind status title mode priority (dnRepo o) model
      task = Task {taskId = tid, taskFrontmatter = fm, taskBody = body}
  writeTaskFile vault task
  applyBinds vault tid (dnBinds o)
  logEvent
    "task_new"
    [ ("task", toJSON tid)
    , ("kind", toJSON (kindText kind))
    , ("status", toJSON (statusText status))
    , ("title", toJSON title)
    ]
  TIO.putStrLn (unTaskId tid)

blankFrontmatter
  :: UTCTime
  -> TaskKind
  -> Status
  -> Text
  -> Maybe Mode
  -> Maybe Priority
  -> Maybe FilePath
  -> Maybe Text
  -> Frontmatter
blankFrontmatter now kind status title mode priority repo model =
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
    , fmModel = model
    , fmRetryCount = 0
    , fmVerify = Nothing
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
        , -- Dropped tasks are hidden from the default listing.
          -- Show them only when --status dropped is explicitly requested.
          (null statusFilters && fmStatus (taskFrontmatter t) /= Dropped)
            || fmStatus (taskFrontmatter t) `elem` statusFilters
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

doRun :: DoRunOpts -> IO ()
doRun o = do
  taskFP <- parseAbsFile' (drTaskFile o)
  let taskDirP = parent taskFP
      tasksDirP = parent taskDirP
      vaultRoot = parent tasksDirP
      tidTxt = T.dropWhileEnd (== '/') (T.pack (toFilePath (Path.dirname taskDirP)))
      tid = TaskId tidTxt
  vault <- case drVault o of
    Just _ -> resolveVault (drVault o)
    Nothing -> pure (Vault vaultRoot)
  task <- readTask vault tid
  runClaude vault task

doWatch :: DoWatchOpts -> IO ()
doWatch o = do
  vault <- resolveVault (dwVault o)
  watchVault vault (dwMaxConcurrent o)

doRetry :: DoRetryOpts -> IO ()
doRetry o = do
  vault <- resolveVault (dretVault o)
  let tid = TaskId (dretId o)
      newModel = case dretModel o of { Just "" -> Nothing; x -> x }
  task <- readTask vault tid
  let fm = taskFrontmatter task
  case fmStatus fm of
    Blocked -> pure ()
    other -> die ("retry: task is " <> T.unpack (statusText other) <> ", not blocked")
  mutateFrontmatter vault tid $ \f ->
    f
      { fmStatus = Ready
      , fmRetryCount = fmRetryCount f + 1
      , fmModel = maybe (fmModel f) Just newModel
      }
  -- Clear session-specific meta so the new run starts fresh, but keep
  -- the telegram binding so notifications still route to the right chat.
  mutateMeta vault tid $ \m ->
    m
      { metaClaudeSessionId = Nothing
      , metaStartedAt = Nothing
      , metaFinishedAt = Nothing
      , metaCurrentStep = Nothing
      , metaLastToolCall = Nothing
      , metaTotalCostUsd = Nothing
      , metaTokens = Nothing
      , metaPlanDecision = Nothing
      , metaPlanRevision = Nothing
      , metaPlanDecidedAt = Nothing
      }
  TIO.putStrLn ("retry: " <> unTaskId tid)

doDrop :: IdAndVault -> IO ()
doDrop iv = do
  vault <- resolveVault (ivVault iv)
  let tid = TaskId (ivId iv)
  mutateFrontmatter vault tid (\fm -> fm {fmStatus = Dropped})
  TIO.putStrLn ("dropped: " <> unTaskId tid)

doPref :: DoPrefOpts -> IO ()
doPref po = do
  vault <- resolveVault (dpVault po)
  let fp = preferencesFile vault
  case dpVerb po of
    PrefSet rule -> do
      prefs <- readPreferencesList fp
      writePreferencesList fp (prefs <> [rule])
      TIO.putStrLn ("pref set: " <> rule)
    PrefList -> do
      prefs <- readPreferencesList fp
      if null prefs
        then TIO.putStrLn "(no preferences set)"
        else mapM_ (\(i, p) -> TIO.putStrLn (T.pack (show (i :: Int)) <> ". " <> p)) (zip [1 ..] prefs)
    PrefClear n -> do
      prefs <- readPreferencesList fp
      when (n < 1 || n > length prefs) $
        die ("pref clear: index " <> show n <> " out of range (1-" <> show (length prefs) <> ")")
      let updated = take (n - 1) prefs <> drop n prefs
      writePreferencesList fp updated
      TIO.putStrLn ("pref cleared: #" <> T.pack (show n))

parseAbsFile' :: FilePath -> IO (Path Abs File)
parseAbsFile' fp =
  case (parseAbsFile fp :: Maybe (Path Abs File)) of
    Just p -> pure p
    Nothing -> case (parseRelFile fp :: Maybe (Path Rel File)) of
      Just rel -> do
        cwd <- getCurrentDir
        pure (cwd </> rel)
      Nothing -> die ("not a valid file path: " <> fp)

-- ---------------------------------------------------------------------------
-- Handlers: pot agent *

agentAsk :: AgentAskOpts -> IO ()
agentAsk o = do
  (vault, tid) <- resolveTaskFromEnv
  qdir <- questionsDir vault tid
  ensureDir qdir
  num <- nextQuestionNumber qdir
  qfp <- questionFile vault tid num
  afp <- answerFile vault tid num
  cancelFp <- cancelFile vault tid
  now <- getCurrentTime
  let optionsList = parseOptionsCsv (aaOptions o)
      frontmatterValue =
        object $
          [ "asked_at" .= now
          , "urgency" .= aaUrgency o
          ]
            <> maybe [] (\os -> ["options" .= os]) optionsList
      content =
        "---\n"
          <> Yaml.encode frontmatterValue
          <> "---\n"
          <> TE.encodeUtf8 (aaQuestion o <> "\n")
  atomicWriteBinaryFile qfp content
  logEvent
    "question_asked"
    [ ("task", toJSON tid)
    , ("num", toJSON num)
    , ("urgency", toJSON (aaUrgency o))
    ]
  res <- waitForFile afp [cancelFp] (aaTimeout o)
  case res of
    Found () -> do
      bs <- BS.readFile (toFilePath afp)
      let txt = either (const "") id (TE.decodeUtf8' bs)
      logEvent
        "answer_received"
        [ ("task", toJSON tid)
        , ("num", toJSON num)
        ]
      TIO.putStrLn (T.strip txt)
    Cancelled -> do
      logEvent
        "question_cancelled"
        [ ("task", toJSON tid)
        , ("num", toJSON num)
        ]
      exitWith (ExitFailure 130)
    TimedOut -> do
      logEvent
        "question_timeout"
        [ ("task", toJSON tid)
        , ("num", toJSON num)
        ]
      exitWith (ExitFailure 124)

parseOptionsCsv :: Maybe Text -> Maybe [Text]
parseOptionsCsv Nothing = Nothing
parseOptionsCsv (Just t)
  | T.null (T.strip t) = Nothing
  | otherwise = Just (map T.strip (T.splitOn "," t))

-- | Scan @questions\/@ for files of the form @NNN.md@ or @NNN.answer.md@
-- and return one more than the largest @NNN@. Returns 1 when the
-- directory is empty or absent.
nextQuestionNumber :: Path Abs Dir -> IO Int
nextQuestionNumber dir = do
  e <- doesDirExist dir
  if not e
    then pure 1
    else do
      (_dirs, files) <- listDir dir
      let nums = [n | f <- files, Just n <- [parseQuestionFileNum (toFilePath (filename f))]]
      pure (1 + maximum (0 : nums))

parseQuestionFileNum :: FilePath -> Maybe Int
parseQuestionFileNum name
  | length name >= 6
  , all isDigit (take 3 name)
  , drop 3 name == ".md" || drop 3 name == ".answer.md" =
      Just (read (take 3 name))
  | otherwise = Nothing

agentStatus :: Text -> IO ()
agentStatus txt = do
  (vault, tid) <- resolveTaskFromEnv
  mutateMeta vault tid (\m -> m {metaCurrentStep = Just txt})

agentNote :: Text -> IO ()
agentNote txt = do
  (vault, tid) <- resolveTaskFromEnv
  fp <- transcriptFile vault tid
  appendTextLine fp txt

agentFinding :: Text -> IO ()
agentFinding txt = do
  (vault, tid) <- resolveTaskFromEnv
  fp <- findingsFile vault tid
  appendTextLine fp txt

agentPlan :: Text -> IO ()
agentPlan txt = do
  (vault, tid) <- resolveTaskFromEnv
  fp <- planFile vault tid
  atomicWriteBinaryFile fp (TE.encodeUtf8 txt)
  mutateMeta vault tid $ \m ->
    m
      { metaPlanDecision = Just PDPending
      , metaPlanRevision = Nothing
      , metaPlanDecidedAt = Nothing
      }
  -- Write plan.notified AFTER plan.md so Horizon's watcher triggers on a
  -- stable, fully-written plan file rather than the intermediate write.
  nfp <- planNotifiedFile vault tid
  atomicWriteBinaryFile nfp ""
  logEvent "plan_written" [("task", toJSON tid)]
  cancelFp <- cancelFile vault tid
  res <- waitForCondition (checkPlanDecision vault tid) [cancelFp] Nothing
  case res of
    Found PDApproved -> do
      logEvent "plan_approved" [("task", toJSON tid)]
      TIO.putStrLn "approved"
      exitSuccess
    Found PDRevise -> do
      m <- readMetaOrEmpty vault tid
      logEvent "plan_revise" [("task", toJSON tid)]
      TIO.putStrLn ("revise: " <> maybe "" id (metaPlanRevision m))
      exitSuccess
    Found PDRejected -> do
      logEvent "plan_rejected" [("task", toJSON tid)]
      TIO.putStrLn "rejected"
      exitWith (ExitFailure 1)
    Found PDPending -> die "internal error: waiter returned PDPending"
    Cancelled -> exitWith (ExitFailure 130)
    TimedOut -> exitWith (ExitFailure 124)

checkPlanDecision :: Vault -> TaskId -> IO (Maybe PlanDecision)
checkPlanDecision vault tid = do
  m <- readMetaOrEmpty vault tid
  pure $ case metaPlanDecision m of
    Just PDPending -> Nothing
    Just d -> Just d
    Nothing -> Nothing

agentDone :: Maybe Text -> IO ()
agentDone msgM = do
  (vault, tid) <- resolveTaskFromEnv
  -- Pre-done verify hook (issue #10). If the task's frontmatter has
  -- a `verify` field, run it via `bash -c`. Non-zero exit refuses
  -- the transition: task stays in_progress, verify output is
  -- appended to the transcript, and pot agent done exits non-zero so
  -- the spawned agent sees the failure and can fix-and-retry.
  mTask <- readTaskMaybe vault tid
  let mVerify = case mTask of
        Just (Right t) -> fmVerify (taskFrontmatter t)
        _ -> Nothing
  case mVerify of
    Just cmd -> do
      (code, out, err) <- runVerify cmd
      case code of
        ExitSuccess -> do
          appendVerify vault tid cmd code out err
          finalizeDone vault tid msgM
        ExitFailure n -> do
          appendVerify vault tid cmd code out err
          logEvent
            "task_verify_failed"
            [ ("task", toJSON tid)
            , ("exit_code", toJSON n)
            ]
          hPutStrLn stderr $
            "pot agent done refused: verify exited with " <> show n
              <> ". Task stays in_progress. See transcript for output."
          exitWith (ExitFailure 2)
    Nothing -> finalizeDone vault tid msgM

-- | Apply the actual done transition once verify has either passed
-- or been skipped. Overwrites current_step with a terminal value
-- (issue #9) so the recorded last-step text reflects end state.
finalizeDone :: Vault -> TaskId -> Maybe Text -> IO ()
finalizeDone vault tid msgM = do
  now <- getCurrentTime
  mutateFrontmatter vault tid (\fm -> fm {fmStatus = Done})
  mutateMeta vault tid $ \m ->
    m
      { metaFinishedAt = Just now
      , metaCurrentStep = Just (fromMaybe "done" msgM)
      }
  case msgM of
    Just msg -> do
      fp <- transcriptFile vault tid
      appendTextLine fp ("\n## done\n" <> msg)
    Nothing -> pure ()
  logEvent "task_done" [("task", toJSON tid)]

-- | Run the verify command in a subshell. Captures stdout + stderr
-- separately so the transcript can show both. Inherits the process'
-- working directory and environment, which under `pot do watch` is
-- the task's working directory (the spawned agent's POSIX cwd).
runVerify :: Text -> IO (ExitCode, Text, Text)
runVerify cmd = do
  let pc = setStdin closed (shell (T.unpack cmd))
  (code, out, err) <- readProcess pc
  let dec = either (const "") id . TE.decodeUtf8' . BL.toStrict
  pure (code, dec out, dec err)

appendVerify :: Vault -> TaskId -> Text -> ExitCode -> Text -> Text -> IO ()
appendVerify vault tid cmd code out err = do
  fp <- transcriptFile vault tid
  let header =
        "\n## verify (exit="
          <> T.pack (show (exitCodeInt code))
          <> ")\n$ "
          <> cmd
          <> "\n"
      body =
        (if T.null out then "" else "stdout:\n" <> out <> "\n")
          <> (if T.null err then "" else "stderr:\n" <> err <> "\n")
  appendTextLine fp (header <> body)

exitCodeInt :: ExitCode -> Int
exitCodeInt = \case
  ExitSuccess -> 0
  ExitFailure n -> n

agentBlocked :: Text -> IO ()
agentBlocked reason = do
  (vault, tid) <- resolveTaskFromEnv
  now <- getCurrentTime
  mutateFrontmatter vault tid (\fm -> fm {fmStatus = Blocked})
  mutateMeta vault tid $ \m ->
    m
      { metaFinishedAt = Just now
      , metaCurrentStep = Just ("blocked: " <> reason)
      }
  fp <- transcriptFile vault tid
  appendTextLine fp ("\n## blocked\nReason: " <> reason)
  logEvent
    "task_blocked"
    [ ("task", toJSON tid)
    , ("reason", toJSON reason)
    ]

-- ---------------------------------------------------------------------------
-- Helpers

appendTextLine :: Path Abs File -> Text -> IO ()
appendTextLine fp txt = do
  ensureDir (parent fp)
  BS.appendFile (toFilePath fp) (TE.encodeUtf8 (txt <> "\n"))

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

-- | Resolve the task in scope for an @agent@ verb, reading
-- @$POTENTIALITY_TASK_DIR@. Fails the process when the env var is unset
-- because agent verbs are only meaningful inside a spawn.
resolveTaskFromEnv :: IO (Vault, TaskId)
resolveTaskFromEnv = do
  envVal <- lookupEnv "POTENTIALITY_TASK_DIR"
  case envVal of
    Nothing -> die "POTENTIALITY_TASK_DIR is not set (run `pot agent ...` only inside a spawn)"
    Just fp -> do
      td <- parseAbsDir' fp
      let tasksParent = parent td
          vaultRoot = parent tasksParent
          tidTxt = T.dropWhileEnd (== '/') (T.pack (toFilePath (Path.dirname td)))
      pure (Vault vaultRoot, TaskId tidTxt)

die :: String -> IO a
die msg = do
  hPutStrLn stderr msg
  exitFailure

