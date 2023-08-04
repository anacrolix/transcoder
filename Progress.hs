{-# LANGUAGE DeriveGeneric   #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE InstanceSigs #-}

module Progress where

import           Control.Lens
import           Data.Aeson
import           Data.Aeson.Types ()
import           Data.Char
import           Data.List
import           Data.Maybe
import           GHC.Generics

data Progress = Progress
  { _ready                    :: Bool
  , _downloading              :: Bool
  , _progressDownloadProgress :: Float
  , _probing                  :: Bool
  , _converting               :: Bool
  , _convertPos               :: Integer
  , _storing                  :: Bool
  , _inputDuration            :: Integer
  , _queued                   :: Bool
  } deriving (Generic, Show, Eq)

makeLenses ''Progress

instance ToJSON Progress where
  toEncoding :: Progress -> Encoding
  toEncoding =
    genericToEncoding $
    defaultOptions
    { fieldLabelModifier =
        mapHead toUpper . trimPrefix "progress" . drop 1
    }

mapHead :: (a -> a) -> [a] -> [a]
mapHead f (x:xs) = f x: xs
mapHead _ [] = []

defaultProgress :: Progress
defaultProgress =
  Progress
  { _ready = False
  , _downloading = False
  , _progressDownloadProgress = 0
  , _probing = False
  , _converting = False
  , _convertPos = 0
  , _inputDuration = 0
  , _storing = False
  , _queued = False
  }

-- <*> is from Applicative ((->) r)
trimPrefix p = fromMaybe <*> stripPrefix p
