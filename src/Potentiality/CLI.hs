-- | Parser and dispatch for the @pot@ binary. Mirrors the verb tree in
-- @spec\/04-cli.md@: @pot do *@ for orchestrator\/human-side commands,
-- @pot agent *@ for agent-side commands. The subcommand split is
-- convention, not enforcement; both are reachable from any shell.
module Potentiality.CLI
  ( run
  ) where

import Control.Monad (forM, unless, when)
import Data.Aeson (Value, object, (.=))
import Data.Char (isDigit)
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
import Data.Yaml qualified as Yaml
import Options.Applicative
import Path (Abs, Dir, File, Path, filename, parent, parseAbsDir, parseRelFile, toFilePath, (</>))
import Path qualified
import Path.IO (doesDirExist, doesFileExist, ensureDir, getCurrentDir, listDir)
import Potentiality.Atomic (atomicWriteBinaryFile)
import Potentiality.Meta
  ( Meta (..)
  , PlanDecision (..)
  , mutateMeta
  , readMetaOrEmpty
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
import Potentiality.Vault
  ( Vault (..)
  , answerFile
  , cancelFile
  , findingsFile
  , planFile
  , questionFile
  , questionsDir
  , transcriptFile
  )
import Potentiality.Vault.Scan (listTaskIds)
import Potentiality.Version (version)
import Potentiality.Wait (WaitResult (..), waitForCondition, waitForFile)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitFailure, exitSuccess, exitWith)
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
  res <- waitForFile afp [cancelFp] (aaTimeout o)
  case res of
    Found () -> do
      bs <- BS.readFile (toFilePath afp)
      let txt = either (const "") id (TE.decodeUtf8' bs)
      TIO.putStrLn (T.strip txt)
    Cancelled -> exitWith (ExitFailure 130)
    TimedOut -> exitWith (ExitFailure 124)

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
  cancelFp <- cancelFile vault tid
  res <- waitForCondition (checkPlanDecision vault tid) [cancelFp] Nothing
  case res of
    Found PDApproved -> do
      TIO.putStrLn "approved"
      exitSuccess
    Found PDRevise -> do
      m <- readMetaOrEmpty vault tid
      TIO.putStrLn ("revise: " <> maybe "" id (metaPlanRevision m))
      exitSuccess
    Found PDRejected -> do
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
  now <- getCurrentTime
  mutateFrontmatter vault tid (\fm -> fm {fmStatus = Done})
  mutateMeta vault tid (\m -> m {metaFinishedAt = Just now})
  case msgM of
    Just msg -> do
      fp <- transcriptFile vault tid
      appendTextLine fp ("\n## done\n" <> msg)
    Nothing -> pure ()

agentBlocked :: Text -> IO ()
agentBlocked reason = do
  (vault, tid) <- resolveTaskFromEnv
  now <- getCurrentTime
  mutateFrontmatter vault tid (\fm -> fm {fmStatus = Blocked})
  mutateMeta vault tid (\m -> m {metaFinishedAt = Just now})
  fp <- transcriptFile vault tid
  appendTextLine fp ("\n## blocked\nReason: " <> reason)

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

-- Suppress unused-warning for symbols re-exported but not yet used.
_when :: Bool -> IO () -> IO ()
_when = when
