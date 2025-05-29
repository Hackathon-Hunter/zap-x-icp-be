import Principal "mo:base/Principal";
import HashMap "mo:base/HashMap";
import Array "mo:base/Array";
import Iter "mo:base/Iter";
import Time "mo:base/Time";
import Result "mo:base/Result";
import Hash "mo:base/Hash";
import Types "./Types";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Nat64 "mo:base/Nat64";
import Text "mo:base/Text";
import Blob "mo:base/Blob";
import Option "mo:base/Option";
import Error "mo:base/Error";

actor class Token(
    _name : Text,
    _symbol : Text,
    _decimals : Nat8,
    _totalSupply : Nat,
    _fee : Nat,
    _owner : Principal,
) = this {

    private stable var name : Text = _name;
    private stable var symbol : Text = _symbol;
    private stable var decimals : Nat8 = _decimals;
    private stable var totalSupply : Nat = _totalSupply;
    private stable var fee : Nat = _fee;
    private stable let owner : Principal = _owner;

    private stable let zapManagerCanisterId : Principal = Principal.fromText("3ykjv-vqaaa-aaaaj-a2beq-cai");

    private var balances = HashMap.HashMap<Principal, Nat>(10, Principal.equal, Principal.hash);

    private stable var nextTxId : Nat = 0;
    private var transactions = HashMap.HashMap<Nat, Types.Transaction>(100, Nat.equal, Hash.hash);

    public type Account = {
        owner : Principal;
        subaccount : ?Subaccount;
    };

    public type Subaccount = Blob;
    private let defaultSubaccount : Subaccount = Blob.fromArrayMut(Array.init(32, 0 : Nat8));

    public type ICRC1TransferArgs = {
        from_subaccount : ?Subaccount;
        to : Account;
        amount : Nat;
        fee : ?Nat;
        memo : ?Blob;
        created_at_time : ?Nat64;
    };

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

    private stable var balancesEntries : [(Principal, Nat)] = [];
    private stable var transactionsEntries : [(Nat, Types.Transaction)] = [];

    system func preupgrade() {
        balancesEntries := Iter.toArray(balances.entries());
        transactionsEntries := Iter.toArray(transactions.entries());
    };

    system func postupgrade() {
        balances := HashMap.fromIter(balancesEntries.vals(), balancesEntries.size(), Principal.equal, Principal.hash);
        transactions := HashMap.fromIter(transactionsEntries.vals(), transactionsEntries.size(), Nat.equal, Hash.hash);
        balancesEntries := [];
        transactionsEntries := [];
    };

    private func initOwnerBalance() {
        balances.put(owner, totalSupply);
    };

    initOwnerBalance();

    private func principalToAccount(p : Principal) : Account {
        {
            owner = p;
            subaccount = null;
        };
    };

    private func accountToKey(account : Account) : Principal {
        account.owner;
    };

    private func getBalance(account : Account) : Nat {
        let key = accountToKey(account);
        switch (balances.get(key)) {
            case null 0;
            case (?balance) balance;
        };
    };

    private func _transfer(from : Principal, to : Principal, amount : Nat) : Types.TransferResult {
        if (amount == 0) {
            return #Err(#InvalidAmount);
        };

        let fromBalance = switch (balances.get(from)) {
            case null 0;
            case (?balance) balance;
        };

        if (fromBalance < amount + fee) {
            return #Err(#InsufficientBalance);
        };

        balances.put(from, fromBalance - amount - fee);

        let toBalance = switch (balances.get(to)) {
            case null 0;
            case (?balance) balance;
        };
        balances.put(to, toBalance + amount);

        let txId = nextTxId;
        nextTxId += 1;

        let transaction : Types.Transaction = {
            id = txId;
            from = from;
            to = to;
            amount = amount;
            fee = fee;
            timestamp = Time.now();
            memo = null;
            tokenSymbol = symbol;
        };

        transactions.put(txId, transaction);

        #Ok(txId);
    };

    private func _mint(to : Principal, amount : Nat, memoText : ?Text) : Types.TransferResult {
        if (amount == 0) {
            return #Err(#InvalidAmount);
        };

        let toBalance = switch (balances.get(to)) {
            case null 0;
            case (?balance) balance;
        };

        balances.put(to, toBalance + amount);
        totalSupply += amount;

        let txId = nextTxId;
        nextTxId += 1;

        let actualMemo = switch (memoText) {
            case (null) { ?"MINT" };
            case (?text) { ?text };
        };

        let transaction : Types.Transaction = {
            id = txId;
            from = owner; // Minting from owner
            to = to;
            amount = amount;
            fee = 0; // No fee for minting
            timestamp = Time.now();
            memo = actualMemo;
            tokenSymbol = symbol;
        };

        transactions.put(txId, transaction);

        #Ok(txId);
    };

    private func _burn(from : Principal, amount : Nat, memoText : ?Text) : Types.TransferResult {
        if (amount == 0) {
            return #Err(#InvalidAmount);
        };

        let fromBalance = switch (balances.get(from)) {
            case null 0;
            case (?balance) balance;
        };

        if (fromBalance < amount) {
            return #Err(#InsufficientBalance);
        };

        balances.put(from, fromBalance - amount);
        totalSupply -= amount;

        let txId = nextTxId;
        nextTxId += 1;

        let actualMemo = switch (memoText) {
            case (null) { ?"BURN" };
            case (?text) { ?text };
        };

        let transaction : Types.Transaction = {
            id = txId;
            from = from;
            to = owner;
            amount = amount;
            fee = 0;
            timestamp = Time.now();
            memo = actualMemo;
            tokenSymbol = symbol;
        };

        transactions.put(txId, transaction);

        #Ok(txId);
    };

    public query func icrc1_name() : async Text {
        name;
    };

    public query func icrc1_symbol() : async Text {
        symbol;
    };

    public query func icrc1_decimals() : async Nat8 {
        decimals;
    };

    public query func icrc1_fee() : async Nat {
        fee;
    };

    public query func icrc1_total_supply() : async Nat {
        totalSupply;
    };

    public query func icrc1_minting_account() : async ?Account {
        ?principalToAccount(owner);
    };

    public query func icrc1_balance_of(account : Account) : async Nat {
        getBalance(account);
    };

    public shared (msg) func icrc1_transfer(args : ICRC1TransferArgs) : async Result.Result<Nat, ICRC1TransferError> {
        let fromAccount = {
            owner = msg.caller;
            subaccount = args.from_subaccount;
        };

        let fromKey = accountToKey(fromAccount);
        let toKey = accountToKey(args.to);

        let fromBalance = getBalance(fromAccount);

        if (fromBalance < args.amount + fee) {
            return #err(#InsufficientFunds { balance = fromBalance });
        };

        if (Option.isSome(args.fee) and Option.unwrap(args.fee) != fee) {
            return #err(#BadFee { expected_fee = fee });
        };

        balances.put(fromKey, fromBalance - args.amount - fee);

        let toBalance = getBalance(args.to);
        balances.put(toKey, toBalance + args.amount);

        let txId = nextTxId;
        nextTxId += 1;

        let memoText = switch (args.memo) {
            case (null) { null };
            case (?blob) {
                ?"ICRC1_TRANSFER";
            };
        };

        let transaction : Types.Transaction = {
            id = txId;
            from = fromKey;
            to = toKey;
            amount = args.amount;
            fee = fee;
            timestamp = Time.now();
            memo = memoText;
            tokenSymbol = symbol;
        };

        transactions.put(txId, transaction);

        #ok(txId);
    };

    public query func icrc1_supported_standards() : async [{
        name : Text;
        url : Text;
    }] {
        [{ name = "ICRC-1"; url = "https://github.com/dfinity/ICRC-1" }];
    };

    public query func getTokenInfo() : async Types.TokenInfo {
        {
            name = name;
            symbol = symbol;
            decimals = decimals;
            totalSupply = totalSupply;
            fee = fee;
        };
    };

    public query func balanceOf(account : Principal) : async Nat {
        switch (balances.get(account)) {
            case null 0;
            case (?balance) balance;
        };
    };

    public shared (msg) func zapManagerTransfer(to : Principal, amount : Nat, memo : ?Text) : async Types.TransferResult {
        // Verify the caller is the ZapManager canister
        if (msg.caller != zapManagerCanisterId) {
            return #Err(#Unauthorized);
        };

        _mint(to, amount, memo);
    };

    public shared (msg) func mint(to : Principal, amount : Nat) : async Types.TransferResult {

        if (
            msg.caller != owner and
            msg.caller != Principal.fromText("ca6ap-jtp5u-pakkx-6fcis-b3vix-zibh7-ld7nj-zf2hs-vo4xc-t6i4c-nae") and
            msg.caller != zapManagerCanisterId
        ) {
            return #Err(#Unauthorized);
        };

        _mint(to, amount, null);
    };

    public shared (msg) func burn(from : Principal, amount : Nat) : async Types.TransferResult {
        // Only owner can burn
        if (msg.caller != owner) {
            return #Err(#Unauthorized);
        };

        _burn(from, amount, null);
    };

    public query func getTransaction(txId : Nat) : async ?Types.Transaction {
        transactions.get(txId);
    };

    public query func getOwner() : async Principal {
        owner;
    };

    public query func isAuthorized(caller : Principal) : async Bool {
        caller == owner or caller == zapManagerCanisterId or caller == Principal.fromText("ca6ap-jtp5u-pakkx-6fcis-b3vix-zibh7-ld7nj-zf2hs-vo4xc-t6i4c-nae");
    };
};
