{-# LANGUAGE DeriveGeneric   #-}
{-# LANGUAGE TemplateHaskell #-}

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
  toEncoding =
    genericToEncoding $
    defaultOptions
    { fieldLabelModifier =
        (\(h:t) -> toUpper h : t) . trimPrefix "progress" . drop 1
    }

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

trimPrefix p = fromMaybe <*> stripPrefix p
