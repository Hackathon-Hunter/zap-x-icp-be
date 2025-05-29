import Principal "mo:base/Principal";
import Array "mo:base/Array";
import Time "mo:base/Time";
import Iter "mo:base/Iter";
import HashMap "mo:base/HashMap";
import Text "mo:base/Text";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Hash "mo:base/Hash";
import Int "mo:base/Int";
import Result "mo:base/Result";
import Error "mo:base/Error";
import Blob "mo:base/Blob";

// Import our modules
import Types "Types";
import Utils "Utils";
import TokenService "TokenService";

actor ZapManager {
    public type Account = {
        owner : Principal;
        subaccount : ?[Nat8];
    };

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

    public type TokenActor = actor {
        icrc1_name : () -> async Text;
        icrc1_symbol : () -> async Text;
        icrc1_decimals : () -> async Nat8;
        icrc1_fee : () -> async Nat;
        icrc1_total_supply : () -> async Nat;
        icrc1_balance_of : (Account) -> async Nat;
        icrc1_metadata : () -> async [(Text, { #Nat : Nat; #Int : Int; #Text : Text; #Blob : [Nat8] })];

        // Admin functions
        mint : (Principal, Nat) -> async TransferResult;
        burn : (Principal, Nat) -> async TransferResult;
    };

    // Configuration
    private stable var ckIdrCanisterId : Text = "";
    private stable var ckUsdCanisterId : Text = "";
    private stable var isInitialized : Bool = false;
    private stable var owner : Principal = Principal.fromText("4pzfl-o35wy-m642s-gm3ot-5j4aq-zywlz-2b3jt-d2rlw-36q7o-nmtcx-oqe");
    private stable var additionalAdmins : [Principal] = [
        Principal.fromText("4pzfl-o35wy-m642s-gm3ot-5j4aq-zywlz-2b3jt-d2rlw-36q7o-nmtcx-oqe"),
        Principal.fromText("6vkm4-udxft-3dcoj-3efxo-25xih-lnyhl-3y352-yi7ip-6zqjk-nkkbt-fae"),
        Principal.fromText("jyh2a-hym3t-zn35a-vh2wf-ehicm-m4m4h-woxld-toveg-klawp-ttkwb-4ae"),
        Principal.fromText("ca6ap-jtp5u-pakkx-6fcis-b3vix-zibh7-ld7nj-zf2hs-vo4xc-t6i4c-nae"),
    ];

    // Storage
    private stable var nextTxId : Nat = 0;
    private var transactions = HashMap.HashMap<Nat, Types.Transaction>(100, Nat.equal, Hash.hash);
    private var merchants = HashMap.HashMap<Principal, Types.MerchantData>(10, Principal.equal, Principal.hash);

    // Stable variables for upgrades
    private stable var transactionEntries : [(Nat, Types.Transaction)] = [];
    private stable var merchantEntries : [(Principal, Types.MerchantData)] = [];

    // Helper functions
    private func isAuthorized(principal : Principal) : Bool {
        if (principal == owner) {
            return true;
        };
        for (admin in additionalAdmins.vals()) {
            if (principal == admin) {
                return true;
            };
        };
        if (principal == Principal.fromText("ca6ap-jtp5u-pakkx-6fcis-b3vix-zibh7-ld7nj-zf2hs-vo4xc-t6i4c-nae")) {
            return true;
        };
        false;
    };

    private func isOwner(principal : Principal) : Bool {
        principal == owner;
    };

    // System upgrade hooks
    system func preupgrade() {
        merchantEntries := Iter.toArray(merchants.entries());
        transactionEntries := Iter.toArray(transactions.entries());
    };

    system func postupgrade() {
        // Convert existing merchant data if needed
        merchants := HashMap.HashMap<Principal, Types.MerchantData>(10, Principal.equal, Principal.hash);
        
        for ((principal, oldData) in merchantEntries.vals()) {
            // Handle legacy data with Int registrationDate
            let newData : Types.MerchantData = {
                name = oldData.name;
                email = oldData.email;
                location = oldData.location;
                businessType = oldData.businessType;
                icpAddress = oldData.icpAddress;
                website = oldData.website;
                phoneNumber = oldData.phoneNumber;
                registrationDate = ?Time.now(); // Set current time for all merchants on upgrade
            };
            merchants.put(principal, newData);
        };
        
        merchantEntries := [];
        
        // Restore transactions
        transactions := HashMap.fromIter(transactionEntries.vals(), transactionEntries.size(), Nat.equal, Hash.hash);
        transactionEntries := [];
    };

    // Initialization - Only owner can initialize
    public shared (msg) func initializeTokens(ckIdrId : Principal, ckUsdId : Principal) : async Bool {
        if (isInitialized and not isOwner(msg.caller)) {
            return false;
        };

        ckIdrCanisterId := Principal.toText(ckIdrId);
        ckUsdCanisterId := Principal.toText(ckUsdId);
        isInitialized := true;
        true;
    };

    // Query functions
    public query func isReady() : async Bool {
        isInitialized;
    };

    public query func getOwner() : async Principal {
        owner;
    };

    public query func getTokenCanisters() : async [(Text, Text)] {
        [
            ("ckIdr", ckIdrCanisterId),
            ("ckUsd", ckUsdCanisterId),
        ];
    };

    // Token information functions
    public func getTokenInfo(symbol : Text) : async ?Types.TokenInfo {
        if (not isInitialized) {
            return null;
        };

        let tokenCanisters = [
            ("ckIdr", ckIdrCanisterId),
            ("ckUsd", ckUsdCanisterId),
        ];

        switch (TokenService.getTokenActor(symbol, tokenCanisters)) {
            case (null) null;
            case (?token) {
                let name = await token.icrc1_name();
                let symbol = await token.icrc1_symbol();
                let decimals = await token.icrc1_decimals();
                let totalSupply = await token.icrc1_total_supply();
                let fee = await token.icrc1_fee();

                ?{
                    name = name;
                    symbol = symbol;
                    decimals = decimals;
                    totalSupply = totalSupply;
                    fee = fee;
                };
            };
        };
    };

    public func getAllTokensInfo() : async [(Text, Types.TokenInfo)] {
        var result : [(Text, Types.TokenInfo)] = [];

        if (not isInitialized) {
            return result;
        };

        let tokenCanisters = [
            ("ckIdr", ckIdrCanisterId),
            ("ckUsd", ckUsdCanisterId),
        ];

        // Get ckIdr info
        switch (TokenService.getTokenActor("ckIdr", tokenCanisters)) {
            case (?token) {
                let name = await token.icrc1_name();
                let symbol = await token.icrc1_symbol();
                let decimals = await token.icrc1_decimals();
                let totalSupply = await token.icrc1_total_supply();
                let fee = await token.icrc1_fee();

                let info : Types.TokenInfo = {
                    name = name;
                    symbol = symbol;
                    decimals = decimals;
                    totalSupply = totalSupply;
                    fee = fee;
                };
                result := Array.append(result, [("ckIdr", info)]);
            };
            case (null) {};
        };

        // Get ckUsd info
        switch (TokenService.getTokenActor("ckUsd", tokenCanisters)) {
            case (?token) {
                let name = await token.icrc1_name();
                let symbol = await token.icrc1_symbol();
                let decimals = await token.icrc1_decimals();
                let totalSupply = await token.icrc1_total_supply();
                let fee = await token.icrc1_fee();

                let info : Types.TokenInfo = {
                    name = name;
                    symbol = symbol;
                    decimals = decimals;
                    totalSupply = totalSupply;
                    fee = fee;
                };
                result := Array.append(result, [("ckUsd", info)]);
            };
            case (null) {};
        };

        result;
    };

    // Balance functions
    public func getBalance(account : Types.Account, symbol : Text) : async ?Nat {
        if (not isInitialized) {
            return null;
        };

        let tokenCanisters = [
            ("ckIdr", ckIdrCanisterId),
            ("ckUsd", ckUsdCanisterId),
        ];

        switch (TokenService.getTokenActor(symbol, tokenCanisters)) {
            case (null) null;
            case (?token) {
                ?(await token.icrc1_balance_of(account));
            };
        };
    };

    public func getAllBalances(account : Types.Account) : async [(Text, Nat)] {
        var result : [(Text, Nat)] = [];

        if (not isInitialized) {
            return result;
        };

        let tokenCanisters = [
            ("ckIdr", ckIdrCanisterId),
            ("ckUsd", ckUsdCanisterId),
        ];

        // Get ckIdr balance
        switch (TokenService.getTokenActor("ckIdr", tokenCanisters)) {
            case (?token) {
                let balance = await token.icrc1_balance_of(account);
                result := Array.append(result, [("ckIdr", balance)]);
            };
            case (null) {};
        };

        // Get ckUsd balance
        switch (TokenService.getTokenActor("ckUsd", tokenCanisters)) {
            case (?token) {
                let balance = await token.icrc1_balance_of(account);
                result := Array.append(result, [("ckUsd", balance)]);
            };
            case (null) {};
        };

        result;
    };

    // Token operations - Admin/Owner can mint to merchants
    public shared (msg) func mintToMerchant(
        merchantAccount : Types.Account,
        tokenSymbol : { #ckIdr; #ckUsd },
        amount : Nat,
    ) : async Types.TransferResult {

        if (not isAuthorized(msg.caller)) {
            return #Err(#GenericError({ error_code = 401; message = "Unauthorized - Only owner/admin can mint tokens" }));
        };

        let symbolText = switch (tokenSymbol) {
            case (#ckIdr) "ckIdr";
            case (#ckUsd) "ckUsd";
        };

        let tokenCanisters = [
            ("ckIdr", ckIdrCanisterId),
            ("ckUsd", ckUsdCanisterId),
        ];

        switch (TokenService.getTokenActor(symbolText, tokenCanisters)) {
            case (null) {
                #Err(#GenericError({ error_code = 404; message = symbolText # " token not initialized" }));
            };
            case (?tokenActor) {
                // Create transaction record
                let txId = nextTxId;
                nextTxId += 1;

                let transaction : Types.Transaction = {
                    id = txId;
                    from = Utils.principalToAccount(msg.caller);
                    to = merchantAccount;
                    amount = amount;
                    tokenSymbol = symbolText;
                    timestamp = Time.now();
                    status = #Pending;
                    transactionType = #MerchantTransfer;
                    reference = null;
                    memo = null;
                };

                transactions.put(txId, transaction);

                // Execute mint with merchant's Principal
                try {
                    let result = await TokenService.mintTokens(tokenActor, merchantAccount.owner, amount);
                    
                    // Update transaction status
                    let updatedStatus = switch (result) {
                        case (#Ok(_)) #Completed;
                        case (#Err(err)) #Failed(debug_show (err));
                    };

                    let updatedTx = {
                        transaction with status = updatedStatus;
                    };

                    transactions.put(txId, updatedTx);
                    result;
                } catch (e) {
                    // Handle any trap errors
                    let errorMsg = "Token mint failed: " # Error.message(e);
                    let updatedTx = {
                        transaction with
                        status = #Failed(errorMsg);
                    };
                    transactions.put(txId, updatedTx);
                    #Err(#GenericError({ error_code = 500; message = errorMsg }));
                };
            };
        };
    };

    // Owner/Admin-only transfer function
    public shared (msg) func transferFromOwner(
        toPrincipal : Principal,
        tokenSymbol : { #ckIdr; #ckUsd },
        amount : Nat,
        memo : ?Text,
    ) : async Types.TransferResult {

        // Only authorized users (owner/admin) can call this function
        if (not isAuthorized(msg.caller)) {
            return #Err(#GenericError({ error_code = 401; message = "Unauthorized - Only owner/admin can transfer tokens" }));
        };

        let symbolText = switch (tokenSymbol) {
            case (#ckIdr) "ckIdr";
            case (#ckUsd) "ckUsd";
        };

        let tokenCanisters = [
            ("ckIdr", ckIdrCanisterId),
            ("ckUsd", ckUsdCanisterId),
        ];

        switch (TokenService.getTokenActor(symbolText, tokenCanisters)) {
            case (null) {
                #Err(#GenericError({ error_code = 404; message = symbolText # " token not initialized" }));
            };
            case (?tokenActor) {
                // Create transaction record
                let txId = nextTxId;
                nextTxId += 1;

                let toAccount = Utils.principalToAccount(toPrincipal);
                let transaction : Types.Transaction = {
                    id = txId;
                    from = Utils.principalToAccount(msg.caller); // Track who actually made the transfer
                    to = toAccount;
                    amount = amount;
                    tokenSymbol = symbolText;
                    timestamp = Time.now();
                    status = #Pending;
                    transactionType = #Transfer;
                    reference = memo;
                    memo = null;
                };

                transactions.put(txId, transaction);

                // Execute mint to recipient
                try {
                    let result = await TokenService.mintTokens(tokenActor, toPrincipal, amount);

                    // Update transaction status
                    let updatedStatus = switch (result) {
                        case (#Ok(_)) #Completed;
                        case (#Err(err)) #Failed(debug_show (err));
                    };

                    let updatedTx = {
                        transaction with
                        status = updatedStatus;
                    };

                    transactions.put(txId, updatedTx);
                    result;
                } catch (e) {
                    // Handle any trap errors
                    let errorMsg = "Token mint failed: " # Error.message(e);
                    let updatedTx = {
                        transaction with
                        status = #Failed(errorMsg);
                    };
                    transactions.put(txId, updatedTx);
                    #Err(#GenericError({ error_code = 500; message = errorMsg }));
                };
            };
        };
    };

    // Batch transfer function - Only for owner/admin
    public shared (msg) func batchTransferFromOwner(
        transfers : [(Principal, Nat)],
        tokenSymbol : { #ckIdr; #ckUsd },
        memo : ?Text,
    ) : async [(Principal, Types.TransferResult)] {

        // Only authorized users (owner/admin) can call this function
        if (not isAuthorized(msg.caller)) {
            return Array.map<(Principal, Nat), (Principal, Types.TransferResult)>(
                transfers,
                func(t) = (t.0, #Err(#GenericError({ error_code = 401; message = "Unauthorized - Only owner/admin can transfer tokens" }))),
            );
        };

        let symbolText = switch (tokenSymbol) {
            case (#ckIdr) "ckIdr";
            case (#ckUsd) "ckUsd";
        };

        let tokenCanisters = [
            ("ckIdr", ckIdrCanisterId),
            ("ckUsd", ckUsdCanisterId),
        ];

        switch (TokenService.getTokenActor(symbolText, tokenCanisters)) {
            case (null) {
                Array.map<(Principal, Nat), (Principal, Types.TransferResult)>(
                    transfers,
                    func(t) = (t.0, #Err(#GenericError({ error_code = 404; message = symbolText # " token not initialized" }))),
                );
            };
            case (?tokenActor) {
                var results : [(Principal, Types.TransferResult)] = [];

                for ((recipient, amount) in transfers.vals()) {
                    // Create transaction record
                    let txId = nextTxId;
                    nextTxId += 1;

                    let toAccount = Utils.principalToAccount(recipient);
                    let transaction : Types.Transaction = {
                        id = txId;
                        from = Utils.principalToAccount(msg.caller); // Track who made the transfer
                        to = toAccount;
                        amount = amount;
                        tokenSymbol = symbolText;
                        timestamp = Time.now();
                        status = #Pending;
                        transactionType = #Transfer;
                        reference = memo;
                        memo = null;
                    };

                    transactions.put(txId, transaction);

                    // Execute mint to recipient with Principal instead of Account
                    try {
                        let result = await TokenService.mintTokens(tokenActor, recipient, amount);

                        // Update transaction status
                        let updatedStatus = switch (result) {
                            case (#Ok(_)) #Completed;
                            case (#Err(err)) #Failed(debug_show (err));
                        };

                        let updatedTx = {
                            transaction with
                            status = updatedStatus;
                        };

                        transactions.put(txId, updatedTx);
                        results := Array.append(results, [(recipient, result)]);
                    } catch (e) {
                        let errorMsg = "Token mint failed: " # Error.message(e);
                        let updatedTx = {
                            transaction with
                            status = #Failed(errorMsg);
                        };
                        transactions.put(txId, updatedTx);
                        let errorResult = #Err(#GenericError({ error_code = 500; message = errorMsg }));
                        results := Array.append(results, [(recipient, errorResult)]);
                    };
                };

                results;
            };
        };
    };

    // Burn function - Admin/Owner only
    public shared (msg) func burnFromAccount(
        fromAccount : Types.Account,
        tokenSymbol : { #ckIdr; #ckUsd },
        amount : Nat,
    ) : async Types.TransferResult {

        if (not isAuthorized(msg.caller)) {
            return #Err(#GenericError({ error_code = 401; message = "Unauthorized - Only owner/admin can burn tokens" }));
        };

        let symbolText = switch (tokenSymbol) {
            case (#ckIdr) "ckIdr";
            case (#ckUsd) "ckUsd";
        };

        let tokenCanisters = [
            ("ckIdr", ckIdrCanisterId),
            ("ckUsd", ckUsdCanisterId),
        ];

        switch (TokenService.getTokenActor(symbolText, tokenCanisters)) {
            case (null) {
                #Err(#GenericError({ error_code = 404; message = symbolText # " token not initialized" }));
            };
            case (?tokenActor) {
                // Create transaction record
                let txId = nextTxId;
                nextTxId += 1;

                let transaction : Types.Transaction = {
                    id = txId;
                    from = fromAccount;
                    to = Utils.principalToAccount(msg.caller);
                    amount = amount;
                    tokenSymbol = symbolText;
                    timestamp = Time.now();
                    status = #Pending;
                    transactionType = #Burn;
                    reference = null;
                    memo = null;
                };

                transactions.put(txId, transaction);

                try {
                    let result = await TokenService.burnTokens(tokenActor, fromAccount.owner, amount);
                    
                    // Update transaction status
                    let updatedStatus = switch (result) {
                        case (#Ok(_)) #Completed;
                        case (#Err(err)) #Failed(debug_show (err));
                    };

                    let updatedTx = {
                        transaction with status = updatedStatus;
                    };

                    transactions.put(txId, updatedTx);
                    result;
                } catch (e) {
                    let errorMsg = "Token burn failed: " # Error.message(e);
                    let updatedTx = {
                        transaction with
                        status = #Failed(errorMsg);
                    };
                    transactions.put(txId, updatedTx);
                    #Err(#GenericError({ error_code = 500; message = errorMsg }));
                };
            };
        };
    };

    // Transaction history functions
    public query func getTransaction(txId : Nat) : async ?Types.Transaction {
        transactions.get(txId);
    };

    public query func getUserTransactions(userAccount : Types.Account) : async [Types.Transaction] {
        let allTxs = Iter.toArray(transactions.vals());
        Array.filter<Types.Transaction>(
            allTxs,
            func(tx) = (tx.from.owner == userAccount.owner) or (tx.to.owner == userAccount.owner),
        );
    };

    public query func getTransactionsByType(userAccount : Types.Account, txType : Types.TransactionType) : async [Types.Transaction] {
        let allTxs = Iter.toArray(transactions.vals());
        Array.filter<Types.Transaction>(
            allTxs,
            func(tx) = ((tx.from.owner == userAccount.owner) or (tx.to.owner == userAccount.owner)) and
            (tx.transactionType == txType),
        );
    };

    public query func getTransactionsByStatus(status : Types.TransactionStatus) : async [Types.Transaction] {
        let allTxs = Iter.toArray(transactions.vals());
        Array.filter<Types.Transaction>(allTxs, func(tx) = tx.status == status);
    };

    public query func getAllTransactions(start : Nat, limit : Nat) : async [Types.Transaction] {
        let txArray = Iter.toArray(transactions.vals());
        let size = txArray.size();

        if (start >= size) {
            return [];
        };

        let end = if (start + limit > size) size else start + limit;
        Array.tabulate<Types.Transaction>(end - start, func(i) = txArray[start + i]);
    };

    // Merchant functions
    public shared (msg) func registerMerchant(merchantPrincipal : ?Principal, data : Types.MerchantData) : async Bool {
        let targetPrincipal = switch (merchantPrincipal) {
            case (null) msg.caller;
            case (?principal) {
                if (principal != msg.caller and not isAuthorized(msg.caller)) {
                    return false;
                };
                principal;
            };
        };
        
        let merchantData = Utils.createMerchantData(data);
        merchants.put(targetPrincipal, merchantData);
        true;
    };

    public shared (msg) func updateMerchantProfile(merchantPrincipal : ?Principal, data : Types.MerchantData) : async Bool {
        let targetPrincipal = switch (merchantPrincipal) {
            case (null) msg.caller;
            case (?principal) {
                if (principal != msg.caller and not isAuthorized(msg.caller)) {
                    return false;
                };
                principal;
            };
        };
        
        switch (merchants.get(targetPrincipal)) {
            case (null) {
                let merchantData = Utils.createMerchantData(data);
                merchants.put(targetPrincipal, merchantData);
                true;
            };
            case (?existingData) {
                let updatedData = Utils.mergeMerchantData(existingData, data);
                merchants.put(targetPrincipal, updatedData);
                true;
            };
        };
    };

    // Clear merchant data (admin only)
    public shared (msg) func clearMerchant(merchantId : Principal) : async Bool {
        if (not isAuthorized(msg.caller)) {
            return false;
        };
        
        merchants.delete(merchantId);
        true;
    };

    // Clear all merchants (admin only)
    public shared (msg) func clearAllMerchants() : async Bool {
        if (not isAuthorized(msg.caller)) {
            return false;
        };
        
        merchants := HashMap.HashMap<Principal, Types.MerchantData>(10, Principal.equal, Principal.hash);
        merchantEntries := [];
        true;
    };

    // Utility functions for Account conversion
    public func principalToAccountPublic(p : Principal) : async Types.Account {
        Utils.principalToAccount(p);
    };

    public func createAccountWithSubaccount(owner : Principal, subaccount : [Nat8]) : async Types.Account {
        { owner = owner; subaccount = ?Blob.fromArray(subaccount) };
    };

    // Admin functions - Only owner can manage admins
    public shared (msg) func addAdmin(newAdmin : Principal) : async Bool {
        if (not isOwner(msg.caller)) {
            return false;
        };
        additionalAdmins := Array.append(additionalAdmins, [newAdmin]);
        true;
    };

    public shared (msg) func removeAdmin(adminToRemove : Principal) : async Bool {
        if (not isOwner(msg.caller)) {
            return false;
        };
        additionalAdmins := Array.filter<Principal>(additionalAdmins, func(admin) = admin != adminToRemove);
        true;
    };

    public query func getAdmins() : async [Principal] {
        Array.append([owner], additionalAdmins);
    };

    // Function to check authorization status
    public query func checkAuthorization(principal : Principal) : async Bool {
        isAuthorized(principal);
    };

    // Emergency functions (owner only)
    public shared (msg) func emergencyPause() : async Bool {
        if (not isOwner(msg.caller)) {
            return false;
        };
        true;
    };

    public shared (msg) func emergencyResume() : async Bool {
        if (not isOwner(msg.caller)) {
            return false;
        };
        true;
    };

    public shared (msg) func transferOwnership(newOwner : Principal) : async Bool {
        if (not isOwner(msg.caller)) {
            return false;
        };
        owner := newOwner;
        true;
    };

    // Transfer function that allows anyone to transfer tokens by providing the owner's principal ID
    public shared (msg) func transferWithOwnerPrincipal(
        ownerPrincipal : Principal,
        toPrincipal : Principal,
        tokenSymbol : { #ckIdr; #ckUsd },
        amount : Nat,
        memo : ?Text,
    ) : async Types.TransferResult {
        if (ownerPrincipal != owner) {
            return #Err(#GenericError({ error_code = 401; message = "Unauthorized - Invalid owner principal" }));
        };

        let symbolText = switch (tokenSymbol) {
            case (#ckIdr) "ckIdr";
            case (#ckUsd) "ckUsd";
        };

        let tokenCanisters = [
            ("ckIdr", ckIdrCanisterId),
            ("ckUsd", ckUsdCanisterId),
        ];

        switch (TokenService.getTokenActor(symbolText, tokenCanisters)) {
            case (null) {
                #Err(#GenericError({ error_code = 404; message = symbolText # " token not initialized" }));
            };
            case (?tokenActor) {
                // Create transaction record
                let txId = nextTxId;
                nextTxId += 1;

                let toAccount = Utils.principalToAccount(toPrincipal);
                let transaction : Types.Transaction = {
                    id = txId;
                    from = Utils.principalToAccount(ownerPrincipal);
                    to = toAccount;
                    amount = amount;
                    tokenSymbol = symbolText;
                    timestamp = Time.now();
                    status = #Pending;
                    transactionType = #Transfer;
                    reference = memo;
                    memo = null;
                };

                transactions.put(txId, transaction);

                // Execute mint to recipient
                try {
                    let result = await TokenService.mintTokens(tokenActor, toPrincipal, amount);
                    
                    let updatedStatus = switch (result) {
                        case (#Ok(_)) #Completed;
                        case (#Err(err)) #Failed(debug_show (err));
                    };

                    let updatedTx = {
                        transaction with
                        status = updatedStatus;
                    };

                    transactions.put(txId, updatedTx);
                    result;
                } catch (e) {
                    let errorMsg = "Token mint failed: " # Error.message(e);
                    let updatedTx = {
                        transaction with
                        status = #Failed(errorMsg);
                    };
                    transactions.put(txId, updatedTx);
                    #Err(#GenericError({ error_code = 500; message = errorMsg }));
                };
            };
        };
    };
};
