{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use underscore" #-}

import Control.Arrow ((>>>))
import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.Lock as Lock
import Control.Concurrent.STM
import Control.Lens
import Control.Monad
import Control.Monad.IO.Unlift
import Control.Monad.Trans.Except
import Control.Monad.Trans.Maybe
import qualified Crypto.Hash.MD5 as MD5
import Data.Aeson
import qualified Data.Bifunctor (second)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.ByteString.Builder (byteString)
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Lazy as LBS
import Data.ByteString.Streaming.HTTP as Http.Client hiding (
    runResourceT,
 )
import Data.Char
import Data.Default.Class
import Data.Foldable
import Data.Hex
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Maybe
import Data.String
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.X509
import Data.X509.CertificateStore
import Data.X509.Validation
import Extra
import qualified FFmpeg
import Network.HTTP.Types
import Network.TLS
import Network.Wai as Wai
import Network.Wai.Handler.Warp as Warp
import Network.Wai.Handler.WarpTLS
import Network.Wai.Handler.WebSockets
import Network.Wai.Parse
import Network.Wai.Streaming
import Network.WebSockets.Connection
import Progress
import SkipChan
import Streaming as S
import Streaming.ByteString (ByteStream)
import qualified Streaming.ByteString as BS
import qualified Streaming.ByteString.Char8 as BSC
import qualified Streaming.Prelude as S
import System.Directory
import System.DiskSpace
import System.Environment
import System.Exit (ExitCode (..))
import System.FilePath
import System.IO
import System.Log.Formatter
import System.Log.Handler
import System.Log.Handler.Simple
import System.Log.Logger
import System.Process
import Text.Printf
import Transcoder
import UnliftIO.Exception
import UnliftIO.Resource as Resource

progressAppPort :: Port
progressAppPort = 3001

main :: IO () = do
    hSetBuffering stderr LineBuffering
    h <-
        streamHandler stderr DEBUG >>= \h ->
            return $
                setFormatter h $
                    simpleLogFormatter "[$time $loggername/$prio] $msg"
    updateGlobalLogger rootLoggerName $ clearLevel . setHandlers [h]
    debugM rootLoggerName "started main"
    certStore <- fromJust <$> readCertificateStore "certificate.pem"
    t <- newTranscoder progressAppPort
    extraHosts <- getArgs
    let allHosts = "localhost" : extraHosts
    let allProgressServers :: [IO ()] = runProgressServer t . fromString <$> allHosts <*> pure progressAppPort
    let mainServers = map (runMainServer certStore t . fromString) allHosts
    raceAll $ allProgressServers ++ mainServers

mainPort = 3000

-- runMainServer :: a -> b -> c -> IO ()
runMainServer :: CertificateStore -> Transcoder -> HostPreference -> IO ()
runMainServer certStore t host = do
    infoM rootLoggerName $ "starting main http server at " <> show host <> ":" <> show mainPort
    runTLS
        defaultTlsSettings
            { tlsWantClientCert = True
            , tlsServerHooks =
                def
                    { onClientCertificate =
                        \chain -> do
                            reasons <-
                                validate
                                    Data.X509.HashSHA256
                                    defaultHooks
                                    defaultChecks{checkLeafV3 = False}
                                    certStore
                                    def
                                    ("localhost", C.pack $ ":" <> show mainPort)
                                    chain
                            return $
                                case reasons of
                                    [] -> CertificateUsageAccept
                                    reasons ->
                                        CertificateUsageReject $
                                            CertificateRejectOther $
                                                show reasons
                    }
            }
        (setTimeout (24 * 60 * 60) . setHost host . setPort mainPort . setOnException Transcoder.onException $ defaultSettings)
        $ app t
