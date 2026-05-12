-- | Read a @task.md@ file from disk and split it into structured
-- frontmatter plus body text.
--
-- The on-disk format is YAML frontmatter delimited by @---@ lines,
-- followed by Markdown:
--
-- @
-- ---
-- schema: 1
-- kind: research
-- ...
-- ---
-- # task body in Markdown
-- @
--
-- See @spec\/03-vault-layout.md@ for the full schema. The closing fence
-- MUST be @\\n---\\n@; files that end with a bare @\\n---@ (no trailing
-- newline) are accepted as a tolerated edge case.
module Potentiality.Task.Parse
  ( ParseError (..)
  , parseTaskFile
  , parseTaskBytes
  , splitFrontmatter
  ) where

import Control.Exception (Exception)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BSC
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Yaml qualified as Yaml
import Potentiality.Task (Task (..), TaskId)

data ParseError
  = MissingFrontmatter
  | UnterminatedFrontmatter
  | YamlError Yaml.ParseException
  | EncodingError String
  deriving stock (Show)

instance Eq ParseError where
  MissingFrontmatter == MissingFrontmatter = True
  UnterminatedFrontmatter == UnterminatedFrontmatter = True
  YamlError a == YamlError b = show a == show b
  EncodingError a == EncodingError b = a == b
  _ == _ = False

instance Exception ParseError

parseTaskFile :: TaskId -> FilePath -> IO (Either ParseError Task)
parseTaskFile tid fp = parseTaskBytes tid <$> BS.readFile fp

parseTaskBytes :: TaskId -> ByteString -> Either ParseError Task
parseTaskBytes tid bs = do
  (fmBs, bodyBs) <- splitFrontmatter bs
  fm <- first YamlError (Yaml.decodeEither' fmBs)
  body <- decodeBody bodyBs
  pure
    Task
      { taskId = tid
      , taskFrontmatter = fm
      , taskBody = stripLeading body
      }

decodeBody :: ByteString -> Either ParseError Text
decodeBody = first (EncodingError . show) . TE.decodeUtf8'

-- | Strip a single optional leading newline. Frontmatter is followed by
-- @---\\n@; the body conventionally begins on the next line.
stripLeading :: Text -> Text
stripLeading t = case T.uncons t of
  Just ('\n', rest) -> rest
  _ -> t

-- | Bytes layout invariant for the @\\n---\\n@ close: returns
-- (yamlBytes, bodyBytes) when the file starts with @---\\n@ and the
-- frontmatter is terminated by @\\n---\\n@ or @\\n---@ at EOF.
splitFrontmatter :: ByteString -> Either ParseError (ByteString, ByteString)
splitFrontmatter bs
  | not (BS.isPrefixOf openFence bs) = Left MissingFrontmatter
  | otherwise =
      let afterOpen = BS.drop (BS.length openFence) bs
          (yamlBs, rest) = BS.breakSubstring closeFenceFull afterOpen
       in if not (BS.null rest)
            then Right (yamlBs, BS.drop (BS.length closeFenceFull) rest)
            else case BS.breakSubstring closeFenceBare afterOpen of
              (yamlBs', rest')
                | not (BS.null rest')
                    && BS.drop (BS.length closeFenceBare) rest' == BS.empty ->
                    Right (yamlBs', BS.empty)
                | otherwise -> Left UnterminatedFrontmatter
  where
    openFence = BSC.pack "---\n"
    closeFenceFull = BSC.pack "\n---\n"
    closeFenceBare = BSC.pack "\n---"

