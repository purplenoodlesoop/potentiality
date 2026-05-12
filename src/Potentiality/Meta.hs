-- | The @meta.yaml@ file alongside @task.md@: session bookkeeping the
-- daemon writes, the agent updates, and Horizon reads. See
-- @spec\/03-vault-layout.md@.
module Potentiality.Meta
  ( Meta (..)
  , Tokens (..)
  , PlanDecision (..)
  , TelegramBindingMeta (..)
  , planDecisionText
  , parsePlanDecision
  , emptyMeta
  , readMeta
  , readMetaOrEmpty
  , writeMeta
  , mutateMeta
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
import Data.Aeson.Types (Pair)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Yaml qualified as Yaml
import Path (toFilePath)
import Path.IO (doesFileExist)
import Potentiality.Atomic (atomicWriteBinaryFile)
import Potentiality.Task (TaskId)
import Potentiality.Vault (Vault, metaFile)

-- | Session bookkeeping. Every field is optional because a task starts
-- without a session and accretes state over its lifetime.
data Meta = Meta
  { metaSession :: Maybe TaskId
  , metaClaudeSessionId :: Maybe Text
  , metaStartedAt :: Maybe UTCTime
  , metaFinishedAt :: Maybe UTCTime
  , metaCurrentStep :: Maybe Text
  , metaLastToolCall :: Maybe Text
  , metaTotalCostUsd :: Maybe Double
  , metaTokens :: Maybe Tokens
  , metaPlanDecision :: Maybe PlanDecision
  , metaPlanRevision :: Maybe Text
  , metaPlanDecidedAt :: Maybe UTCTime
  , metaTelegram :: Maybe TelegramBindingMeta
  }
  deriving stock (Show, Eq)

data Tokens = Tokens
  { tokInput :: Int
  , tokOutput :: Int
  , tokCacheRead :: Int
  }
  deriving stock (Show, Eq)

data PlanDecision = PDPending | PDApproved | PDRevise | PDRejected
  deriving stock (Show, Eq)

planDecisionText :: PlanDecision -> Text
planDecisionText = \case
  PDPending -> "pending"
  PDApproved -> "approved"
  PDRevise -> "revise"
  PDRejected -> "rejected"

parsePlanDecision :: Text -> Either String PlanDecision
parsePlanDecision = \case
  "pending" -> Right PDPending
  "approved" -> Right PDApproved
  "revise" -> Right PDRevise
  "rejected" -> Right PDRejected
  other -> Left ("unknown plan_decision: " <> T.unpack other)

instance FromJSON PlanDecision where
  parseJSON = withText "PlanDecision" $ either fail pure . parsePlanDecision

instance ToJSON PlanDecision where
  toJSON = String . planDecisionText

instance FromJSON Tokens where
  parseJSON = withObject "Tokens" $ \o ->
    Tokens
      <$> o .:? "input" .!= 0
      <*> o .:? "output" .!= 0
      <*> o .:? "cache_read" .!= 0

instance ToJSON Tokens where
  toJSON t =
    object
      [ "input" .= tokInput t
      , "output" .= tokOutput t
      , "cache_read" .= tokCacheRead t
      ]

data TelegramBindingMeta = TelegramBindingMeta
  { tgmChatId :: Integer
  , tgmThreadId :: Maybe Integer
  , tgmMessageId :: Maybe Integer
  , tgmUserId :: Maybe Integer
  }
  deriving stock (Show, Eq)

instance FromJSON TelegramBindingMeta where
  parseJSON = withObject "TelegramBindingMeta" $ \o ->
    TelegramBindingMeta
      <$> o .: "chat_id"
      <*> o .:? "thread_id"
      <*> o .:? "message_id"
      <*> o .:? "user_id"

instance ToJSON TelegramBindingMeta where
  toJSON t =
    object
      [ "chat_id" .= tgmChatId t
      , "thread_id" .= tgmThreadId t
      , "message_id" .= tgmMessageId t
      , "user_id" .= tgmUserId t
      ]

instance FromJSON Meta where
  parseJSON = withObject "Meta" $ \o ->
    Meta
      <$> o .:? "session"
      <*> o .:? "claude_session_id"
      <*> o .:? "started_at"
      <*> o .:? "finished_at"
      <*> o .:? "current_step"
      <*> o .:? "last_tool_call"
      <*> o .:? "total_cost_usd"
      <*> o .:? "tokens"
      <*> o .:? "plan_decision"
      <*> o .:? "plan_revision"
      <*> o .:? "plan_decided_at"
      <*> o .:? "telegram"

instance ToJSON Meta where
  toJSON m =
    object $
      concat
        [ optKV "session" (metaSession m)
        , optKV "claude_session_id" (metaClaudeSessionId m)
        , optKV "started_at" (metaStartedAt m)
        , optKV "finished_at" (metaFinishedAt m)
        , optKV "current_step" (metaCurrentStep m)
        , optKV "last_tool_call" (metaLastToolCall m)
        , optKV "total_cost_usd" (metaTotalCostUsd m)
        , optKV "tokens" (metaTokens m)
        , optKV "plan_decision" (metaPlanDecision m)
        , optKV "plan_revision" (metaPlanRevision m)
        , optKV "plan_decided_at" (metaPlanDecidedAt m)
        , optKV "telegram" (metaTelegram m)
        ]

optKV :: ToJSON a => Text -> Maybe a -> [Pair]
optKV _ Nothing = []
optKV k (Just v) = [Key.fromText k .= v]

emptyMeta :: Meta
emptyMeta =
  Meta
    { metaSession = Nothing
    , metaClaudeSessionId = Nothing
    , metaStartedAt = Nothing
    , metaFinishedAt = Nothing
    , metaCurrentStep = Nothing
    , metaLastToolCall = Nothing
    , metaTotalCostUsd = Nothing
    , metaTokens = Nothing
    , metaPlanDecision = Nothing
    , metaPlanRevision = Nothing
    , metaPlanDecidedAt = Nothing
    , metaTelegram = Nothing
    }

readMeta :: Vault -> TaskId -> IO (Maybe Meta)
readMeta vault tid = do
  fp <- metaFile vault tid
  exists <- doesFileExist fp
  if not exists
    then pure Nothing
    else do
      bs <- BS.readFile (toFilePath fp)
      case Yaml.decodeEither' bs of
        Left e -> error ("meta.yaml parse failed: " <> show e)
        Right m -> pure (Just m)

readMetaOrEmpty :: Vault -> TaskId -> IO Meta
readMetaOrEmpty v t = maybe emptyMeta id <$> readMeta v t

writeMeta :: Vault -> TaskId -> Meta -> IO ()
writeMeta vault tid m = do
  fp <- metaFile vault tid
  atomicWriteBinaryFile fp (Yaml.encode m)

mutateMeta :: Vault -> TaskId -> (Meta -> Meta) -> IO ()
mutateMeta vault tid f = do
  m <- readMetaOrEmpty vault tid
  writeMeta vault tid (f m)
