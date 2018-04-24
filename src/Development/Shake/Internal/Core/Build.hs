{-# LANGUAGE RecordWildCards, PatternGuards, ScopedTypeVariables, NamedFieldPuns, GADTs #-}
{-# LANGUAGE Rank2Types, ConstraintKinds #-}

module Development.Shake.Internal.Core.Build(
    getDatabaseValue,
    apply, apply1,
    ) where

import Development.Shake.Classes
import Development.Shake.Internal.Core.Pool
import Development.Shake.Internal.Value
import Development.Shake.Internal.Errors
import Development.Shake.Internal.Core.Types
import Development.Shake.Internal.Core.Action
import Development.Shake.Internal.Options
import Development.Shake.Internal.Core.Monad
import Development.Shake.Internal.Core.History() -- FIXME: Enable soon
import Development.Shake.Internal.Core.Wait3
import qualified Data.ByteString.Char8 as BS
import Control.Monad.IO.Class
import General.Extra
import qualified General.Intern as Intern
import General.Intern(Id)

import Control.Applicative
import Control.Exception
import Control.Monad.Extra
import Numeric.Extra
import qualified Data.HashMap.Strict as Map
import qualified General.Ids as Ids
import Development.Shake.Internal.Core.Rules
import Data.Typeable.Extra
import Data.IORef.Extra
import Data.Maybe
import Data.List.Extra
import Data.Tuple.Extra
import Data.Either.Extra
import System.Time.Extra
import Prelude


---------------------------------------------------------------------
-- LOW-LEVEL OPERATIONS ON THE DATABASE

getKeyId :: Database -> Key -> Locked Id
getKeyId Database{..} k = do
    is <- liftIO $ readIORef intern
    case Intern.lookup k is of
        Just i -> return i
        Nothing -> do
            (is, i) <- return $ Intern.add k is
            -- make sure to write it into Status first to maintain Database invariants
            liftIO $ Ids.insert status i (k,Missing)
            liftIO $ writeIORef' intern is
            return i

getIdKeyStatus :: Database -> Id -> Locked (Key, Status)
getIdKeyStatus Database{..} i = do
    res <- liftIO $ Ids.lookup status i
    case res of
        Nothing -> throwM $ errorInternal $ "interned value missing from database, " ++ show i
        Just v -> return v


setIdKeyStatus :: Global -> Database -> Id -> Key -> Status -> Locked ()
setIdKeyStatus Global{..} database@Database{..} i k v = do
    liftIO $ globalDiagnostic $ do
        old <- Ids.lookup status i
        let changeStatus = maybe "Missing" (statusType . snd) old ++ " -> " ++ statusType v ++ ", " ++ maybe "<unknown>" (show . fst) old
        let changeValue = case v of
                Ready r -> Just $ "    = " ++ showBracket (result r) ++ " " ++ (if built r == changed r then "(changed)" else "(unchanged)")
                _ -> Nothing
        return $ changeStatus ++ maybe "" ("\n" ++) changeValue
    setIdKeyStatusQuiet database i k v

setIdKeyStatusQuiet :: Database -> Id -> Key -> Status -> Locked ()
setIdKeyStatusQuiet Database{..} i k v =
    liftIO $ Ids.insert status i (k,v)


---------------------------------------------------------------------
-- QUERIES

getDatabaseValue :: (RuleResult key ~ value, ShakeValue key, Typeable value) => key -> Action (Maybe (Either BS.ByteString value))
getDatabaseValue k = do
    Global{..} <- Action getRO
    (_, status) <- liftIO $ runLocked globalDatabase $ \database ->
        getIdKeyStatus database =<< getKeyId database (newKey k)
    return $ case getResult status of
        Just r -> Just $ fromValue <$> result r
        _ -> Nothing


---------------------------------------------------------------------
-- NEW STYLE PRIMITIVES

statusToEither (Ready r) = Right r
statusToEither (Error e) = Left e

-- | Lookup the value for a single Id, may need to spawn it
lookupOne :: Global -> Stack -> Database -> Id -> Locked (Wait (Either SomeException (Result Value)))
lookupOne global stack database i = do
    (k, s) <- getIdKeyStatus database i
    case s of
        Waiting _ _ -> retry
        Loaded r -> buildOne global stack database i k (Just r) >> retry
        Missing -> buildOne global stack database i k Nothing >> retry
        _ -> return $ Now $ statusToEither s
    where
        retry = return $ Later $ \continue -> do
            (k, s) <- getIdKeyStatus database i
            case s of
                Waiting (NoShow w) r -> do
                    let w2 v = w v >> continue (statusToEither v)
                    setIdKeyStatusQuiet database i k $ Waiting (NoShow w2) r
                _ -> continue $ statusToEither s


-- | Build a key, must currently be either Loaded or Missing, changes to Waiting
buildOne :: Global -> Stack -> Database -> Id -> Key -> Maybe (Result BS.ByteString) -> Locked ()
buildOne global@Global{..} stack database i k r = case addStack i k stack of
    Left e ->
        setIdKeyStatus global database i k $ Error e
    Right stack -> do
        setIdKeyStatus global database i k (Waiting (NoShow $ const $ return ()) r)
        go <- maybe (return $ Now RunDependenciesChanged) (buildRunMode global stack database) r
        fromLater go $ \mode ->
            liftIO $ addPool PoolStart globalPool $ runKey global stack k r mode $ \res -> do
                runLocked globalDatabase $ \_ -> do
                    let val = either Error (Ready . runValue . snd) res
                    (_, Waiting (NoShow w) _) <- getIdKeyStatus database i
                    setIdKeyStatus global database i k val
                    w val
                case res of
                    Right (produced, RunResult{..}) | runChanged /= ChangedNothing -> journal database i k runValue{result=runStore}
                    _ -> return ()


-- | Compute the value for a given RunMode
buildRunMode :: Global -> Stack -> Database -> Result a -> Locked (Wait RunMode)
buildRunMode global stack database me = fmap conv <$> firstJustWaitOrdered
    [firstJustWaitUnordered $ map (fmap (fmap test) . lookupOne global stack database) x | Depends x <- depends me]
    where
        conv x = if isJust x then RunDependenciesChanged else RunDependenciesSame
        test (Right dep) | changed dep <= built me = Nothing
        test _ = Just ()


-- | Execute a rule, returning the associated values. If possible, the rules will be run in parallel.
--   This function requires that appropriate rules have been added with 'addUserRule'.
--   All @key@ values passed to 'apply' become dependencies of the 'Action'.
apply :: (RuleResult key ~ value, ShakeValue key, Typeable value) => [key] -> Action [value]
-- Don't short-circuit [] as we still want error messages
apply (ks :: [key]) = withResultType $ \(_ :: Maybe (Action [value])) -> do
    -- this is the only place a user can inject a key into our world, so check they aren't throwing
    -- in unevaluated bottoms
    liftIO $ mapM_ (evaluate . rnf) ks

    let tk = typeRep (Proxy :: Proxy key)
        tv = typeRep (Proxy :: Proxy value)
    Global{..} <- Action getRO
    Local{localBlockApply} <- Action getRW
    whenJust localBlockApply $ throwM . errorNoApply tk (show <$> listToMaybe ks)
    case Map.lookup tk globalRules of
        Nothing -> throwM $ errorNoRuleToBuildType tk (show <$> listToMaybe ks) (Just tv)
        Just BuiltinRule{builtinResult=tv2} | tv /= tv2 -> throwM $ errorInternal $ "result type does not match, " ++ show tv ++ " vs " ++ show tv2
        _ -> fmap (map fromValue) $ applyKeyValue $ map newKey ks


applyKeyValue :: [Key] -> Action [Value]
applyKeyValue [] = return []
applyKeyValue ks = do
    global@Global{..} <- Action getRO
    Local{localStack} <- Action getRW

    (is, wait) <- liftIO $ runLocked globalDatabase $ \database -> do
        is <- mapM (getKeyId database) ks
        wait <- firstJustWaitUnordered $ map (fmap (fmap (either Just (const Nothing))) . lookupOne global localStack database) $ nubOrd is
        wait <- flip fmapWait (return wait) $ \x -> case x of
            Just e -> return $ Left e
            Nothing -> Right <$> mapM (fmap (\(_, Ready r) -> result r) . getIdKeyStatus database) is
        return (is, wait)
    Action $ modifyRW $ \s -> s{localDepends = Depends is : localDepends s}

    case wait of
        Now vs -> either (Action . throwRAW) return vs
        Later k -> do
            offset <- liftIO offsetTime
            vs <- Action $ captureRAW $ \continue ->
                -- can only manipulate k with the globalDatabase held
                -- have to EITHER captureRAW always, or take the database twice when adding to the pool
                runLocked globalDatabase $ \_ -> k $ \x ->
                    liftIO $ addPool (if isLeft x then PoolException else PoolResume) globalPool $ continue x
            offset <- liftIO offset
            Action $ modifyRW $ addDiscount offset
            return vs


{-
runIdentify :: Map.HashMap TypeRep BuiltinRule -> Key -> Value -> BS.ByteString
runIdentify mp k v
    | Just BuiltinRule{..} <- Map.lookup (typeKey k) mp = builtinIdentity k v
    | otherwise = throwImpure $ errorInternal "runIdentify can't find rule"
-}

runKey
    :: Global
    -> Stack  -- Given the current stack with the key added on
    -> Key -- The key to build
    -> Maybe (Result BS.ByteString) -- A previous result, or Nothing if never been built before
    -> RunMode -- True if any of the children were dirty
    -> Capture (Either SomeException (Maybe [FilePath], RunResult (Result Value)))
        -- Either an error, or a (the produced files, the result).
runKey global@Global{globalOptions=ShakeOptions{..},..} stack k r mode continue = do
    let tk = typeKey k
    BuiltinRule{..} <- case Map.lookup tk globalRules of
        Nothing -> throwM $ errorNoRuleToBuildType tk (Just $ show k) Nothing
        Just r -> return r

    let s = newLocal stack shakeVerbosity
    time <- offsetTime
    runAction global s (do
        res <- builtinRun k (fmap result r) mode
        liftIO $ evaluate $ rnf res

        -- completed, now track anything required afterwards
        lintTrackFinished
        producesCheck

        Action $ fmap ((,) res) getRW) $ \x -> case x of
            Left e -> do
                e <- if isNothing shakeLint then return e else handle return $
                    do lintCurrentDirectory globalCurDir $ "Running " ++ show k; return e
                continue . Left . toException =<< shakeException global (showStack stack) e
            Right (RunResult{..}, Local{..})
                | runChanged == ChangedNothing || runChanged == ChangedStore, Just r <- r ->
                    continue $ Right $ (,) produced $ RunResult runChanged runStore (r{result = runValue})
                | otherwise -> do
                    dur <- time
                    let (cr, c) | Just r <- r, runChanged == ChangedRecomputeSame = (ChangedRecomputeSame, changed r)
                                | otherwise = (ChangedRecomputeDiff, globalStep)
                    continue $ Right $ (,) produced $ RunResult cr runStore Result
                        {result = runValue
                        ,changed = c
                        ,built = globalStep
                        ,depends = nubDepends $ reverse localDepends
                        ,execution = doubleToFloat $ dur - localDiscount
                        ,traces = reverse localTraces}
                where produced = if localCache /= CacheYes then Nothing else Just $ reverse $ map snd localProduces


-- | Apply a single rule, equivalent to calling 'apply' with a singleton list. Where possible,
--   use 'apply' to allow parallelism.
apply1 :: (RuleResult key ~ value, ShakeValue key, Typeable value) => key -> Action value
apply1 = fmap head . apply . return