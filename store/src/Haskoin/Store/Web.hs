{-# LANGUAGE CPP                 #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
module Haskoin.Store.Web
    ( -- * Web
      WebConfig (..)
    , Except (..)
    , WebLimits (..)
    , WebTimeouts (..)
    , runWeb
    ) where

import           Conduit                       ()
import           Control.Applicative           ((<|>))
import           Control.Monad                 (forever, unless, when, (<=<))
import           Control.Monad.Logger          (MonadLoggerIO, logErrorS,
                                                logInfoS)
import           Control.Monad.Reader          (ReaderT, ask, asks, local,
                                                runReaderT)
import           Control.Monad.Trans           (lift)
import           Control.Monad.Trans.Maybe     (MaybeT (..), runMaybeT)
import           Data.Aeson                    (Encoding, ToJSON (..), Value)
import           Data.Aeson.Encode.Pretty      (Config (..), defConfig,
                                                encodePretty')
import           Data.Aeson.Encoding           (encodingToLazyByteString, list)
import           Data.Aeson.Text               (encodeToLazyText)
import           Data.ByteString.Builder       (lazyByteString)
import qualified Data.ByteString.Lazy          as L
import qualified Data.ByteString.Lazy.Char8    as C
import           Data.Char                     (isSpace)
import           Data.Default                  (Default (..))
import           Data.Function                 ((&))
import           Data.List                     (nub)
import           Data.Maybe                    (catMaybes, fromMaybe,
                                                listToMaybe, mapMaybe)
import           Data.Proxy                    (Proxy (..))
import           Data.Serialize                as Serialize
import           Data.String                   (fromString)
import           Data.String.Conversions       (cs)
import           Data.Text                     (Text)
import qualified Data.Text.Encoding            as T
import           Data.Text.Lazy                (toStrict)
import           Data.Time.Clock               (NominalDiffTime, diffUTCTime,
                                                getCurrentTime)
import           Data.Time.Clock.System        (getSystemTime, systemSeconds)
import           Data.Word                     (Word32, Word64)
import           Database.RocksDB              (Property (..), getProperty)
import qualified Haskoin.Block                 as H
import           Haskoin.Constants
import           Haskoin.Network
import           Haskoin.Node                  (Chain, OnlinePeer (..),
                                                PeerManager, chainGetBest,
                                                getPeers, sendMessage)
import           Haskoin.Store.BlockStore
import           Haskoin.Store.Cache
import           Haskoin.Store.Common
import           Haskoin.Store.Data
import           Haskoin.Store.Database.Reader
import           Haskoin.Store.Manager
import           Haskoin.Store.WebCommon
import           Haskoin.Transaction
import           Haskoin.Util
import           Network.HTTP.Types            (Status (..), status400,
                                                status403, status404, status500,
                                                status503)
import           Network.Wai                   (Middleware, Request (..),
                                                responseStatus)
import           Network.Wai.Handler.Warp      (defaultSettings, setHost,
                                                setPort)
import           NQE                           (Inbox, receive,
                                                withSubscription)
import           Text.Printf                   (printf)
import           UnliftIO                      (MonadIO, MonadUnliftIO,
                                                askRunInIO, liftIO, timeout)
import           Web.Scotty.Internal.Types     (ActionT)
import qualified Web.Scotty.Trans              as S

type WebT m = ActionT Except (ReaderT WebConfig m)

data WebLimits = WebLimits
    { maxLimitCount      :: !Word32
    , maxLimitFull       :: !Word32
    , maxLimitOffset     :: !Word32
    , maxLimitDefault    :: !Word32
    , maxLimitGap        :: !Word32
    , maxLimitInitialGap :: !Word32
    }
    deriving (Eq, Show)

instance Default WebLimits where
    def =
        WebLimits
            { maxLimitCount = 200000
            , maxLimitFull = 5000
            , maxLimitOffset = 50000
            , maxLimitDefault = 100
            , maxLimitGap = 32
            , maxLimitInitialGap = 20
            }

data WebConfig = WebConfig
    { webHost       :: !String
    , webPort       :: !Int
    , webStore      :: !Store
    , webMaxDiff    :: !Int
    , webMaxPending :: !Int
    , webMaxLimits  :: !WebLimits
    , webReqLog     :: !Bool
    , webTimeouts   :: !WebTimeouts
    , webVersion    :: !String
    , webNoMempool  :: !Bool
    }

data WebTimeouts = WebTimeouts
    { txTimeout    :: !Word64
    , blockTimeout :: !Word64
    }
    deriving (Eq, Show)

data SerialAs = SerialAsBinary | SerialAsJSON | SerialAsPrettyJSON
    deriving (Eq, Show)

instance Default WebTimeouts where
    def = WebTimeouts {txTimeout = 300, blockTimeout = 7200}

instance (MonadUnliftIO m, MonadLoggerIO m) =>
         StoreReadBase (ReaderT WebConfig m) where
    getNetwork = runInWebReader getNetwork
    getBestBlock = runInWebReader getBestBlock
    getBlocksAtHeight height = runInWebReader (getBlocksAtHeight height)
    getBlock bh = runInWebReader (getBlock bh)
    getTxData th = runInWebReader (getTxData th)
    getSpender op = runInWebReader (getSpender op)
    getUnspent op = runInWebReader (getUnspent op)
    getBalance a = runInWebReader (getBalance a)
    getMempool = runInWebReader getMempool

instance (MonadUnliftIO m, MonadLoggerIO m) =>
         StoreReadExtra (ReaderT WebConfig m) where
    getMaxGap = runInWebReader getMaxGap
    getInitialGap = runInWebReader getInitialGap
    getBalances as = runInWebReader (getBalances as)
    getAddressesTxs as = runInWebReader . getAddressesTxs as
    getAddressesUnspents as = runInWebReader . getAddressesUnspents as
    xPubBals = runInWebReader . xPubBals
    xPubSummary = runInWebReader . xPubSummary
    xPubUnspents xpub = runInWebReader . xPubUnspents xpub
    xPubTxs xpub = runInWebReader . xPubTxs xpub

instance (MonadUnliftIO m, MonadLoggerIO m) => StoreReadBase (WebT m) where
    getNetwork = lift getNetwork
    getBestBlock = lift getBestBlock
    getBlocksAtHeight = lift . getBlocksAtHeight
    getBlock = lift . getBlock
    getTxData = lift . getTxData
    getSpender = lift . getSpender
    getUnspent = lift . getUnspent
    getBalance = lift . getBalance
    getMempool = lift getMempool

instance (MonadUnliftIO m, MonadLoggerIO m) => StoreReadExtra (WebT m) where
    getBalances = lift . getBalances
    getAddressesTxs as = lift . getAddressesTxs as
    getAddressesUnspents as = lift . getAddressesUnspents as
    xPubBals = lift . xPubBals
    xPubSummary = lift . xPubSummary
    xPubUnspents xpub = lift . xPubUnspents xpub
    xPubTxs xpub = lift . xPubTxs xpub
    getMaxGap = lift getMaxGap
    getInitialGap = lift getInitialGap

-------------------
-- Path Handlers --
-------------------

runWeb :: (MonadUnliftIO m , MonadLoggerIO m) => WebConfig -> m ()
runWeb cfg@WebConfig {webHost = host, webPort = port, webReqLog = reqlog} = do
    reqLogger <- logIt
    runner <- askRunInIO
    S.scottyOptsT opts (runner . (`runReaderT` cfg)) $ do
        when reqlog $ S.middleware reqLogger
        S.defaultHandler defHandler
        handlePaths
        S.notFound $ S.raise ThingNotFound
  where
    opts = def {S.settings = settings defaultSettings}
    settings = setPort port . setHost (fromString host)

defHandler :: Monad m => Except -> WebT m ()
defHandler e = do
    proto <- setupContentType False
    case e of
        ThingNotFound -> S.status status404
        BadRequest    -> S.status status400
        UserError _   -> S.status status400
        StringError _ -> S.status status400
        ServerError   -> S.status status500
        BlockTooLarge -> S.status status403
    S.raw $ protoSerial proto toEncoding toJSON e

handlePaths ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => S.ScottyT Except (ReaderT WebConfig m) ()
handlePaths = do
    -- Block Paths
    pathPretty
        (GetBlock <$> paramLazy <*> paramDef)
        scottyBlock
        blockDataToEncoding
        blockDataToJSON
    pathCompact
        (GetBlocks <$> param <*> paramDef)
        scottyBlocks
        (list . blockDataToEncoding)
        (json_list blockDataToJSON)
    pathCompact
        (GetBlockRaw <$> paramLazy)
        scottyBlockRaw
        (const toEncoding)
        (const toJSON)
    pathPretty
        (GetBlockBest <$> paramDef)
        scottyBlockBest
        blockDataToEncoding
        blockDataToJSON
    pathCompact
        (GetBlockBestRaw & return)
        scottyBlockBestRaw
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetBlockLatest <$> paramDef)
        scottyBlockLatest
        (list . blockDataToEncoding)
        (json_list blockDataToJSON)
    pathPretty
        (GetBlockHeight <$> paramLazy <*> paramDef)
        scottyBlockHeight
        (list . blockDataToEncoding)
        (json_list blockDataToJSON)
    pathCompact
        (GetBlockHeights <$> param <*> paramDef)
        scottyBlockHeights
        (list . blockDataToEncoding)
        (json_list blockDataToJSON)
    pathCompact
        (GetBlockHeightRaw <$> paramLazy)
        scottyBlockHeightRaw
        (const toEncoding)
        (const toJSON)
    pathPretty
        (GetBlockTime <$> paramLazy <*> paramDef)
        scottyBlockTime
        blockDataToEncoding
        blockDataToJSON
    pathCompact
        (GetBlockTimeRaw <$> paramLazy)
        scottyBlockTimeRaw
        (const toEncoding)
        (const toJSON)
    -- Transaction Paths
    pathPretty
        (GetTx <$> paramLazy)
        scottyTx
        transactionToEncoding
        transactionToJSON
    pathCompact
        (GetTxs <$> param)
        scottyTxs
        (list . transactionToEncoding)
        (json_list transactionToJSON)
    pathCompact
        (GetTxRaw <$> paramLazy)
        scottyTxRaw
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetTxsRaw <$> param)
        scottyTxsRaw
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetTxsBlock <$> paramLazy)
        scottyTxsBlock
        (list . transactionToEncoding)
        (json_list transactionToJSON)
    pathCompact
        (GetTxsBlockRaw <$> paramLazy)
        scottyTxsBlockRaw
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetTxAfter <$> paramLazy <*> paramLazy)
        scottyTxAfter
        (const toEncoding)
        (const toJSON)
    pathCompact
        (PostTx <$> parseBody)
        scottyPostTx
        (const toEncoding)
        (const toJSON)
    pathPretty
        (GetMempool <$> paramOptional <*> parseOffset)
        scottyMempool
        (const toEncoding)
        (const toJSON)
    -- Address Paths
    pathPretty
        (GetAddrTxs <$> paramLazy <*> parseLimits)
        scottyAddrTxs
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetAddrsTxs <$> param <*> parseLimits)
        scottyAddrsTxs
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetAddrTxsFull <$> paramLazy <*> parseLimits)
        scottyAddrTxsFull
        (list . transactionToEncoding)
        (json_list transactionToJSON)
    pathCompact
        (GetAddrsTxsFull <$> param <*> parseLimits)
        scottyAddrsTxsFull
        (list . transactionToEncoding)
        (json_list transactionToJSON)
    pathPretty
        (GetAddrBalance <$> paramLazy)
        scottyAddrBalance
        balanceToEncoding
        balanceToJSON
    pathCompact
        (GetAddrsBalance <$> param)
        scottyAddrsBalance
        (list . balanceToEncoding)
        (json_list balanceToJSON)
    pathPretty
        (GetAddrUnspent <$> paramLazy <*> parseLimits)
        scottyAddrUnspent
        (list . unspentToEncoding)
        (json_list unspentToJSON)
    pathCompact
        (GetAddrsUnspent <$> param <*> parseLimits)
        scottyAddrsUnspent
        (list . unspentToEncoding)
        (json_list unspentToJSON)
    -- XPubs
    pathPretty
        (GetXPub <$> paramLazy <*> paramDef <*> paramDef)
        scottyXPub
        (const toEncoding)
        (const toJSON)
    pathPretty
        (GetXPubTxs <$> paramLazy <*> paramDef <*> parseLimits <*> paramDef)
        scottyXPubTxs
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetXPubTxsFull <$> paramLazy <*> paramDef <*> parseLimits <*> paramDef)
        scottyXPubTxsFull
        (list . transactionToEncoding)
        (json_list transactionToJSON)
    pathPretty
        (GetXPubBalances <$> paramLazy <*> paramDef <*> paramDef)
        scottyXPubBalances
        (list . xPubBalToEncoding)
        (json_list xPubBalToJSON)
    pathPretty
        (GetXPubUnspent <$> paramLazy <*> paramDef <*> parseLimits <*> paramDef)
        scottyXPubUnspent
        (list . xPubUnspentToEncoding)
        (json_list xPubUnspentToJSON)
    pathCompact
        (GetXPubEvict <$> paramLazy <*> paramDef)
        scottyXPubEvict
        (const toEncoding)
        (const toJSON)
    -- Network
    pathPretty
        (GetPeers & return)
        scottyPeers
        (const toEncoding)
        (const toJSON)
    pathPretty
         (GetHealth & return)
         scottyHealth
         (const toEncoding)
         (const toJSON)
    S.get "/events" scottyEvents
    S.get "/dbstats" scottyDbStats
  where
    json_list f net = toJSONList . map (f net)

pathPretty ::
       (ApiResource a b, MonadIO m)
    => WebT m a
    -> (a -> WebT m b)
    -> (Network -> b -> Encoding)
    -> (Network -> b -> Value)
    -> S.ScottyT Except (ReaderT WebConfig m) ()
pathPretty parser action encJson encValue =
    pathCommon parser action encJson encValue True

pathCompact ::
       (ApiResource a b, MonadIO m)
    => WebT m a
    -> (a -> WebT m b)
    -> (Network -> b -> Encoding)
    -> (Network -> b -> Value)
    -> S.ScottyT Except (ReaderT WebConfig m) ()
pathCompact parser action encJson encValue =
    pathCommon parser action encJson encValue False

pathCommon ::
       (ApiResource a b, MonadIO m)
    => WebT m a
    -> (a -> WebT m b)
    -> (Network -> b -> Encoding)
    -> (Network -> b -> Value)
    -> Bool
    -> S.ScottyT Except (ReaderT WebConfig m) ()
pathCommon parser action encJson encValue pretty =
    S.addroute (resourceMethod proxy) (capturePath proxy) $ do
        setHeaders
        proto <- setupContentType pretty
        net <- lift $ asks (storeNetwork . webStore)
        apiRes <- parser
        res <- action apiRes
        S.raw $ protoSerial proto (encJson net) (encValue net) res
  where
    toProxy :: WebT m a -> Proxy a
    toProxy = const Proxy
    proxy = toProxy parser

protoSerial
    :: Serialize a
    => SerialAs
    -> (a -> Encoding)
    -> (a -> Value)
    -> a
    -> L.ByteString
protoSerial SerialAsBinary _ _     = runPutLazy . put
protoSerial SerialAsJSON f _       = encodingToLazyByteString . f
protoSerial SerialAsPrettyJSON _ g =
    encodePretty' defConfig {confTrailingNewline = True} . g

setHeaders :: (Monad m, S.ScottyError e) => ActionT e m ()
setHeaders = S.setHeader "Access-Control-Allow-Origin" "*"

setupContentType :: Monad m => Bool -> ActionT Except m SerialAs
setupContentType pretty = do
    accept <- S.header "accept"
    maybe goJson setType accept
  where
    setType "application/octet-stream" = goBinary
    setType _                          = goJson
    goBinary = do
        S.setHeader "Content-Type" "application/octet-stream"
        return SerialAsBinary
    goJson = do
        S.setHeader "Content-Type" "application/json"
        p <- S.param "pretty" `S.rescue` const (return pretty)
        return $ if p then SerialAsPrettyJSON else SerialAsJSON

-- GET Block / GET Blocks --

scottyBlock ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetBlock -> WebT m BlockData
scottyBlock (GetBlock h (NoTx noTx)) =
    maybe (S.raise ThingNotFound) (return . pruneTx noTx) =<< getBlock h

scottyBlocks ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetBlocks -> WebT m [BlockData]
scottyBlocks (GetBlocks hs (NoTx noTx)) =
    (pruneTx noTx <$>) . catMaybes <$> mapM getBlock (nub hs)

pruneTx :: Bool -> BlockData -> BlockData
pruneTx False b = b
pruneTx True b  = b {blockDataTxs = take 1 (blockDataTxs b)}

-- GET BlockRaw --

scottyBlockRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockRaw
    -> WebT m (RawResult H.Block)
scottyBlockRaw (GetBlockRaw h) = RawResult <$> getRawBlock h

getRawBlock ::
       (MonadUnliftIO m, MonadLoggerIO m) => H.BlockHash -> WebT m H.Block
getRawBlock h = do
    b <- maybe (S.raise ThingNotFound) return =<< getBlock h
    refuseLargeBlock b
    toRawBlock b

toRawBlock :: (Monad m, StoreReadBase m) => BlockData -> m H.Block
toRawBlock b = do
    let ths = blockDataTxs b
    txs <- map transactionData . catMaybes <$> mapM getTransaction ths
    return H.Block {H.blockHeader = blockDataHeader b, H.blockTxns = txs}

refuseLargeBlock :: Monad m => BlockData -> WebT m ()
refuseLargeBlock BlockData {blockDataTxs = txs} = do
    WebLimits {maxLimitFull = f} <- lift $ asks webMaxLimits
    when (length txs > fromIntegral f) $ S.raise BlockTooLarge

-- GET BlockBest / BlockBestRaw --

scottyBlockBest ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetBlockBest -> WebT m BlockData
scottyBlockBest (GetBlockBest noTx) = do
    bestM <- getBestBlock
    maybe (S.raise ThingNotFound) (scottyBlock . (`GetBlock` noTx)) bestM

scottyBlockBestRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockBestRaw
    -> WebT m (RawResult H.Block)
scottyBlockBestRaw _ =
    RawResult <$> (maybe (S.raise ThingNotFound) getRawBlock =<< getBestBlock)

-- GET BlockLatest --

scottyBlockLatest ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockLatest
    -> WebT m [BlockData]
scottyBlockLatest (GetBlockLatest (NoTx noTx)) =
    maybe (S.raise ThingNotFound) (go [] <=< getBlock) =<< getBestBlock
  where
    go acc Nothing = return acc
    go acc (Just b)
        | blockDataHeight b <= 0 = return acc
        | length acc == 99 = return (b:acc)
        | otherwise = do
            let prev = H.prevBlock (blockDataHeader b)
            go (pruneTx noTx b : acc) =<< getBlock prev

-- GET BlockHeight / BlockHeights / BlockHeightRaw --

scottyBlockHeight ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetBlockHeight -> WebT m [BlockData]
scottyBlockHeight (GetBlockHeight h noTx) =
    scottyBlocks . (`GetBlocks` noTx) =<< getBlocksAtHeight (fromIntegral h)

scottyBlockHeights ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockHeights
    -> WebT m [BlockData]
scottyBlockHeights (GetBlockHeights (HeightsParam heights) noTx) = do
    bhs <- concat <$> mapM getBlocksAtHeight (fromIntegral <$> heights)
    scottyBlocks (GetBlocks bhs noTx)

scottyBlockHeightRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockHeightRaw
    -> WebT m (RawResultList H.Block)
scottyBlockHeightRaw (GetBlockHeightRaw h) =
    RawResultList <$> (mapM getRawBlock =<< getBlocksAtHeight (fromIntegral h))

-- GET BlockTime / BlockTimeRaw --

scottyBlockTime ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetBlockTime -> WebT m BlockData
scottyBlockTime (GetBlockTime (TimeParam t) (NoTx noTx)) =
    maybe (S.raise ThingNotFound) (return . pruneTx noTx) =<< blockAtOrBefore t

scottyBlockTimeRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockTimeRaw
    -> WebT m (RawResult H.Block)
scottyBlockTimeRaw (GetBlockTimeRaw (TimeParam t)) = do
    b <- maybe (S.raise ThingNotFound) return =<< blockAtOrBefore t
    refuseLargeBlock b
    RawResult <$> toRawBlock b

-- GET Transactions --

scottyTx :: (MonadUnliftIO m, MonadLoggerIO m) => GetTx -> WebT m Transaction
scottyTx (GetTx txid) =
    maybe (S.raise ThingNotFound) return =<< getTransaction txid

scottyTxs ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetTxs -> WebT m [Transaction]
scottyTxs (GetTxs txids) = catMaybes <$> mapM getTransaction (nub txids)

scottyTxRaw ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetTxRaw -> WebT m (RawResult Tx)
scottyTxRaw (GetTxRaw txid) = do
    tx <- maybe (S.raise ThingNotFound) return =<< getTransaction txid
    return $ RawResult $ transactionData tx

scottyTxsRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetTxsRaw
    -> WebT m (RawResultList Tx)
scottyTxsRaw (GetTxsRaw txids) = do
    txs <- catMaybes <$> mapM getTransaction (nub txids)
    return $ RawResultList $ transactionData <$> txs

scottyTxsBlock ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetTxsBlock -> WebT m [Transaction]
scottyTxsBlock (GetTxsBlock h) = do
    b <- maybe (S.raise ThingNotFound) return =<< getBlock h
    refuseLargeBlock b
    catMaybes <$> mapM getTransaction (blockDataTxs b)

scottyTxsBlockRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetTxsBlockRaw
    -> WebT m (RawResultList Tx)
scottyTxsBlockRaw (GetTxsBlockRaw h) =
    RawResultList . fmap transactionData <$> scottyTxsBlock (GetTxsBlock h)

-- GET TransactionAfterHeight --

scottyTxAfter ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetTxAfter
    -> WebT m (GenericResult (Maybe Bool))
scottyTxAfter (GetTxAfter txid height) =
    GenericResult <$> cbAfterHeight (fromIntegral height) txid

-- | Check if any of the ancestors of this transaction is a coinbase after the
-- specified height. Returns'Nothing' if answer cannot be computed before
-- hitting limits.
cbAfterHeight ::
       (MonadIO m, StoreReadBase m)
    => H.BlockHeight
    -> TxHash
    -> m (Maybe Bool)
cbAfterHeight height begin =
    go (10000 :: Int) [begin] -- Depth first search
  where
    go 0 _ = return Nothing -- We searched too far. Return Nothing.
    go _ [] = return $ Just False -- Nothing left to search.
    go i (txid:xs) =
        getTransaction txid >>= \case
            Nothing -> return Nothing -- Error. Bail out.
            Just tx
                | cbCheck tx -> return $ Just True -- Stop everything. Return.
                | heightCheck tx -> go i xs -- Continue search sideways
                | otherwise -> do
                    let is = outPointHash . inputPoint <$> transactionInputs tx
                    -- We have to search down and search sideways
                    go (i - 1) is `returnOr` go i xs
    cbCheck tx =
        any isCoinbase (transactionInputs tx) &&
        blockRefHeight (transactionBlock tx) > height
    heightCheck tx =
        case transactionBlock tx of
            BlockRef thisHeight _ -> thisHeight <= height
            _                     -> False
    returnOr a b =
        a >>= \case
            Just True -> return $ Just True -- Bubble up this result
            _ -> b

-- POST Transaction --

scottyPostTx :: (MonadUnliftIO m, MonadLoggerIO m) => PostTx -> WebT m TxId
scottyPostTx (PostTx tx) =
    lift ask >>= \cfg -> lift (publishTx cfg tx) >>= \case
        Right () -> return $ TxId (txHash tx)
        Left e@(PubReject _) -> S.raise $ UserError $ show e
        _ -> S.raise ServerError

-- | Publish a new transaction to the network.
publishTx ::
       (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m)
    => WebConfig
    -> Tx
    -> m (Either PubExcept ())
publishTx cfg tx =
    withSubscription pub $ \s ->
        getTransaction (txHash tx) >>= \case
            Just _ -> return $ Right ()
            Nothing -> go s
  where
    pub = storePublisher (webStore cfg)
    mgr = storeManager (webStore cfg)
    net = storeNetwork (webStore cfg)
    go s =
        getPeers mgr >>= \case
            [] -> return $ Left PubNoPeers
            OnlinePeer {onlinePeerMailbox = p}:_ -> do
                MTx tx `sendMessage` p
                let v =
                        if getSegWit net
                            then InvWitnessTx
                            else InvTx
                sendMessage
                    (MGetData (GetData [InvVector v (getTxHash (txHash tx))]))
                    p
                f p s
    t = 5 * 1000 * 1000
    f p s
      | webNoMempool cfg = return $ Right ()
      | otherwise =
        liftIO (timeout t (g p s)) >>= \case
            Nothing -> return $ Left PubTimeout
            Just (Left e) -> return $ Left e
            Just (Right ()) -> return $ Right ()
    g p s =
        receive s >>= \case
            StoreTxReject p' h' c _
                | p == p' && h' == txHash tx -> return . Left $ PubReject c
            StorePeerDisconnected p'
                | p == p' -> return $ Left PubPeerDisconnected
            StoreMempoolNew h'
                | h' == txHash tx -> return $ Right ()
            _ -> g p s

-- GET Mempool / Events --

scottyMempool ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetMempool -> WebT m [TxHash]
scottyMempool (GetMempool limitM (OffsetParam o)) = do
    wl <- lift $ asks webMaxLimits
    let wl' = wl { maxLimitCount = 0 }
        l = Limits (validateLimit wl' False limitM) (fromIntegral o) Nothing
    map snd . applyLimits l <$> getMempool

scottyEvents :: MonadLoggerIO m => WebT m ()
scottyEvents = do
    setHeaders
    proto <- setupContentType False
    pub <- lift $ asks (storePublisher . webStore)
    S.stream $ \io flush' ->
        withSubscription pub $ \sub ->
            forever $
            flush' >> receiveEvent sub >>= maybe (return ()) (io . serial proto)
  where
    serial proto e =
        lazyByteString $ protoSerial proto toEncoding toJSON e <> newLine proto
    newLine SerialAsBinary     = mempty
    newLine SerialAsJSON       = "\n"
    newLine SerialAsPrettyJSON = mempty

receiveEvent :: Inbox StoreEvent -> IO (Maybe Event)
receiveEvent sub = do
    se <- receive sub
    return $
        case se of
            StoreBestBlock b  -> Just (EventBlock b)
            StoreMempoolNew t -> Just (EventTx t)
            _                 -> Nothing

-- GET Address Transactions --

scottyAddrTxs ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetAddrTxs -> WebT m [TxRef]
scottyAddrTxs (GetAddrTxs addr pLimits) =
    getAddressTxs addr =<< paramToLimits False pLimits

scottyAddrsTxs ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetAddrsTxs -> WebT m [TxRef]
scottyAddrsTxs (GetAddrsTxs addrs pLimits) =
    getAddressesTxs addrs =<< paramToLimits False pLimits

scottyAddrTxsFull ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetAddrTxsFull
    -> WebT m [Transaction]
scottyAddrTxsFull (GetAddrTxsFull addr pLimits) = do
    txs <- getAddressTxs addr =<< paramToLimits True pLimits
    catMaybes <$> mapM (getTransaction . txRefHash) txs

scottyAddrsTxsFull :: (MonadUnliftIO m, MonadLoggerIO m)
                   => GetAddrsTxsFull -> WebT m [Transaction]
scottyAddrsTxsFull (GetAddrsTxsFull addrs pLimits) = do
    txs <- getAddressesTxs addrs =<< paramToLimits True pLimits
    catMaybes <$> mapM (getTransaction . txRefHash) txs

scottyAddrBalance :: (MonadUnliftIO m, MonadLoggerIO m)
                  => GetAddrBalance -> WebT m Balance
scottyAddrBalance (GetAddrBalance addr) = getDefaultBalance addr

scottyAddrsBalance ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetAddrsBalance -> WebT m [Balance]
scottyAddrsBalance (GetAddrsBalance addrs) = getBalances addrs

scottyAddrUnspent ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetAddrUnspent -> WebT m [Unspent]
scottyAddrUnspent (GetAddrUnspent addr pLimits) =
    getAddressUnspents addr =<< paramToLimits False pLimits

scottyAddrsUnspent ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetAddrsUnspent -> WebT m [Unspent]
scottyAddrsUnspent (GetAddrsUnspent addrs pLimits) =
    getAddressesUnspents addrs =<< paramToLimits False pLimits

-- GET XPubs --

scottyXPub ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetXPub -> WebT m XPubSummary
scottyXPub (GetXPub xpub deriv (NoCache noCache)) =
    lift . runNoCache noCache $ xPubSummary $ XPubSpec xpub deriv

scottyXPubTxs ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetXPubTxs -> WebT m [TxRef]
scottyXPubTxs (GetXPubTxs xpub deriv pLimits (NoCache noCache)) = do
    limits <- paramToLimits False pLimits
    lift . runNoCache noCache $ xPubTxs (XPubSpec xpub deriv) limits

scottyXPubTxsFull ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetXPubTxsFull
    -> WebT m [Transaction]
scottyXPubTxsFull (GetXPubTxsFull xpub deriv pLimits n@(NoCache noCache)) = do
    refs <- scottyXPubTxs (GetXPubTxs xpub deriv pLimits n)
    txs <- lift . runNoCache noCache $ mapM (getTransaction . txRefHash) refs
    return $ catMaybes txs

scottyXPubBalances ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetXPubBalances -> WebT m [XPubBal]
scottyXPubBalances (GetXPubBalances xpub deriv (NoCache noCache)) =
    filter f <$> lift (runNoCache noCache (xPubBals spec))
  where
    spec = XPubSpec xpub deriv
    f = not . nullBalance . xPubBal

scottyXPubUnspent ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetXPubUnspent
    -> WebT m [XPubUnspent]
scottyXPubUnspent (GetXPubUnspent xpub deriv pLimits (NoCache noCache)) = do
    limits <- paramToLimits False pLimits
    lift . runNoCache noCache $ xPubUnspents (XPubSpec xpub deriv) limits

scottyXPubEvict ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetXPubEvict
    -> WebT m (GenericResult Bool)
scottyXPubEvict (GetXPubEvict xpub deriv) = do
    cache <- lift $ asks (storeCache . webStore)
    lift . withCache cache $ evictFromCache [XPubSpec xpub deriv]
    return $ GenericResult True

-- GET Network Information --

scottyPeers :: MonadLoggerIO m => GetPeers -> WebT m [PeerInformation]
scottyPeers _ = lift $
    getPeersInformation =<< asks (storeManager . webStore)

-- | Obtain information about connected peers from peer manager process.
getPeersInformation
    :: MonadLoggerIO m => PeerManager -> m [PeerInformation]
getPeersInformation mgr =
    mapMaybe toInfo <$> getPeers mgr
  where
    toInfo op = do
        ver <- onlinePeerVersion op
        let as = onlinePeerAddress op
            ua = getVarString $ userAgent ver
            vs = version ver
            sv = services ver
            rl = relay ver
        return
            PeerInformation
                { peerUserAgent = ua
                , peerAddress = show as
                , peerVersion = vs
                , peerServices = sv
                , peerRelay = rl
                }

scottyHealth ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetHealth -> WebT m HealthCheck
scottyHealth _ = do
    h <- lift $ ask >>= healthCheck
    unless (isOK h) $ S.status status503
    return h

blockHealthCheck :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m)
                 => WebConfig -> m BlockHealth
blockHealthCheck cfg = do
    let ch = storeChain $ webStore cfg
        blockHealthMaxDiff = webMaxDiff cfg
    blockHealthHeaders <-
        H.nodeHeight <$> chainGetBest ch
    blockHealthBlocks <-
        maybe 0 blockDataHeight <$>
        runMaybeT (MaybeT getBestBlock >>= MaybeT . getBlock)
    return BlockHealth {..}

lastBlockHealthCheck :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m)
                     => Chain -> WebTimeouts -> m TimeHealth
lastBlockHealthCheck ch tos = do
    n <- fromIntegral . systemSeconds <$> liftIO getSystemTime
    t <- fromIntegral . H.blockTimestamp . H.nodeHeader <$> chainGetBest ch
    let timeHealthAge = n - t
        timeHealthMax = fromIntegral $ blockTimeout tos
    return TimeHealth {..}

lastTxHealthCheck :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m)
                  => WebConfig -> m TimeHealth
lastTxHealthCheck WebConfig {..} = do
    n <- fromIntegral . systemSeconds <$> liftIO getSystemTime
    b <- fromIntegral . H.blockTimestamp . H.nodeHeader <$> chainGetBest ch
    t <- listToMaybe <$> getMempool >>= \case
        Just t -> let x = fromIntegral $ fst t
                  in return $ max x b
        Nothing -> return b
    let timeHealthAge = n - t
        timeHealthMax = fromIntegral to
    return TimeHealth {..}
  where
    ch = storeChain webStore
    to = if webNoMempool then blockTimeout webTimeouts else txTimeout webTimeouts

pendingTxsHealthCheck :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m)
                      => WebConfig -> m MaxHealth
pendingTxsHealthCheck cfg = do
    let maxHealthMax = webMaxPending cfg
    maxHealthNum <- blockStorePendingTxs (storeBlock (webStore cfg))
    return MaxHealth {..}

peerHealthCheck :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m)
                => PeerManager -> m CountHealth
peerHealthCheck mgr = do
    let countHealthMin = 1
    countHealthNum <- length <$> getPeers mgr
    return CountHealth {..}

healthCheck :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m)
            => WebConfig -> m HealthCheck
healthCheck cfg@WebConfig {..} = do
    healthBlocks     <- blockHealthCheck cfg
    healthLastBlock  <- lastBlockHealthCheck (storeChain webStore) webTimeouts
    healthLastTx     <- lastTxHealthCheck cfg
    healthPendingTxs <- pendingTxsHealthCheck cfg
    healthPeers      <- peerHealthCheck (storeManager webStore)
    let healthNetwork = getNetworkName (storeNetwork webStore)
        healthVersion = webVersion
        hc = HealthCheck {..}
    unless (isOK hc) $ do
        let t = toStrict $ encodeToLazyText hc
        $(logErrorS) "Web" $ "Health check failed: " <> t
    return hc

scottyDbStats :: MonadLoggerIO m => WebT m ()
scottyDbStats = do
    setHeaders
    db <- lift $ asks (databaseHandle . storeDB . webStore)
    statsM <- lift (getProperty db Stats)
    S.text $ maybe "Could not get stats" cs statsM

-----------------------
-- Parameter Parsing --
-----------------------

-- | Returns @Nothing@ if the parameter is not supplied. Raises an exception on
-- parse failure.
paramOptional :: (Param a, Monad m) => WebT m (Maybe a)
paramOptional = go Proxy
  where
    go :: (Param a, Monad m) => Proxy a -> WebT m (Maybe a)
    go proxy = do
        net <- lift $ asks (storeNetwork . webStore)
        tsM :: Maybe [Text] <- p `S.rescue` const (return Nothing)
        case tsM of
            Nothing -> return Nothing -- Parameter was not supplied
            Just ts -> maybe (S.raise err) (return . Just) $ parseParam net ts
      where
        l = proxyLabel proxy
        p = Just <$> S.param (cs l)
        err = UserError $ "Unable to parse param " <> cs l

-- | Raises an exception if the parameter is not supplied
param :: (Param a, Monad m) => WebT m a
param = go Proxy
  where
    go :: (Param a, Monad m) => Proxy a -> WebT m a
    go proxy = do
        resM <- paramOptional
        case resM of
            Just res -> return res
            _ ->
                S.raise . UserError $
                "The param " <> cs (proxyLabel proxy) <> " was not defined"

-- | Returns the default value of a parameter if it is not supplied. Raises an
-- exception on parse failure.
paramDef :: (Default a, Param a, Monad m) => WebT m a
paramDef = fromMaybe def <$> paramOptional

-- | Does not raise exceptions. Will call @Scotty.next@ if the parameter is
-- not supplied or if parsing fails.
paramLazy :: (Param a, Monad m) => WebT m a
paramLazy = do
    resM <- paramOptional `S.rescue` const (return Nothing)
    maybe S.next return resM

parseBody :: (MonadIO m, Serialize a) => WebT m a
parseBody = do
    b <- S.body
    case hex b <|> bin (L.toStrict b) of
        Nothing -> S.raise $ UserError "Failed to parse request body"
        Just x  -> return x
  where
    bin = eitherToMaybe . Serialize.decode
    hex = bin <=< decodeHex . cs . C.filter (not . isSpace)

parseOffset :: Monad m => WebT m OffsetParam
parseOffset = do
    res@(OffsetParam o) <- paramDef
    limits <- lift $ asks webMaxLimits
    when (maxLimitOffset limits > 0 && fromIntegral o > maxLimitOffset limits) $
        S.raise . UserError $
        "offset exceeded: " <> show o <> " > " <> show (maxLimitOffset limits)
    return res

parseStart ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Maybe StartParam
    -> WebT m (Maybe Start)
parseStart Nothing = return Nothing
parseStart (Just s) =
    runMaybeT $
    case s of
        StartParamHash {startParamHash = h}     -> start_tx h <|> start_block h
        StartParamHeight {startParamHeight = h} -> start_height h
        StartParamTime {startParamTime = q}     -> start_time q
  where
    start_height h = return $ AtBlock $ fromIntegral h
    start_block h = do
        b <- MaybeT $ getBlock (H.BlockHash h)
        return $ AtBlock (blockDataHeight b)
    start_tx h = do
        _ <- MaybeT $ getTxData (TxHash h)
        return $ AtTx (TxHash h)
    start_time q = do
        b <- MaybeT $ blockAtOrBefore q
        let g = blockDataHeight b
        return $ AtBlock g

parseLimits :: Monad m => WebT m LimitsParam
parseLimits = LimitsParam <$> paramOptional <*> parseOffset <*> paramOptional

paramToLimits ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Bool
    -> LimitsParam
    -> WebT m Limits
paramToLimits full (LimitsParam limitM o startM) = do
    wl <- lift $ asks webMaxLimits
    Limits (validateLimit wl full limitM) (fromIntegral o) <$> parseStart startM

validateLimit :: WebLimits -> Bool -> Maybe LimitParam -> Word32
validateLimit wl full limitM =
    f m $ maybe d (fromIntegral . getLimitParam) limitM
  where
    m | full && maxLimitFull wl > 0 = maxLimitFull wl
      | otherwise = maxLimitCount wl
    d = maxLimitDefault wl
    f a 0 = a
    f 0 b = b
    f a b = min a b

---------------
-- Utilities --
---------------

runInWebReader ::
       MonadIO m
    => CacheT (DatabaseReaderT m) a
    -> ReaderT WebConfig m a
runInWebReader f = do
    bdb <- asks (storeDB . webStore)
    mc <- asks (storeCache . webStore)
    lift $ runReaderT (withCache mc f) bdb

runNoCache :: MonadIO m => Bool -> ReaderT WebConfig m a -> ReaderT WebConfig m a
runNoCache False f = f
runNoCache True f =
    local (\s -> s {webStore = (webStore s) {storeCache = Nothing}}) f

logIt :: (MonadUnliftIO m, MonadLoggerIO m) => m Middleware
logIt = do
    runner <- askRunInIO
    return $ \app req respond -> do
        t1 <- getCurrentTime
        app req $ \res -> do
            t2 <- getCurrentTime
            let d = diffUTCTime t2 t1
                s = responseStatus res
            runner $
                $(logInfoS) "Web" $
                fmtReq req <> " [" <> fmtStatus s <> " / " <> fmtDiff d <> "]"
            respond res

fmtReq :: Request -> Text
fmtReq req =
    let m = requestMethod req
        v = httpVersion req
        p = rawPathInfo req
        q = rawQueryString req
     in T.decodeUtf8 $ m <> " " <> p <> q <> " " <> cs (show v)

fmtDiff :: NominalDiffTime -> Text
fmtDiff d =
    cs (printf "%0.3f" (realToFrac (d * 1000) :: Double) :: String) <> " ms"

fmtStatus :: Status -> Text
fmtStatus s = cs (show (statusCode s)) <> " " <> cs (statusMessage s)

