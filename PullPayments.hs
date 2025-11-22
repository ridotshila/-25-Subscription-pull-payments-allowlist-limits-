{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE DeriveGeneric       #-}

module Main where

import Prelude (IO, print, putStrLn, String)
import qualified Prelude as H

import PlutusTx
import PlutusTx.Prelude        hiding (Semigroup(..), unless, ($))
import Plutus.V2.Ledger.Api
  ( BuiltinData
  , ScriptContext (..)
  , TxInfo (..)
  , TxOut (..)
  , Validator
  , mkValidatorScript
  , PubKeyHash
  , Address (..)
  , Credential (..)
  , adaSymbol
  , adaToken
  , txOutValue
  , txOutAddress
  , txInfoOutputs
  , POSIXTime
  , txInfoValidRange
  )
import Plutus.V2.Ledger.Contexts (txSignedBy)
import Plutus.V1.Ledger.Interval (contains, from)
import qualified Plutus.V1.Ledger.Value as Value

import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Short as SBS
import Codec.Serialise (serialise)

import Cardano.Api (writeFileTextEnvelope)
import Cardano.Api.Shelley (PlutusScript (..), PlutusScriptV2)

--------------------------------------------------------------------------------
-- Datum & Redeemer
--------------------------------------------------------------------------------

-- SubDatum: subscriber, merchant, period, limit, spentInPeriod, resetAt.
data SubDatum = SubDatum
    { sdSubscriber    :: PubKeyHash
    , sdMerchant      :: PubKeyHash
    , sdPeriod        :: Integer       -- stored as integer (e.g. milliseconds) if desired; not used directly on-chain here
    , sdLimit         :: Integer       -- lovelace limit per period
    , sdSpentInPeriod :: Integer       -- lovelace spent in current period
    , sdResetAt       :: POSIXTime     -- epoch time when current period resets (inclusive)
    }
PlutusTx.unstableMakeIsData ''SubDatum

-- Redeemer: Charge | Cancel | TopUp | Update.
data SubAction = Charge Integer                -- amount to charge (lovelace)
               | Cancel
               | TopUp Integer                 -- declared topup amount (off-chain must also provide value)
               | Update Integer Integer POSIXTime  -- newLimit, newPeriod, newResetAt
PlutusTx.unstableMakeIsData ''SubAction

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

{-# INLINABLE pubKeyHashAddress #-}
pubKeyHashAddress :: PubKeyHash -> Address
pubKeyHashAddress pkh = Address (PubKeyCredential pkh) Nothing

{-# INLINABLE valuePaidTo #-}
-- Sum of ADA (lovelace) paid to a given pubkey in tx outputs
valuePaidTo :: TxInfo -> PubKeyHash -> Integer
valuePaidTo info pkh =
    let outs = txInfoOutputs info
        matches = [ Value.valueOf (txOutValue o) adaSymbol adaToken
                  | o <- outs
                  , txOutAddress o == pubKeyHashAddress pkh
                  ]
    in foldr (+) 0 matches

{-# INLINABLE nowInRange #-}
-- Check if the tx's valid range includes a POSIXTime >= t (i.e. reset time is reachable in this tx)
nowInRange :: TxInfo -> POSIXTime -> Bool
nowInRange info t = contains (from t) (txInfoValidRange info)

{-# INLINABLE remainingAllowance #-}
-- Compute remaining allowance taking into account whether reset window passed in this tx.
-- If reset has occurred in this transaction (i.e. valid range includes resetAt), then
-- allowance = limit (spentInPeriod considered reset).
remainingAllowance :: TxInfo -> SubDatum -> Integer
remainingAllowance info sd =
    let limit = sdLimit sd
        spent = sdSpentInPeriod sd
        resetAt = sdResetAt sd
        resetOccurred = nowInRange info resetAt
    in if resetOccurred then limit else (limit - spent)

--------------------------------------------------------------------------------
-- Core validator
--------------------------------------------------------------------------------

{-# INLINABLE mkSubscriptionValidator #-}
mkSubscriptionValidator :: SubDatum -> SubAction -> ScriptContext -> Bool
mkSubscriptionValidator datum action ctx =
    case action of
      Charge amt ->
        traceIfFalse "charge: positive amount required" (amt > 0)
        && traceIfFalse "charge: merchant signature required" (txSignedBy info (sdMerchant datum))
        && traceIfFalse "charge: amount exceeds remaining allowance for period" (amt <= remaining)
        && traceIfFalse "charge: merchant not paid enough" (valuePaidTo info (sdMerchant datum) >= amt)
        where
          info = scriptContextTxInfo ctx
          remaining = remainingAllowance info datum

      Cancel ->
        -- subscriber may cancel anytime; require subscriber signature.
        traceIfFalse "cancel: subscriber signature required" (txSignedBy info (sdSubscriber datum))
        where
          info = scriptContextTxInfo ctx

      TopUp amt ->
        -- TopUp must be signed by subscriber (they authorize adding funds)
        traceIfFalse "topup: subscriber signature required" (txSignedBy info (sdSubscriber datum))
        && traceIfFalse "topup: positive topup required" (amt > 0)
        -- Note: on-chain cannot fully verify the added lovelace in the continuing UTxO;
        -- off-chain must ensure the correct additional value is included.
        where
          info = scriptContextTxInfo ctx

      Update newLimit newPeriod newResetAt ->
        -- Only the subscriber can update subscription parameters
        traceIfFalse "update: subscriber signature required" (txSignedBy info (sdSubscriber datum))
        && traceIfFalse "update: newLimit non-negative" (newLimit >= 0)
        && traceIfFalse "update: newPeriod non-negative" (newPeriod >= 0)
        && traceIfFalse "update: newResetAt non-negative" (newResetAt >= 0)
        where
          info = scriptContextTxInfo ctx

--------------------------------------------------------------------------------
-- Wrap & compile
--------------------------------------------------------------------------------

{-# INLINABLE wrapped #-}
wrapped :: BuiltinData -> BuiltinData -> BuiltinData -> ()
wrapped d r c =
    let sd  = unsafeFromBuiltinData d :: SubDatum
        act = unsafeFromBuiltinData r :: SubAction
        ctx = unsafeFromBuiltinData c :: ScriptContext
    in if mkSubscriptionValidator sd act ctx
         then ()
         else traceError "SubscriptionEscrow: validation failed"

validator :: Validator
validator = mkValidatorScript $$(PlutusTx.compile [|| wrapped ||])

--------------------------------------------------------------------------------
-- Write validator to file
--------------------------------------------------------------------------------

saveValidator :: IO ()
saveValidator = do
    let scriptSerialised = serialise validator
        scriptShortBs    = SBS.toShort (LBS.toStrict scriptSerialised)
        plutusScript     = PlutusScriptSerialised scriptShortBs :: PlutusScript PlutusScriptV2
    r <- writeFileTextEnvelope "pullpayments-validator.plutus" Nothing plutusScript
    case r of
      Left err -> print err
      Right () -> putStrLn "Subscription pull validator written to: pullpayments-validator.plutus"

main :: IO ()
main = saveValidator
