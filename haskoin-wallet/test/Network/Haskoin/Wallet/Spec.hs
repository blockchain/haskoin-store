{-# LANGUAGE OverloadedStrings #-}
module Network.Haskoin.Wallet.Spec where

import           Control.Lens                               ((^.), _1, _2, _3,
                                                             _4)
import qualified Data.ByteString                            as BS
import           Data.Either
import qualified Data.Map.Strict                            as M
import           Data.Maybe
import           Data.Monoid
import qualified Data.Serialize                             as S
import           Data.String.Conversions                    (cs)
import qualified Data.Text                                  as T
import           Data.Word
import           Network.Haskoin.Block
import           Network.Haskoin.Crypto
import           Network.Haskoin.Script
import           Network.Haskoin.Transaction
import           Network.Haskoin.Util
import           Network.Haskoin.Wallet.AccountStore
import           Network.Haskoin.Wallet.Amounts
import           Network.Haskoin.Wallet.Arbitrary           ()
import           Network.Haskoin.Wallet.Entropy
import           Network.Haskoin.Wallet.HTTP
import           Network.Haskoin.Wallet.HTTP.BlockchainInfo
import           Network.Haskoin.Wallet.HTTP.Haskoin
import           Network.Haskoin.Wallet.HTTP.Insight
import           Network.Haskoin.Wallet.Signing
import           Numeric
import           Test.Hspec
import           Test.QuickCheck

walletSpec :: Spec
walletSpec = do
    diceSpec
    mnemonicSpec
    serializeSpec
    balanceSpec
    buildSpec
    signingSpec
    mergeAddressTxsSpec
    blockchainServiceSpec
    insightServiceSpec
    -- haskoinServiceSpec -- Activate this when it's ready in prodnet

diceSpec :: Spec
diceSpec =
    describe "Dice base 6 API" $ do
        it "can decode the base 6 test vectors" $ do
            decodeBase6 BS.empty `shouldBe` Just BS.empty
            decodeBase6 "6" `shouldBe` decodeHex "00"
            decodeBase6 "666" `shouldBe` decodeHex "00"
            decodeBase6 "661" `shouldBe` decodeHex "01"
            decodeBase6 "6615" `shouldBe` decodeHex "0B"
            decodeBase6 "6645" `shouldBe` decodeHex "1D"
            decodeBase6 "66456666" `shouldBe` decodeHex "92D0"
            decodeBase6 "111111111111111111111111111111111" `shouldBe`
                decodeHex "07E65FDC244B0133333333"
            decodeBase6 "55555555555555555555555555555555" `shouldBe`
                decodeHex "06954FE21E3E80FFFFFFFF"
            decodeBase6
                "161254362643213454433626115643626632163246612666332415423213664" `shouldBe`
                decodeHex "0140F8D002341BDF377F1723C9EB6C7ACFF134581C"
        it "can decode the base 6 property" $
            property $ \i ->
                i >=
                0 ==>
                let s = showIntAtBase 6 b6 (i :: Integer) ""
                in Just (integerToBS i) == decodeBase6 (cs s)
        it "can calculate the required dice rolls for a given entropy" $ do
            requiredRolls 16 `shouldBe` 49
            requiredRolls 20 `shouldBe` 61
            requiredRolls 24 `shouldBe` 74
            requiredRolls 28 `shouldBe` 86
            requiredRolls 32 `shouldBe` 99
        it "can convert dice rolls to entropy" $ do
            diceToEntropy 16 "" `shouldSatisfy` isLeft
            diceToEntropy 16 (replicate 48 '6') `shouldSatisfy` isLeft
            diceToEntropy 16 (replicate 50 '6') `shouldSatisfy` isLeft
            diceToEntropy 16 (replicate 48 '6' <> "7") `shouldSatisfy` isLeft
            diceToEntropy 16 (replicate 48 '6' <> "0") `shouldSatisfy` isLeft
            diceToEntropy 16 (replicate 49 '6') `shouldBe`
                (Right $ BS.replicate 16 0x00)
            diceToEntropy 20 (replicate 61 '6') `shouldBe`
                (Right $ BS.replicate 20 0x00)
            diceToEntropy 24 (replicate 74 '6') `shouldBe`
                (Right $ BS.replicate 24 0x00)
            diceToEntropy 28 (replicate 86 '6') `shouldBe`
                (Right $ BS.replicate 28 0x00)
            diceToEntropy 32 (replicate 99 '6') `shouldBe`
                (Right $ BS.replicate 32 0x00)
            diceToEntropy 32 (replicate 99 '1') `shouldBe`
                Right
                    (fromJust $
                     decodeHex
                         "302582058C61D13F1F9AA61CB6B5982DC3D9A42B333333333333333333333333")
            diceToEntropy
                32
                "666655555555555555555544444444444444444444444333333333333333333322222222222222222111111111111111111" `shouldBe`
                Right
                    (fromJust $
                     decodeHex
                         "002F8D57547E01B124FE849EE71CB96CA91478A542F7D4AA833EFAF5255F3333")
            diceToEntropy
                32
                "615243524162543244414631524314243526152432442413461523424314523615243251625434236413615423162365223" `shouldBe`
                Right
                    (fromJust $
                     decodeHex
                         "0CC66852D7580358E47819E37CDAF115E00364724346D83D49E59F094DB4972F")
        it "can mix entropy" $ do
            mixEntropy (BS.pack [0x00]) (BS.pack [0x00]) `shouldBe`
                (Right $ BS.pack [0x00])
            mixEntropy (BS.pack [0x00]) (BS.pack [0xff]) `shouldBe`
                (Right $ BS.pack [0xff])
            mixEntropy (BS.pack [0xff]) (BS.pack [0x00]) `shouldBe`
                (Right $ BS.pack [0xff])
            mixEntropy (BS.pack [0xff]) (BS.pack [0xff]) `shouldBe`
                (Right $ BS.pack [0x00])
            mixEntropy (BS.pack [0xaa]) (BS.pack [0x55]) `shouldBe`
                (Right $ BS.pack [0xff])
            mixEntropy (BS.pack [0x55, 0xaa]) (BS.pack [0xaa, 0x55]) `shouldBe`
                (Right $ BS.pack [0xff, 0xff])
            mixEntropy (BS.pack [0x7a, 0x54]) (BS.pack [0xd3, 0x8e]) `shouldBe`
                (Right $ BS.pack [0xa9, 0xda])

mnemonicSpec :: Spec
mnemonicSpec =
    describe "Mnemonic API" $
    -- https://github.com/iancoleman/bip39/issues/58
     do
        it "can derive iancoleman issue 58" $ do
            let m =
                    "fruit wave dwarf banana earth journey tattoo true farm silk olive fence"
                p = "banana"
                xpub = deriveXPubKey $ fromRight undefined $ signingKey p m 0
                (addr0, _) = derivePathAddr xpub extDeriv 0
            addr0 `shouldBe` "17rxURoF96VhmkcEGCj5LNQkmN9HVhWb7F"
        it "can derive a prvkey from a mnemonic" $ do
            let xprv = fromRight undefined $ signingKey (cs pwd) (cs mnem) 0
            xprv `shouldBe` fst keys
        it "can derive a pubkey from a mnemonic" $ do
            let xpub =
                    deriveXPubKey $
                    fromRight undefined $ signingKey (cs pwd) (cs mnem) 0
            xpub `shouldBe` snd keys
        it "can derive addresses from a mnemonic" $ do
            let addrs = take 5 $ derivePathAddrs (snd keys) extDeriv 0
            map fst3 addrs `shouldBe` take 5 extAddrs

serializeSpec :: Spec
serializeSpec =
    describe "Binary encoding and decoding" $
    it "can serialize TxSignData type" $
    property $ \t -> Right t == S.decode (S.encode (t :: TxSignData))

balanceSpec :: Spec
balanceSpec =
    describe "Amount parser" $ do
        it "can read and show a satoshi amounts" $
            property $ \w -> do
                let unit = UnitSatoshi
                readAmount unit (showAmount unit w) `shouldBe` Just w
        it "can read and show a bit amounts" $
            property $ \w -> do
                let unit = UnitBit
                readAmount unit (showAmount unit w) `shouldBe` Just w
        it "can read and show a bitcoin amounts" $
            property $ \w -> do
                let unit = UnitBitcoin
                readAmount unit (showAmount unit w) `shouldBe` Just w
        it "can parse example balances" $
        -- Satoshi Balances
         do
            readAmount UnitSatoshi "0" `shouldBe` Just 0
            readAmount UnitSatoshi "0000" `shouldBe` Just 0
            readAmount UnitSatoshi "0.0" `shouldBe` Nothing
            readAmount UnitSatoshi "8" `shouldBe` Just 8
            readAmount UnitSatoshi "100" `shouldBe` Just 100
            readAmount UnitSatoshi "1234567890" `shouldBe` Just 1234567890
            readAmount UnitSatoshi "1'234'567'890" `shouldBe` Just 1234567890
            readAmount UnitSatoshi "1 234 567 890" `shouldBe` Just 1234567890
            readAmount UnitSatoshi "1_234_567_890" `shouldBe` Just 1234567890
        -- Bits Balances
            readAmount UnitBit "0" `shouldBe` Just 0
            readAmount UnitBit "0000" `shouldBe` Just 0
            readAmount UnitBit "0.0" `shouldBe` Just 0
            readAmount UnitBit "0.00" `shouldBe` Just 0
            readAmount UnitBit "0.000" `shouldBe` Nothing
            readAmount UnitBit "0.10" `shouldBe` Just 10
            readAmount UnitBit "0.1" `shouldBe` Just 10
            readAmount UnitBit "0.01" `shouldBe` Just 1
            readAmount UnitBit "1" `shouldBe` Just 100
            readAmount UnitBit "100" `shouldBe` Just 10000
            readAmount UnitBit "100.00" `shouldBe` Just 10000
            readAmount UnitBit "100.01" `shouldBe` Just 10001
            readAmount UnitBit "1234567890.9" `shouldBe` Just 123456789090
            readAmount UnitBit "1'234'567'890.90" `shouldBe` Just 123456789090
            readAmount UnitBit "1 234 567 890.90" `shouldBe` Just 123456789090
            readAmount UnitBit "1_234_567_890.90" `shouldBe` Just 123456789090
        -- BitcoinBalances
            readAmount UnitBitcoin "0" `shouldBe` Just 0
            readAmount UnitBitcoin "0000" `shouldBe` Just 0
            readAmount UnitBitcoin "0.0" `shouldBe` Just 0
            readAmount UnitBitcoin "0.00000000" `shouldBe` Just 0
            readAmount UnitBitcoin "0.000000000" `shouldBe` Nothing
            readAmount UnitBitcoin "0.1" `shouldBe` Just 10000000
            readAmount UnitBitcoin "0.1000" `shouldBe` Just 10000000
            readAmount UnitBitcoin "0.10000000" `shouldBe` Just 10000000
            readAmount UnitBitcoin "0.100000000" `shouldBe` Nothing
            readAmount UnitBitcoin "1" `shouldBe` Just 100000000
            readAmount UnitBitcoin "100" `shouldBe` Just 10000000000
            readAmount UnitBitcoin "1234567890.9" `shouldBe`
                Just 123456789090000000
            readAmount UnitBitcoin "1'234'567'890.9009" `shouldBe`
                Just 123456789090090000
            readAmount UnitBitcoin "1 234 567 890.9009" `shouldBe`
                Just 123456789090090000
            readAmount UnitBitcoin "1_234_567_890.9009" `shouldBe`
                Just 123456789090090000

signingSpec :: Spec
signingSpec =
    describe "Transaction signer" $ do
        it "can sign a simple transaction" $ do
            let fundTx = testTx' [(head extAddrs, 100000000)]
                newTx =
                    testTx
                        [(txHash fundTx, 0)]
                        [(head othAddrs, 50000000), (head intAddrs, 40000000)]
                dat = TxSignData newTx [fundTx] [extDeriv :/ 0] [intDeriv :/ 0]
                xPrv = fromRight undefined $ signingKey (cs pwd) (cs mnem) 0
                (res, tx) = fromRight undefined $ signWalletTx dat xPrv
            res `shouldBe`
                TxSummary
                { txSummaryTxHash = Just $ txHash tx
                , txSummaryOutbound = M.fromList [(head othAddrs, 50000000)]
                , txSummaryInbound =
                      M.fromList [(head intAddrs, (40000000, intDeriv :/ 0))]
                , txSummaryNonStd = 0
                , txSummaryMyInputs =
                      M.fromList [(head extAddrs, (100000000, extDeriv :/ 0))]
                , txSummaryAmount = 60000000
                , txSummaryFee = 10000000
                , txSummaryFeeByte = 44444
                , txSummaryIsSigned = True
                }
        it "can partially sign a transaction" $ do
            let fundTx =
                    testTx'
                        [(head extAddrs, 100000000), (extAddrs !! 2, 200000000)]
                newTx =
                    testTx
                        [(txHash fundTx, 0), (txHash fundTx, 1)]
                        [(othAddrs !! 1, 200000000), (intAddrs !! 1, 50000000)]
                dat = TxSignData newTx [fundTx] [extDeriv :/ 2] [intDeriv :/ 1]
                xPrv = fromRight undefined $ signingKey (cs pwd) (cs mnem) 0
                (res, tx) = fromRight undefined $ signWalletTx dat xPrv
            res `shouldBe`
                TxSummary
                { txSummaryTxHash = Just $ txHash tx
                , txSummaryOutbound = M.fromList [(othAddrs !! 1, 200000000)]
                , txSummaryInbound =
                      M.fromList [(intAddrs !! 1, (50000000, intDeriv :/ 1))]
                , txSummaryNonStd = 0
                , txSummaryMyInputs =
                      M.fromList [(extAddrs !! 2, (200000000, extDeriv :/ 2))]
                , txSummaryAmount = 150000000
                , txSummaryFee = 50000000
                , txSummaryFeeByte = 187265
                , txSummaryIsSigned = False
                }
        it "can send coins to your own wallet only" $ do
            let fundTx =
                    testTx'
                        [(head extAddrs, 100000000), (extAddrs !! 1, 200000000)]
                newTx =
                    testTx
                        [(txHash fundTx, 0), (txHash fundTx, 1)]
                        [(extAddrs !! 2, 200000000), (head intAddrs, 50000000)]
                dat =
                    TxSignData
                        newTx
                        [fundTx]
                        [extDeriv :/ 0, extDeriv :/ 1]
                        [intDeriv :/ 0, extDeriv :/ 2]
                xPrv = fromRight undefined $ signingKey (cs pwd) (cs mnem) 0
                (res, tx) = fromRight undefined $ signWalletTx dat xPrv
            res `shouldBe`
                TxSummary
                { txSummaryTxHash = Just $ txHash tx
                , txSummaryOutbound = M.empty
                , txSummaryInbound =
                      M.fromList
                          [ (head intAddrs, (50000000, intDeriv :/ 0))
                          , (extAddrs !! 2, (200000000, extDeriv :/ 2))
                          ]
                , txSummaryNonStd = 0
                , txSummaryMyInputs =
                      M.fromList
                          [ (extAddrs !! 1, (200000000, extDeriv :/ 1))
                          , (head extAddrs, (100000000, extDeriv :/ 0))
                          ]
                , txSummaryAmount = 50000000
                , txSummaryFee = 50000000
                , txSummaryFeeByte = 134408
                , txSummaryIsSigned = True
                }
        it "can sign a complex transaction" $ do
            let fundTx1 =
                    testTx'
                        [ (head extAddrs, 100000000)
                        , (extAddrs !! 1, 200000000)
                        , (extAddrs !! 1, 300000000)
                        ]
                fundTx2 =
                    testTx'
                        [ (extAddrs !! 3, 400000000)
                        , (head extAddrs, 500000000)
                        , (extAddrs !! 2, 600000000)
                        ]
                newTx =
                    testTx
                        [ (txHash fundTx1, 0)
                        , (txHash fundTx1, 1)
                        , (txHash fundTx1, 2)
                        , (txHash fundTx2, 1)
                        , (txHash fundTx2, 2)
                        ]
                        [ (head othAddrs, 1000000000)
                        , (othAddrs !! 1, 200000000)
                        , (othAddrs !! 1, 100000000)
                        , (head intAddrs, 50000000)
                        , (intAddrs !! 1, 100000000)
                        , (head intAddrs, 150000000)
                        ]
                dat =
                    TxSignData
                        newTx
                        [fundTx1, fundTx2]
                        [extDeriv :/ 0, extDeriv :/ 1, extDeriv :/ 2]
                        [intDeriv :/ 0, intDeriv :/ 1]
                xPrv = fromRight undefined $ signingKey (cs pwd) (cs mnem) 0
                (res, tx) = fromRight undefined $ signWalletTx dat xPrv
            res `shouldBe`
                TxSummary
                { txSummaryTxHash = Just $ txHash tx
                , txSummaryOutbound =
                      M.fromList
                          [ (head othAddrs, 1000000000)
                          , (othAddrs !! 1, 300000000)
                          ]
                , txSummaryInbound =
                      M.fromList
                          [ (head intAddrs, (200000000, intDeriv :/ 0))
                          , (intAddrs !! 1, (100000000, intDeriv :/ 1))
                          ]
                , txSummaryNonStd = 0
                , txSummaryMyInputs =
                      M.fromList
                          [ (extAddrs !! 1, (500000000, extDeriv :/ 1))
                          , (extAddrs !! 2, (600000000, extDeriv :/ 2))
                          , (head extAddrs, (600000000, extDeriv :/ 0))
                          ]
                , txSummaryAmount = 1400000000
                , txSummaryFee = 100000000
                , txSummaryFeeByte = 105152
                , txSummaryIsSigned = True
                }
        it "can show \"Tx is missing inputs from private keys\" error" $ do
            let fundTx1 = testTx' [(extAddrs !! 1, 100000000)]
                newTx =
                    testTx
                        [(txHash fundTx1, 0)]
                        [(head othAddrs, 50000000), (head intAddrs, 40000000)]
                dat =
                    TxSignData
                        newTx
                        [fundTx1]
                        [extDeriv :/ 0, extDeriv :/ 1]
                        [intDeriv :/ 0]
                xPrv = fromRight undefined $ signingKey (cs pwd) (cs mnem) 0
            signWalletTx dat xPrv `shouldBe`
                Left "Tx is missing inputs from private keys"
        it "can show \"Tx is missing change outputs\" error" $ do
            let fundTx = testTx' [(head extAddrs, 100000000)]
                newTx =
                    testTx
                        [(txHash fundTx, 0)]
                        [(head othAddrs, 50000000), (intAddrs !! 2, 20000000)]
                dat =
                    TxSignData
                        newTx
                        [fundTx]
                        [extDeriv :/ 0]
                        [intDeriv :/ 1, intDeriv :/ 2]
                xPrv = fromRight undefined $ signingKey (cs pwd) (cs mnem) 0
            signWalletTx dat xPrv `shouldBe` Left "Tx is missing change outputs"
        it "can show \"Referenced input transactions are missing\" error" $ do
            let fundTx1 = testTx' [(head extAddrs, 100000000)]
                fundTx2 = testTx' [(extAddrs !! 1, 200000000)]
                newTx =
                    testTx
                        [(txHash fundTx1, 0), (txHash fundTx2, 0)]
                        [(head othAddrs, 50000000), (head intAddrs, 40000000)]
                dat = TxSignData newTx [fundTx2] [extDeriv :/ 0] [intDeriv :/ 0]
                xPrv = fromRight undefined $ signingKey (cs pwd) (cs mnem) 0
            signWalletTx dat xPrv `shouldBe`
                Left "Referenced input transactions are missing"

buildSpec :: Spec
buildSpec =
    describe "Transaction builder" $
    it "can build a transaction" $ do
        let coins =
                [ WalletCoin
                      (OutPoint dummyTid1 0)
                      (PayPKHash $ getAddrHash $ head extAddrs)
                      100000000
                , WalletCoin
                      (OutPoint dummyTid1 1)
                      (PayPKHash $ getAddrHash $ extAddrs !! 1)
                      200000000
                , WalletCoin
                      (OutPoint dummyTid1 2)
                      (PayPKHash $ getAddrHash $ extAddrs !! 1)
                      300000000
                , WalletCoin
                      (OutPoint dummyTid1 3)
                      (PayPKHash $ getAddrHash $ extAddrs !! 2)
                      400000000
                ]
            change = (head intAddrs, intDeriv :/ 0, 0)
            rcps = [(head othAddrs, 200000000), (othAddrs !! 1, 200000000)]
            allAddrs = zip extAddrs $ map (extDeriv :/) [0 ..]
            resE = buildWalletTx allAddrs coins change rcps 314 10000
        (map prevOutput . txIn . (^. _1) <$> resE) `shouldBe`
            Right [OutPoint dummyTid1 2, OutPoint dummyTid1 3]
        (sum . map outValue . txOut . (^. _1) <$> resE) `shouldBe`
            Right 699871888
        ((^. _2) <$> resE) `shouldBe` Right [dummyTid1]
        ((^. _3) <$> resE) `shouldBe` Right [extDeriv :/ 1, extDeriv :/ 2]
        ((^. _4) <$> resE) `shouldBe` Right [intDeriv :/ 0]

mergeAddressTxsSpec :: Spec
mergeAddressTxsSpec =
    describe "mergeAddressTxs" $ do
        it "Can merge input addresses" $ do
            let as =
                    [ AddressTx
                          (head extAddrs)
                          (dummyTxHash 1)
                          1000
                          (dummyBlockHash 1)
                          1
                    , AddressTx
                          (head extAddrs)
                          (dummyTxHash 1)
                          2000
                          (dummyBlockHash 1)
                          1
                    , AddressTx
                          (extAddrs !! 1)
                          (dummyTxHash 1)
                          4000
                          (dummyBlockHash 1)
                          1
                    , AddressTx
                          (extAddrs !! 1)
                          (dummyTxHash 2)
                          5000
                          (dummyBlockHash 2)
                          2
                    ]
            mergeAddressTxs as `shouldBe`
                [ TxMovement
                      (dummyTxHash 1)
                      M.empty
                      (M.fromList [(head extAddrs, 3000), (extAddrs !! 1, 4000)])
                      7000
                      1
                , TxMovement
                      (dummyTxHash 2)
                      M.empty
                      (M.fromList [(extAddrs !! 1, 5000)])
                      5000
                      2
                ]
        it "Can merge input and output addresses" $ do
            let as =
                    [ AddressTx
                          (head extAddrs)
                          (dummyTxHash 1)
                          1000
                          (dummyBlockHash 1)
                          1
                    , AddressTx
                          (head extAddrs)
                          (dummyTxHash 1)
                          (-1000)
                          (dummyBlockHash 1)
                          1
                    , AddressTx
                          (head extAddrs)
                          (dummyTxHash 2)
                          1000
                          (dummyBlockHash 2)
                          2
                    , AddressTx
                          (extAddrs !! 1)
                          (dummyTxHash 1)
                          4000
                          (dummyBlockHash 1)
                          1
                    , AddressTx
                          (extAddrs !! 2)
                          (dummyTxHash 1)
                          (-2000)
                          (dummyBlockHash 1)
                          1
                    , AddressTx
                          (extAddrs !! 2)
                          (dummyTxHash 1)
                          (-3000)
                          (dummyBlockHash 1)
                          1
                    , AddressTx
                          (extAddrs !! 2)
                          (dummyTxHash 2)
                          (-2000)
                          (dummyBlockHash 2)
                          2
                    , AddressTx
                          (extAddrs !! 2)
                          (dummyTxHash 1)
                          6000
                          (dummyBlockHash 1)
                          1
                    ]
            mergeAddressTxs as `shouldBe`
                [ TxMovement
                      (dummyTxHash 1)
                      (M.fromList [(head extAddrs, 1000), (extAddrs !! 2, 5000)])
                      (M.fromList
                           [ (head extAddrs, 1000)
                           , (extAddrs !! 1, 4000)
                           , (extAddrs !! 2, 6000)
                           ])
                      5000
                      1
                , TxMovement
                      (dummyTxHash 2)
                      (M.fromList [(extAddrs !! 2, 2000)])
                      (M.fromList [(head extAddrs, 1000)])
                      (-1000)
                      2
                ]

blockchainServiceSpec :: Spec
blockchainServiceSpec =
    describe "Blockchain.info service (online test)" $ do
        it "can receive balance (online test)" $ do
            res <-
                httpBalance
                    blockchainInfoService
                    ["1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"]
            res `shouldSatisfy` (>= 5000000000)
        it "can receive coins (online test)" $ do
            res <-
                httpUnspent
                    blockchainInfoService
                    ["1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"]
            head res `shouldBe`
                ( OutPoint
                      "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"
                      0
                , PayPK
                      "04678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5f"
                , 5000000000)
        it "can receive a transaction (online test)" $ do
            let tid =
                    "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"
            res <- httpTx blockchainInfoService tid
            txHash res `shouldBe` tid

insightServiceSpec :: Spec
insightServiceSpec =
    describe "Insight service (online test)" $ do
        it "can receive balance (online test)" $ do
            res <-
                httpBalance
                    insightService
                    ["1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"]
            res `shouldSatisfy` (>= 1600000000)
        it "can receive coins (online test)" $ do
            res <-
                httpUnspent
                    insightService
                    ["1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"]
            res `shouldSatisfy`
                (( OutPoint
                       "5609df21a76484bfd4a890e624723f87465916f0036b1fa8a06b9c2e8e63be30"
                       12
                 , PayPKHash "62e907b15cbf27d5425399ebf6f0fb50ebb88f18"
                 , 333000) `elem`)
        it "can receive a transaction (online test)" $ do
            let tid =
                    "0e3e2357e806b6cdb1f70b54c3a3a17b6714ee1f0e68bebb44a74b1efd512098"
            res <- httpTx insightService tid
            txHash res `shouldBe` tid

haskoinServiceSpec :: Spec
haskoinServiceSpec =
    describe "Haskoin service (online test)" $ do
        it "can receive balance (online test)" $ do
            res <-
                httpBalance
                    haskoinService
                    ["1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"]
            res `shouldSatisfy` (>= 5000000000)
        it "can receive coins (online test)" $ do
            res <-
                httpUnspent
                    haskoinService
                    ["1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"]
            head res `shouldBe`
                ( OutPoint
                      "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"
                      0
                , PayPK
                      "04678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5f"
                , 5000000000)
        it "can receive a transaction (online test)" $ do
            let tid =
                    "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"
            res <- httpTx haskoinService tid
            txHash res `shouldBe` tid


{- Test Constants -}

pwd :: T.Text
pwd = "correct horse battery staple"

mnem :: T.Text
mnem = "snow senior nerve virus fabric now fringe clip marble interest analyst can"

keys :: (XPrvKey, XPubKey)
keys = ( "xprv9yHxeaLAZvxXb9VtJNesqk8avfN8misGAW9DUW9eacZJNqsfZxqKLmK5jfmvFideQqGesviJeagzSQYCuQySjgvt7TdfowKja5aJqbgyuNh"
        , "xpub6CHK45s4QJWpodaMQQBtCt5KUhCdBBb7Xj4pGtZG8x6HFeCp7W9ZtZdZaxA34YtFAhuebiKqLqHLYoB8HDadGutW8kEH4HeMdeS1KJz8Uah"
        )

extAddrs :: [Address]
extAddrs =
    [ "1KEn7jEXa7KCLeZy59dka5qRJBLnPMmrLj"
    , "1AVj9WSYayTwUd8rS1mTTo4A6CPsS83VTg"
    , "1Dg6Kg7kQuyiZz41HRWXKUWKRu6ZyEf1Nr"
    , "1yQZuJjA6w7hXpc3C2LRiCv22rKCas7F1"
    , "1cWcYiGK7NwjPBJuKRqZxV4aymUnPu1mx"
    , "1MZuimSXigp8oqxkVUvZofqHNtVjdcdAqc"
    , "1JReTkpFnsrMqhSEJwUNZXPAyeTo2HQfnE"
    , "1Hx9xWAHhcjea5uJnyADktCfcLbuBnRnwA"
    , "1HXJhfiD7JFCGMFZnhKRsZxoPF7xDTqWXP"
    , "1MZpAt1FofY69B6fzooFxZqe6SdrVrC3Yw"
    ]

intAddrs :: [Address]
intAddrs =
    [ "17KiDLpE3r92gWR8kFGkYDtgHqEVJrznvn"
    , "1NqNFsuS7K3dfF8RnAVr9YYCMvJuF9GCn6"
    , "1MZNPWwFwy2CqVgWBq6unPWBWrZTQ7WTnr"
    , "19XbPiR98wmoJQZ42K8pVMzdCwSXZBh7iz"
    , "1Gkn7EsphiaYuv6XXvG4Kyg3LSfqFMeXHX"
    , "14VkCGcLkNqUwRMVjpLEyodAhXvzUWLqPM"
    , "1PkyVUxPMGTLzUWNFNraMagACA1x3eD4CF"
    , "1M2mmDhWTjEuqPfUdaQH6XPsr5i29gx581"
    , "184JdZjasQUmNo2AimkbKAW2sxXMF9BAvK"
    , "13b1QVnWFRwCrjvhthj4JabpnJ4nyxbBqm"
    ]

othAddrs :: [Address]
othAddrs =
    [ "1JCq8Aa9d9rg4T4XV93RV3DMxd5u7GkSSU"
    , "1PxH6Yutj49mRAabGvcTxnLkFZCuXDXvRJ"
    , "191J7K3FaXXyM7C9ceSMRsJNF6aWCvvf1Q"
    , "1FVnYNLRdR5vQkynApupUez6ZfcDqsLHdj"
    , "1PmNJHnbk7Kct5FMqbEVRxqqR2mXVQKK5P"
    , "18CaQNcVwzUkE9KvwmMd6a5UWNgqJFEAh1"
    , "1M2Cv69B7LRud8su2wdd7HV2i6MrXqzdKP"
    , "19xYPmoJ2XV1vJnSkzsrXUJXCgKvPE3ri4"
    , "1N2JAKWVFAoKFEUci3tY3kvrGFY6poRgvm"
    , "15EANoYyJoo1J51ERdQzNwZCyhEtPfcP8g"
    ]

{- Test Helpers -}

testTx :: [(TxHash, Word32)] -> [(Address, Word64)] -> Tx
testTx xs ys =
    Tx 1 txi txo 0
  where
    txi = map (\(h,p) -> TxIn (OutPoint h p) (BS.pack [1]) maxBound) xs
    f   = encodeOutputBS . PayPKHash
    txo = map (\(a,v) -> TxOut v $ f (getAddrHash a) ) ys

testTx' :: [(Address, Word64)] -> Tx
testTx' = testTx [ (dummyTid1, 0) ]

dummyTid1 :: TxHash
dummyTid1 = dummyTxHash 1

dummyTxHash :: Word8 -> TxHash
dummyTxHash w =
    fromRight (error "Could not decode tx hash") $
    S.decode $ w `BS.cons` BS.replicate 31 0x00

dummyBlockHash :: Word8 -> BlockHash
dummyBlockHash w =
    fromRight (error "Could not decode block hash") $
    S.decode $ w `BS.cons` BS.replicate 31 0x00
