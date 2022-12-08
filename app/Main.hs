module Main ( main ) where

-- base
import Data.Foldable
  ( for_ )

-- bytestring
import qualified Data.ByteString.Lazy as Lazy.ByteString
  ( readFile, writeFile )

-- containers
import qualified Data.Map as Map
  ( empty )
import qualified Data.Set as Set
  ( empty )

-- directory
import System.Directory
  ( canonicalizePath, createDirectoryIfMissing
  , doesDirectoryExist )

-- build-env
import Build
import CabalPlan
import Config
import File
  ( parseCabalDotConfigPkgs, parseSeedFile )
import Options
import Parse
  ( runOptionsParser )

--------------------------------------------------------------------------------

main :: IO ()
main = do
  Opts { compiler, cabal, mode, verbosity, delTemp } <- runOptionsParser
  case mode of
    PlanMode { planModeInputs, planOutput } -> do
      CabalPlanBinary planBinary <-
        computePlanFromInputs delTemp verbosity compiler cabal planModeInputs
      normalMsg verbosity $
        "Writing build plan to '" <> planOutput <> "'"
      Lazy.ByteString.writeFile planOutput planBinary
    FetchMode ( FetchDescription { fetchDir, fetchInputPlan } ) newOrUpd -> do
      plan <- getPlan delTemp verbosity compiler cabal fetchInputPlan
      doFetch verbosity cabal fetchDir True newOrUpd plan
    BuildMode ( Build { buildFetchDescr = FetchDescription { fetchDir, fetchInputPlan }
                      , buildFetch, buildStrategy, buildDestDir
                      , configureArgs, ghcPkgArgs } ) -> do
      plan <- getPlan delTemp verbosity compiler cabal fetchInputPlan
      case buildFetch of
        Prefetched     -> return ()
        Fetch newOrUpd -> doFetch verbosity cabal fetchDir False newOrUpd plan
      case buildStrategy of
        Script fp -> normalMsg verbosity $ "Writing build script to " <> fp
        _         -> normalMsg verbosity "Building and registering packages"
      buildPlan verbosity compiler fetchDir buildDestDir buildStrategy
        configureArgs ghcPkgArgs
        plan

-- | Generate the contents of @pkg.cabal@ and @cabal.project@ files, using
--
--  - a seed file containing packages to build (with constraints, flags
--    and allow-newer),
--  - a @cabal.config@ freeze file,
--  - explicit packages and allow-newer specified as command-line arguments.
parsePlanInputs :: Verbosity -> PlanInputs -> IO CabalFilesContents
parsePlanInputs verbosity (PlanInputs { planPins, planPkgs, planAllowNewer })
  = do (pkgs, fileAllowNewer) <- parsePlanPackages verbosity planPkgs
       let
         allAllowNewer = fileAllowNewer <> planAllowNewer
           -- NB: allow-newer specified in the command-line overrides
           -- the allow-newer included in the seed file.
         cabalContents = cabalFileContentsFromPackages pkgs
       projectContents <-
         case planPins of
           Nothing -> return $ cabalProjectContentsFromPackages pkgs Map.empty allAllowNewer
           Just (FromFile pinCabalConfig) -> do
             normalMsg verbosity $
               "Reading 'cabal.config' file at '" <> pinCabalConfig <> "'"
             pins <- parseCabalDotConfigPkgs pinCabalConfig
             return $ cabalProjectContentsFromPackages pkgs pins allAllowNewer
           Just (Explicit pins) -> do
             return $ cabalProjectContentsFromPackages pkgs pins allAllowNewer
       return $ CabalFilesContents { cabalContents, projectContents }

-- | Retrieve the seed packages we want to build, either from a seed file
-- or from explicit command line arguments.
parsePlanPackages :: Verbosity -> PackageData UnitSpecs -> IO (UnitSpecs, AllowNewer)
parsePlanPackages _ (Explicit units) = return (units, AllowNewer Set.empty)
parsePlanPackages verbosity (FromFile fp) =
  do normalMsg verbosity $
       "Reading seed packages from '" <> fp <> "'"
     parseSeedFile fp

-- | Compute a build plan by calling @cabal build --dry-run@ with the generated
-- @pkg.cabal@ and @cabal.project@ files.
computePlanFromInputs :: TempDirPermanence
                      -> Verbosity
                      -> Compiler
                      -> Cabal
                      -> PlanInputs
                      -> IO CabalPlanBinary
computePlanFromInputs delTemp verbosity comp cabal inputs
    = do cabalFileContents <- parsePlanInputs verbosity inputs
         normalMsg verbosity "Computing build plan"
         computePlan delTemp verbosity comp cabal cabalFileContents

-- | Retrieve a cabal build plan, either by computing it or using
-- a pre-existing @plan.json@ file.
getPlan :: TempDirPermanence -> Verbosity -> Compiler -> Cabal -> Plan -> IO CabalPlan
getPlan delTemp verbosity comp cabal planMode = do
   planBinary <-
     case planMode of
       ComputePlan planInputs mbPlanOutputPath -> do
        plan@(CabalPlanBinary planData) <-
          computePlanFromInputs delTemp verbosity comp cabal planInputs
        for_ mbPlanOutputPath \ planOutputPath ->
          Lazy.ByteString.writeFile planOutputPath planData
        return plan
       UsePlan { planJSONPath } ->
         do
           normalMsg verbosity $
             "Reading build plan from '" <> planJSONPath <> "'"
           CabalPlanBinary <$> Lazy.ByteString.readFile planJSONPath
   return $ parsePlanBinary planBinary

-- | Fetch all packages in a cabal build plan.
doFetch :: Verbosity
        -> Cabal
        -> FilePath
        -> Bool -- ^ True <=> we are fetching (not building)
                -- (only relevant for error messages)
        -> NewOrExisting
        -> CabalPlan
        -> IO ()
doFetch verbosity cabal fetchDir0 weAreFetching newOrUpd plan = do
  fetchDir       <- canonicalizePath fetchDir0
  fetchDirExists <- doesDirectoryExist fetchDir
  case newOrUpd of
    New | fetchDirExists ->
      error $ unlines $
       "Fetch directory already exists." : existsMsg
          ++ [ "Fetch directory: " <> fetchDir  ]
    Existing | not fetchDirExists ->
      error $ unlines
        [ "Fetch directory must already exist when using --update."
        , "Fetch directory: " <> fetchDir ]
    _ -> return ()
  createDirectoryIfMissing True fetchDir
  normalMsg verbosity $
    "Fetching sources from build plan into directory '" <> fetchDir <> "'"
  fetchPlan verbosity cabal fetchDir plan

  where
    existsMsg
      | weAreFetching
      = [ "Use --update to update an existing directory." ]
      | otherwise
      = [ "Use --prefetched to build using a prefetched source directory,"
        , "or --update to continue fetching before building." ]
