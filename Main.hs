{-# LANGUAGE OverloadedStrings #-}

import Control.Arrow ((>>>))
import Control.Concurrent.STM
import Control.Exception
-- import Control.Lens
import Control.Monad
import Control.Monad.Trans.Class
import Control.Monad.Trans.Except
import Crypto.Hash.MD5 as MD5
import Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Lazy as LBS
-- import Data.ByteString.Lazy.Progress
import Data.Char
import Data.Hex
import qualified Data.List as List
import Data.Maybe
import Data.Monoid
import Data.Set as Set
import Debug.Trace
import Network.HTTP.Types
import Network.Wai as Wai
import Network.Wai.Handler.Warp
import System.Directory
import System.Process
import Pipes.HTTP
import Pipes.ByteString as PB
import System.IO
import Pipes

main :: IO ()
main = do
  ops <- newTVarIO Set.empty
  run 3000 $ app ops

type OpId = String

type ServerRequest = Wai.Request

app :: TVar (Set OpId) -> ServerRequest -> (Wai.Response -> IO b) -> IO b
app ops req respond = do
  traceIO $ "serving " <> C.unpack (rawPathInfo req <> rawQueryString req)
  resp <- serveTranscode ops req
  respond resp

badParam :: ByteString -> Wai.Response
badParam name = responseLBS status400 [] $ LBS.fromStrict $ "bad " <> name

serveTranscode :: TVar (Set OpId) -> ServerRequest -> IO Wai.Response
serveTranscode ops req =
  runBreakT $ do
    i <- queryValue "i"
    f <- queryValue "f"
    let outputName = C.unpack $ getOutputName i opt f
    lift $
      bracket_ (claimOp outputName ops) (releaseOp outputName ops) $ do
        ready <- doesFileExist outputName
        unless ready $ transcode outputName i opt
        -- Warp seems to handle the file parts for us if we pass Nothing.
        return $ responseFile status200 [] outputName Nothing
  where
    qs = Wai.queryString req
    queryValue :: ByteString -> ExceptT Wai.Response IO ByteString
    queryValue k =
      maybe (throwE . badParam $ k) return $ getFirstQueryValue k qs
    opt = getQueryValues "opt" qs

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

transcode :: String -> ByteString -> [ByteString] -> IO ()
transcode name i opts =
  do download i inputFile
     onException
       (callProcess (List.head args) (List.tail args))
       (removeFileIfExists name)
     `finally` removeFileIfExists inputFile
  where
    inputFile = name <> ".input"
    args = ffmpegArgs name inputFile $ List.map C.unpack opts

removeFileIfExists :: FilePath -> IO ()
removeFileIfExists file = doesFileExist file >>= flip when (removeFile file)

newHttpClientManager = newManager defaultManagerSettings

download :: ByteString -> FilePath -> IO ()
download i file = do
  req <- parseRequest . C.unpack $ i
  m <- newHttpClientManager
  traceIO $ "downloading " <> file
  withHTTP req m $ \resp -> do
    let cl = contentLength (Pipes.HTTP.responseHeaders resp)
    withFile file WriteMode $ \out ->
      runEffect $ responseBody resp >-> progress (show cl) >-> PB.toHandle out
    

contentLength :: ResponseHeaders -> Maybe Int
contentLength hs = read <$> C.unpack <$> snd <$> List.find (\(n,_)->n==hContentLength) hs

progress :: String -> Pipe ByteString ByteString IO ()
progress length = go 0
  where 
    go last = do
      liftIO $ traceIO $ "downloaded " <> show last <> "/" <> length
      bs <- await
      let step = B.length bs
      yield bs
      go $ last + step

ffmpegArgs outputName i opts =
  ["nice", "ffmpeg", "-hide_banner", "-i", i] ++ opts ++ ["-y", outputName]

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

claimOp :: String -> TVar (Set OpId) -> IO ()
claimOp op ops =
  atomically $ do
    opsval <- readTVar ops
    if member op opsval
      then retry
      else modifyTVar ops $ Set.insert op

releaseOp :: String -> TVar (Set OpId) -> IO ()
releaseOp file active = atomically $ modifyTVar active $ Set.delete file

getOutputName :: ByteString -> [ByteString] -> ByteString -> ByteString
getOutputName i opts f =
  (C.pack . List.map toLower . C.unpack . hex $ hashStrings (i : opts)) <> "." <>
  f

hashStrings :: [ByteString] -> ByteString
hashStrings = updates MD5.init >>> finalize
