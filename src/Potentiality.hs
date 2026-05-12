module Potentiality (run) where

import Data.Version (showVersion)
import Options.Applicative
import Potentiality.Version (version)

data Command
  = Version
  | Help

commandParser :: Parser Command
commandParser =
  flag' Version (long "version" <> short 'V' <> help "Print version and exit")
    <|> pure Help

opts :: ParserInfo Command
opts =
  info
    (commandParser <**> helper)
    ( fullDesc
        <> progDesc "Potentiality — Haskell agent runner over a Markdown vault."
        <> header ("pot " <> showVersion version)
    )

run :: IO ()
run = do
  cmd <- execParser opts
  case cmd of
    Version -> putStrLn (showVersion version)
    Help -> putStrLn "pot: subcommands not yet implemented; see spec/ and run `pot --help`."
