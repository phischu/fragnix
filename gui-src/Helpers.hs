module Helpers where

import Fragnix.Declaration (
    writeDeclarations)
import Fragnix.Slice (
    writeSliceDefault, SliceID)
import Fragnix.Environment (
    loadEnvironment,persistEnvironment,
    environmentPath,builtinEnvironmentPath)
import Fragnix.SliceSymbols (
    updateEnvironment,findMainSliceIDs)
import Fragnix.ModuleDeclarations (
    parse, moduleDeclarationsWithEnvironment,
    moduleSymbols)
import Fragnix.DeclarationLocalSlices (
    declarationLocalSlices)
import Fragnix.HashLocalSlices (
    hashLocalSlices)
import Fragnix.SliceSymbols (
    lookupLocalIDs)
import Fragnix.SliceCompiler (
    writeSliceModules, invokeGHCMain)

-- import Language.Haskell.Names (ppError)

import System.Clock (
    getTime, Clock(Monotonic), toNanoSecs, diffTimeSpec)
import qualified Data.Map as Map (union)

import Data.Foldable (for_)
import Control.Monad (forM)
import System.Environment (getArgs)
import Text.Printf (printf)


-- | Take a list of module paths and compile them into slices
slice :: [FilePath] -> IO ()
slice modulePaths = do
  putStrLn "Loading environment ..."

  environment <- timeIt (do
      builtinEnvironment <- loadEnvironment builtinEnvironmentPath
      userEnvironment <- loadEnvironment environmentPath
      return (Map.union builtinEnvironment userEnvironment))

  putStrLn "Parsing modules ..."

  modules <- timeIt (forM modulePaths parse)

  putStrLn "Extracting declarations ..."

  let declarations = moduleDeclarationsWithEnvironment environment modules
  timeIt (writeDeclarations "fragnix/temp/declarations/declarations.json" declarations)

  putStrLn "Slicing ..."

  let (localSlices, symbolLocalIDs) = declarationLocalSlices declarations
  let (localSliceIDMap, slices) = hashLocalSlices localSlices
  let symbolSliceIDs = lookupLocalIDs symbolLocalIDs localSliceIDMap
  timeIt (for_ slices writeSliceDefault)

  putStrLn "Updating environment ..."

  let updatedEnvironment = updateEnvironment symbolSliceIDs (moduleSymbols environment modules)
  timeIt (persistEnvironment environmentPath updatedEnvironment)

-- | Take a SliceID and compile it into an executable
compile :: SliceID -> IO ()
compile mainSliceID = do
  putStrLn ("Compiling " ++ show mainSliceID)
  putStrLn ("Generating compilation units...")
  timeIt (writeSliceModules mainSliceID)
  putStrLn ("Invoking GHC")
  _ <- timeIt (invokeGHCMain mainSliceID)
  return ()


-- | Execute the given action and print the time it took.
timeIt :: IO a -> IO a
timeIt action = do
    timeBefore <- getTime Monotonic
    result <- action
    timeAfter <- getTime Monotonic
    let timeDifference = fromIntegral (toNanoSecs (diffTimeSpec timeBefore timeAfter)) * 1e-9 :: Double
    printf "Took %6.2fs\n" timeDifference
    return result