// TokenTypes.mo - Types specific to the Token implementation
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";

module {
    // Token info type
    public type TokenInfo = {
        name : Text;
        symbol : Text;
        decimals : Nat8;
        totalSupply : Nat;
        fee : Nat;
    };

    // Transaction record
    public type Transaction = {
        id : Nat;
        from : Principal;
        to : Principal;
        amount : Nat;
        fee : Nat;
        timestamp : Int;
        memo : ?Text;
        tokenSymbol : Text;
    };

    // Token-specific result types
    public type TransferResult = {
        #Ok : Nat;
        #Err : TransferError;
    };

    public type TransferError = {
        #InvalidAmount;
        #InsufficientBalance;
        #Unauthorized;
    };

    // ICRC-1 Account Type
    public type Account = {
        owner : Principal;
        subaccount : ?Subaccount;
    };

    public type Subaccount = Blob;

    // ICRC-1 TransferArgs Type
    public type ICRC1TransferArgs = {
        from_subaccount : ?Subaccount;
        to : Account;
        amount : Nat;
        fee : ?Nat;
        memo : ?Blob;
        created_at_time : ?Nat64;
    };

    // ICRC-1 Transfer Error Type (for compatibility with ZapManager)
    public type ICRC1TransferError = {
        #BadFee : { expected_fee : Nat };
        #BadBurn : { min_burn_amount : Nat };
        #InsufficientFunds : { balance : Nat };
        #TooOld;
        #CreatedInFuture : { ledger_time : Nat64 };
        #Duplicate : { duplicate_of : Nat };
        #TemporarilyUnavailable;
        #GenericError : { error_code : Nat; message : Text };
    };
} 