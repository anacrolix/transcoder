{-# LANGUAGE DeriveGeneric #-}

module FFmpeg where

import Data.Aeson
import Data.ByteString.Lazy
import GHC.Generics
import System.Process

probeDuration :: String -> IO (Maybe Float)
probeDuration s = do
  (_, Just hout, _, ph) <-
    createProcess
      (proc
         "ffprobe"
         [ "-loglevel"
         , "error"
         , "-show_format"
         , "-show_streams"
         , "-of"
         , "json"
         , s
         ])
      {std_out = CreatePipe}
  info <- decode <$> hGetContents hout
  return $ read . duration . format <$> info

data Info = Info
  { format :: Format
  } deriving (Generic)

instance FromJSON Info

data Format = Format
  { duration :: String
  } deriving (Generic)

instance FromJSON Format
