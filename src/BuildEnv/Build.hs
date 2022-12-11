{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      :  BuildEnv.Build
-- Description :  Computing, fetching and building plans
--
-- 'computePlan' computes a Cabal plan by generating @pkg.cabal@ and
-- @cabal.project@ files with the given dependencies, constraints, flags...,
-- calling @cabal build --dry-run@ to compute a build plan, and parsing
-- the resulting @plan.json@ file.
--
-- 'fetchPlan' calls @cabal unpack@ to fetch all packages in the given plan.
--
-- 'buildPlan' builds each unit in the build plan from source,
-- using 'buildUnit'. This can be done either asynchronously or sequentially
-- in dependency order, depending on the 'BuildStrategy'.
-- 'buildPlan' can also be used to output a shell script containing
-- build instructions, with the 'Script' 'BuildStrategy'.
module BuildEnv.Build
  ( -- * Computing, fetching and building plans
    computePlan
  , fetchPlan
  , buildPlan

    -- * Generating @pkg.cabal@ and @cabal.project@ files.
  , CabalFilesContents(..)
  , cabalFileContentsFromPackages
  , cabalProjectContentsFromPackages
  ) where

-- base
import Control.Exception
  ( IOException, catch )
import Control.Monad
  ( when )
import Control.Monad.Fix
  ( MonadFix(mfix) )
import Data.Char
  ( isSpace )
import Data.Foldable
  ( for_ )
import Data.Maybe
  ( mapMaybe, maybeToList, isNothing )
import Data.String
  ( IsString )
import Data.Traversable
  ( for )
import Data.Version
  ( Version )

-- async
import Control.Concurrent.Async
  ( async, wait )

-- bytestring
import qualified Data.ByteString.Lazy as Lazy.ByteString
  ( readFile )

-- containers
import qualified Data.Graph as Graph
  ( graphFromEdges', reverseTopSort )
import Data.Map.Strict
  ( Map )
import qualified Data.Map.Strict as Map
import qualified Data.Map.Lazy as Lazy
  ( Map )
import qualified Data.Map.Lazy as Lazy.Map
import Data.Set
  ( Set )
import qualified Data.Set as Set
  ( elems, fromList, toList )

-- directory
import System.Directory
  ( canonicalizePath, createDirectoryIfMissing
  , doesDirectoryExist, removeDirectoryRecursive
  )

-- filepath
import System.FilePath
  ( (</>), (<.>)
  , isAbsolute
  )

-- text
import Data.Text
  ( Text )
import qualified Data.Text    as Text
import qualified Data.Text.IO as Text
  ( appendFile, writeFile )

-- build-env
import BuildEnv.BuildOne
  ( PkgDbDirs(..), getPkgDbDirs, getPkgDir
  , setupPackage, buildUnit )
import BuildEnv.CabalPlan
import qualified BuildEnv.CabalPlan as Configured
  ( ConfiguredUnit(..) )
import BuildEnv.Config
import BuildEnv.Script
  ( BuildScript, runBuildScript, script )
import BuildEnv.Utils
  ( CallProcess(..), callProcessInIO, withTempDir
  , AbstractQSem(..), qsem, noSem )

--------------------------------------------------------------------------------
-- Planning.

-- | The name of the dummy cabal package on which we will call
-- @cabal@ to obtain a build plan.
dummyPackageName :: IsString str => str
dummyPackageName = "build-env-dummy-package"

-- | The 'UnitId' of the (local) dummy package (version 0).
dummyUnitId :: UnitId
dummyUnitId = UnitId $ dummyPackageName <> "-0-inplace"

-- | Query @cabal@ to obtain a build plan for the given packages,
-- by reading the output @plan.json@ of a @cabal build --dry-run@ invocation.
--
-- Use 'generateCabalFilesContents' to generate the @cabal@ file contents
-- from a collection of packages with constraints and flags. See also
-- 'readCabalDotConfig' and 'parseSeedFile' for other ways of obtaining
-- this information.
--
-- Use 'parsePlanBinary' to turn the returned 'CabalPlanBinary' into
-- a 'CabalPlan'.
computePlan :: TempDirPermanence
            -> Verbosity
            -> Compiler
            -> Cabal
            -> CabalFilesContents
            -> IO CabalPlanBinary
computePlan delTemp verbosity comp cabal ( CabalFilesContents { cabalContents, projectContents } ) =
  withTempDir delTemp "build" \ dir -> do
    verboseMsg verbosity $ "Computing plan in build directory " <> Text.pack dir
    Text.writeFile (dir </> "cabal" <.> "project") projectContents
    Text.writeFile (dir </> dummyPackageName <.> "cabal") cabalContents
    let cabalBuildArgs =
          globalCabalArgs cabal ++
            [ "build"
            , "--dry-run"
            , "--with-compiler", ghcPath comp
            , cabalVerbosity verbosity ]
    debugMsg verbosity $
      Text.unlines $ "cabal" : map ( ("  " <>) . Text.pack ) cabalBuildArgs
    callProcessInIO $
      CP { cwd          = dir
         , prog         = cabalPath cabal
         , args         = cabalBuildArgs
         , extraPATH    = []
         , extraEnvVars = []
         , sem          = noSem }

    let planPath = dir </> "dist-newstyle" </> "cache" </> "plan.json"
    CabalPlanBinary <$> Lazy.ByteString.readFile planPath

-- | The contents of a dummy @cabal.project@ file, specifying
-- package constraints, flags and allow-newer.
cabalProjectContentsFromPackages :: FilePath -> UnitSpecs -> PkgSpecs -> AllowNewer -> Text
cabalProjectContentsFromPackages workDir units pins (AllowNewer allowNewer) =
      packages
   <> allowNewers
   <> flagSpecs
   <> constraints
  where

    packages
      | null localPkgs
      = "packages: .\n\n"
      | otherwise
      = Text.intercalate ",\n          "
        ( "packages: ." : map ( Text.pack . makeAbsolute ) ( Map.elems localPkgs ) )
      <> "\n"

    makeAbsolute :: FilePath -> FilePath
    makeAbsolute fp
      | isAbsolute fp
      = fp
      | otherwise
      = workDir </> fp

    isLocal :: (PkgSrc, PkgSpec, Set ComponentName) -> Maybe FilePath
    isLocal ( Local src, _, _ ) = Just src
    isLocal _ = Nothing
    localPkgs = Map.mapMaybe isLocal units

    allPkgs = fmap ( \ ( _, spec, _ ) -> spec ) units
            `unionPkgSpecsOverriding`
              pins
      -- Constraints from the SEED file (units) should override
      -- constraints from the cabal.config file (pins).

    constraints = Text.unlines
        [ Text.unwords ["constraints:", unPkgName nm, cts]
        | (nm, ps) <- Map.assocs allPkgs
        , Constraints cts <- maybeToList $ psConstraints ps
        , not (Text.all isSpace cts)
        ]

    allowNewers
      | null allowNewer
      = ""
      | otherwise
      = Text.unlines $
          "allow-newer:" :
            [ "    " <> p <> ":" <> q <> ","
            | (p,q) <- Set.elems allowNewer ]

    flagSpecs = Text.unlines
        [ Text.unlines
          [ "package " <> unPkgName nm
          , "  flags: " <> showFlagSpec (psFlags ps)
          ]
        | (nm, ps) <- Map.assocs allPkgs
        , let flags = psFlags ps
        , not $ flagSpecIsEmpty flags
        ]

-- | The contents of a dummy Cabal file with dependencies on
-- the specified units (without any constraints).
--
-- The corresponding package Id is 'dummyPackageId'.
cabalFileContentsFromPackages :: UnitSpecs -> Text
cabalFileContentsFromPackages units =
  Text.unlines
    [ "cabal-version: 3.0"
    , "name: " <> dummyPackageName
    , "version: 0"
    , "library" ]
  <> libDepends
  <> exeDepends
  where
    isLib (ComponentName ty lib) = case ty of { Lib -> Just lib; _ -> Nothing }
    isExe (ComponentName ty exe) = case ty of { Exe -> Just exe; _ -> Nothing }
    allLibs = [ (pkg, libsInPkg)
              | (pkg, (_, _, comps)) <- Map.assocs units
              , let libsInPkg = mapMaybe isLib $ Set.toList comps
              , not (null libsInPkg) ]
    allExes = [ (pkg, exesInPkg)
            | (pkg, (_, _, comps)) <- Map.assocs units
            , let exesInPkg = mapMaybe isExe $ Set.toList comps
            , not (null exesInPkg) ]

    dep (PkgName pkg) [comp]
      = pkg <> ":" <> comp
    dep (PkgName pkg) comps
      = pkg <> ":{" <> Text.intercalate "," comps <> "}"

    libDepends
      | null allLibs
      = ""
      | otherwise
      = "\n  build-depends:\n"
          <> Text.intercalate ",\n"
               [ "    " <> dep pkg libs
               | (pkg, libs) <- allLibs ]
      <> "\n"

    exeDepends
      | null allExes
      = ""
      | otherwise
      = "\n  build-tool-depends:\n"
          <> Text.intercalate ",\n"
               [ "    " <> dep pkg exes
               | (pkg, exes) <- allExes ]
      <> "\n"

-- | The file contents of the Cabal files of a Cabal project:
-- @pkg.cabal@ and @cabal.project@.
data CabalFilesContents
  = CabalFilesContents
    { cabalContents   :: Text
      -- ^ The package Cabal file contents.
    , projectContents :: Text
      -- ^ The @cabal.project@ file contents.
    }

--------------------------------------------------------------------------------
-- Fetching.

-- | Fetch the sources of a 'CabalPlan', calling @cabal unpack@ on each
-- package and putting it into the correspondingly named and versioned
-- subfolder of the specified directory (e.g. @pkg-name-1.2.3@).
fetchPlan :: Verbosity
          -> Cabal
          -> FilePath  -- ^ directory in which to put the sources
          -> CabalPlan
          -> IO ()
fetchPlan verbosity cabal fetchDir cabalPlan =
    for_ pkgs \ (pkgNm, pkgVer) -> do
      let nameVersion = pkgNameVersion pkgNm pkgVer
          nmVerStr = Text.unpack nameVersion
      pkgDirExists <- doesDirectoryExist (fetchDir </> nmVerStr)
      if   pkgDirExists
      then normalMsg verbosity $ "NOT fetching " <> nameVersion
      else cabalFetch verbosity cabal fetchDir nmVerStr
  where
    pkgs :: Set (PkgName, Version)
    pkgs = Set.fromList
               -- Some packages might have multiple components;
               -- we don't want to fetch the package itself multiple times.
         $ mapMaybe remotePkgNameVersion
         $ planUnits cabalPlan

    remotePkgNameVersion :: PlanUnit -> Maybe (PkgName, Version)
    remotePkgNameVersion = \case
      PU_Configured ( ConfiguredUnit { puPkgName = nm, puVersion = ver, puPkgSrc = src } )
        | Remote <- src -- only fetch remote packages
        -> Just (nm, ver)
      _ -> Nothing

-- | Call @cabal get@ to fetch a single package from Hackage.
cabalFetch :: Verbosity -> Cabal -> FilePath -> String -> IO ()
cabalFetch verbosity cabal root pkgNmVer = do
    normalMsg verbosity $ "Fetching " <> Text.pack pkgNmVer
    let args = globalCabalArgs cabal ++
                 [ "get"
                 , pkgNmVer
                 , cabalVerbosity verbosity ]
    callProcessInIO $
      CP { cwd          = root
         , prog         = cabalPath cabal
         , args
         , extraPATH    = []
         , extraEnvVars = []
         , sem          = noSem }

--------------------------------------------------------------------------------
-- Building.

-- | Build a 'CabalPlan'. This will install all the packages in the plan
-- by running their @Setup@ scripts. Libraries will be registered
-- into a local package database at @<install-dir>/package.conf@.
--
-- Note: this function will fail if one of the packages has already been
-- registered in the package database.
buildPlan :: Verbosity
          -> Compiler
          -> FilePath    -- ^ fetched sources directory (input)
          -> DestDir Raw -- ^ installation directory structure (output)
          -> BuildStrategy
          -> ( ConfiguredUnit -> UnitArgs )
             -- ^ extra arguments
          -> CabalPlan   -- ^ the build plan to execute
          -> IO ()
buildPlan verbosity comp fetchDir0 destDir0
          buildStrat
          userUnitArgs
          cabalPlan
  = do
    fetchDir <- canonicalizePath fetchDir0
    dest@( DestDir { installDir, prefix, destDir } )
      <- canonicalizeDestDir destDir0
    createDirectoryIfMissing True installDir

    -- Create the package database directories (if they don't already exist).
    -- See Note [Using two package databases] in BuildOne.
    pkgDbDirs@( PkgDbDirs { tempPkgDbDir, finalPkgDbDir } ) <-
      getPkgDbDirs fetchDir installDir
    tempPkgDbExists <- doesDirectoryExist tempPkgDbDir
    when tempPkgDbExists $
     removeDirectoryRecursive tempPkgDbDir
       `catch` \ ( _ :: IOException ) -> return ()
    mapM_ (createDirectoryIfMissing True) [ tempPkgDbDir, finalPkgDbDir ]

    normalMsg verbosity $ "\nPreparing packages for build"
    verboseMsg verbosity $
      Text.unlines [ "Directory structure:"
                   , "      prefix: " <> Text.pack prefix
                   , "     destDir: " <> Text.pack destDir
                   , "  installDir: " <> Text.pack installDir ]
    debugMsg verbosity $ "Packages:\n" <>
      Text.unlines
        [ "  - " <> pkgNameVersion nm ver
        | (nm, ver) <- Map.keys pkgMap ]
    debugMsg verbosity $ "Units:\n" <>
      Text.unlines
        [ "  - " <> pkgNm <> ":" <> cabalComponent compName
        | ( ConfiguredUnit
            { puPkgName = PkgName pkgNm
            , puComponentName = compName }
          , _ ) <- unitsToBuild
        ]

    let unitSetupScript :: ConfiguredUnit -> IO BuildScript
        unitSetupScript pu@(ConfiguredUnit { puSetupDepends }) = do
          let pkgDir = getPkgDir fetchDir pu
          setupPackage verbosity comp pkgDbDirs pkgDir puSetupDepends
        unitBuildScript :: ConfiguredUnit -> BuildScript
        unitBuildScript pu =
          let pkgDir = getPkgDir fetchDir pu
          in buildUnit verbosity comp pkgDbDirs pkgDir dest
                (userUnitArgs pu)
                depMap pu

    case buildStrat of
      Async n -> do
        let j :: Text
            j = "-j" <> case n of { 0 -> "" ; _ -> Text.pack (show n) }
        normalMsg verbosity $
          "\nBuilding and installing units asynchronously with " <> j

        AbstractQSem { withAbstractQSem } <- qsem n
        (_, unitAsyncs) <- mfix \ ~(pkgAsyncs, unitAsyncs) -> do

          let -- Compile the Setup script of the package the unit belongs to.
              -- (This should happen only once per package.)
              doPkgSetupAsync :: ConfiguredUnit -> IO ()
              doPkgSetupAsync cu@( ConfiguredUnit { puSetupDepends } ) = do

                -- Wait for the @setup-depends@ units.
                for_ puSetupDepends \ setupDepId ->
                  for_ (unitAsyncs Map.!? setupDepId) wait

                -- Setup the package.
                withAbstractQSem do
                  setupScript <- unitSetupScript cu
                  runBuildScript setupScript

              -- Configure, build and install the unit.
              doUnitAsync :: ( ConfiguredUnit, Maybe UnitId ) -> IO ()
              doUnitAsync ( pu, _didSetup ) = do

                let nm  = Configured.puPkgName pu
                    ver = Configured.puVersion pu

                -- Wait for the package to have been setup.
                wait $ pkgAsyncs Map.! (nm, ver)

                -- Wait until we have built the units we depend on.
                for_ (unitDepends pu) \ depUnitId ->
                  for_ (unitAsyncs Map.!? depUnitId) wait

                -- Build the unit!
                withAbstractQSem $
                  runBuildScript $ unitBuildScript pu

          -- Kick off setting up the packages...
          finalPkgAsyncs  <- for pkgMap  (async . doPkgSetupAsync)
          -- ... and building the units.
          finalUnitAsyncs <- for unitMap (async . doUnitAsync)
          return (finalPkgAsyncs, finalUnitAsyncs)
        mapM_ wait unitAsyncs

      TopoSort -> do
        normalMsg verbosity "\nBuilding and installing units sequentially.\n\
                            \NB: pass -j<N> for increased parallelism."
        for_ unitsToBuild \ ( cu, didSetup ) -> do
          when (isNothing didSetup) $
            unitSetupScript cu >>= runBuildScript
          runBuildScript (unitBuildScript cu)

      Script fp -> do
        normalMsg verbosity $ "\nWriting build scripts to " <> Text.pack fp
        allScripts <- for unitsToBuild \ ( cu, didSetup ) -> do
          mbSetup <- if   isNothing didSetup
                     then unitSetupScript cu
                     else return []
          let build = unitBuildScript cu
          return $ mbSetup ++ build
        Text.appendFile fp $ script $ concat allScripts

  where

    pkgMap :: Map (PkgName, Version) ConfiguredUnit
    pkgMap = Lazy.Map.fromList
      [ ((puPkgName, puVersion), cu)
      | ( cu@( ConfiguredUnit { puPkgName, puVersion } ), didSetup ) <- unitsToBuild
      , isNothing didSetup ]

    -- Units to build, in dependency order.
    unitsToBuild :: [(ConfiguredUnit, Maybe UnitId)]
    unitsToBuild
      = tagUnits $ sortPlan cabalPlan

    unitMap :: Lazy.Map UnitId (ConfiguredUnit, Maybe UnitId)
    unitMap = Lazy.Map.fromList
              [ (puId, pu)
              | pu@( ConfiguredUnit { puId }, _ ) <- unitsToBuild ]

    depMap :: Map UnitId PlanUnit
    depMap = Map.fromList
              [ (planUnitUnitId pu, pu)
              | pu <- planUnits cabalPlan ]


-- | Sort the units in a 'CabalPlan' in dependency order.
sortPlan :: CabalPlan -> [ConfiguredUnit]
sortPlan plan =
    map (fst3 . lookupVertex) $ Graph.reverseTopSort gr
  where
    fst3 :: (a,b,c) -> a
    fst3 (a,_,_) = a
    (gr, lookupVertex) = Graph.graphFromEdges'
       [ (pu, puId, allDepends pu)
       | PU_Configured pu@(ConfiguredUnit { puId }) <- planUnits plan
       ]

-- | Tag units in a build plan: the first unit we compile in each package
-- is tagged (with @'Nothing'@) as having the responsibility to build
-- the Setup executable for the package it belongs to, while other units
-- in this same package are tagged with @'Just' uid@, where @uid@ is the unit
-- which is responsible for building the Setup executable.
tagUnits :: [ConfiguredUnit] -> [(ConfiguredUnit, Maybe UnitId)]
tagUnits = go Map.empty
  where
    go _ [] = []
    go seenPkgs ( cu@( ConfiguredUnit { puId } ):cus)
      | puId == dummyUnitId
      = go seenPkgs cus
      | let nm  = Configured.puPkgName cu
            ver = Configured.puVersion cu
      , ( mbUnit, newPkgs ) <- Map.insertLookupWithKey (\_ a _ -> a) (nm,ver) puId seenPkgs
      = (cu, mbUnit) : go newPkgs cus