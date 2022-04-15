module SkipChan where

import           Control.Concurrent.MVar
import           Data.Maybe
import           System.IO.Unsafe

data SkipChan a =
  SkipChan (MVar (Maybe a, [MVar ()]))
           (MVar ())

instance Show a => Show (SkipChan a) where
  show (SkipChan main sem) =
    "SkipChan " ++ show ((v, length waiters), sem')
    where
      (v, waiters) = unsafePerformIO $ readMVar main
      sem' = case unsafePerformIO $ tryReadMVar sem of
        Nothing -> False
        Just _  -> True

newSkipChan :: IO (SkipChan a)
newSkipChan = do
  sem <- newEmptyMVar
  main <- newMVar (Nothing, [sem])
  return (SkipChan main sem)

putSkipChan :: SkipChan a -> a -> IO ()
putSkipChan (SkipChan main _) v = do
  (_, sems) <- takeMVar main
  putMVar main (Just v, [])
  mapM_ (\sem -> putMVar sem ()) sems

getSkipChan :: SkipChan a -> IO a
getSkipChan (SkipChan main sem) = do
  takeMVar sem
  (v, sems) <- takeMVar main
  putMVar main (v, sem : sems)
  return . fromJust $ v

dupSkipChan :: SkipChan a -> IO (SkipChan a)
dupSkipChan (SkipChan main _) = do
  sem <- newEmptyMVar
  (v, sems) <- takeMVar main
  putMVar main (v, sem : sems)
  return (SkipChan main sem)
