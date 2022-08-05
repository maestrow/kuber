{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE OverloadedStrings #-}
module Cardano.Kuber.Core.TxBuilder

where


import Cardano.Api hiding(txMetadata, txFee)
import Cardano.Api.Shelley hiding (txMetadata, txFee)
import Cardano.Kuber.Error
import PlutusTx (ToData)
import Cardano.Slotting.Time
import qualified Cardano.Ledger.Alonzo.TxBody as LedgerBody
import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.Map (Map)
import Control.Exception
import Data.Either
import Cardano.Kuber.Util
import Data.Functor ((<&>))
import qualified Data.ByteString.Short as SBS
import qualified Data.ByteString.Lazy as LBS
import Codec.Serialise (serialise)

import Data.Set (Set)
import Data.Maybe (mapMaybe, catMaybes)
import Data.List (intercalate, sortBy)
import qualified Data.Foldable as Foldable
import Plutus.V1.Ledger.Api (PubKeyHash(PubKeyHash), Validator (Validator), unValidatorScript, TxOut, CurrencySymbol, MintingPolicy)
import qualified Plutus.V1.Ledger.Api as Plutus
import Data.Aeson.Types (FromJSON(parseJSON), (.:), Parser)
import qualified Data.Aeson as A
import qualified Data.Text as T
import Control.Monad.IO.Class (MonadIO(liftIO))
import Data.Aeson ((.:?), (.!=), KeyValue ((.=)), ToJSON (toJSON))
import qualified Data.Aeson as A.Object
import qualified Data.Vector as V
import qualified Data.Text.Encoding as T
import Debug.Trace (trace, traceM)
import qualified Data.HashMap.Strict as HM
import Data.String (IsString(fromString))
import qualified Debug.Trace as Debug
import qualified Data.Aeson as Aeson
import Data.Word (Word64)
import qualified Data.HashMap.Internal.Strict as H
import Data.Bifunctor
import Cardano.Kuber.Utility.ScriptUtil (plutusScriptToScriptAny)


data TxMintingScript = TxSimpleScript ScriptInAnyLang
              | TxPlutusScript ScriptInAnyLang ScriptData (Maybe ExecutionUnits)
                            deriving(Show)

newtype TxValidatorScript = TxValidatorScript ScriptInAnyLang deriving (Show)

data TxInputResolved_ = TxInputUtxo (UTxO AlonzoEra)
              | TxInputScriptUtxo TxValidatorScript (Maybe ScriptData) ScriptData (Maybe ExecutionUnits) (UTxO AlonzoEra)
              | TxInputReferenceScriptUtxo TxIn (Maybe ScriptData) ScriptData (Maybe ExecutionUnits) (UTxO AlonzoEra)

              deriving (Show)


data TxInputUnResolved_ = TxInputTxin TxIn
              | TxInputAddr (AddressInEra AlonzoEra)
              | TxInputScriptTxin TxValidatorScript (Maybe ScriptData) ScriptData (Maybe ExecutionUnits) TxIn
              | TxInputReferenceScriptTxin TxIn (Maybe ScriptData) ScriptData (Maybe ExecutionUnits) TxIn

              deriving (Show)

data TxInput  = TxInputResolved TxInputResolved_ | TxInputUnResolved TxInputUnResolved_ deriving (Show)

newtype TxInputReference  = TxInputReference TxIn deriving (Show)

data TxOutputContent =
     TxOutAddress (AddressInEra AlonzoEra) Value
  |  TxOutAddressWithReference (AddressInEra AlonzoEra) Value TxValidatorScript
  |  TxOutScriptAddress (AddressInEra AlonzoEra) Value (Hash ScriptData)
  |  TxOutScriptAddressWithData (AddressInEra AlonzoEra) Value   ScriptData
  |  TxOutPkh PubKeyHash Value
  |  TxOutScript TxValidatorScript Value  (Hash ScriptData)
  |  TxOutScriptWithData TxValidatorScript Value ScriptData deriving (Show)

data TxOutput = TxOutput {
  content :: TxOutputContent,
  deductFee :: Bool,
  addChange :: Bool
} deriving (Show)

data TxCollateral =  TxCollateralTxin TxIn
                  |  TxCollateralUtxo (UTxO AlonzoEra) deriving (Show)

data TxSignature =  TxSignatureAddr (AddressInEra AlonzoEra)
                  | TxSignaturePkh PubKeyHash
                  | TxSignatureSkey (SigningKey PaymentKey)
                  deriving (Show)



data TxChangeAddr = TxChangeAddrUnset
                  | TxChangeAddr (AddressInEra AlonzoEra) deriving (Show)

data TxInputSelection = TxSelectableAddresses [AddressInEra AlonzoEra]
                  | TxSelectableUtxos  (UTxO AlonzoEra)
                  | TxSelectableTxIn [TxIn]
                  | TxSelectableSkey [SigningKey PaymentKey]
                  deriving(Show)


data TxMintData = TxMintData PolicyId (ScriptWitness WitCtxMint AlonzoEra) Value deriving (Show)

-- TxBuilder object
-- It is a semigroup and monoid instance, so it can be constructed using helper function
-- and merged to construct a transaction specification
data TxBuilder=TxBuilder{
    txSelections :: [TxInputSelection],
    txInputs:: [TxInput],
    txInputReferences:: [TxInputReference],
    txOutputs :: [TxOutput],
    txCollaterals :: [TxCollateral],  -- collateral for the transaction
    txValidityStart :: Maybe Integer,
    txValidityEnd :: Maybe Integer,
    txMintData :: [TxMintData],
    txSignatures :: [TxSignature],
    txFee :: Maybe Integer,
    txDefaultChangeAddr :: Maybe (AddressInEra AlonzoEra),
    txMetadata :: Map Word64 Aeson.Value
  } deriving (Show)

instance Monoid TxBuilder where
  mempty = TxBuilder  [] [] [] [] [] Nothing Nothing [] [] Nothing Nothing Map.empty

instance Semigroup TxBuilder where
  (<>)  txb1 txb2 =TxBuilder{
    txSelections = txSelections txb1 ++ txSelections txb2,
    txInputs = txInputs txb1 ++ txInputs txb2,
    txInputReferences = txInputReferences txb1 ++ txInputReferences txb2,
    txOutputs = txOutputs txb1 ++ txOutputs txb2,
    txCollaterals  = txCollaterals txb1 ++ txCollaterals txb2,  -- collateral for the transaction
    txValidityStart = case txValidityStart txb1 of
          Just v1 -> case txValidityStart txb2 of
            Just v2 -> Just $ min v1 v2
            Nothing -> Just v1
          Nothing -> txValidityStart txb2,
    txValidityEnd = case txValidityEnd txb1 of
      Just v1 -> case txValidityEnd txb2 of
        Just v2 -> Just $ max v1 v2
        _ -> Just v1
      _ -> txValidityEnd txb2,
    txMintData = txMintData txb1 <> txMintData txb2,
    txSignatures = txSignatures txb1 ++ txSignatures txb2,
    txFee  = case txFee txb1 of
      Just f -> case txFee txb2 of
        Just f2 -> Just $ max f f2
        _ -> Just f
      Nothing -> txFee txb2,
    txDefaultChangeAddr = case txDefaultChangeAddr txb1 of
      Just addr -> Just addr
      _ -> txDefaultChangeAddr txb2,
    txMetadata = txMetadata txb1 <> txMetadata txb2
  }


data TxContext = TxContext {
  ctxAvailableUtxo :: UTxO AlonzoEra,
  ctxBuiler :: [TxBuilder]
}

txSelection :: TxInputSelection -> TxBuilder
txSelection v = TxBuilder  [v] [] [] [] [] Nothing Nothing [] [] Nothing Nothing Map.empty

txInput :: TxInput -> TxBuilder
txInput v = TxBuilder  [] [v] [] [] [] Nothing Nothing [] [] Nothing Nothing Map.empty

txInputReference :: TxInputReference -> TxBuilder
txInputReference v = TxBuilder  [] [] [v] [] [] Nothing Nothing [] [] Nothing Nothing Map.empty


txMints :: [TxMintData] -> TxBuilder
txMints md= TxBuilder  [] [] [] [] [] Nothing Nothing md [] Nothing Nothing Map.empty


txOutput :: TxOutput -> TxBuilder
txOutput v =  TxBuilder  [] [] [] [v] [] Nothing Nothing [] [] Nothing Nothing Map.empty

txCollateral :: TxCollateral -> TxBuilder
txCollateral v =  TxBuilder  [] [] [] [] [v] Nothing Nothing [] [] Nothing Nothing Map.empty

txSignature :: TxSignature -> TxBuilder
txSignature v =  TxBuilder  [] [] [] [] [] Nothing Nothing [] [v] Nothing Nothing Map.empty



-- Transaction validity

-- Set validity Start and end time in posixMilliseconds
txValidPosixTimeRangeMs :: Integer -> Integer -> TxBuilder
txValidPosixTimeRangeMs start end = TxBuilder  [] [] [] [] [] (Just start) (Just end) [] [] Nothing Nothing Map.empty

-- set  validity statart time in posixMilliseconds
txValidFromPosixMs:: Integer -> TxBuilder
txValidFromPosixMs start =  TxBuilder  [] [] [] [] [] (Just start) Nothing [] [] Nothing Nothing Map.empty

-- set transaction validity end time in posixMilliseconds
txValidUntilPosixMs :: Integer -> TxBuilder
txValidUntilPosixMs end =  TxBuilder  [] [] [] [] [] Nothing (Just end) [] [] Nothing Nothing Map.empty

--- minting
txMint  v = txMints [v]

-- mint Simple Script
txMintSimpleScript :: SimpleScript SimpleScriptV2   ->   [(AssetName,Integer)] -> TxBuilder
txMintSimpleScript simpleScript amounts = txMint $ TxMintData policyId  witness (valueFromList  $ map (bimap (AssetId policyId) Quantity )  amounts )
  where
    witness=   SimpleScriptWitness SimpleScriptV2InAlonzo SimpleScriptV2 (SScript simpleScript)
    script = SimpleScript SimpleScriptV2 simpleScript
    policyId = scriptPolicyId script


-- pay to an Address
txPayTo:: AddressInEra AlonzoEra ->Value ->TxBuilder
txPayTo addr v=  txOutput $  TxOutput (TxOutAddress  addr v) False False

txPayToWithReference:: Plutus.Script -> AddressInEra AlonzoEra ->Value ->TxBuilder
txPayToWithReference pScript addr v=  txOutput $  TxOutput (TxOutAddressWithReference addr v (TxValidatorScript (plutusScriptToScriptAny pScript))) False False

-- pay to an Address by pubKeyHash. Note that the resulting address will be an enterprise address
txPayToPkh:: PubKeyHash  ->Value ->TxBuilder
txPayToPkh pkh v= txOutput $  TxOutput ( TxOutPkh  pkh  v ) False False

-- pay to Script address
txPayToScript :: AddressInEra AlonzoEra -> Value -> Hash ScriptData -> TxBuilder
txPayToScript addr v d = txOutput $  TxOutput (TxOutScriptAddress  addr v d) False False

--Alonzo era functions
-- pay to script Address with datum added to the transaction
txPayToScriptWithData :: AddressInEra AlonzoEra -> Value -> ScriptData -> TxBuilder
txPayToScriptWithData addr v d  = txOutput $ TxOutput  (TxOutScriptAddressWithData addr v  d) False False

-- pay to script with reference script attached to the output
txPayToScriptWithReference :: Plutus.Script -> Value -> Hash ScriptData -> TxBuilder
txPayToScriptWithReference pScript v d = txOutput $ TxOutput (TxOutScript (TxValidatorScript (plutusScriptToScriptAny pScript)) v d) False False

-- pay to script with reference script attached to the output and datum inlined
txPayToScriptWithDataAndReference :: Plutus.Script -> Value -> ScriptData -> TxBuilder
txPayToScriptWithDataAndReference pScript v d  =
  txOutput $ TxOutput (TxOutScriptWithData (TxValidatorScript $ plutusScriptToScriptAny pScript) v d) False False

-- input consmptions

-- use Utxo as input in the transaction
txConsumeUtxos :: UTxO AlonzoEra -> TxBuilder
txConsumeUtxos utxo =  txInput $ TxInputResolved $  TxInputUtxo  utxo

-- use the TxIn as input in the transaction
-- the Txout value and address  is determined by querying the node
txConsumeTxIn :: TxIn -> TxBuilder
txConsumeTxIn  v = txInput $ TxInputUnResolved $ TxInputTxin v

-- use the TxIn as input in the transaction
-- the Txout value and address  is determined by querying the node
txReferenceTxIn :: TxIn -> TxBuilder
txReferenceTxIn  v = txInputReference $ TxInputReference v


-- use txIn as input in the transaction
-- Since TxOut is also given the txIn is not queried from the node.
txConsumeUtxo :: TxIn -> Cardano.Api.Shelley.TxOut CtxUTxO AlonzoEra -> TxBuilder
txConsumeUtxo tin v =txConsumeUtxos $ UTxO $ Map.singleton tin  v

-- Mark this address as txExtraKeyWitness in the transaction object.
txSignBy :: AddressInEra AlonzoEra -> TxBuilder
txSignBy  a = txSignature (TxSignatureAddr a)

-- Mark this PublicKeyhash as txExtraKeyWitness in the transaction object.
txSignByPkh :: PubKeyHash  -> TxBuilder
txSignByPkh p = txSignature $ TxSignaturePkh p

-- Mark this signingKey's vKey as txExtraKey Witness in the transaction object.
-- When validating `txSignedBy` in plutus, this can be used to add the
txSign :: SigningKey PaymentKey -> TxBuilder
txSign p = txSignature $ TxSignatureSkey p
-- Lock value and data in a script.
-- It's a script that we depend on. but we are not testing it.
-- So, the validator of this script will not be executed.


-- Redeem from a Script. The script address and value in the TxIn is determined automatically by querying the utxo from cardano node
txRedeemTxin:: TxIn -> ScriptInAnyLang ->ScriptData -> ScriptData  -> TxBuilder
txRedeemTxin txin script _data _redeemer = txInput $ TxInputUnResolved $ TxInputScriptTxin  ( TxValidatorScript $ script)  (Just  _data)  _redeemer  Nothing txin

-- Redeem from Script Address.
-- TxOut is provided so the address and value need not be queried from the caradno-node
txRedeemUtxo :: TxIn -> Cardano.Api.Shelley.TxOut CtxUTxO AlonzoEra -> ScriptInAnyLang  -> ScriptData  -> ScriptData -> Maybe ExecutionUnits ->TxBuilder
txRedeemUtxo txin txout script _data _redeemer exUnitsM = txInput $ TxInputResolved $ TxInputScriptUtxo  (  TxValidatorScript $ script)  (Just _data)  _redeemer  exUnitsM $ UTxO $ Map.singleton txin  txout

txRedeemUtxoWithInlineDatum :: TxIn -> Cardano.Api.Shelley.TxOut CtxUTxO AlonzoEra -> ScriptInAnyLang  -> ScriptData -> Maybe ExecutionUnits ->TxBuilder
txRedeemUtxoWithInlineDatum txin txout script _redeemer exUnitsM = txInput $ TxInputResolved $ TxInputScriptUtxo  (TxValidatorScript script)  Nothing _redeemer  exUnitsM $ UTxO $ Map.singleton txin  txout

txRedeemTxinWithInlineDatum :: TxIn  -> ScriptInAnyLang  -> ScriptData -> Maybe ExecutionUnits ->TxBuilder
txRedeemTxinWithInlineDatum txin  script _redeemer exUnitsM = txInput $ TxInputUnResolved $ TxInputScriptTxin  (TxValidatorScript script)  Nothing _redeemer  exUnitsM  txin

type ScriptReferenceTxIn = TxIn

txRedeemUtxoWithReferenceScript :: ScriptReferenceTxIn ->  TxIn -> Cardano.Api.Shelley.TxOut CtxUTxO AlonzoEra  -> ScriptData ->  ScriptData -> Maybe ExecutionUnits ->TxBuilder
txRedeemUtxoWithReferenceScript scRefTxIn txin txout _data _redeemer exUnitsM = txInput $ TxInputResolved $ TxInputReferenceScriptUtxo scRefTxIn (Just _data) _redeemer exUnitsM (UTxO $ Map.singleton txin  txout)

txRedeemTxinWithReferenceScript :: ScriptReferenceTxIn ->  TxIn -> Cardano.Api.Shelley.TxOut CtxUTxO AlonzoEra  -> ScriptData ->  ScriptData -> Maybe ExecutionUnits ->TxBuilder
txRedeemTxinWithReferenceScript scRefTxIn txin txout _data _redeemer exUnitsM = txInput $ TxInputUnResolved $ TxInputReferenceScriptTxin scRefTxIn (Just _data) _redeemer exUnitsM txin

txRedeemUtxoWithInlineDatumWithReferenceScript :: ScriptReferenceTxIn ->  TxIn -> Cardano.Api.Shelley.TxOut CtxUTxO AlonzoEra  -> ScriptData -> Maybe ExecutionUnits ->TxBuilder
txRedeemUtxoWithInlineDatumWithReferenceScript scRefTxIn txin txout  _redeemer exUnitsM = txInput $ TxInputResolved $ TxInputReferenceScriptUtxo scRefTxIn Nothing _redeemer exUnitsM (UTxO $ Map.singleton txin  txout)

txRedeemTxinWithInlineDatumWithReferenceScript :: ScriptReferenceTxIn ->  TxIn -> Cardano.Api.Shelley.TxOut CtxUTxO AlonzoEra  -> ScriptData -> Maybe ExecutionUnits ->TxBuilder
txRedeemTxinWithInlineDatumWithReferenceScript scRefTxIn txin txout  _redeemer exUnitsM = txInput $ TxInputUnResolved $ TxInputReferenceScriptTxin scRefTxIn Nothing _redeemer exUnitsM txin


 -- wallet addresses, from which utxos can be spent for balancing the transaction
txWalletAddresses :: [AddressInEra AlonzoEra] -> TxBuilder
txWalletAddresses v = txSelection $ TxSelectableAddresses  v

-- wallet address, from which utxos can be spent  for balancing the transaction
txWalletAddress :: AddressInEra AlonzoEra -> TxBuilder
txWalletAddress v = txWalletAddresses [v]

-- wallet utxos, that can be spent  for balancing the transaction
txWalletUtxos :: UTxO AlonzoEra -> TxBuilder
txWalletUtxos v =  txSelection $  TxSelectableUtxos v

-- wallet utxo, that can be spent  for balancing the transaction
txWalletUtxo :: TxIn -> Cardano.Api.Shelley.TxOut CtxUTxO AlonzoEra -> TxBuilder
txWalletUtxo tin tout = txWalletUtxos $  UTxO $ Map.singleton tin  tout

txWalletSignKey :: SigningKey PaymentKey -> TxBuilder
txWalletSignKey s= txWalletSignKeys [s]

txWalletSignKeys :: [SigningKey PaymentKey] -> TxBuilder
txWalletSignKeys s= txSelection $ TxSelectableSkey s

txAddTxInCollateral :: TxIn -> TxBuilder
txAddTxInCollateral colTxIn = txCollateral $ TxCollateralTxin colTxIn
