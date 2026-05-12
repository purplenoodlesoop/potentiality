-- | Aeson decoders for Claude Code's @--output-format=stream-json@.
--
-- We parse only the events we act on (init, text deltas, tool-use starts,
-- api retries, terminal result). Everything else falls into 'EOther' and
-- is logged verbatim to @transcript.jsonl@. Lenient on purpose: Claude
-- Code's event schema evolves, and we shouldn't crash the run when an
-- unknown event type appears.
module Potentiality.StreamJson
  ( Event (..)
  , InitInfo (..)
  , ResultInfo (..)
  , Usage (..)
  , parseEvent
  , isContinuation
  , renderEvent
  ) where

import Control.Applicative (empty, (<|>))
import Data.Aeson (FromJSON (..), Value (..), withObject, (.!=), (.:), (.:?))
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

data Event
  = EInit InitInfo
  | ETextDelta Text
  | EToolUseStart Text Value
  | EApiRetry Text
  | EResult ResultInfo
  | EOther Value
  deriving stock (Show)

data InitInfo = InitInfo
  { iiSessionId :: Text
  , iiModel :: Maybe Text
  }
  deriving stock (Show)

data ResultInfo = ResultInfo
  { riSubtype :: Maybe Text
  , riStopReason :: Maybe Text
  , riCostUsd :: Maybe Double
  , riUsage :: Maybe Usage
  , riSessionId :: Maybe Text
  , riResultText :: Maybe Text
  }
  deriving stock (Show)

data Usage = Usage
  { uInput :: Int
  , uOutput :: Int
  , uCacheCreate :: Int
  , uCacheRead :: Int
  }
  deriving stock (Show)

instance FromJSON Usage where
  parseJSON = withObject "Usage" $ \o ->
    Usage
      <$> o .:? "input_tokens" .!= 0
      <*> o .:? "output_tokens" .!= 0
      <*> o .:? "cache_creation_input_tokens" .!= 0
      <*> o .:? "cache_read_input_tokens" .!= 0

-- | Map one decoded JSON value to a recognized event, falling back to
-- 'EOther' when nothing matches.
parseEvent :: Value -> Event
parseEvent v = fromMaybe (EOther v) (parseMaybe topLevel v)
  where
    topLevel :: Value -> Parser Event
    topLevel = withObject "Event" $ \o -> do
      typ <- o .: "type" :: Parser Text
      case typ of
        "system" -> parseSystem o
        "stream_event" -> o .: "event" >>= parseStreamEvent
        "result" -> EResult <$> parseResult o
        "assistant" -> parseAssistant o
        _ -> empty

    parseSystem o = do
      sub <- (o .:? "subtype" :: Parser (Maybe Text))
      case sub of
        Just "init" ->
          EInit
            <$> ( InitInfo
                    <$> o .: "session_id"
                    <*> o .:? "model"
                )
        Just "api_retry" -> EApiRetry <$> (o .:? "error" .!= "")
        _ -> empty

    parseStreamEvent =
      withObject "stream event" $ \e -> do
        t <- e .: "type" :: Parser Text
        case t of
          "message_delta" -> do
            delta <- e .: "delta"
            parseDelta delta
          "content_block_start" -> do
            cb <- e .: "content_block"
            parseContentBlock cb
          _ -> empty

    parseDelta = withObject "delta" $ \d -> do
      t <- d .: "type" :: Parser Text
      case t of
        "text_delta" -> ETextDelta <$> d .: "text"
        _ -> empty

    parseContentBlock = withObject "content_block" $ \c -> do
      t <- c .: "type" :: Parser Text
      case t of
        "tool_use" -> do
          name <- c .: "name"
          input <- c .:? "input" .!= Null
          pure (EToolUseStart name input)
        _ -> empty

    -- 'assistant' shape: a fully formed assistant message with content
    -- blocks. Older claude builds emit this instead of streamed deltas.
    parseAssistant o = do
      msg <- o .: "message"
      content <- msg .: "content"
      pieces <- traverse extractText content <|> pure []
      pure (ETextDelta (T.concat pieces))

    extractText = withObject "content piece" $ \c -> do
      t <- c .: "type" :: Parser Text
      case t of
        "text" -> c .: "text"
        _ -> pure ""

    parseResult o =
      ResultInfo
        <$> o .:? "subtype"
        <*> o .:? "stop_reason"
        <*> o .:? "total_cost_usd"
        <*> o .:? "usage"
        <*> o .:? "session_id"
        <*> o .:? "result"

-- | True for events whose textual rendering should concatenate with the
-- preceding one (i.e. token deltas). False otherwise.
isContinuation :: Event -> Bool
isContinuation (ETextDelta _) = True
isContinuation _ = False

-- | Human-readable rendering for @transcript.md@. The raw value lives in
-- @transcript.jsonl@; this is the friendly view.
renderEvent :: Event -> Text
renderEvent (EInit ii) =
  "## init"
    <> "\nsession: "
    <> iiSessionId ii
    <> maybe "" (\m -> "\nmodel: " <> m) (iiModel ii)
renderEvent (ETextDelta t) = t
renderEvent (EToolUseStart name _) = "\n## tool_use: " <> name
renderEvent (EApiRetry e) = "\n## api_retry: " <> e
renderEvent (EResult ri) =
  "\n## result"
    <> maybe "" (\s -> "\nsubtype: " <> s) (riSubtype ri)
    <> maybe "" (\s -> "\nstop_reason: " <> s) (riStopReason ri)
    <> maybe "" (\c -> "\ntotal_cost_usd: " <> T.pack (show c)) (riCostUsd ri)
    <> maybe "" (\u -> "\nusage: in=" <> T.pack (show (uInput u)) <> " out=" <> T.pack (show (uOutput u))) (riUsage ri)
renderEvent (EOther _) = ""
