{-# LANGUAGE CPP #-}
{-# LANGUAGE RankNTypes #-}

-- |
-- Module      :  Utils
-- Description :  Utilities for @build-env@.
module Utils
    ( CallProcess(..), callProcessInIO
    , TempDirPermanence(..), withTempDir
    , AbstractQSem(..), qsem, withQSem, noSem
    , exe
    ) where

-- base
import Control.Concurrent.QSem
  ( QSem, newQSem, signalQSem, waitQSem )
import Data.List
  ( intercalate )
import Data.Word
  ( Word8 )
import System.Environment
  ( getEnvironment )
import System.Exit
  ( ExitCode(..) )
import GHC.Stack
  ( HasCallStack )

-- containers
import Data.Map.Strict
  ( Map )
import qualified Data.Map.Strict as Map
  ( alter, fromList, toList )

-- process
import qualified System.Process as Proc

-- temporary
import System.IO.Temp
    ( createTempDirectory
    , getCanonicalTemporaryDirectory
    , withSystemTempDirectory
    )

-- build-env
import Config
  ( Args, TempDirPermanence(..) )

--------------------------------------------------------------------------------

-- | Arguments to 'callProcess'.
data CallProcess
  = CP
  { cwd          :: FilePath
     -- ^ working directory
  , extraPATH    :: [FilePath]
     -- ^ filepaths to add to PATH
  , extraEnvVars :: [(String, String)]
     -- ^ extra environment variables
  , prog         :: FilePath
     -- ^ executable
  , args         :: Args
     -- ^ arguments
  , sem          :: AbstractQSem
     -- ^ lock to take
  }

-- | Run a command inside the specified working directory.
--
-- Crashes if the spawned command returns with nonzero exit code.
callProcessInIO :: HasCallStack => CallProcess -> IO ()
callProcessInIO ( CP { cwd, extraPATH, extraEnvVars, prog, args, sem } ) = do
    env <-
      if null extraPATH && null extraEnvVars
      then return Nothing
      else do env0 <- getEnvironment
              let env1 = Map.fromList $ env0 ++ extraEnvVars
                  env2 = Map.toList $ augmentSearchPath "PATH" extraPATH env1
              return $ Just env2
    let processArgs =
          ( Proc.proc prog args )
            { Proc.cwd = Just cwd
            , Proc.env = env }
    res <- withAbstractQSem sem do
      (_, _, _, ph) <- Proc.createProcess processArgs
      Proc.waitForProcess ph
    case res of
      ExitSuccess -> return ()
      ExitFailure i -> do
        let argsStr
             | null args = ""
             | otherwise = " " ++ unwords args
        error ("command failed with exit code " ++ show i ++ ":\n"
              ++ "  > " ++ prog ++ argsStr )

-- | Add filepaths to the given key in a key/value environment.
augmentSearchPath :: Ord k => k -> [FilePath] -> Map k String -> Map k String
augmentSearchPath _   []    = id
augmentSearchPath var paths = Map.alter f var
  where
    pathsVal = intercalate pATHSeparator paths
    f Nothing  = Just pathsVal
    f (Just p) = Just (p <> pATHSeparator <> pathsVal)

withTempDir :: TempDirPermanence -> String -> (FilePath -> IO a) -> IO a
withTempDir del name k =
  case del of
    DeleteTempDirs
      -> withSystemTempDirectory name k
    Don'tDeleteTempDirs
      -> do root <- getCanonicalTemporaryDirectory
            createTempDirectory root name >>= k

-- | OS-dependent executable file extension.
exe :: String
exe =
#if defined(mingw32_HOST_OS)
  "exe"
#else
  ""
#endif

-- | OS-dependent separator for PATH variable.
pATHSeparator :: String
pATHSeparator =
#if defined(mingw32_HOST_OS)
  ";"
#else
  ":"
#endif

--------------------------------------------------------------------------------
-- Semaphores.

-- | Abstract acquire/release mechanism.
newtype AbstractQSem =
  AbstractQSem { withAbstractQSem :: forall r. IO r -> IO r }

-- | Create an acquire/release mechanism for the given number of tokens.
--
-- An input of @0@ means unrestricted (no semaphore at all).
qsem :: Word8 -> IO AbstractQSem
qsem 0 = return noSem
qsem n = do
  sem <- newQSem (fromIntegral n)
  return $ withQSem sem

-- | Abstract acquire/release mechanism controlled by the given 'QSem'.
withQSem :: QSem -> AbstractQSem
withQSem sem =
  AbstractQSem \ mr -> do
    waitQSem sem
    r <- mr
    signalQSem sem
    return r

-- | No acquire/release mechanism required.
noSem :: AbstractQSem
noSem = AbstractQSem { withAbstractQSem = id }
