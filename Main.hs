{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use underscore" #-}

import qualified Data.ByteString.Char8 as C
import Data.Default.Class
import Data.Maybe
import Data.String
import Data.X509
import Data.X509.CertificateStore
import Data.X509.Validation
import Network.TLS
import Network.Wai.Handler.Warp as Warp
import Network.Wai.Handler.WarpTLS
import System.Environment
import System.IO
import System.Log.Formatter
import System.Log.Handler
import System.Log.Handler.Simple
import System.Log.Logger
import Transcoder

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
