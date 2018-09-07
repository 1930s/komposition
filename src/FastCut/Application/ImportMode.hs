{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

{-# LANGUAGE ConstraintKinds   #-}
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedLabels  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds         #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE RebindableSyntax  #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TypeOperators     #-}
module FastCut.Application.ImportMode where

import           FastCut.Application.Base

import           Control.Lens
import           Data.String                 (fromString)

import           FastCut.Focus
import           FastCut.Import.Audio
import           FastCut.Import.Video
import           FastCut.Library
import           FastCut.MediaType
import           FastCut.Project

import           FastCut.Application.KeyMaps

data ImportFileForm = ImportFileForm
  { selectedFile :: Maybe FilePath
  , autoSplit    :: Bool
  }

importFile
  :: Application t m
  => Name n
  -> Project
  -> Focus ft
  -> ThroughMode TimelineMode ImportMode (t m) n Project
importFile gui project focus' = do
  let initialModel =
        ImportFileModel {autoSplitValue = False, autoSplitAvailable = True}
  enterImport gui initialModel
  f <- fillForm initialModel
                ImportFileForm {selectedFile = Nothing, autoSplit = False}
  returnToTimeline gui project focus'
  maybe (ireturn project) (importAsset gui project) f
  where
    fillForm model mf = do
      updateImport gui model
      cmd <- nextEvent gui
      case (cmd, mf) of
        (CommandKeyMappedEvent Cancel, _) -> ireturn Nothing
        (CommandKeyMappedEvent Help  , _) -> do
          help gui [ModeKeyMap SImportMode (keymaps SImportMode)]
          fillForm model mf
        (ImportClicked, ImportFileForm { selectedFile = Just file, ..}) ->
          ireturn (Just (file, autoSplit))
        (ImportClicked          , form) -> fillForm model form
        (ImportFileSelected file, form) -> fillForm
          model { autoSplitValue     = False
                , autoSplitAvailable = maybe False isSupportedVideoFile file
                }
          form { selectedFile = file }
        (ImportAutoSplitSet s, form) ->
          fillForm model { autoSplitValue = s } form { autoSplit = s }

data Ok = Ok deriving (Eq, Enum)

instance DialogChoice Ok where
  toButtonLabel Ok = "OK"

importAsset
  :: (UserInterface m, IxMonadIO m)
  => Name n
  -> Project
  -> (FilePath, Bool)
  -> Actions m '[n := Remain (State m TimelineMode)] r Project
importAsset gui project (filepath, autoSplit)
  | isSupportedVideoFile filepath
  = let
      action = case autoSplit of
        True -> importVideoFileAutoSplit filepath (project ^. workingDirectory)
        False ->
          fmap (: []) <$> importVideoFile filepath (project ^. workingDirectory)
    in  progressBar gui "Import Video" action >>>= \case
          Nothing -> do
            ireturn project
          Just assets -> handleImportResult gui project SVideo assets
  | isSupportedAudioFile filepath
  = progressBar gui
                "Import Video"
                (importAudioFile filepath (project ^. workingDirectory))
    >>>= \case
           Nothing -> ireturn project
           Just asset ->
             handleImportResult gui project SAudio (fmap pure asset)
  | otherwise
  = do
    _ <- dialog
      gui
      "Unsupported File"
      "The file extension of the file you've selected is not supported."
      [Ok]
    ireturn project

handleImportResult
  :: (UserInterface m, IxMonadIO m, Show err)
  => Name n
  -> Project
  -> SMediaType mt
  -> Either err [Asset mt]
  -> Actions m '[n := Remain (State m TimelineMode)] r Project
handleImportResult gui project mediaType result = case (mediaType, result) of
  (_, Left err) -> do
    iliftIO (print err)
    _ <- dialog gui "Import Failed!" (show err) [Ok]
    ireturn project
  (SVideo, Right assets) -> do
    project & library . videoAssets %~ (<> assets) & ireturn
  (SAudio, Right assets) -> do
    project & library . audioAssets %~ (<> assets) & ireturn
