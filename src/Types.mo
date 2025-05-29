// Types.mo - Common types for the Zap system

import Principal "mo:base/Principal";
import Nat "mo:base/Nat";
import Text "mo:base/Text";
import Time "mo:base/Time";

module {
    // Account types
    public type Account = {
        owner : Principal;
        subaccount : ?[Nat8];
    };

    // Token types
    public type TransferResult = {
        #Ok : Nat;
        #Err : TransferError;
    };

    public type TransferError = {
        #BadFee : { expected_fee : Nat };
        #BadBurn : { min_burn_amount : Nat };
        #InsufficientFunds : { balance : Nat };
        #TooOld;
        #CreatedInFuture : { ledger_time : Nat64 };
        #Duplicate : { duplicate_of : Nat };
        #TemporarilyUnavailable;
        #GenericError : { error_code : Nat; message : Text };
    };

    public type TokenInfo = {
        name : Text;
        symbol : Text;
        decimals : Nat8;
        totalSupply : Nat;
        fee : Nat;
    };

    public type TokenTransferResult = {
        #Ok : Nat;
        #Err : {
            #InvalidAmount;
            #InsufficientBalance;
            #Unauthorized;
        };
    };

    // Token interface
    public type TokenActor = actor {
        // ICRC-1 functions
        icrc1_name : () -> async Text;
        icrc1_symbol : () -> async Text;
        icrc1_decimals : () -> async Nat8;
        icrc1_fee : () -> async Nat;
        icrc1_total_supply : () -> async Nat;
        icrc1_balance_of : (Account) -> async Nat;
        icrc1_metadata : () -> async [(Text, { #Nat : Nat; #Int : Int; #Text : Text; #Blob : [Nat8] })];

        // Admin functions
        mint : (Principal, Nat) -> async TokenTransferResult;
        burn : (Principal, Nat) -> async TokenTransferResult;
    };

    // Transaction types
    public type Transaction = {
        id : Nat;
        from : Account;
        to : Account;
        amount : Nat;
        tokenSymbol : Text;
        timestamp : Int;
        status : TransactionStatus;
        transactionType : TransactionType;
        reference : ?Text;
        memo : ?[Nat8];
    };

    public type TransactionStatus = {
        #Pending;
        #Completed;
        #Failed : Text;
    };

    public type TransactionType = {
        #Transfer;
        #Mint;
        #Burn;
        #MerchantTransfer;
    };

    // Merchant types
    public type MerchantData = {
        name : ?Text;
        email : ?Text;
        location : ?Text;
        businessType : ?Text;
        icpAddress : ?Text;
        website : ?Text;
        phoneNumber : ?Text;
        registrationDate : ?Int;
    };
} 