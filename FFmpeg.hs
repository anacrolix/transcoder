{-# LANGUAGE BangPatterns  #-}
{-# LANGUAGE DeriveGeneric #-}

module FFmpeg where

import           Data.Aeson
import           Data.ByteString.Lazy
import           GHC.Generics
import           System.Process

probeDuration :: String -> IO (Maybe Float)
probeDuration s =
  withCreateProcess
    (proc
       "ffprobe"
       ["-loglevel", "error", "-show_format", "-show_streams", "-of", "json", s])
    {std_out = CreatePipe} $ \_ (Just hout) _ _ -> do
    !info <- decode <$> hGetContents hout
    return $ read . duration . format <$> info

data Info = Info
  { format :: Format
  } deriving (Generic)

instance FromJSON Info

data Format = Format
  { duration :: String
  } deriving (Generic)

instance FromJSON Format
