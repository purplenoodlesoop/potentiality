-- | Self-contained ULID generation. We do NOT pull in a Hackage ULID
-- library — the spec is small (48-bit ms timestamp + 80-bit randomness,
-- Crockford-base32 over 26 characters) and adding a dependency is more
-- code to audit than the implementation here.
--
-- This module is intentionally not crypto-grade — 'System.Random' is fine
-- for ULID's collision-avoidance purpose (ULIDs are time-sorted and the
-- random suffix only needs to disambiguate ties). If we ever need
-- adversary-resistant uniqueness, swap to a crypto-grade RNG.
module Potentiality.Ulid
  ( newUlid
  , formatUlid
  , ulidAlphabet
  ) where

import Data.Bits (shiftR, (.&.))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word (Word64, Word8)
import System.Random (randomRIO)

-- | Crockford base32 alphabet. No I, L, O, U.
ulidAlphabet :: String
ulidAlphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

base32Char :: Int -> Char
base32Char i = ulidAlphabet !! (i .&. 0x1f)

-- | Generate a fresh ULID: current ms + 80 random bits.
newUlid :: IO Text
newUlid = do
  ms <- getCurrentMillis
  rnd <- mapM (const (randomRIO (0, 255 :: Int))) [1 .. 10 :: Int]
  pure (formatUlid ms (map fromIntegral rnd))

getCurrentMillis :: IO Word64
getCurrentMillis = do
  t <- getPOSIXTime
  pure (floor (t * 1000))

-- | Encode a 48-bit timestamp + 10 random bytes into the 26-char ULID
-- representation. Pure for testability.
formatUlid :: Word64 -> [Word8] -> Text
formatUlid ts rnd =
  T.pack (encodeTimestamp ts <> encodeRandom rnd)

-- 48-bit ms timestamp → 10 base32 chars (high 5-bit group on the left).
encodeTimestamp :: Word64 -> String
encodeTimestamp t = [base32Char (fromIntegral (t `shiftR` (5 * i))) | i <- [9, 8 .. 0]]

-- 10 random bytes (80 bits) → 16 base32 chars.
encodeRandom :: [Word8] -> String
encodeRandom bytes =
  let n :: Integer
      n = foldl (\acc b -> acc * 256 + fromIntegral b) 0 bytes
      go :: Int -> Integer -> String
      go 0 _ = ""
      go k v = base32Char (fromIntegral (v `mod` 32)) : go (k - 1) (v `div` 32)
   in reverse (go 16 n)
