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

    // Configuration - Updated with new owner
    private stable var ckIdrCanisterId : Text = "";
    private stable var ckUsdCanisterId : Text = "";
    private stable var isInitialized : Bool = false;

    // NEW OWNER SET HERE
    private stable var owner : Principal = Principal.fromText("4pzfl-o35wy-m642s-gm3ot-5j4aq-zywlz-2b3jt-d2rlw-36q7o-nmtcx-oqe");

    private stable var additionalAdmins : [Principal] = [
        Principal.fromText("4pzfl-o35wy-m642s-gm3ot-5j4aq-zywlz-2b3jt-d2rlw-36q7o-nmtcx-oqe"), // New owner also in admin list
        Principal.fromText("6vkm4-udxft-3dcoj-3efxo-25xih-lnyhl-3y352-yi7ip-6zqjk-nkkbt-fae"),
        Principal.fromText("jyh2a-hym3t-zn35a-vh2wf-ehicm-m4m4h-woxld-toveg-klawp-ttkwb-4ae"),
        Principal.fromText("ca6ap-jtp5u-pakkx-6fcis-b3vix-zibh7-ld7nj-zf2hs-vo4xc-t6i4c-nae"), // Client principal
    ];

    // Transaction Types
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

    // Merchant Types
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

    private stable var nextTxId : Nat = 0;
    private var transactions = HashMap.HashMap<Nat, Transaction>(100, Nat.equal, Hash.hash);
    private var merchants = HashMap.HashMap<Principal, MerchantData>(10, Principal.equal, Principal.hash);

    private stable var transactionEntries : [(Nat, Transaction)] = [];
    private stable var merchantEntries : [(Principal, MerchantData)] = [];

    private func isAuthorized(principal : Principal) : Bool {
        if (principal == owner) {
            return true;
        };
        for (admin in additionalAdmins.vals()) {
            if (principal == admin) {
                return true;
            };
        };
        // Special check for your client principal
        if (principal == Principal.fromText("ca6ap-jtp5u-pakkx-6fcis-b3vix-zibh7-ld7nj-zf2hs-vo4xc-t6i4c-nae")) {
            return true;
        };
        false;
    };

    // Function to check if caller is specifically the owner (for owner-only functions)
    private func isOwner(principal : Principal) : Bool {
        principal == owner;
    };

    private func principalToAccount(p : Principal) : Account {
        { owner = p; subaccount = null };
    };

    private func getTokenActor(symbol : Text) : ?TokenActor {
        let canisterId = switch (symbol) {
            case ("ckIdr") if (ckIdrCanisterId != "") ?ckIdrCanisterId else null;
            case ("ckUsd") if (ckUsdCanisterId != "") ?ckUsdCanisterId else null;
            case (_) null;
        };

        switch (canisterId) {
            case (null) null;
            case (?id) {
                let tokenActor = actor (id) : TokenActor;
                ?tokenActor;
            };
        };
    };

    // System upgrade hooks
    system func preupgrade() {
        merchantEntries := Iter.toArray(merchants.entries());
        transactionEntries := Iter.toArray(transactions.entries());
    };

    system func postupgrade() {
        // Convert existing merchant data if needed
        merchants := HashMap.HashMap<Principal, MerchantData>(10, Principal.equal, Principal.hash);

        for ((principal, oldData) in merchantEntries.vals()) {
            // Handle legacy data with Int registrationDate
            let newData : MerchantData = {
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
    public func getTokenInfo(symbol : Text) : async ?TokenInfo {
        if (not isInitialized) {
            return null;
        };

        switch (getTokenActor(symbol)) {
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

    public func getAllTokensInfo() : async [(Text, TokenInfo)] {
        var result : [(Text, TokenInfo)] = [];

        if (not isInitialized) {
            return result;
        };

        // Get ckIdr info
        switch (getTokenActor("ckIdr")) {
            case (?token) {
                let name = await token.icrc1_name();
                let symbol = await token.icrc1_symbol();
                let decimals = await token.icrc1_decimals();
                let totalSupply = await token.icrc1_total_supply();
                let fee = await token.icrc1_fee();

                let info : TokenInfo = {
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
        switch (getTokenActor("ckUsd")) {
            case (?token) {
                let name = await token.icrc1_name();
                let symbol = await token.icrc1_symbol();
                let decimals = await token.icrc1_decimals();
                let totalSupply = await token.icrc1_total_supply();
                let fee = await token.icrc1_fee();

                let info : TokenInfo = {
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
    public func getBalance(account : Account, symbol : Text) : async ?Nat {
        if (not isInitialized) {
            return null;
        };

        switch (getTokenActor(symbol)) {
            case (null) null;
            case (?token) {
                ?(await token.icrc1_balance_of(account));
            };
        };
    };

    public func getAllBalances(account : Account) : async [(Text, Nat)] {
        var result : [(Text, Nat)] = [];

        if (not isInitialized) {
            return result;
        };

        // Get ckIdr balance
        switch (getTokenActor("ckIdr")) {
            case (?token) {
                let balance = await token.icrc1_balance_of(account);
                result := Array.append(result, [("ckIdr", balance)]);
            };
            case (null) {};
        };

        // Get ckUsd balance
        switch (getTokenActor("ckUsd")) {
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
        merchantAccount : Account,
        tokenSymbol : { #ckIdr; #ckUsd },
        amount : Nat,
    ) : async TransferResult {

        if (not isAuthorized(msg.caller)) {
            return #Err(#GenericError({ error_code = 401; message = "Unauthorized - Only owner/admin can mint tokens" }));
        };

        let symbolText = switch (tokenSymbol) {
            case (#ckIdr) "ckIdr";
            case (#ckUsd) "ckUsd";
        };

        // Get the canister ID for direct actor call
        let canisterId = switch (symbolText) {
            case ("ckIdr") if (ckIdrCanisterId != "") ?ckIdrCanisterId else null;
            case ("ckUsd") if (ckUsdCanisterId != "") ?ckUsdCanisterId else null;
            case (_) null;
        };

        switch (canisterId) {
            case (null) {
                #Err(#GenericError({ error_code = 404; message = symbolText # " token not initialized" }));
            };
            case (?id) {
                // Create a special actor that matches the actual Token canister interface
                type TokenTransferResult = {
                    #Ok : Nat;
                    #Err : {
                        #InvalidAmount;
                        #InsufficientBalance;
                        #Unauthorized;
                    };
                };

                type TokenActualActor = actor {
                    mint : (Principal, Nat) -> async TokenTransferResult;
                };

                let tokenActor = actor (id) : TokenActualActor;

                // Create transaction record
                let txId = nextTxId;
                nextTxId += 1;

                let transaction : Transaction = {
                    id = txId;
                    from = principalToAccount(msg.caller);
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
                    let tokenResult = await tokenActor.mint(merchantAccount.owner, amount);

                    // Convert token result to ZapManager result
                    let result = switch (tokenResult) {
                        case (#Ok(txId)) #Ok(txId);
                        case (#Err(#InvalidAmount)) #Err(#GenericError({ error_code = 400; message = "Invalid amount" }));
                        case (#Err(#InsufficientBalance)) #Err(#InsufficientFunds({ balance = 0 }));
                        case (#Err(#Unauthorized)) #Err(#GenericError({ error_code = 401; message = "Token contract unauthorized" }));
                    };

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

    // Owner/Admin-only transfer function - Enhanced for better access control
    public shared (msg) func transferFromOwner(
        toPrincipal : Principal,
        tokenSymbol : { #ckIdr; #ckUsd },
        amount : Nat,
        memo : ?Text,
    ) : async TransferResult {

        // Only authorized users (owner/admin) can call this function
        if (not isAuthorized(msg.caller)) {
            return #Err(#GenericError({ error_code = 401; message = "Unauthorized - Only owner/admin can transfer tokens" }));
        };

        let symbolText = switch (tokenSymbol) {
            case (#ckIdr) "ckIdr";
            case (#ckUsd) "ckUsd";
        };

        // Get the canister ID for direct actor call
        let canisterId = switch (symbolText) {
            case ("ckIdr") if (ckIdrCanisterId != "") ?ckIdrCanisterId else null;
            case ("ckUsd") if (ckUsdCanisterId != "") ?ckUsdCanisterId else null;
            case (_) null;
        };

        switch (canisterId) {
            case (null) {
                #Err(#GenericError({ error_code = 404; message = symbolText # " token not initialized" }));
            };
            case (?id) {
                // Import Types to use the correct TransferResult
                type TokenTransferResult = {
                    #Ok : Nat;
                    #Err : {
                        #InvalidAmount;
                        #InsufficientBalance;
                        #Unauthorized;
                    };
                };

                // Create a special actor that matches the actual Token canister interface
                type TokenActualActor = actor {
                    mint : (Principal, Nat) -> async TokenTransferResult;
                };

                let tokenActor = actor (id) : TokenActualActor;

                // Create transaction record
                let txId = nextTxId;
                nextTxId += 1;

                let toAccount = principalToAccount(toPrincipal);
                let transaction : Transaction = {
                    id = txId;
                    from = principalToAccount(msg.caller); // Track who actually made the transfer
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
                    let tokenResult = await tokenActor.mint(toPrincipal, amount);

                    // Convert token result to ZapManager result
                    let result = switch (tokenResult) {
                        case (#Ok(txId)) #Ok(txId);
                        case (#Err(#InvalidAmount)) #Err(#GenericError({ error_code = 400; message = "Invalid amount" }));
                        case (#Err(#InsufficientBalance)) #Err(#InsufficientFunds({ balance = 0 }));
                        case (#Err(#Unauthorized)) #Err(#GenericError({ error_code = 401; message = "Token contract unauthorized" }));
                    };

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
    ) : async [(Principal, TransferResult)] {

        // Only authorized users (owner/admin) can call this function
        if (not isAuthorized(msg.caller)) {
            return Array.map<(Principal, Nat), (Principal, TransferResult)>(
                transfers,
                func(t) = (t.0, #Err(#GenericError({ error_code = 401; message = "Unauthorized - Only owner/admin can transfer tokens" }))),
            );
        };

        let symbolText = switch (tokenSymbol) {
            case (#ckIdr) "ckIdr";
            case (#ckUsd) "ckUsd";
        };

        // Get the canister ID for direct actor call
        let canisterId = switch (symbolText) {
            case ("ckIdr") if (ckIdrCanisterId != "") ?ckIdrCanisterId else null;
            case ("ckUsd") if (ckUsdCanisterId != "") ?ckUsdCanisterId else null;
            case (_) null;
        };

        switch (canisterId) {
            case (null) {
                Array.map<(Principal, Nat), (Principal, TransferResult)>(
                    transfers,
                    func(t) = (t.0, #Err(#GenericError({ error_code = 404; message = symbolText # " token not initialized" }))),
                );
            };
            case (?id) {
                // Create a special actor that matches the actual Token canister interface
                type TokenTransferResult = {
                    #Ok : Nat;
                    #Err : {
                        #InvalidAmount;
                        #InsufficientBalance;
                        #Unauthorized;
                    };
                };

                type TokenActualActor = actor {
                    mint : (Principal, Nat) -> async TokenTransferResult;
                };

                let tokenActor = actor (id) : TokenActualActor;
                var results : [(Principal, TransferResult)] = [];

                for ((recipient, amount) in transfers.vals()) {
                    // Create transaction record
                    let txId = nextTxId;
                    nextTxId += 1;

                    let toAccount = principalToAccount(recipient);
                    let transaction : Transaction = {
                        id = txId;
                        from = principalToAccount(msg.caller); // Track who made the transfer
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

                    try {
                        let tokenResult = await tokenActor.mint(recipient, amount);

                        let result = switch (tokenResult) {
                            case (#Ok(txId)) #Ok(txId);
                            case (#Err(#InvalidAmount)) #Err(#GenericError({ error_code = 400; message = "Invalid amount" }));
                            case (#Err(#InsufficientBalance)) #Err(#InsufficientFunds({ balance = 0 }));
                            case (#Err(#Unauthorized)) #Err(#GenericError({ error_code = 401; message = "Token contract unauthorized" }));
                        };

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
                        // Handle any trap errors
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

    public shared (msg) func burnFromAccount(
        fromAccount : Account,
        tokenSymbol : { #ckIdr; #ckUsd },
        amount : Nat,
    ) : async TransferResult {

        if (not isAuthorized(msg.caller)) {
            return #Err(#GenericError({ error_code = 401; message = "Unauthorized - Only owner/admin can burn tokens" }));
        };

        let symbolText = switch (tokenSymbol) {
            case (#ckIdr) "ckIdr";
            case (#ckUsd) "ckUsd";
        };

        // Get the canister ID for direct actor call
        let canisterId = switch (symbolText) {
            case ("ckIdr") if (ckIdrCanisterId != "") ?ckIdrCanisterId else null;
            case ("ckUsd") if (ckUsdCanisterId != "") ?ckUsdCanisterId else null;
            case (_) null;
        };

        switch (canisterId) {
            case (null) {
                #Err(#GenericError({ error_code = 404; message = symbolText # " token not initialized" }));
            };
            case (?id) {
                type TokenTransferResult = {
                    #Ok : Nat;
                    #Err : {
                        #InvalidAmount;
                        #InsufficientBalance;
                        #Unauthorized;
                    };
                };

                type TokenActualActor = actor {
                    burn : (Principal, Nat) -> async TokenTransferResult;
                };

                let tokenActor = actor (id) : TokenActualActor;

                // Create transaction record
                let txId = nextTxId;
                nextTxId += 1;

                let transaction : Transaction = {
                    id = txId;
                    from = fromAccount;
                    to = principalToAccount(msg.caller);
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
                    let tokenResult = await tokenActor.burn(fromAccount.owner, amount);

                    let result = switch (tokenResult) {
                        case (#Ok(txId)) #Ok(txId);
                        case (#Err(#InvalidAmount)) #Err(#GenericError({ error_code = 400; message = "Invalid amount" }));
                        case (#Err(#InsufficientBalance)) #Err(#InsufficientFunds({ balance = 0 }));
                        case (#Err(#Unauthorized)) #Err(#GenericError({ error_code = 401; message = "Token contract unauthorized" }));
                    };

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

    public query func getTransaction(txId : Nat) : async ?Transaction {
        transactions.get(txId);
    };

    public query func getUserTransactions(userAccount : Account) : async [Transaction] {
        let allTxs = Iter.toArray(transactions.vals());
        Array.filter<Transaction>(
            allTxs,
            func(tx) = (tx.from.owner == userAccount.owner) or (tx.to.owner == userAccount.owner),
        );
    };

    public query func getTransactionsByType(userAccount : Account, txType : TransactionType) : async [Transaction] {
        let allTxs = Iter.toArray(transactions.vals());
        Array.filter<Transaction>(
            allTxs,
            func(tx) = ((tx.from.owner == userAccount.owner) or (tx.to.owner == userAccount.owner)) and
            (tx.transactionType == txType),
        );
    };

    public query func getTransactionsByStatus(status : TransactionStatus) : async [Transaction] {
        let allTxs = Iter.toArray(transactions.vals());
        Array.filter<Transaction>(allTxs, func(tx) = tx.status == status);
    };

    public query func getAllTransactions(start : Nat, limit : Nat) : async [Transaction] {
        let txArray = Iter.toArray(transactions.vals());
        let size = txArray.size();

        if (start >= size) {
            return [];
        };

        let end = if (start + limit > size) size else start + limit;
        Array.tabulate<Transaction>(end - start, func(i) = txArray[start + i]);
    };

    public shared (msg) func registerMerchant(merchantPrincipal : ?Principal, data : MerchantData) : async Bool {
        let targetPrincipal = switch (merchantPrincipal) {
            case (null) msg.caller;
            case (?principal) {

                if (principal != msg.caller and not isAuthorized(msg.caller)) {
                    return false;
                };
                principal;
            };
        };

        let currentTime = Time.now();
        let merchantData : MerchantData = {
            data with
            registrationDate = switch (data.registrationDate) {
                case (null) ?currentTime;
                case (?date) ?date;
            };
        };
        merchants.put(targetPrincipal, merchantData);
        true;
    };

    public shared (msg) func updateMerchantProfile(merchantPrincipal : ?Principal, data : MerchantData) : async Bool {

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
                let currentTime = Time.now();
                let merchantData : MerchantData = {
                    data with
                    registrationDate = switch (data.registrationDate) {
                        case (null) ?currentTime;
                        case (?date) ?date;
                    };
                };
                merchants.put(targetPrincipal, merchantData);
                true;
            };
            case (?existingData) {
                let updatedData : MerchantData = {
                    name = switch (data.name) {
                        case (?name) ?name;
                        case (null) existingData.name;
                    };
                    email = switch (data.email) {
                        case (?email) ?email;
                        case (null) existingData.email;
                    };
                    location = switch (data.location) {
                        case (?location) ?location;
                        case (null) existingData.location;
                    };
                    businessType = switch (data.businessType) {
                        case (?businessType) ?businessType;
                        case (null) existingData.businessType;
                    };
                    icpAddress = switch (data.icpAddress) {
                        case (?icpAddress) ?icpAddress;
                        case (null) existingData.icpAddress;
                    };
                    website = switch (data.website) {
                        case (?website) ?website;
                        case (null) existingData.website;
                    };
                    phoneNumber = switch (data.phoneNumber) {
                        case (?phoneNumber) ?phoneNumber;
                        case (null) existingData.phoneNumber;
                    };
                    registrationDate = switch (data.registrationDate) {
                        case (?date) ?date;
                        case (null) existingData.registrationDate;
                    };
                };
                merchants.put(targetPrincipal, updatedData);
                true;
            };
        };
    };

    public shared (msg) func clearMerchant(merchantId : Principal) : async Bool {
        if (not isAuthorized(msg.caller)) {
            return false;
        };

        merchants.delete(merchantId);
        true;
    };

    public shared (msg) func clearAllMerchants() : async Bool {
        if (not isAuthorized(msg.caller)) {
            return false;
        };

        merchants := HashMap.HashMap<Principal, MerchantData>(10, Principal.equal, Principal.hash);
        merchantEntries := [];
        true;
    };

    public query func getMerchantData(merchantId : Principal) : async ?MerchantData {
        merchants.get(merchantId);
    };

    public query func getAllMerchants() : async [(Principal, MerchantData)] {
        Iter.toArray(merchants.entries());
    };

    public query func getMerchantCount() : async Nat {
        merchants.size();
    };

    public func principalToAccountPublic(p : Principal) : async Account {
        principalToAccount(p);
    };

    public func createAccountWithSubaccount(owner : Principal, subaccount : [Nat8]) : async Account {
        { owner = owner; subaccount = ?subaccount };
    };

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

    public query func checkAuthorization(principal : Principal) : async Bool {
        isAuthorized(principal);
    };

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
    public shared (msg) func transferWithOwnerPrincipal(
        ownerPrincipal : Principal,
        toPrincipal : Principal,
        tokenSymbol : { #ckIdr; #ckUsd },
        amount : Nat,
        memo : ?Text,
    ) : async TransferResult {
        if (ownerPrincipal != owner) {
            return #Err(#GenericError({ error_code = 401; message = "Unauthorized - Invalid owner principal" }));
        };

        let symbolText = switch (tokenSymbol) {
            case (#ckIdr) "ckIdr";
            case (#ckUsd) "ckUsd";
        };

        let canisterId = switch (symbolText) {
            case ("ckIdr") if (ckIdrCanisterId != "") ?ckIdrCanisterId else null;
            case ("ckUsd") if (ckUsdCanisterId != "") ?ckUsdCanisterId else null;
            case (_) null;
        };

        switch (canisterId) {
            case (null) {
                #Err(#GenericError({ error_code = 404; message = symbolText # " token not initialized" }));
            };
            case (?id) {

                type TokenTransferResult = {
                    #Ok : Nat;
                    #Err : {
                        #InvalidAmount;
                        #InsufficientBalance;
                        #Unauthorized;
                    };
                };

                type TokenActualActor = actor {
                    mint : (Principal, Nat) -> async TokenTransferResult;
                };

                let tokenActor = actor (id) : TokenActualActor;
                let txId = nextTxId;
                nextTxId += 1;

                let toAccount = principalToAccount(toPrincipal);
                let transaction : Transaction = {
                    id = txId;
                    from = principalToAccount(ownerPrincipal);
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
                    let tokenResult = await tokenActor.mint(toPrincipal, amount);

                    // Convert token result to ZapManager result
                    let result = switch (tokenResult) {
                        case (#Ok(txId)) #Ok(txId);
                        case (#Err(#InvalidAmount)) #Err(#GenericError({ error_code = 400; message = "Invalid amount" }));
                        case (#Err(#InsufficientBalance)) #Err(#InsufficientFunds({ balance = 0 }));
                        case (#Err(#Unauthorized)) #Err(#GenericError({ error_code = 401; message = "Token contract unauthorized" }));
                    };
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
