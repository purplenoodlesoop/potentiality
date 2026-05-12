module Potentiality.Version (version) where

import Data.Version (Version, makeVersion)

version :: Version
version = makeVersion [0, 1, 0]
