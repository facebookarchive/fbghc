
-- | Linking Haskell units
module GHC.Linker.Unit
   ( collectLinkOpts
   , collectArchives
   , getUnitLinkOpts
   , getLibs
   )
where

import GHC.Prelude
import GHC.Platform.Ways
import GHC.Unit.Types
import GHC.Unit.Info
import GHC.Unit.State
import GHC.Unit.Env
import GHC.Utils.Misc

import qualified GHC.Data.ShortText as ST

import GHC.Driver.Session

import Control.Monad
import System.Directory
import System.FilePath

-- | Find all the link options in these and the preload packages,
-- returning (package hs lib options, extra library options, other flags)
getUnitLinkOpts :: DynFlags -> UnitEnv -> [UnitId] -> IO ([String], [String], [String])
getUnitLinkOpts dflags unit_env pkgs = do
    ps <- mayThrowUnitErr $ preloadUnitsInfo' unit_env pkgs
    return (collectLinkOpts dflags ps)

collectLinkOpts :: DynFlags -> [UnitInfo] -> ([String], [String], [String])
collectLinkOpts dflags ps =
    (
        concatMap (map ("-l" ++) . unitHsLibs (ghcNameVersion dflags) (ways dflags)) ps,
        reorderLibs $ concatMap (map ("-l" ++) . map ST.unpack . unitExtDepLibsSys) ps,
        concatMap (map ST.unpack . unitLinkerOptions) ps
    )

reorderLibs :: [String] -> [String]
reorderLibs opts
  -- There is a bug in glibc < 2.34 which occurs when passing -lc before -lpthread.
  -- See https://sourceware.org/bugzilla/show_bug.cgi?id=15648
  --
  -- This usually manifests with the error:
  --   lowlevellock.c:28:0: error:
  --   multiple definitions of `___lll_lock_wait_private'
  | let (before, after) = break (== libc) opts
  , not (pthread `elem` before)
  , pthread `elem` after
  = before ++ pthread_and_deps ++ after
  | otherwise
  = opts
  where
    libc = "-lc"
    pthread = "-lpthread"
    rt = "-lrt"
    pthread_and_deps = [ rt, pthread ]

collectArchives :: DynFlags -> UnitInfo -> IO [FilePath]
collectArchives dflags pc =
  filterM doesFileExist [ searchPath </> ("lib" ++ lib ++ ".a")
                        | searchPath <- searchPaths
                        , lib <- libs ]
  where searchPaths = ordNub . filter notNull . libraryDirsForWay (ways dflags) $ pc
        libs        = unitHsLibs (ghcNameVersion dflags) (ways dflags) pc ++ map ST.unpack (unitExtDepLibsSys pc)

-- | Either the 'unitLibraryDirs' or 'unitLibraryDynDirs' as appropriate for the way.
libraryDirsForWay :: Ways -> UnitInfo -> [String]
libraryDirsForWay ws
  | WayDyn `elem` ws = map ST.unpack . unitLibraryDynDirs
  | otherwise        = map ST.unpack . unitLibraryDirs

getLibs :: DynFlags -> UnitEnv -> [UnitId] -> IO [(String,String)]
getLibs dflags unit_env pkgs = do
  ps <- mayThrowUnitErr $ preloadUnitsInfo' unit_env pkgs
  fmap concat . forM ps $ \p -> do
    let candidates = [ (l </> f, f) | l <- collectLibraryDirs (ways dflags) [p]
                                    , f <- (\n -> "lib" ++ n ++ ".a") <$> unitHsLibs (ghcNameVersion dflags) (ways dflags) p ]
    filterM (doesFileExist . fst) candidates

