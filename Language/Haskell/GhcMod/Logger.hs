module Language.Haskell.GhcMod.Logger (
    withLogger
  , withLogger'
  , checkErrorPrefix
  , errsToStr
  , errBagToStrList
  ) where

import Control.Arrow
import Control.Applicative
import Data.List (isPrefixOf)
import qualified Data.Map as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Control.Monad.Reader (Reader, asks, runReader)
import Data.IORef (IORef, newIORef, readIORef, writeIORef, modifyIORef)
import System.FilePath (normalise, makeRelative)
import Text.PrettyPrint

import ErrUtils (ErrMsg, errMsgShortDoc, errMsgExtraInfo)
import GHC (DynFlags, SrcSpan, Severity(SevError))
import HscTypes
import Outputable
import qualified GHC as G
import Bag

import Language.Haskell.GhcMod.Convert
import Language.Haskell.GhcMod.Doc (showPage)
import Language.Haskell.GhcMod.DynFlags (withDynFlags)
import Language.Haskell.GhcMod.Monad.Types
import Language.Haskell.GhcMod.Error
import Language.Haskell.GhcMod.Types
import qualified Language.Haskell.GhcMod.Gap as Gap
import Prelude

type Builder = [String] -> [String]

data Log = Log [String] Builder

newtype LogRef = LogRef (IORef Log)

data GmPprEnv = GmPprEnv { rsDynFlags :: DynFlags
                         , rsPprStyle :: PprStyle
                         , rsMapFile :: FilePath -> FilePath
                         }

type GmPprEnvM a = Reader GmPprEnv a

emptyLog :: Log
emptyLog = Log [] id

newLogRef :: IO LogRef
newLogRef = LogRef <$> newIORef emptyLog

readAndClearLogRef :: LogRef -> IO [String]
readAndClearLogRef (LogRef ref) = do
    Log _ b <- readIORef ref
    writeIORef ref emptyLog
    return $ b []

appendLogRef :: GmPprEnv -> DynFlags -> LogRef -> DynFlags -> Severity -> SrcSpan -> PprStyle -> SDoc -> IO ()
appendLogRef rs df (LogRef ref) _ sev src st msg = modifyIORef ref update
  where
    l = runReader (ppMsg src sev msg) rs{rsDynFlags=df, rsPprStyle=st}
    update lg@(Log ls b)
      | l `elem` ls = lg
      | otherwise   = Log (l:ls) (b . (l:))

----------------------------------------------------------------

-- | Set the session flag (e.g. "-Wall" or "-w:") then
--   executes a body. Logged messages are returned as 'String'.
--   Right is success and Left is failure.
withLogger :: (GmGhc m, GmEnv m, GmState m)
           => (DynFlags -> DynFlags)
           -> m a
           -> m (Either String (String, a))
withLogger f action = do
  env <- G.getSession
  opts <- options
  let conv = convert opts
  eres <- withLogger' env $ \setDf ->
      withDynFlags (f . setDf) action
  return $ either (Left . conv) (Right . first conv) eres

withLogger' :: (IOish m, GmState m, GmEnv m)
    => HscEnv -> ((DynFlags -> DynFlags) -> m a) -> m (Either [String] ([String], a))
withLogger' env action = do
    logref <- liftIO $ newLogRef

    rfm <- do
      mm <- Map.toList <$> getMMappedFiles
      let
          mf :: FilePath -> FileMapping -> Maybe (FilePath, FilePath)
          mf from (RedirectedMapping to)
                 = Just (to, from)
          mf _ _ = Nothing
      return $ Map.fromList $ mapMaybe (uncurry mf) mm

    crdl <- cradle

    let dflags = hsc_dflags env
        pu = icPrintUnqual dflags (hsc_IC env)
        stl = mkUserStyle pu AllTheWay
        st = GmPprEnv {
                rsDynFlags = dflags
              , rsPprStyle = stl
              , rsMapFile = \key ->
                              fromMaybe key
                              $ makeRelative (cradleRootDir crdl)
                              <$> Map.lookup key rfm
        }

        setLogger df = Gap.setLogAction df $ appendLogRef st df logref
        handlers = [
            GHandler $ \ex -> return $ Left $ runReader (sourceError ex) st,
            GHandler $ \ex -> return $ Left [render $ ghcExceptionDoc ex]
         ]

    a <- gcatches (Right <$> action setLogger) handlers
    ls <- liftIO $ readAndClearLogRef logref

    return ((,) ls <$> a)

errBagToStrList :: HscEnv -> Bag ErrMsg -> [String]
errBagToStrList env errs = let
    dflags = hsc_dflags env
    pu = icPrintUnqual dflags (hsc_IC env)
    st = mkUserStyle pu AllTheWay
 in runReader (errsToStr (bagToList errs)) GmPprEnv{rsDynFlags=dflags, rsPprStyle=st}

----------------------------------------------------------------

-- | Converting 'SourceError' to 'String'.
sourceError :: SourceError -> GmPprEnvM [String]
sourceError = errsToStr . reverse . bagToList . srcErrorMessages

errsToStr :: [ErrMsg] -> GmPprEnvM [String]
errsToStr = mapM ppErrMsg

----------------------------------------------------------------

ppErrMsg :: ErrMsg -> GmPprEnvM String
ppErrMsg err = do
    dflag <- asks rsDynFlags
    st <- asks rsPprStyle
    let ext = showPage dflag st (errMsgExtraInfo err)
    m <- ppMsg spn SevError msg
    return $ m ++ (if null ext then "" else "\n" ++ ext)
   where
     spn = Gap.errorMsgSpan err
     msg = errMsgShortDoc err

ppMsg :: SrcSpan -> Severity-> SDoc -> GmPprEnvM String
ppMsg spn sev msg = do
  dflag <- asks rsDynFlags
  st <- asks rsPprStyle
  let cts  = showPage dflag st msg
  prefix <- ppMsgPrefix spn sev cts
  return $ prefix ++ cts

ppMsgPrefix :: SrcSpan -> Severity -> String -> GmPprEnvM String
ppMsgPrefix spn sev cts = do
  dflag <- asks rsDynFlags
  mr <- asks rsMapFile
  let defaultPrefix
        | Gap.isDumpSplices dflag = ""
        | otherwise               = checkErrorPrefix
  return $ fromMaybe defaultPrefix $ do
    (line,col,_,_) <- Gap.getSrcSpan spn
    file <- mr <$> normalise <$> Gap.getSrcFile spn
    let severityCaption = Gap.showSeverityCaption sev
        pref0 | or (map (\x -> x `isPrefixOf` cts) warningAsErrorPrefixes)
                          = file ++ ":" ++ show line ++ ":" ++ show col ++ ":"
              | otherwise = file ++ ":" ++ show line ++ ":" ++ show col ++ ":" ++ severityCaption
    return pref0

checkErrorPrefix :: String
checkErrorPrefix = "Dummy:0:0:Error:"

warningAsErrorPrefixes :: [String]
warningAsErrorPrefixes = ["Couldn't match expected type"
                         , "Couldn't match type"
                         , "No instance for"]
