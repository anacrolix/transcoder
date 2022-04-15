module Extra where

import           Control.Monad.Trans           (MonadIO, liftIO)
import           Control.Monad.Trans.Resource  (MonadResource)
import           Streaming.ByteString          (ByteStream, hGetContents)
import           Streaming.ByteString.Internal (bracketByteString)
import           System.IO                     (IOMode (ReadMode),
                                                SeekMode (AbsoluteSeek), hClose,
                                                hSeek, openBinaryFile)

readFileFrom :: (MonadResource m, MonadIO m) => Integer -> FilePath -> ByteStream m ()
readFileFrom off path = bracketByteString (openBinaryFile path ReadMode) hClose $ \h -> do
    liftIO $ hSeek h AbsoluteSeek off
    hGetContents h
