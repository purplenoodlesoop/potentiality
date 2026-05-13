-- | Read and write the vault-root @preferences.md@ file. Preferences are
-- injected into every spawned agent's system prompt so behavioural rules
-- persist across tasks without repeating them in each task body.
module Potentiality.Preferences
  ( loadPreferences
  , readPreferencesList
  , writePreferencesList
  , prefsToSystemPrompt
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.!=), (.:?), (.=))
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import Path (Abs, File, Path, toFilePath)
import Path.IO (doesFileExist)
import Potentiality.Atomic (atomicWriteBinaryFile)
import Potentiality.Vault (Vault, preferencesFile)

newtype PrefsFile = PrefsFile {pfPreferences :: [Text]}

instance FromJSON PrefsFile where
  parseJSON = withObject "preferences" $ \o ->
    PrefsFile <$> o .:? "preferences" .!= []

instance ToJSON PrefsFile where
  toJSON pf = object ["preferences" .= pfPreferences pf]

-- | Load all preferences for a vault. Returns an empty list when the
-- preferences file is absent (first run) or contains no rules.
loadPreferences :: Vault -> IO [Text]
loadPreferences vault = readPreferencesList (preferencesFile vault)

-- | Parse the preference list from a file.
readPreferencesList :: Path Abs File -> IO [Text]
readPreferencesList fp = do
  exists <- doesFileExist fp
  if not exists
    then pure []
    else do
      bs <- BS.readFile (toFilePath fp)
      if BS.null bs
        then pure []
        else case Yaml.decodeEither' bs of
          Left _ -> pure []
          Right pf -> pure (pfPreferences pf)

-- | Write a list of preference strings back to the file.
writePreferencesList :: Path Abs File -> [Text] -> IO ()
writePreferencesList fp prefs =
  atomicWriteBinaryFile fp (Yaml.encode (PrefsFile prefs))

-- | Convert a preference list to a system-prompt section.
prefsToSystemPrompt :: [Text] -> Text
prefsToSystemPrompt [] = ""
prefsToSystemPrompt ps =
  "\n## User preferences\n\n"
    <> T.unlines (map ("- " <>) ps)
    <> "\nAlways follow the above preferences when making decisions.\n"
