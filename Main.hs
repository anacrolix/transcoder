{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE PartialTypeSignatures #-}

import Control.Arrow ((>>>))
import Control.Concurrent
import Control.Concurrent.Lock as Lock
import Control.Concurrent.STM
import Control.Exception
import Control.Lens
import Control.Monad
import Control.Monad.Reader
import Control.Monad.Trans.Except
import Control.Monad.Trans.Resource as Resource
import qualified Crypto.Hash.MD5 as MD5
import Data.Aeson
import Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Streaming as BS
import qualified Data.ByteString.Streaming.Char8 as BSC
import Data.Char
import Data.Hex
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Maybe
import Data.Monoid
import qualified FFmpeg
import Network.HTTP.Types
import Network.Wai as Wai
import Network.Wai.Handler.Warp as Warp
import Network.Wai.Handler.WebSockets
import Network.Wai.Streaming
import Network.WebSockets.Connection
import Pipes
import Pipes.ByteString as PB
import Pipes.HTTP
import Progress
import SkipChan
import Streaming as S
import qualified Streaming.Prelude as S
import System.Directory
import System.Exit (ExitCode(..))
import System.FilePath
import System.IO
import System.IO.Unsafe
import System.Log.Formatter
import System.Log.Handler
import System.Log.Handler.Simple
import System.Log.Logger
import System.Process

-- import Network.Wai.Handler.Warp.File
progressAppPort :: Port
progressAppPort = 3001

main :: IO () = do
  h <-
    streamHandler stderr DEBUG >>= \h ->
      return $
      setFormatter h $ simpleLogFormatter "[$time $loggername/$prio] $msg"
  updateGlobalLogger rootLoggerName $ clearLevel . setHandlers [h]
  debugM rootLoggerName "started main"
  t <- newTranscoder
  forkIO $ do
    debugM rootLoggerName $
      "progress server starting on port " <> show progressAppPort
    Warp.runSettings
      (setTimeout 10000 . setPort progressAppPort $ defaultSettings) $
      progressApp $ \id pos -> updateProgress id t $ set convertPos pos
  infoM rootLoggerName $ "starting main http server on port " <> show mainPort
  Warp.run mainPort $ app t
  where
    mainPort = 3000

newTranscoder :: IO Transcoder
newTranscoder = do
  a <- newTVarIO Map.empty
  es <- newTVarIO Map.empty
  transcodeLock <- new
  return $
    Transcoder
      a
      es
      ("localhost:" <> show progressAppPort)
      newSimpleStore
      transcodeLock

type OpId = FilePath

type ServerRequest = Wai.Request

type EventChan = SkipChan ()

type RefCount = Integer

data Transcoder = Transcoder
  { active :: TVar (Map.Map OpId Progress)
  , events :: TVar (Map.Map OpId (RefCount, EventChan))
  , progressListenerAddr :: String
  , store :: Store
  , transcodeLock :: Lock
  }

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
  infoM rootLoggerName $
    "serving " <> (show $ isWebSocketsReq req) <> " " <>
    C.unpack (rawPathInfo req <> rawQueryString req)
  resp <- serveTranscode t req
  respond resp

wsApp :: OperationEnv -> PendingConnection -> IO ()
wsApp env pending_conn = do
  conn <- acceptRequest pending_conn
  es <- dupEvents t oi
  let relayProgress = go Nothing
        where
          go last = do
            p <- getProgress oi t
            when (fromMaybe True $ (/= p) <$> last) $
              sendTextData conn $ encode p
            getSkipChan es
  relayProgress `finally` decEvents t oi
  where
    t = transcoder env
    oi = target env

decEvents :: Transcoder -> OpId -> IO ()
decEvents t oi =
  atomically $
  modifyTVar' (events t) $
  flip Map.update oi $ \(rc, ec) ->
    if rc == 1
      then Nothing
      else Just (rc - 1, ec)

dupEvents :: Transcoder -> OpId -> IO EventChan
dupEvents t oi = do
  newValue <- newSkipChan
  join $
    atomically $ do
      m <- readTVar $ events t
      let (ret, m') =
            case Map.lookup oi m of
              Nothing -> (return newValue, Map.insert oi (1, newValue) m)
              Just (rc, es) -> (dupSkipChan es, Map.insert oi (rc + 1, es) m)
      writeTVar (events t) m'
      return ret

badParam :: ByteString -> Wai.Response
badParam name =
  responseLBS status400 [] $ LBS.fromStrict $ "bad " <> name <> "\n"

getProgress :: OpId -> Transcoder -> IO Progress
getProgress op t = do
  ps <- readTVarIO $ active t
  case Map.lookup op ps of
    Just p -> return p
    Nothing -> do
      _ready <- store t & have $ op
      return $
        if _ready
          then set ready True defaultProgress
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
          ready <- store t & have $ target env
          unless ready $ transcode env
          -- TODO: Take a streamingResponse from the store's get method.
          -- Warp seems to handle the file parts for us if we pass Nothing.
          return $
            responseFile status200 [] ((get . store) t $ target env) Nothing
  where
    qs = Wai.queryString req
    queryValue :: ByteString -> ExceptT Wai.Response IO ByteString
    queryValue k =
      maybe (throwE . badParam $ k) return $ getFirstQueryValue k qs
    opts = getQueryValues "opt" qs

type BreakT m a = ExceptT a m a

runBreakT :: (Functor m) => BreakT m a -> m a
runBreakT = fmap mergeEither . runExceptT

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
    Just (_, ec) -> putSkipChan ec ()

{-# NOINLINE devNull #-}
devNull :: Handle
devNull =
  unsafePerformIO $ do
    warningM rootLoggerName "opening /dev/null"
    openFile "/dev/null" ReadWriteMode

withProgressFlag env f a = bracket_ (up $ set f True) (up $ set f False) a
  where
    up = updateProgressEnv env

updateProgressEnv env = updateProgress (target env) (transcoder env)

transcode :: OperationEnv -> IO ()
transcode env = do
  withProgressFlag env downloading $ download env onDownloadProgress
  forkIO $ getDuration env
  let runTranscode =
        withFile logFilePath WriteMode $ \logFile ->
          withCreateProcess
            (proc (List.head args) (List.tail args))
            { std_err = UseHandle logFile
            , std_out = UseHandle logFile
            , std_in = UseHandle devNull
            } $ \_ _ _ ph -> waitForProcess ph
  withProgressFlag env converting $
    runResourceT $ do
      queued <- allocateProgressFlag env queued
      allocate_
        (acquire $ transcodeLock . transcoder $ env)
        (Lock.release $ transcodeLock . transcoder $ env)
      Resource.release queued
      liftIO $
        runTranscode >>= \case
          ExitSuccess -> do
            storeFile transcodeFile
            storeFile logFilePath
            removeFile transcodeFile
            removeFile _inputFile
            removeFile logFilePath
          ExitFailure code -> do
            warningM "transcode" $
              "process " <> show args <> " failed with exit code " <> show code
            removeFileIfExists $ target env
  where
    logFilePath = transcodeFile <> ".log"
    _inputFile = inputFile env
    transcodeFile = target env
    args = ffmpegArgs env
    up = updateProgress (target env) (transcoder env)
    onDownloadProgress = up . set progressDownloadProgress
    storeFile id = do
      debugM rootLoggerName $ "storing " <> id
      (put . store . transcoder $ env) id $ BS.readFile id

allocateProgressFlag :: OperationEnv -> _ -> ResourceT IO ReleaseKey
allocateProgressFlag env flag =
  fst <$>
  allocate_
    (updateProgressEnv env (set flag True))
    (updateProgressEnv env (set flag False))

allocate_ a f = allocate a (\_ -> f)

removeFileIfExists :: FilePath -> IO ()
removeFileIfExists file = doesFileExist file >>= flip when (removeFile file)

newHttpClientManager :: IO Manager
newHttpClientManager = newManager defaultManagerSettings

type FileLength = Integer

download :: OperationEnv -> (Float -> IO ()) -> IO ()
download env progress = do
  let file = inputFile env
  req <- parseRequest . C.unpack $ inputUrl env
  m <- newHttpClientManager
  infoM rootLoggerName $ "downloading " <> file
  withHTTP req m $ \resp -> do
    when (Pipes.HTTP.responseStatus resp /= status200) $
      error $ show $ Pipes.HTTP.responseStatus resp
    let cl = contentLength (Pipes.HTTP.responseHeaders resp) :: Maybe FileLength
    existingSize <-
      (Just <$> getFileSize file) `catch`
      (\(_ :: IOException) -> return Nothing)
    let complete = fromMaybe False $ (==) <$> cl <*> existingSize
    let bytesProgress fl =
          progress $
          case cl of
            Just total -> fromIntegral fl / fromIntegral total
            Nothing -> 0.5
    unless complete $
      withFile file WriteMode $ \out ->
        runEffect $
        responseBody resp >-> downloadProgress bytesProgress >-> PB.toHandle out

contentLength :: ResponseHeaders -> Maybe FileLength
contentLength hs =
  (read . C.unpack . snd) <$> List.find (\(n, _) -> n == hContentLength) hs

downloadProgress :: (FileLength -> IO ()) -> Pipe ByteString ByteString IO ()
downloadProgress pos = go 0
  where
    go last = do
      bs <- await
      let step = fromIntegral $ B.length bs
      let next = last + step
      lift $ pos next
      Pipes.yield bs
      go next

ffmpegArgs :: OperationEnv -> [String]
ffmpegArgs env =
  let i = inputFile env
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
hashStrings = MD5.updates MD5.init >>> MD5.finalize

-- This is the request site for ffmpeg's progress parameter.
progressApp :: (OpId -> Integer -> IO ()) -> Application
progressApp f req respond = do
  let id =
        fmap C.unpack . getFirstQueryValue "id" $ Wai.queryString req :: Maybe OpId
  case id of
    Nothing -> respond $ responseLBS status400 [] "no id"
    Just id -> do
      resp <- respond $ responseLBS status200 [] ""
      -- TODO: This doesn't seem to work?
      pauseTimeout req
      let act :: [String] -> IO ()
          act ss =
            case ss of
              ("out_time_ms":s:_) -> do
                debugM "progress" $ id <> ": " <> show ss
                f id $ 1000 * read s
              -- Maybe return Bool for continuation based on progress field
              _ -> return ()
      let sBody = BSC.fromChunks $ streamingRequest req :: BS.ByteString IO ()
          lines = BSC.lines $ sBody :: Stream (BS.ByteString IO) IO ()
          bsLines = S.mapped BSC.toStrict lines :: Stream (Of ByteString) IO ()
          sLines =
            S.map (fmap C.unpack . C.split '=') bsLines :: Stream (Of [String]) IO ()
      -- BSC.stdout sBody
      S.mapM_ act sLines
      return resp

getDuration :: OperationEnv -> IO ()
getDuration env = do
  md <- FFmpeg.probeDuration $ inputFile env
  case md of
    Nothing -> return ()
    Just d ->
      updateProgress (target env) (transcoder env) $
      set inputDuration $ ceiling $ d * 1e9

data Store = Store
  { put :: OpId -> BS.ByteString (ResourceT IO) () -> IO ()
  -- TODO: This should return a streaming thingy.
  , get :: OpId -> FilePath
  , have :: OpId -> IO Bool
  }

newSimpleStore =
  Store
  { put =
      \id bs -> do
        let filePath = "simple" </> id
        createDirectoryIfMissing True $ takeDirectory filePath
        runResourceT $ BS.writeFile filePath bs
  , get = \id -> "simple" </> id
  , have = \id -> doesFileExist ("simple" </> id)
  }
