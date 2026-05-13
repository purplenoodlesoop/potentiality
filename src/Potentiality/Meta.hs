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
  , applyBinds
  ) where

import Data.Aeson
  ( FromJSON (..)
  , Result (..)
  , ToJSON (..)
  , Value (..)
  , decodeStrict
  , fromJSON
  , object
  , withObject
  , withText
  , (.!=)
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Pair)
import Data.ByteString qualified as BS
import Data.List (foldl')
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Data.Yaml qualified as Yaml
import Path (toFilePath)
import Path.IO (doesFileExist)
import Potentiality.Atomic (atomicWriteBinaryFile)
import Potentiality.Task (TaskId)
import Potentiality.TaskLock (withTaskLock)
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
mutateMeta vault tid f = withTaskLock vault tid $ do
  m <- readMetaOrEmpty vault tid
  writeMeta vault tid (f m)

-- | Apply a list of @KEY=VAL@ bindings to the task's @meta.yaml@.
--
-- Each entry has the form @dotted.key.path=value@. The key path
-- creates nested objects as needed. The value is parsed as JSON
-- (so numbers, booleans, and null are typed) and falls back to a
-- string when it isn't valid JSON.
--
-- After all bindings are applied, the resulting document is
-- validated against the 'Meta' schema. If a binding produces an
-- unparsable @meta.yaml@ (e.g. @plan_decision=banana@) the call
-- fails and the file is not touched.
applyBinds :: Vault -> TaskId -> [Text] -> IO ()
applyBinds _ _ [] = pure ()
applyBinds vault tid binds = withTaskLock vault tid $ do
  fp <- metaFile vault tid
  base <- readRawMeta fp
  parsed <- traverse parseBindEntry binds
  let updated = foldl' (\v (k, val) -> setAtPath k val v) base parsed
  case fromJSON updated :: Result Meta of
    Error e -> error ("--bind produces invalid meta.yaml: " <> e)
    Success _ -> atomicWriteBinaryFile fp (Yaml.encode updated)
  where
    readRawMeta path = do
      exists <- doesFileExist path
      if not exists
        then pure (Object KeyMap.empty)
        else do
          bs <- BS.readFile (toFilePath path)
          if BS.null bs
            then pure (Object KeyMap.empty)
            else case Yaml.decodeEither' bs of
              Left e -> error ("meta.yaml parse failed: " <> show e)
              Right v -> pure v

parseBindEntry :: Text -> IO ([Text], Value)
parseBindEntry raw = case T.breakOn "=" raw of
  (k, eqV)
    | T.null eqV -> error ("--bind requires KEY=VAL form: " <> T.unpack raw)
    | T.null (T.strip k) -> error ("--bind has empty key: " <> T.unpack raw)
    | otherwise ->
        let path = T.splitOn "." (T.strip k)
            valText = T.drop 1 eqV
         in pure (path, coerceBindValue valText)

setAtPath :: [Text] -> Value -> Value -> Value
setAtPath [] new _ = new
setAtPath (k : rest) new current =
  let obj = case current of
        Object o -> o
        _ -> KeyMap.empty
      inner = fromMaybe (Object KeyMap.empty) (KeyMap.lookup (Key.fromText k) obj)
      updated = setAtPath rest new inner
   in Object (KeyMap.insert (Key.fromText k) updated obj)

-- | Coerce a CLI string into a JSON 'Value'. Falls back to 'String'
-- when the input isn't a valid JSON literal. So @12345@ becomes a
-- number, @true@/@false@ become bools, and arbitrary text stays text.
coerceBindValue :: Text -> Value
coerceBindValue t = fromMaybe (String t) (decodeStrict (TE.encodeUtf8 t))
