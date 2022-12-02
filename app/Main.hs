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
        computePlanFromInputs delTemp verbosity cabal planModeInputs
      normalMsg verbosity $
        "Writing build plan to '" <> planOutput <> "'"
      BSL.writeFile planOutput planBinary
    FetchMode ( FetchDescription { fetchDir, fetchInputPlan } ) newOrUpd -> do
      plan <- getPlan delTemp verbosity cabal fetchInputPlan
      doFetch verbosity cabal fetchDir newOrUpd plan
    BuildMode ( Build { buildFetchDescr = FetchDescription { fetchDir, fetchInputPlan }
                      , buildFetch, buildStrategy, buildDestDir
                      , configureArgs, ghcPkgArgs } ) -> do
      plan <- getPlan delTemp verbosity cabal fetchInputPlan
      case buildFetch of
        Prefetched     -> return ()
        Fetch newOrUpd -> doFetch verbosity cabal fetchDir newOrUpd plan
      normalMsg verbosity "Building and registering packages"
      buildPlan delTemp verbosity compiler fetchDir buildDestDir buildStrategy
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
         cabalContents = cabalFileContentsFromPackages (Map.keys pkgs)
       projectContents <-
         case planPins of
           Nothing -> return $ cabalProjectContentsFromPackages pkgs allAllowNewer
           Just (FromFile pinCabalConfig) -> do
             normalMsg verbosity $
               "Reading 'cabal.config' file at '" <> pinCabalConfig <> "'"
             pins <- parseCabalDotConfigPkgs pinCabalConfig
             return $
               cabalProjectContentsFromPackages
                 (pkgs `unionPkgSpecs` pins)
                   -- NB: unionPkgsSpecs is left-biased: constraints from the
                   -- SEED file override constraints from the cabal.config file.
                 allAllowNewer
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
computePlanFromInputs :: TempDirPermanence
                      -> Verbosity
                      -> Cabal
                      -> PlanInputs
                      -> IO CabalPlanBinary
computePlanFromInputs delTemp verbosity cabal inputs
    = do cabalFileContents <- parsePlanInputs verbosity inputs
         normalMsg verbosity "Computing build plan"
         computePlan delTemp verbosity cabal cabalFileContents

-- | Retrieve a cabal build plan, either by computing it or using
-- a pre-existing @plan.json@ file.
getPlan :: TempDirPermanence -> Verbosity -> Cabal -> Plan -> IO CabalPlan
getPlan delTemp verbosity cabal planMode = do
   planBinary <-
     case planMode of
       ComputePlan planInputs   ->
        computePlanFromInputs delTemp verbosity cabal planInputs
       UsePlan { planJSONPath } ->
         do
           normalMsg verbosity $
             "Reading build plan from '" <> planJSONPath <> "'"
           CabalPlanBinary <$> BSL.readFile planJSONPath
   return $ parsePlanBinary planBinary

-- | Fetch all packages in a cabal build plan.
doFetch :: Verbosity -> Cabal -> FilePath -> NewOrUpdate -> CabalPlan -> IO ()
doFetch verbosity cabal fetchDir newOrUpd plan = do
  normalMsg verbosity $
    "Fetching sources from build plan into directory '" <> fetchDir <> "'"
  fetchPlan verbosity cabal fetchDir newOrUpd plan
