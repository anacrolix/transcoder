module SkipChan where

import Control.Concurrent.MVar

data SkipChan a =
  SkipChan (MVar (a, [MVar ()]))
           (MVar ())

newSkipChan :: IO (SkipChan a)
newSkipChan = do
  sem <- newEmptyMVar
  main <- newMVar (undefined, [sem])
  return (SkipChan main sem)

putSkipChan :: SkipChan a -> a -> IO ()
putSkipChan (SkipChan main _) v = do
  (_, sems) <- takeMVar main
  putMVar main (v, [])
  mapM_ (\sem -> putMVar sem ()) sems

getSkipChan :: SkipChan a -> IO a
getSkipChan (SkipChan main sem) = do
  takeMVar sem
  (v, sems) <- takeMVar main
  putMVar main (v, sem : sems)
  return v

dupSkipChan :: SkipChan a -> IO (SkipChan a)
dupSkipChan (SkipChan main _) = do
  sem <- newEmptyMVar
  (v, sems) <- takeMVar main
  putMVar main (v, sem : sems)
  return (SkipChan main sem)
