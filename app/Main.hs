module Main ( main ) where

-- bytestring
import qualified Data.ByteString.Lazy as BSL
  ( readFile, writeFile )

-- containers
import qualified Data.Map as Map
  ( keys, union )

-- build-env
import Build
import CabalPlan
import Config
  ( Cabal, Verbosity, normalMsg )
import File
  ( readCabalDotConfig, parseSeedFile )
import Options
import Parse
  ( runOptionsParser )

--------------------------------------------------------------------------------

main :: IO ()
main = do
  Opts { compiler, cabal, mode, verbosity } <- runOptionsParser
  case mode of
    PlanMode { planModeInputs, planOutput } -> do
      CabalPlanBinary planBinary <-
        computePlanFromInputs verbosity cabal planModeInputs
      normalMsg verbosity $
        "Writing build plan to '" <> planOutput <> "'"
      BSL.writeFile planOutput planBinary
    FetchMode ( FetchDescription { fetchDir, fetchInputPlan } ) -> do
      plan <- getPlan verbosity cabal fetchInputPlan
      doFetch verbosity cabal fetchDir plan
    BuildMode ( Build { buildFetchDescr = FetchDescription { fetchDir, fetchInputPlan }
                      , buildFetch, buildStrategy, buildOutputDir } ) -> do
      plan <- getPlan verbosity cabal fetchInputPlan
      case buildFetch of
        Prefetched -> return ()
        Fetch      -> doFetch verbosity cabal fetchDir plan
      normalMsg verbosity $
        "Building and registering packages in directory '" <> buildOutputDir <> "'"
      buildPlan verbosity compiler fetchDir buildOutputDir buildStrategy plan

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
         cabalContents = cabalFileContentsFromPackages (Map.keys pkgs)
       projectContents <-
         case planPins of
           Nothing -> return $ cabalProjectContentsFromPackages pkgs allAllowNewer
           Just (FromFile pinCabalConfig) -> do
             normalMsg verbosity $
               "Reading 'cabal.config' file at '" <> pinCabalConfig <> "'"
             pins <- readCabalDotConfig pinCabalConfig
             return $
               cabalProjectContentsFromPackages pkgs allAllowNewer <> pins
               -- A @cabal.config@ file uses valid @cabal.project@ syntax,
               -- so we can directly append it to the generated @cabal.project@.
           Just (Explicit pinnedPkgs) -> do
             let allPkgs = pkgs `Map.union` pinnedPkgs
             return $ cabalProjectContentsFromPackages allPkgs allAllowNewer
       return $ CabalFilesContents { cabalContents, projectContents }

-- | Retrieve the seed packages we want to build, either from a seed file
-- or from explicit command line arguments.
parsePlanPackages :: Verbosity -> PackageData -> IO (PkgSpecs, AllowNewer)
parsePlanPackages _ (Explicit pkgs) = return (pkgs, AllowNewer [])
parsePlanPackages verbosity (FromFile fp) =
  do normalMsg verbosity $
       "Reading seed packages from '" <> fp <> "'"
     parseSeedFile fp

-- | Compute a build plan by calling @cabal build --dry-run@ with the generated
-- @pkg.cabal@ and @cabal.project@ files.
computePlanFromInputs :: Verbosity -> Cabal -> PlanInputs -> IO CabalPlanBinary
computePlanFromInputs verbosity cabal inputs
    = do cabalFileContents <- parsePlanInputs verbosity inputs
         normalMsg verbosity "Computing build plan"
         computePlan verbosity cabal cabalFileContents

-- | Retrieve a cabal build plan, either by computing it or using
-- a pre-existing @plan.json@ file.
getPlan :: Verbosity -> Cabal -> Plan -> IO CabalPlan
getPlan verbosity cabal planMode = do
   planBinary <-
     case planMode of
       ComputePlan planInputs   ->
        computePlanFromInputs verbosity cabal planInputs
       UsePlan { planJSONPath } ->
         do
           normalMsg verbosity $
             "Reading build plan from '" <> planJSONPath <> "'"
           CabalPlanBinary <$> BSL.readFile planJSONPath
   return $ parsePlanBinary planBinary

-- | Fetch all packages in a cabal build plan.
doFetch :: Verbosity -> Cabal -> FilePath -> CabalPlan -> IO ()
doFetch verbosity cabal fetchDir plan = do
  normalMsg verbosity $
    "Fetching sources from build plan into directory '" <> fetchDir <> "'"
  fetchPlan verbosity cabal fetchDir plan
