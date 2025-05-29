// TokenService.mo - Service for token operations

import Principal "mo:base/Principal";
import Error "mo:base/Error";
import Types "Types";
import Utils "Utils";
import Text "mo:base/Text";
import Time "mo:base/Time";

module {
    // Get token actor for a specific token symbol
    public func getTokenActor(tokenSymbol : Text, tokenCanisters : [(Text, Text)]) : ?Types.TokenActor {
        for ((symbol, canisterId) in tokenCanisters.vals()) {
            if (symbol == tokenSymbol and canisterId != "") {
                let tokenCanister : Types.TokenActor = actor(canisterId);
                return ?tokenCanister;
            };
        };
        null
    };

    // Process token transfer
    public func processTokenTransfer(
        tokenActor : Types.TokenActor,
        from : Types.Account,
        to : Types.Account,
        amount : Nat,
        tokenSymbol : Text,
        txId : Nat,
        transactionType : Types.TransactionType,
        reference : ?Text,
        caller : Principal,
    ) : async Types.TransferResult {
        let transaction : Types.Transaction = {
            id = txId;
            from = from;
            to = to;
            amount = amount;
            tokenSymbol = tokenSymbol;
            timestamp = Time.now();
            status = #Pending;
            transactionType = transactionType;
            reference = reference;
            memo = null;
        };

        try {
            let tokenResult = await tokenActor.mint(to.owner, amount);
            
            // Convert token result to ZapManager result
            let result = switch (tokenResult) {
                case (#Ok(txId)) #Ok(txId);
                case (#Err(#InvalidAmount)) #Err(#GenericError({ error_code = 400; message = "Invalid amount" }));
                case (#Err(#InsufficientBalance)) #Err(#InsufficientFunds({ balance = 0 }));
                case (#Err(#Unauthorized)) #Err(#GenericError({ error_code = 401; message = "Token contract unauthorized" }));
            };

            result
        } catch (e) {
            // Handle any trap errors
            let errorMsg = "Token operation failed: " # Error.message(e);
            #Err(#GenericError({ error_code = 500; message = errorMsg }));
        };
    };

    // Mint tokens to a recipient
    public func mintTokens(
        tokenActor : Types.TokenActor, 
        to : Principal, 
        amount : Nat
    ) : async Types.TransferResult {
        try {
            let tokenResult = await tokenActor.mint(to, amount);
            
            // Convert token result to ZapManager result
            switch (tokenResult) {
                case (#Ok(txId)) #Ok(txId);
                case (#Err(#InvalidAmount)) #Err(#GenericError({ error_code = 400; message = "Invalid amount" }));
                case (#Err(#InsufficientBalance)) #Err(#InsufficientFunds({ balance = 0 }));
                case (#Err(#Unauthorized)) #Err(#GenericError({ error_code = 401; message = "Token contract unauthorized" }));
            };
        } catch (e) {
            // Handle any trap errors
            let errorMsg = "Token mint failed: " # Error.message(e);
            #Err(#GenericError({ error_code = 500; message = errorMsg }));
        };
    };

    // Burn tokens from an account
    public func burnTokens(
        tokenActor : Types.TokenActor, 
        from : Principal, 
        amount : Nat
    ) : async Types.TransferResult {
        try {
            let tokenResult = await tokenActor.burn(from, amount);
            
            // Convert token result to ZapManager result
            switch (tokenResult) {
                case (#Ok(txId)) #Ok(txId);
                case (#Err(#InvalidAmount)) #Err(#GenericError({ error_code = 400; message = "Invalid amount" }));
                case (#Err(#InsufficientBalance)) #Err(#InsufficientFunds({ balance = 0 }));
                case (#Err(#Unauthorized)) #Err(#GenericError({ error_code = 401; message = "Token contract unauthorized" }));
            };
        } catch (e) {
            // Handle any trap errors
            let errorMsg = "Token burn failed: " # Error.message(e);
            #Err(#GenericError({ error_code = 500; message = errorMsg }));
        };
    };
} 