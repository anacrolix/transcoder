{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DisambiguateRecordFields #-}

import Control.Arrow ((>>>))
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Control.Monad.Reader
import Control.Monad.Trans.Class
import Control.Monad.Trans.Except
import Crypto.Hash.MD5 as MD5
import Data.Aeson
import Data.Aeson.Types
import Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Lazy.Char8 as LC
import Data.Char
import Data.Function
import Data.Hex
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Maybe
import Data.Monoid
import Data.Set as Set
import Debug.Trace
import qualified FFmpeg
import GHC.Generics
import Network.HTTP.Types
import Network.Wai as Wai
import Network.Wai.Handler.Warp
import Network.Wai.Handler.WebSockets
import Network.WebSockets.Connection
import Pipes
import Pipes.ByteString as PB
import Pipes.HTTP
import SkipChan
import System.Directory
import System.IO
import System.Process

main :: IO ()
main = do
  a <- newTVarIO Map.empty
  es <- newTVarIO Map.empty
  let progressAppPort = 3001
  let t = Transcoder a es $ "localhost:" <> show progressAppPort
  forkIO $
    run progressAppPort $
    progressApp $ \id pos -> updateProgress id t $ \p -> p {convertPos = pos}
  run 3000 $ app t

type OpId = FilePath

type ServerRequest = Wai.Request

type EventChan = SkipChan ()

data Transcoder = Transcoder
  { active :: TVar (Map.Map OpId Progress)
  , events :: TVar (Map.Map OpId EventChan)
  , progressListenerAddr :: String
  }

type Operation = ReaderT OperationEnv

data OperationEnv = OperationEnv
  { inputUrl :: ByteString
  , ffmpegOpts :: [ByteString]
  , format :: ByteString
  , transcoder :: Transcoder
  }

target :: OperationEnv -> OpId
target = C.unpack . (getOutputName <$> inputUrl <*> ffmpegOpts <*> format)

inputFile :: OperationEnv -> FilePath
inputFile env = target env <> ".input"

progressUrl :: OperationEnv -> String
progressUrl env =
  "http://" <> progressListenerAddr (transcoder env) <> "/?id=" <> target env

app :: Transcoder -> Application
app t req respond = do
  traceIO $
    "serving " <> (show $ isWebSocketsReq req) <> " " <>
    C.unpack (rawPathInfo req <> rawQueryString req)
  resp <- serveTranscode t req
  respond resp

wsApp :: OperationEnv -> PendingConnection -> IO ()
wsApp env pending_conn =
  join $
  (flip runReaderT) env $ do
    t <- asks transcoder
    oi <- asks target
    lift $ do
      conn <- acceptRequest pending_conn
      es <- dupEvents t oi
      forever $ do
        p <- getProgress oi t
        sendTextData conn $ encode p
        getSkipChan es

dupEvents :: Transcoder -> OpId -> IO EventChan
dupEvents t oi = do
  newValue <- newSkipChan
  join $
    atomically $ do
      m <- readTVar $ events t
      case Map.lookup oi m of
        Just existing -> return $ dupSkipChan existing
        Nothing -> do
          writeTVar (events t) $ Map.insert oi newValue m
          return $ return newValue

badParam :: ByteString -> Wai.Response
badParam name = responseLBS status400 [] $ LBS.fromStrict $ "bad " <> name

getProgress :: OpId -> Transcoder -> IO Progress
getProgress op t = do
  ps <- readTVarIO $ active t
  case Map.lookup op ps of
    Just p -> return p
    Nothing -> do
      ready <- doesFileExist op
      return $
        if ready
          then defaultProgress {ready = True}
          else defaultProgress

serveTranscode :: Transcoder -> ServerRequest -> IO Wai.Response
serveTranscode t req =
  runBreakT $ do
    i <- queryValue "i"
    f <- queryValue "f"
    let env = OperationEnv i opts f t
    case websocketsApp defaultConnectionOptions (wsApp env) req of
      Just resp -> pure resp
      Nothing ->
        lift $
        bracket_ (claimOp env) (releaseOp env) $ do
          ready <- doesFileExist $ target env
          unless ready $ transcode env
          -- Warp seems to handle the file parts for us if we pass Nothing.
          return $ responseFile status200 [] (target env) Nothing
  where
    qs = Wai.queryString req
    queryValue :: ByteString -> ExceptT Wai.Response IO ByteString
    queryValue k =
      maybe (throwE . badParam $ k) return $ getFirstQueryValue k qs
    opts = getQueryValues "opt" qs

type BreakT m a = ExceptT a m a

runBreakT :: (Functor m) => BreakT m a -> m a
runBreakT = fmap mergeEither . runExceptT

breakWith :: (Monad m) => a -> BreakT m a
breakWith = ExceptT . return . Left

maybeToEither :: a -> Maybe b -> Either a b
maybeToEither l Nothing = Left l
maybeToEither _ (Just r) = Right r

mergeEither :: Either a a -> a
mergeEither e =
  case e of
    Left v -> v
    Right v -> v

updateProgress :: OpId -> Transcoder -> (Progress -> Progress) -> IO ()
updateProgress k t f = do
  atomically $ modifyTVar' (active t) $ Map.update (Just . f) k
  onProgressEvent k t

onProgressEvent :: OpId -> Transcoder -> IO ()
onProgressEvent oi t = do
  m <- readTVarIO $ events t
  case Map.lookup oi m of
    Nothing -> return ()
    Just ec -> putSkipChan ec ()

transcode :: OperationEnv -> IO ()
transcode env =
  do bracket_
       (up $ \p ->  p {downloading = True})
       (up $ \p ->  p {downloading = False})
       (let onDownloadProgress f = do
              up $ \p ->  p {progressDownloadProgress = f}
        in download env onDownloadProgress)
     forkIO $ getDuration env
     onException
       (bracket_
          (up $ \p ->  p {converting = True})
          (up $ \p ->  p {converting = False})
          (callProcess (List.head args) (List.tail args)))
       (removeFileIfExists $ target env)
     `finally` removeFileIfExists (inputFile env)
  where
    args = ffmpegArgs env
    up = updateProgress (target env) (transcoder env)

removeFileIfExists :: FilePath -> IO ()
removeFileIfExists file = doesFileExist file >>= flip when (removeFile file)

newHttpClientManager = newManager defaultManagerSettings

type FileLength = Integer

download :: OperationEnv -> (Float -> IO ()) -> IO ()
download env progress = do
  let file = inputFile env
  req <- parseRequest . C.unpack $ inputUrl env
  m <- newHttpClientManager
  traceIO $ "downloading " <> file
  withHTTP req m $ \resp -> do
    let cl = contentLength (Pipes.HTTP.responseHeaders resp)
    let bytesProgress fl =
          progress $
          case cl of
            Just total -> fromIntegral fl / fromIntegral total
            Nothing -> 0.5
    withFile file WriteMode $ \out ->
      runEffect $
      responseBody resp >-> downloadProgress (show cl) bytesProgress >->
      PB.toHandle out

contentLength :: ResponseHeaders -> Maybe FileLength
contentLength hs =
  read <$> C.unpack <$> snd <$> List.find (\(n, _) -> n == hContentLength) hs

downloadProgress ::
     String -> (FileLength -> IO ()) -> Pipe ByteString ByteString IO ()
downloadProgress length pos = go 0
  where
    go last
      -- liftIO $ traceIO $ "downloaded " <> show last <> "/" <> length
     = do
      bs <- await
      let step = fromIntegral $ B.length bs
      let next = last + step
      lift $ pos next
      Pipes.yield bs
      go $ next

ffmpegArgs :: OperationEnv -> [String]
ffmpegArgs env =
  let i = C.unpack . inputUrl $ env
      opts = List.map C.unpack . ffmpegOpts $ env
      outputName = target env
  in ["nice", "ffmpeg", "-hide_banner", "-i", i] ++
     opts ++ ["-progress", progressUrl env, "-y", outputName]

getFirstQueryValue :: ByteString -> Query -> Maybe ByteString
getFirstQueryValue key = List.find (\(k, _) -> k == key) >>> fmap snd >>> join

getQueryValues :: ByteString -> Query -> [ByteString]
getQueryValues key = mapMaybe f
  where
    f (k, Just v) =
      if k == key
        then Just v
        else Nothing
    f (_, Nothing) = Nothing

-- claimOp :: String -> TVar (Map.Map OpId Progress) -> IO ()
claimOp :: OperationEnv -> IO ()
claimOp env =
  let op = target env
      ops = active . transcoder $ env
  in atomically $ do
       opsval <- readTVar ops
       if Map.member op opsval
         then retry
         else modifyTVar ops $ Map.insert op defaultProgress

releaseOp :: OperationEnv -> IO ()
releaseOp env =
  atomically $ modifyTVar (active $ transcoder env) $ Map.delete (target env)

getOutputName :: ByteString -> [ByteString] -> ByteString -> ByteString
getOutputName i opts f =
  (C.pack . List.map toLower . C.unpack . hex $ hashStrings (i : opts)) <> "." <>
  f

hashStrings :: [ByteString] -> ByteString
hashStrings = updates MD5.init >>> finalize

data Progress = Progress
  { ready :: Bool
  , downloading :: Bool
  , progressDownloadProgress :: Float
  , probing :: Bool
  , converting :: Bool
  , convertPos :: Integer
  , inputDuration :: Integer
  } deriving (Generic)

instance ToJSON Progress where
  toEncoding =
    genericToEncoding $
    defaultOptions
    {fieldLabelModifier = (\(h:t) -> (toUpper h) : t) . trimPrefix "progress"}

defaultProgress =
  Progress
  { ready = False
  , downloading = False
  , progressDownloadProgress = 0
  , probing = False
  , converting = False
  , convertPos = 0
  , inputDuration = 0
  }

trimPrefix :: (Eq a) => [a] -> [a] -> [a]
trimPrefix p list =
  if take len list == p
    then drop len list
    else list
  where
    len = List.length p
    take = List.take
    drop = List.drop

progressApp :: (OpId -> Integer -> IO ()) -> Application
progressApp f req respond = do
  let id =
        fmap C.unpack . getFirstQueryValue "id" $ Wai.queryString req :: Maybe OpId
  case id of
    Nothing -> respond $ responseLBS status400 [] "no id"
    Just id -> do
      let act :: [String] -> IO ()
          act ("out_time_ms":s:_) = f id $ 1000 * read s
          act x = traceIO $ show x
      body <- lazyRequestBody req
      sequence_ $
        List.map (act . List.map LC.unpack . LC.split '=') $ LC.lines body
      respond $ responseLBS status200 [] ""

getDuration :: OperationEnv -> IO ()
getDuration env = do
  md <- FFmpeg.probeDuration $ inputFile env
  case md of
    Nothing -> return ()
    Just d ->
      updateProgress (target env) (transcoder env) $ \p ->
        p {inputDuration = ceiling $ d * 1e9}
