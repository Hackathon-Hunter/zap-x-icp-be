// Types.mo - Common types for the token system
import Principal "mo:base/Principal";
import Time "mo:base/Time";

module {
    // Token metadata
    public type TokenInfo = {
        name: Text;
        symbol: Text;
        decimals: Nat8;
        totalSupply: Nat;
        fee: Nat;
    };

    // Transaction record
    public type Transaction = {
        id: Nat;
        from: Principal;
        to: Principal;
        amount: Nat;
        fee: Nat;
        timestamp: Int;
        memo: ?Text;
        tokenSymbol: Text;
    };

    // Transfer arguments
    public type TransferArgs = {
        to: Principal;
        amount: Nat;
        memo: ?Text;
    };

    // Transfer result
    public type TransferResult = {
        #Ok: Nat; // Transaction ID
        #Err: TransferError;
    };

    // Transfer errors
    public type TransferError = {
        #InsufficientBalance;
        #InvalidAmount;
        #Unauthorized;
        #TooOld;
        #CreatedInFuture;
        #Duplicate;
        #TemporarilyUnavailable;
        #Other: Text;
    };

    // Balance query result
    public type BalanceResult = {
        #Ok: Nat;
        #Err: Text;
    };

    // Account balance record
    public type Account = {
        owner: Principal;
        balance: Nat;
    };
    
    // Token Manager initialization arguments
    public type TokenManagerArgs = {
        ckIdrCanisterId: Principal;
        ckUsdCanisterId: Principal;
    };
} 