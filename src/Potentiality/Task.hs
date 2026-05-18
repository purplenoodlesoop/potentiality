-- | Domain types for tasks as defined in @spec/03-vault-layout.md@.
--
-- These are the on-disk schema reflected as Haskell types. JSON\/YAML
-- instances are written manually rather than derived, both to keep the wire
-- format under explicit control and to map YAML's @snake_case@ to Haskell's
-- @camelCase@ without pulling in a generic-options dependency.
module Potentiality.Task
  ( TaskId (..)
  , Task (..)
  , Frontmatter (..)
  , TaskKind (..)
  , kindText
  , parseKind
  , Status (..)
  , statusText
  , parseStatus
  , Mode (..)
  , modeText
  , parseMode
  , Priority (..)
  , priorityText
  , parsePriority
  , PermissionMode (..)
  , permissionModeText
  , parsePermissionMode
  -- already exported above, but make sure 'permissionModeText' is the
  -- canonical surface for downstream modules.
  , PlanApproval (..)
  , planApprovalText
  , parsePlanApproval
  , TelegramBinding (..)
  , schemaVersion
  ) where

import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , Value (..)
  , object
  , withObject
  , withText
  , (.!=)
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.Types (Pair, Parser)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)

-- | Current on-disk schema version. Bumps on any breaking change to the
-- frontmatter layout; @pot@ refuses to operate on unknown future versions.
schemaVersion :: Int
schemaVersion = 1

-- | Opaque task identifier. Conventionally a ULID, but stored as 'Text' so
-- hand-edited tasks with arbitrary directory names still parse.
newtype TaskId = TaskId {unTaskId :: Text}
  deriving stock (Eq, Ord, Show)

-- | A parsed task file: structured frontmatter plus the body Markdown.
data Task = Task
  { taskId :: TaskId
  , taskFrontmatter :: Frontmatter
  , taskBody :: Text
  }
  deriving stock (Show)

-- | YAML frontmatter of @task.md@. Required fields are unwrapped; optional
-- fields are either 'Maybe' or carry kind\/spec-driven defaults.
data Frontmatter = Frontmatter
  { fmSchema :: Int
  , fmKind :: TaskKind
  , fmStatus :: Status
  , fmTitle :: Text
  , fmCreated :: UTCTime
  , fmMode :: Maybe Mode
  , fmRepo :: Maybe FilePath
  , fmPriority :: Priority
  , fmAgentOwner :: Maybe Text
  , fmDependsOn :: [TaskId]
  , fmBudgetUsd :: Maybe Double
  , fmPermissionMode :: Maybe PermissionMode
  , fmAllowedTools :: Maybe [Text]
  , fmPlanApproval :: PlanApproval
  , fmTelegram :: Maybe TelegramBinding
  , fmLabels :: [Text]
  , fmModel :: Maybe Text
  , fmRetryCount :: Int
  , -- | Optional shell command that gates @pot agent done@. When set, the
    -- daemon runs it via @bash -c <verify>@ before accepting the
    -- transition to @done@. Non-zero exit refuses the transition and
    -- the agent stays @in_progress@ with the verify output appended to
    -- the transcript so it can fix and retry. Issue #10.
    fmVerify :: Maybe Text
  }
  deriving stock (Show)

data TaskKind = Code | Research | Design | Review | General
  deriving stock (Eq, Show)

kindText :: TaskKind -> Text
kindText = \case
  Code -> "code"
  Research -> "research"
  Design -> "design"
  Review -> "review"
  General -> "general"

parseKind :: Text -> Either String TaskKind
parseKind = \case
  "code" -> Right Code
  "research" -> Right Research
  "design" -> Right Design
  "review" -> Right Review
  "general" -> Right General
  other -> Left $ "unknown task kind: " <> T.unpack other

data Status = Inbox | Ready | InProgress | Done | Blocked | Dropped
  deriving stock (Eq, Show)

statusText :: Status -> Text
statusText = \case
  Inbox -> "inbox"
  Ready -> "ready"
  InProgress -> "in_progress"
  Done -> "done"
  Blocked -> "blocked"
  Dropped -> "dropped"

parseStatus :: Text -> Either String Status
parseStatus = \case
  "inbox" -> Right Inbox
  "ready" -> Right Ready
  "in_progress" -> Right InProgress
  "done" -> Right Done
  "blocked" -> Right Blocked
  "dropped" -> Right Dropped
  other -> Left $ "unknown status: " <> T.unpack other

data Mode = Ask | Delegate
  deriving stock (Eq, Show)

modeText :: Mode -> Text
modeText = \case
  Ask -> "ask"
  Delegate -> "delegate"

parseMode :: Text -> Either String Mode
parseMode = \case
  "ask" -> Right Ask
  "delegate" -> Right Delegate
  other -> Left $ "unknown mode: " <> T.unpack other

data Priority = Low | Med | High
  deriving stock (Eq, Show)

priorityText :: Priority -> Text
priorityText = \case
  Low -> "low"
  Med -> "med"
  High -> "high"

parsePriority :: Text -> Either String Priority
parsePriority = \case
  "low" -> Right Low
  "med" -> Right Med
  "medium" -> Right Med
  "high" -> Right High
  other -> Left $ "unknown priority: " <> T.unpack other

data PermissionMode
  = PMDefault
  | PMAcceptEdits
  | PMPlan
  | PMBypassPermissions
  deriving stock (Eq, Show)

permissionModeText :: PermissionMode -> Text
permissionModeText = \case
  PMDefault -> "default"
  PMAcceptEdits -> "acceptEdits"
  PMPlan -> "plan"
  PMBypassPermissions -> "bypassPermissions"

parsePermissionMode :: Text -> Either String PermissionMode
parsePermissionMode = \case
  "default" -> Right PMDefault
  "acceptEdits" -> Right PMAcceptEdits
  "plan" -> Right PMPlan
  "bypassPermissions" -> Right PMBypassPermissions
  other -> Left $ "unknown permission_mode: " <> T.unpack other

data PlanApproval = PARequired | PASkipped
  deriving stock (Eq, Show)

planApprovalText :: PlanApproval -> Text
planApprovalText = \case
  PARequired -> "required"
  PASkipped -> "skipped"

parsePlanApproval :: Text -> Either String PlanApproval
parsePlanApproval = \case
  "required" -> Right PARequired
  "skipped" -> Right PASkipped
  other -> Left $ "unknown plan_approval: " <> T.unpack other

data TelegramBinding = TelegramBinding
  { tgChatId :: Integer
  , tgThreadId :: Maybe Integer
  , tgMessageId :: Maybe Integer
  , tgUserId :: Maybe Integer
  }
  deriving stock (Show)

-- JSON / YAML instances. YAML is just parsed-aeson-with-different-bytes.

parseEnum :: (Text -> Either String a) -> Text -> Value -> Parser a
parseEnum p label = withText (T.unpack label) $ \t -> either fail pure (p t)

instance FromJSON TaskKind where
  parseJSON = parseEnum parseKind "TaskKind"

instance ToJSON TaskKind where
  toJSON = String . kindText

instance FromJSON Status where
  parseJSON = parseEnum parseStatus "Status"

instance ToJSON Status where
  toJSON = String . statusText

instance FromJSON Mode where
  parseJSON = parseEnum parseMode "Mode"

instance ToJSON Mode where
  toJSON = String . modeText

instance FromJSON Priority where
  parseJSON = parseEnum parsePriority "Priority"

instance ToJSON Priority where
  toJSON = String . priorityText

instance FromJSON PermissionMode where
  parseJSON = parseEnum parsePermissionMode "PermissionMode"

instance ToJSON PermissionMode where
  toJSON = String . permissionModeText

instance FromJSON PlanApproval where
  parseJSON = parseEnum parsePlanApproval "PlanApproval"

instance ToJSON PlanApproval where
  toJSON = String . planApprovalText

instance FromJSON TelegramBinding where
  parseJSON = withObject "TelegramBinding" $ \o ->
    TelegramBinding
      <$> o .: "chat_id"
      <*> o .:? "thread_id"
      <*> o .:? "message_id"
      <*> o .:? "user_id"

instance ToJSON TelegramBinding where
  toJSON tg =
    object
      [ "chat_id" .= tgChatId tg
      , "thread_id" .= tgThreadId tg
      , "message_id" .= tgMessageId tg
      , "user_id" .= tgUserId tg
      ]

instance FromJSON TaskId where
  parseJSON = withText "TaskId" (pure . TaskId)

instance ToJSON TaskId where
  toJSON = String . unTaskId

instance FromJSON Frontmatter where
  parseJSON = withObject "Frontmatter" $ \o ->
    Frontmatter
      <$> o .: "schema"
      <*> o .: "kind"
      <*> o .: "status"
      <*> o .: "title"
      <*> o .: "created"
      <*> o .:? "mode"
      <*> o .:? "repo"
      <*> o .:? "priority" .!= Med
      <*> o .:? "agent_owner"
      <*> o .:? "depends_on" .!= []
      <*> o .:? "budget_usd"
      <*> o .:? "permission_mode"
      <*> o .:? "allowed_tools"
      <*> o .:? "plan_approval" .!= PARequired
      <*> o .:? "telegram"
      <*> o .:? "labels" .!= []
      <*> o .:? "model"
      <*> o .:? "retry_count" .!= 0
      <*> o .:? "verify"

instance ToJSON Frontmatter where
  toJSON fm =
    object $
      [ "schema" .= fmSchema fm
      , "kind" .= fmKind fm
      , "status" .= fmStatus fm
      , "title" .= fmTitle fm
      , "created" .= fmCreated fm
      , "priority" .= fmPriority fm
      , "plan_approval" .= fmPlanApproval fm
      , "depends_on" .= fmDependsOn fm
      , "labels" .= fmLabels fm
      , "retry_count" .= fmRetryCount fm
      ]
        <> optKV "mode" (fmMode fm)
        <> optKV "repo" (fmRepo fm)
        <> optKV "agent_owner" (fmAgentOwner fm)
        <> optKV "budget_usd" (fmBudgetUsd fm)
        <> optKV "permission_mode" (fmPermissionMode fm)
        <> optKV "allowed_tools" (fmAllowedTools fm)
        <> optKV "telegram" (fmTelegram fm)
        <> optKV "model" (fmModel fm)
        <> optKV "verify" (fmVerify fm)

-- | Emit a YAML key only when the value is 'Just'. Keeps optional fields out
-- of the round-tripped file when unset.
optKV :: ToJSON a => Text -> Maybe a -> [Pair]
optKV _ Nothing = []
optKV k (Just v) = [Key.fromText k .= v]
