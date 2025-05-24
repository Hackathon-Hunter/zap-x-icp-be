import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Buffer "mo:base/Buffer";
import Principal "mo:base/Principal";
import Option "mo:base/Option";
import Time "mo:base/Time";
import Int "mo:base/Int";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Nat64 "mo:base/Nat64";
import HashMap "mo:base/HashMap";
import Iter "mo:base/Iter";

actor class Tokenmania() = this {

  // ========== TRANSACTION HISTORY TYPES ==========
  
  public type TransactionHistoryEntry = {
    tx_index : TxIndex;
    operation_type : Text; // "transfer", "mint", "burn", "approve"
    from_account : ?Account;
    to_account : ?Account;
    amount : ?Tokens;
    fee : Tokens;
    timestamp : Timestamp;
    memo : ?Memo;
  };

  public type TransactionFilter = {
    operation_type : ?Text; // Filter by specific operation
    from_time : ?Timestamp; // Start time filter
    to_time : ?Timestamp;   // End time filter
    min_amount : ?Tokens;   // Minimum amount filter
    max_amount : ?Tokens;   // Maximum amount filter
  };

  public type TransactionSummary = {
    total_transactions : Nat;
    total_transfers : Nat;
    total_mints : Nat;
    total_burns : Nat;
    total_approvals : Nat;
    total_volume : Nat;
    total_fees_paid : Nat;
  };

  // MERCHANT MANAGEMENT SYSTEM
  // Merchant data type
  public type Merchant = {
    principalId : Principal;
    name : Text;
    location : Text;
  };

  // Storage for merchants using HashMap
  private stable var merchantEntries : [(Principal, Merchant)] = [];
  private var merchants = HashMap.HashMap<Principal, Merchant>(0, Principal.equal, Principal.hash);

  // Create a new merchant
  public func createMerchant(principalId : Principal, name : Text, location : Text) : async ?Merchant {
    let newMerchant : Merchant = {
      principalId = principalId;
      name = name;
      location = location;
    };

    merchants.put(principalId, newMerchant);
    ?newMerchant;
  };

  // Read a merchant by principal ID
  public query func getMerchant(principalId : Principal) : async ?Merchant {
    merchants.get(principalId);
  };

  // Get all merchants
  public query func getAllMerchants() : async [Merchant] {
    Iter.toArray(merchants.vals());
  };

  // TOKEN MANAGEMENT SYSTEM (Original ICRC code)
  // Set temporary values for the token.
  // These will be overritten when the token is created.
  stable var init : {
    initial_mints : [{
      account : { owner : Principal; subaccount : ?Blob };
      amount : Nat;
    }];
    minting_account : { owner : Principal; subaccount : ?Blob };
    token_name : Text;
    token_symbol : Text;
    decimals : Nat8;
    transfer_fee : Nat;
  } = {
    initial_mints = [];
    minting_account = {
      owner = Principal.fromBlob("\04");
      subaccount = null;
    };
    token_name = "";
    token_symbol = "";
    decimals = 0;
    transfer_fee = 0;
  };

  stable var logo : Text = "";
  stable var created : Bool = false;

  public query func token_created() : async Bool {
    created;
  };

  public shared ({ caller }) func delete_token() : async Result<Text, Text> {
    if (not created) {
      return #Err("Token not created");
    };

    if (not Principal.equal(caller, init.minting_account.owner)) {
      return #Err("Caller is not the token creator");
    };

    created := false;

    // Reset token details.
    init := {
      initial_mints = [];
      minting_account = {
        owner = Principal.fromBlob("\04");
        subaccount = null;
      };
      token_name = "";
      token_symbol = "";
      decimals = 0;
      transfer_fee = 0;
    };

    // Override the genesis txns.
    log := makeGenesisChain();

    #Ok("Token deleted");
  };

  public shared ({ caller }) func create_token({
    token_name : Text;
    token_symbol : Text;
    initial_supply : Nat;
    token_logo : Text;
  }) : async Result<Text, Text> {
    if (created) {
      return #Err("Token already created");
    };

    if (Principal.isAnonymous(caller)) {
      return #Err("Cannot create token with anonymous principal");
    };

    // Specify actual token details, set the caller to own some inital amount.
    init := {
      initial_mints = [{
        account = {
          owner = caller;
          subaccount = null;
        };
        amount = initial_supply;
      }];
      minting_account = {
        owner = caller;
        subaccount = null;
      };
      token_name;
      token_symbol;
      decimals = 8; // Change this to the number of decimals you want to use.
      transfer_fee = 1; // Change this to the fee you want to charge for transfers.
    };

    // Set the token logo.
    logo := token_logo;

    // Override the genesis chain with new minter and initial mints.
    log := makeGenesisChain();

    created := true;

    #Ok("Token created");
  };

  // From here on, we use the reference implementation of the ICRC Ledger
  // canister from https://github.com/dfinity/ICRC-2/blob/main/ref/ICRC1.mo,
  // except where we add the token logo to the metadata.

  public type Account = { owner : Principal; subaccount : ?Subaccount };
  public type Subaccount = Blob;
  public type Tokens = Nat;
  public type Memo = Blob;
  public type Timestamp = Nat64;
  public type Duration = Nat64;
  public type TxIndex = Nat;
  public type TxLog = Buffer.Buffer<Transaction>;

  public type Value = { #Nat : Nat; #Int : Int; #Blob : Blob; #Text : Text };

  let maxMemoSize = 32;
  let permittedDriftNanos : Duration = 60_000_000_000;
  let transactionWindowNanos : Duration = 24 * 60 * 60 * 1_000_000_000;
  let defaultSubaccount : Subaccount = Blob.fromArrayMut(Array.init(32, 0 : Nat8));

  public type Operation = {
    #Approve : Approve;
    #Transfer : Transfer;
    #Burn : Transfer;
    #Mint : Transfer;
  };

  public type CommonFields = {
    memo : ?Memo;
    fee : ?Tokens;
    created_at_time : ?Timestamp;
  };

  public type Approve = CommonFields and {
    from : Account;
    spender : Account;
    amount : Nat;
    expires_at : ?Nat64;
  };

  public type TransferSource = {
    #Init;
    #Icrc1Transfer;
    #Icrc2TransferFrom;
  };

  public type Transfer = CommonFields and {
    spender : Account;
    source : TransferSource;
    to : Account;
    from : Account;
    amount : Tokens;
  };

  public type Allowance = { allowance : Nat; expires_at : ?Nat64 };

  public type Transaction = {
    operation : Operation;
    // Effective fee for this transaction.
    fee : Tokens;
    timestamp : Timestamp;
  };

  public type DeduplicationError = {
    #TooOld;
    #Duplicate : { duplicate_of : TxIndex };
    #CreatedInFuture : { ledger_time : Timestamp };
  };

  public type CommonError = {
    #InsufficientFunds : { balance : Tokens };
    #BadFee : { expected_fee : Tokens };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };

  public type TransferError = DeduplicationError or CommonError or {
    #BadBurn : { min_burn_amount : Tokens };
  };

  public type ApproveError = DeduplicationError or CommonError or {
    #Expired : { ledger_time : Nat64 };
    #AllowanceChanged : { current_allowance : Nat };
  };

  public type TransferFromError = TransferError or {
    #InsufficientAllowance : { allowance : Nat };
  };

  public type Result<T, E> = { #Ok : T; #Err : E };

  // Checks whether two accounts are semantically equal.
  func accountsEqual(lhs : Account, rhs : Account) : Bool {
    let lhsSubaccount = Option.get(lhs.subaccount, defaultSubaccount);
    let rhsSubaccount = Option.get(rhs.subaccount, defaultSubaccount);

    Principal.equal(lhs.owner, rhs.owner) and Blob.equal(
      lhsSubaccount,
      rhsSubaccount,
    );
  };

  // Check if a principal is involved in an account
  func principalInAccount(principal : Principal, account : Account) : Bool {
    Principal.equal(principal, account.owner);
  };

  // FIXED: Computes the balance of the specified account properly handling underflow
  func balance(account : Account, log : TxLog) : Nat {
    var sum : Int = 0; // Use Int to handle negative values temporarily
    for (tx in log.vals()) {
      switch (tx.operation) {
        case (#Burn(args)) {
          if (accountsEqual(args.from, account)) { 
            sum -= args.amount;
          };
        };
        case (#Mint(args)) {
          if (accountsEqual(args.to, account)) { 
            sum += args.amount;
          };
        };
        case (#Transfer(args)) {
          if (accountsEqual(args.from, account)) {
            sum -= (args.amount + tx.fee);
          };
          if (accountsEqual(args.to, account)) { 
            sum += args.amount;
          };
        };
        case (#Approve(args)) {
          if (accountsEqual(args.from, account)) { 
            sum -= tx.fee;
          };
        };
      };
    };
    
    // Convert to Nat, ensuring non-negative result
    if (sum < 0) {
      0 // Return 0 if balance would be negative
    } else {
      Int.abs(sum)
    }
  };

  // Computes the total token supply.
  func totalSupply(log : TxLog) : Tokens {
    var total : Int = 0; // Use Int to handle potential negative intermediate values
    for (tx in log.vals()) {
      switch (tx.operation) {
        case (#Burn(args)) { total -= args.amount };
        case (#Mint(args)) { total += args.amount };
        case (#Transfer(_)) { total -= tx.fee };
        case (#Approve(_)) { total -= tx.fee };
      };
    };
    
    // Ensure total supply is never negative
    if (total < 0) {
      0
    } else {
      Int.abs(total)
    }
  };

  // Finds a transaction in the transaction log.
  func findTransfer(transfer : Transfer, log : TxLog) : ?TxIndex {
    var i = 0;
    for (tx in log.vals()) {
      switch (tx.operation) {
        case (#Burn(args)) { if (args == transfer) { return ?i } };
        case (#Mint(args)) { if (args == transfer) { return ?i } };
        case (#Transfer(args)) { if (args == transfer) { return ?i } };
        case (_) {};
      };
      i += 1;
    };
    null;
  };

  // Finds an approval in the transaction log.
  func findApproval(approval : Approve, log : TxLog) : ?TxIndex {
    var i = 0;
    for (tx in log.vals()) {
      switch (tx.operation) {
        case (#Approve(args)) { if (args == approval) { return ?i } };
        case (_) {};
      };
      i += 1;
    };
    null;
  };

  // Computes allowance of the spender for the specified account.
  func allowance(account : Account, spender : Account, now : Nat64) : Allowance {
    var allowance : Int = 0; // Use Int to handle potential negative values
    var lastApprovalTs : ?Nat64 = null;

    for (tx in log.vals()) {
      // Reset expired approvals, if any.
      switch (lastApprovalTs) {
        case (?expires_at) {
          if (expires_at < tx.timestamp) {
            allowance := 0;
            lastApprovalTs := null;
          };
        };
        case (null) {};
      };
      // Add pending approvals.
      switch (tx.operation) {
        case (#Approve(args)) {
          if (args.from == account and args.spender == spender) {
            allowance := args.amount;
            lastApprovalTs := args.expires_at;
          };
        };
        case (#Transfer(args)) {
          if (args.from == account and args.spender == spender) {
            if (allowance >= args.amount + tx.fee) {
              allowance -= (args.amount + tx.fee);
            } else {
              allowance := 0; // Prevent negative allowance
            };
          };
        };
        case (_) {};
      };
    };

    switch (lastApprovalTs) {
      case (?expires_at) {
        if (expires_at < now) { 
          { allowance = 0; expires_at = null } 
        } else {
          {
            allowance = Int.abs(allowance);
            expires_at = ?expires_at;
          };
        };
      };
      case (null) { 
        { 
          allowance = if (allowance < 0) 0 else Int.abs(allowance); 
          expires_at = null 
        } 
      };
    };
  };

  // Constructs the transaction log corresponding to the init argument.
  func makeGenesisChain() : TxLog {
    validateSubaccount(init.minting_account.subaccount);

    let now = Nat64.fromNat(Int.abs(Time.now()));
    let log = Buffer.Buffer<Transaction>(100);
    for ({ account; amount } in Array.vals(init.initial_mints)) {
      validateSubaccount(account.subaccount);
      let tx : Transaction = {
        operation = #Mint({
          spender = init.minting_account;
          source = #Init;
          from = init.minting_account;
          to = account;
          amount = amount;
          fee = null;
          memo = null;
          created_at_time = ?now;
        });
        fee = 0;
        timestamp = now;
      };
      log.add(tx);
    };
    log;
  };

  // Traps if the specified blob is not a valid subaccount.
  func validateSubaccount(s : ?Subaccount) {
    let subaccount = Option.get(s, defaultSubaccount);
    assert (subaccount.size() == 32);
  };

  func validateMemo(m : ?Memo) {
    switch (m) {
      case (null) {};
      case (?memo) { assert (memo.size() <= maxMemoSize) };
    };
  };

  func checkTxTime(created_at_time : ?Timestamp, now : Timestamp) : Result<(), DeduplicationError> {
    let txTime : Timestamp = Option.get(created_at_time, now);

    if ((txTime > now) and (txTime - now > permittedDriftNanos)) {
      return #Err(#CreatedInFuture { ledger_time = now });
    };

    if ((txTime < now) and (now - txTime > transactionWindowNanos + permittedDriftNanos)) {
      return #Err(#TooOld);
    };

    #Ok(());
  };

  // The list of all transactions.
  var log : TxLog = makeGenesisChain();

  // The stable representation of the transaction log.
  // Used only during upgrades.
  stable var persistedLog : [Transaction] = [];

  // Initialize merchants from stable storage for upgrades
  system func preupgrade() {
    persistedLog := Buffer.toArray(log);
    merchantEntries := Iter.toArray(merchants.entries());
  };

  system func postupgrade() {
    log := Buffer.Buffer(persistedLog.size());
    for (tx in Array.vals(persistedLog)) {
      log.add(tx);
    };

    merchants := HashMap.fromIter<Principal, Merchant>(
      merchantEntries.vals(),
      merchantEntries.size(),
      Principal.equal,
      Principal.hash,
    );
    merchantEntries := [];
  };

  func recordTransaction(tx : Transaction) : TxIndex {
    let idx = log.size();
    log.add(tx);
    idx;
  };

  func classifyTransfer(log : TxLog, transfer : Transfer) : Result<(Operation, Tokens), TransferError> {
    let minter = init.minting_account;

    if (Option.isSome(transfer.created_at_time)) {
      switch (findTransfer(transfer, log)) {
        case (?txid) { return #Err(#Duplicate { duplicate_of = txid }) };
        case null {};
      };
    };

    let result = if (accountsEqual(transfer.from, minter)) {
      if (Option.get(transfer.fee, 0) != 0) {
        return #Err(#BadFee { expected_fee = 0 });
      };
      (#Mint(transfer), 0);
    } else if (accountsEqual(transfer.to, minter)) {
      if (Option.get(transfer.fee, 0) != 0) {
        return #Err(#BadFee { expected_fee = 0 });
      };

      if (transfer.amount < init.transfer_fee) {
        return #Err(#BadBurn { min_burn_amount = init.transfer_fee });
      };

      let debitBalance = balance(transfer.from, log);
      if (debitBalance < transfer.amount) {
        return #Err(#InsufficientFunds { balance = debitBalance });
      };

      (#Burn(transfer), 0);
    } else {
      let effectiveFee = init.transfer_fee;
      if (Option.get(transfer.fee, effectiveFee) != effectiveFee) {
        return #Err(#BadFee { expected_fee = init.transfer_fee });
      };

      let debitBalance = balance(transfer.from, log);
      if (debitBalance < transfer.amount + effectiveFee) {
        return #Err(#InsufficientFunds { balance = debitBalance });
      };

      (#Transfer(transfer), effectiveFee);
    };
    #Ok(result);
  };

  func applyTransfer(args : Transfer) : Result<TxIndex, TransferError> {
    validateSubaccount(args.from.subaccount);
    validateSubaccount(args.to.subaccount);
    validateMemo(args.memo);

    let now = Nat64.fromNat(Int.abs(Time.now()));

    switch (checkTxTime(args.created_at_time, now)) {
      case (#Ok(_)) {};
      case (#Err(e)) { return #Err(e) };
    };

    switch (classifyTransfer(log, args)) {
      case (#Ok((operation, effectiveFee))) {
        #Ok(recordTransaction({ operation = operation; fee = effectiveFee; timestamp = now }));
      };
      case (#Err(e)) { #Err(e) };
    };
  };

  func overflowOk(x : Nat) : Nat {
    x;
  };

  public shared ({ caller }) func icrc2_transfer({
    from_subaccount : ?Subaccount;
    to : Account;
    amount : Tokens;
    fee : ?Tokens;
    memo : ?Memo;
    created_at_time : ?Timestamp;
  }) : async Result<TxIndex, TransferError> {
    let from = {
      owner = caller;
      subaccount = from_subaccount;
    };
    applyTransfer({
      spender = from;
      source = #Icrc1Transfer;
      from = from;
      to = to;
      amount = amount;
      fee = fee;
      memo = memo;
      created_at_time = created_at_time;
    });
  };

  public query func icrc2_balance_of(account : Account) : async Tokens {
    balance(account, log);
  };

  public query func icrc2_total_supply() : async Tokens {
    totalSupply(log);
  };

  public query func icrc2_minting_account() : async ?Account {
    ?init.minting_account;
  };

  public query func icrc2_name() : async Text {
    init.token_name;
  };

  public query func icrc2_symbol() : async Text {
    init.token_symbol;
  };

  public query func icrc2_decimals() : async Nat8 {
    init.decimals;
  };

  public query func icrc2_fee() : async Nat {
    init.transfer_fee;
  };

  public query func icrc2_metadata() : async [(Text, Value)] {
    [
      ("icrc2:name", #Text(init.token_name)),
      ("icrc2:symbol", #Text(init.token_symbol)),
      ("icrc2:decimals", #Nat(Nat8.toNat(init.decimals))),
      ("icrc2:fee", #Nat(init.transfer_fee)),
      ("icrc2:logo", #Text(logo)),
    ];
  };

  public query func icrc2_supported_standards() : async [{
    name : Text;
    url : Text;
  }] {
    [
      {
        name = "ICRC-2";
        url = "https://github.com/dfinity/ICRC-2/tree/main/standards/ICRC-2";
      },
      {
        name = "ICRC-2";
        url = "https://github.com/dfinity/ICRC-2/tree/main/standards/ICRC-2";
      },
    ];
  };

  public shared ({ caller }) func icrc2_approve({
    from_subaccount : ?Subaccount;
    spender : Account;
    amount : Nat;
    expires_at : ?Nat64;
    expected_allowance : ?Nat;
    memo : ?Memo;
    fee : ?Tokens;
    created_at_time : ?Timestamp;
  }) : async Result<TxIndex, ApproveError> {
    validateSubaccount(from_subaccount);
    validateMemo(memo);

    let now = Nat64.fromNat(Int.abs(Time.now()));

    switch (checkTxTime(created_at_time, now)) {
      case (#Ok(_)) {};
      case (#Err(e)) { return #Err(e) };
    };

    let approverAccount = { owner = caller; subaccount = from_subaccount };
    let approval = {
      from = approverAccount;
      spender = spender;
      amount = amount;
      expires_at = expires_at;
      fee = fee;
      created_at_time = created_at_time;
      memo = memo;
    };

    if (Option.isSome(created_at_time)) {
      switch (findApproval(approval, log)) {
        case (?txid) { return #Err(#Duplicate { duplicate_of = txid }) };
        case (null) {};
      };
    };

    switch (expires_at) {
      case (?expires_at) {
        if (expires_at < now) { return #Err(#Expired { ledger_time = now }) };
      };
      case (null) {};
    };

    let effectiveFee = init.transfer_fee;

    if (Option.get(fee, effectiveFee) != effectiveFee) {
      return #Err(#BadFee({ expected_fee = effectiveFee }));
    };

    switch (expected_allowance) {
      case (?expected_allowance) {
        let currentAllowance = allowance(approverAccount, spender, now);
        if (currentAllowance.allowance != expected_allowance) {
          return #Err(#AllowanceChanged({ current_allowance = currentAllowance.allowance }));
        };
      };
      case (null) {};
    };

    let approverBalance = balance(approverAccount, log);
    if (approverBalance < init.transfer_fee) {
      return #Err(#InsufficientFunds { balance = approverBalance });
    };

    let txid = recordTransaction({
      operation = #Approve(approval);
      fee = effectiveFee;
      timestamp = now;
    });

    assert (balance(approverAccount, log) == overflowOk(approverBalance - effectiveFee));

    #Ok(txid);
  };

  public shared ({ caller }) func icrc2_transfer_from({
    spender_subaccount : ?Subaccount;
    from : Account;
    to : Account;
    amount : Tokens;
    fee : ?Tokens;
    memo : ?Memo;
    created_at_time : ?Timestamp;
  }) : async Result<TxIndex, TransferFromError> {
    validateSubaccount(spender_subaccount);
    validateSubaccount(from.subaccount);
    validateSubaccount(to.subaccount);
    validateMemo(memo);

    let spender = { owner = caller; subaccount = spender_subaccount };
    let transfer : Transfer = {
      spender = spender;
      source = #Icrc2TransferFrom;
      from = from;
      to = to;
      amount = amount;
      fee = fee;
      memo = memo;
      created_at_time = created_at_time;
    };

    if (caller == from.owner) {
      return applyTransfer(transfer);
    };

    let now = Nat64.fromNat(Int.abs(Time.now()));

    switch (checkTxTime(created_at_time, now)) {
      case (#Ok(_)) {};
      case (#Err(e)) { return #Err(e) };
    };

    let (operation, effectiveFee) = switch (classifyTransfer(log, transfer)) {
      case (#Ok(result)) { result };
      case (#Err(err)) { return #Err(err) };
    };

    let preTransferAllowance = allowance(from, spender, now);
    if (preTransferAllowance.allowance < amount + effectiveFee) {
      return #Err(#InsufficientAllowance { allowance = preTransferAllowance.allowance });
    };

    let txid = recordTransaction({
      operation = operation;
      fee = effectiveFee;
      timestamp = now;
    });

    let postTransferAllowance = allowance(from, spender, now);
    assert (postTransferAllowance.allowance == overflowOk(preTransferAllowance.allowance - (amount + effectiveFee)));

    #Ok(txid);
  };

  public query func icrc2_allowance({ account : Account; spender : Account }) : async Allowance {
    allowance(account, spender, Nat64.fromNat(Int.abs(Time.now())));
  };

  // ========== TRANSACTION HISTORY FUNCTIONS ==========

  // Get transaction history for a specific principal with pagination
  public query func getTransactionHistoryByPrincipal(
    principal : Principal, 
    start : ?TxIndex, 
    limit : ?Nat
  ) : async {
    transactions : [TransactionHistoryEntry];
    total_count : Nat;
  } {
    let startIndex = Option.get(start, 0);
    let maxLimit = Option.get(limit, 100);
    let actualLimit = if (maxLimit > 1000) 1000 else maxLimit;
    
    let buffer = Buffer.Buffer<TransactionHistoryEntry>(actualLimit);
    var count = 0;
    var totalMatches = 0;
    
    var i = startIndex;
    while (i < log.size() and count < actualLimit) {
      let tx = log.get(i);
      var isRelevant = false;
      var fromAccount : ?Account = null;
      var toAccount : ?Account = null;
      var amount : ?Tokens = null;
      var operationType = "";
      
      switch (tx.operation) {
        case (#Transfer(args)) {
          if (principalInAccount(principal, args.from) or principalInAccount(principal, args.to)) {
            isRelevant := true;
            fromAccount := ?args.from;
            toAccount := ?args.to;
            amount := ?args.amount;
            operationType := "transfer";
          };
        };
        case (#Mint(args)) {
          if (principalInAccount(principal, args.to)) {
            isRelevant := true;
            fromAccount := ?args.from;
            toAccount := ?args.to;
            amount := ?args.amount;
            operationType := "mint";
          };
        };
        case (#Burn(args)) {
          if (principalInAccount(principal, args.from)) {
            isRelevant := true;
            fromAccount := ?args.from;
            toAccount := ?args.to;
            amount := ?args.amount;
            operationType := "burn";
          };
        };
        case (#Approve(args)) {
          if (principalInAccount(principal, args.from) or principalInAccount(principal, args.spender)) {
            isRelevant := true;
            fromAccount := ?args.from;
            toAccount := ?args.spender;
            amount := ?args.amount;
            operationType := "approve";
          };
        };
      };
      
      if (isRelevant) {
        totalMatches += 1;
        let entry : TransactionHistoryEntry = {
          tx_index = i;
          operation_type = operationType;
          from_account = fromAccount;
          to_account = toAccount;
          amount = amount;
          fee = tx.fee;
          timestamp = tx.timestamp;
          memo = switch (tx.operation) {
            case (#Transfer(args)) args.memo;
            case (#Mint(args)) args.memo;
            case (#Burn(args)) args.memo;
            case (#Approve(args)) args.memo;
          };
        };
        buffer.add(entry);
        count += 1;
      };
      i += 1;
    };
    
    {
      transactions = Buffer.toArray(buffer);
      total_count = totalMatches;
    };
  };

  // Get balance for a principal (uses default subaccount)
  public query func getBalanceByPrincipal(principal : Principal) : async Tokens {
    let account : Account = {
      owner = principal;
      subaccount = null;
    };
    balance(account, log);
  };

  // Get transaction summary for a principal
  public query func getTransactionSummaryByPrincipal(principal : Principal) : async TransactionSummary {
    var totalTransactions = 0;
    var totalTransfers = 0;
    var totalMints = 0;
    var totalBurns = 0;
    var totalApprovals = 0;
    var totalVolume = 0;
    var totalFeesPaid = 0;
    
    for (tx in log.vals()) {
      var isRelevant = false;
      var amount : Nat = 0;
      
      switch (tx.operation) {
        case (#Transfer(args)) {
          if (principalInAccount(principal, args.from) or principalInAccount(principal, args.to)) {
            isRelevant := true;
            totalTransfers += 1;
            amount := args.amount;
            if (principalInAccount(principal, args.from)) {
              totalFeesPaid += tx.fee;
            };
          };
        };
        case (#Mint(args)) {
          if (principalInAccount(principal, args.to)) {
            isRelevant := true;
            totalMints += 1;
            amount := args.amount;
          };
        };
        case (#Burn(args)) {
          if (principalInAccount(principal, args.from)) {
            isRelevant := true;
            totalBurns += 1;
            amount := args.amount;
          };
        };
        case (#Approve(args)) {
          if (principalInAccount(principal, args.from) or principalInAccount(principal, args.spender)) {
            isRelevant := true;
            totalApprovals += 1;
            amount := args.amount;
            if (principalInAccount(principal, args.from)) {
              totalFeesPaid += tx.fee;
            };
          };
        };
      };
      
      if (isRelevant) {
        totalTransactions += 1;
        totalVolume += amount;
      };
    };
    
    {
      total_transactions = totalTransactions;
      total_transfers = totalTransfers;
      total_mints = totalMints;
      total_burns = totalBurns;
      total_approvals = totalApprovals;
      total_volume = totalVolume;
      total_fees_paid = totalFeesPaid;
    };
  };

  // Get filtered transaction history for a principal
  public query func getFilteredTransactionHistory(
    principal : Principal,
    filter : TransactionFilter,
    start : ?TxIndex,
    limit : ?Nat
  ) : async {
    transactions : [TransactionHistoryEntry];
    total_count : Nat;
  } {
    let startIndex = Option.get(start, 0);
    let maxLimit = Option.get(limit, 100);
    let actualLimit = if (maxLimit > 1000) 1000 else maxLimit;
    
    let buffer = Buffer.Buffer<TransactionHistoryEntry>(actualLimit);
    var count = 0;
    var totalMatches = 0;
    
    var i = startIndex;
    while (i < log.size() and count < actualLimit) {
      let tx = log.get(i);
      var isRelevant = false;
      var fromAccount : ?Account = null;
      var toAccount : ?Account = null;
      var amount : ?Tokens = null;
      var operationType = "";
      
      switch (tx.operation) {
        case (#Transfer(args)) {
          if (principalInAccount(principal, args.from) or principalInAccount(principal, args.to)) {
            isRelevant := true;
            fromAccount := ?args.from;
            toAccount := ?args.to;
            amount := ?args.amount;
            operationType := "transfer";
          };
        };
        case (#Mint(args)) {
          if (principalInAccount(principal, args.to)) {
            isRelevant := true;
            fromAccount := ?args.from;
            toAccount := ?args.to;
            amount := ?args.amount;
            operationType := "mint";
          };
        };
        case (#Burn(args)) {
          if (principalInAccount(principal, args.from)) {
            isRelevant := true;
            fromAccount := ?args.from;
            toAccount := ?args.to;
            amount := ?args.amount;
            operationType := "burn";
          };
        };
        case (#Approve(args)) {
          if (principalInAccount(principal, args.from) or principalInAccount(principal, args.spender)) {
            isRelevant := true;
            fromAccount := ?args.from;
            toAccount := ?args.spender;
            amount := ?args.amount;
            operationType := "approve";
          };
        };
      };
      
      if (isRelevant) {
        // Apply filters
        var passesFilter = true;
        
        // Filter by operation type
        switch (filter.operation_type) {
          case (?filterType) {
            if (operationType != filterType) {
              passesFilter := false;
            };
          };
          case (null) {};
        };
        
        // Filter by time range
        switch (filter.from_time) {
          case (?fromTime) {
            if (tx.timestamp < fromTime) {
              passesFilter := false;
            };
          };
          case (null) {};
        };
        
        switch (filter.to_time) {
          case (?toTime) {
            if (tx.timestamp > toTime) {
              passesFilter := false;
            };
          };
          case (null) {};
        };
        
        // Filter by amount range
        switch (amount, filter.min_amount) {
          case (?txAmount, ?minAmount) {
            if (txAmount < minAmount) {
              passesFilter := false;
            };
          };
          case (_, _) {};
        };
        
        switch (amount, filter.max_amount) {
          case (?txAmount, ?maxAmount) {
            if (txAmount > maxAmount) {
              passesFilter := false;
            };
          };
          case (_, _) {};
        };
        
        if (passesFilter) {
          totalMatches += 1;
          let entry : TransactionHistoryEntry = {
            tx_index = i;
            operation_type = operationType;
            from_account = fromAccount;
            to_account = toAccount;
            amount = amount;
            fee = tx.fee;
            timestamp = tx.timestamp;
            memo = switch (tx.operation) {
              case (#Transfer(args)) args.memo;
              case (#Mint(args)) args.memo;
              case (#Burn(args)) args.memo;
              case (#Approve(args)) args.memo;
            };
          };
          buffer.add(entry);
          count += 1;
        };
      };
      i += 1;
    };
    
    {
      transactions = Buffer.toArray(buffer);
      total_count = totalMatches;
    };
  };

  // Get all transactions for a principal (admin function with higher limits)
  public query func getAllTransactionsByPrincipal(principal : Principal) : async [TransactionHistoryEntry] {
    let buffer = Buffer.Buffer<TransactionHistoryEntry>(log.size());
    
    var i = 0;
    while (i < log.size()) {
      let tx = log.get(i);
      var isRelevant = false;
      var fromAccount : ?Account = null;
      var toAccount : ?Account = null;
      var amount : ?Tokens = null;
      var operationType = "";
      
      switch (tx.operation) {
        case (#Transfer(args)) {
          if (principalInAccount(principal, args.from) or principalInAccount(principal, args.to)) {
            isRelevant := true;
            fromAccount := ?args.from;
            toAccount := ?args.to;
            amount := ?args.amount;
            operationType := "transfer";
          };
        };
        case (#Mint(args)) {
          if (principalInAccount(principal, args.to)) {
            isRelevant := true;
            fromAccount := ?args.from;
            toAccount := ?args.to;
            amount := ?args.amount;
            operationType := "mint";
          };
        };
        case (#Burn(args)) {
          if (principalInAccount(principal, args.from)) {
            isRelevant := true;
            fromAccount := ?args.from;
            toAccount := ?args.to;
            amount := ?args.amount;
            operationType := "burn";
          };
        };
        case (#Approve(args)) {
          if (principalInAccount(principal, args.from) or principalInAccount(principal, args.spender)) {
            isRelevant := true;
            fromAccount := ?args.from;
            toAccount := ?args.spender;
            amount := ?args.amount;
            operationType := "approve";
          };
        };
      };
      
      if (isRelevant) {
        let entry : TransactionHistoryEntry = {
          tx_index = i;
          operation_type = operationType;
          from_account = fromAccount;
          to_account = toAccount;
          amount = amount;
          fee = tx.fee;
          timestamp = tx.timestamp;
          memo = switch (tx.operation) {
            case (#Transfer(args)) args.memo;
            case (#Mint(args)) args.memo;
            case (#Burn(args)) args.memo;
            case (#Approve(args)) args.memo;
          };
        };
        buffer.add(entry);
      };
      i += 1;
    };
    
    Buffer.toArray(buffer);
  };

  // Get transaction by index
  public query func getTransaction(txIndex : TxIndex) : async ?TransactionHistoryEntry {
    if (txIndex >= log.size()) {
      return null;
    };
    
    let tx = log.get(txIndex);
    var fromAccount : ?Account = null;
    var toAccount : ?Account = null;
    var amount : ?Tokens = null;
    var operationType = "";
    
    switch (tx.operation) {
      case (#Transfer(args)) {
        fromAccount := ?args.from;
        toAccount := ?args.to;
        amount := ?args.amount;
        operationType := "transfer";
      };
      case (#Mint(args)) {
        fromAccount := ?args.from;
        toAccount := ?args.to;
        amount := ?args.amount;
        operationType := "mint";
      };
      case (#Burn(args)) {
        fromAccount := ?args.from;
        toAccount := ?args.to;
        amount := ?args.amount;
        operationType := "burn";
      };
      case (#Approve(args)) {
        fromAccount := ?args.from;
        toAccount := ?args.spender;
        amount := ?args.amount;
        operationType := "approve";
      };
    };
    
    ?{
      tx_index = txIndex;
      operation_type = operationType;
      from_account = fromAccount;
      to_account = toAccount;
      amount = amount;
      fee = tx.fee;
      timestamp = tx.timestamp;
      memo = switch (tx.operation) {
        case (#Transfer(args)) args.memo;
        case (#Mint(args)) args.memo;
        case (#Burn(args)) args.memo;
        case (#Approve(args)) args.memo;
      };
    };
  };

  // Get latest transactions for a principal
  public query func getLatestTransactionsByPrincipal(principal : Principal, limit : ?Nat) : async [TransactionHistoryEntry] {
    let maxLimit = Option.get(limit, 10);
    let actualLimit = if (maxLimit > 100) 100 else maxLimit;
    
    let buffer = Buffer.Buffer<TransactionHistoryEntry>(actualLimit);
    
    // Start from the latest transactions and work backwards
    if (log.size() == 0) {
      return Buffer.toArray(buffer);
    };
    
    var i = log.size() - 1;
    var count = 0;
    
    label loopLabel loop {
      let tx = log.get(i);
      var isRelevant = false;
      var fromAccount : ?Account = null;
      var toAccount : ?Account = null;
      var amount : ?Tokens = null;
      var operationType = "";
      
      switch (tx.operation) {
        case (#Transfer(args)) {
          if (principalInAccount(principal, args.from) or principalInAccount(principal, args.to)) {
            isRelevant := true;
            fromAccount := ?args.from;
            toAccount := ?args.to;
            amount := ?args.amount;
            operationType := "transfer";
          };
        };
        case (#Mint(args)) {
          if (principalInAccount(principal, args.to)) {
            isRelevant := true;
            fromAccount := ?args.from;
            toAccount := ?args.to;
            amount := ?args.amount;
            operationType := "mint";
          };
        };
        case (#Burn(args)) {
          if (principalInAccount(principal, args.from)) {
            isRelevant := true;
            fromAccount := ?args.from;
            toAccount := ?args.to;
            amount := ?args.amount;
            operationType := "burn";
          };
        };
        case (#Approve(args)) {
          if (principalInAccount(principal, args.from) or principalInAccount(principal, args.spender)) {
            isRelevant := true;
            fromAccount := ?args.from;
            toAccount := ?args.spender;
            amount := ?args.amount;
            operationType := "approve";
          };
        };
      };
      
      if (isRelevant) {
        let entry : TransactionHistoryEntry = {
          tx_index = i;
          operation_type = operationType;
          from_account = fromAccount;
          to_account = toAccount;
          amount = amount;
          fee = tx.fee;
          timestamp = tx.timestamp;
          memo = switch (tx.operation) {
            case (#Transfer(args)) args.memo;
            case (#Mint(args)) args.memo;
            case (#Burn(args)) args.memo;
            case (#Approve(args)) args.memo;
          };
        };
        buffer.add(entry);
        count += 1;
        if (count >= actualLimit) break loopLabel;
      };
      
      if (i == 0) break loopLabel;
      i -= 1;
    };
    
    // Reverse the buffer to get chronological order (oldest first)
    let result = Buffer.toArray(buffer);
    Array.reverse(result);
  };

  // Get transactions by time range for a principal
  public query func getTransactionsByTimeRange(
    principal : Principal,
    fromTime : Timestamp,
    toTime : Timestamp,
    start : ?TxIndex,
    limit : ?Nat
  ) : async {
    transactions : [TransactionHistoryEntry];
    total_count : Nat;
  } {
    let startIndex = Option.get(start, 0);
    let maxLimit = Option.get(limit, 100);
    let actualLimit = if (maxLimit > 1000) 1000 else maxLimit;
    
    let buffer = Buffer.Buffer<TransactionHistoryEntry>(actualLimit);
    var count = 0;
    var totalMatches = 0;
    
    var i = startIndex;
    while (i < log.size() and count < actualLimit) {
      let tx = log.get(i);
      
      // Check if transaction is within time range
      if (tx.timestamp >= fromTime and tx.timestamp <= toTime) {
        var isRelevant = false;
        var fromAccount : ?Account = null;
        var toAccount : ?Account = null;
        var amount : ?Tokens = null;
        var operationType = "";
        
        switch (tx.operation) {
          case (#Transfer(args)) {
            if (principalInAccount(principal, args.from) or principalInAccount(principal, args.to)) {
              isRelevant := true;
              fromAccount := ?args.from;
              toAccount := ?args.to;
              amount := ?args.amount;
              operationType := "transfer";
            };
          };
          case (#Mint(args)) {
            if (principalInAccount(principal, args.to)) {
              isRelevant := true;
              fromAccount := ?args.from;
              toAccount := ?args.to;
              amount := ?args.amount;
              operationType := "mint";
            };
          };
          case (#Burn(args)) {
            if (principalInAccount(principal, args.from)) {
              isRelevant := true;
              fromAccount := ?args.from;
              toAccount := ?args.to;
              amount := ?args.amount;
              operationType := "burn";
            };
          };
          case (#Approve(args)) {
            if (principalInAccount(principal, args.from) or principalInAccount(principal, args.spender)) {
              isRelevant := true;
              fromAccount := ?args.from;
              toAccount := ?args.spender;
              amount := ?args.amount;
              operationType := "approve";
            };
          };
        };
        
        if (isRelevant) {
          totalMatches += 1;
          let entry : TransactionHistoryEntry = {
            tx_index = i;
            operation_type = operationType;
            from_account = fromAccount;
            to_account = toAccount;
            amount = amount;
            fee = tx.fee;
            timestamp = tx.timestamp;
            memo = switch (tx.operation) {
              case (#Transfer(args)) args.memo;
              case (#Mint(args)) args.memo;
              case (#Burn(args)) args.memo;
              case (#Approve(args)) args.memo;
            };
          };
          buffer.add(entry);
          count += 1;
        };
      };
      i += 1;
    };
    
    {
      transactions = Buffer.toArray(buffer);
      total_count = totalMatches;
    };
  };

  // Get merchant transaction history
  public query func getMerchantTransactionHistory(
    merchantPrincipal : Principal,
    start : ?TxIndex,
    limit : ?Nat
  ) : async ?{
    transactions : [TransactionHistoryEntry];
    total_count : Nat;
    merchant_info : Merchant;
  } {
    switch (merchants.get(merchantPrincipal)) {
      case (?merchant) {
        let startIndex = Option.get(start, 0);
        let maxLimit = Option.get(limit, 100);
        let actualLimit = if (maxLimit > 1000) 1000 else maxLimit;
        
        let buffer = Buffer.Buffer<TransactionHistoryEntry>(actualLimit);
        var count = 0;
        var totalMatches = 0;
        
        var i = startIndex;
        while (i < log.size() and count < actualLimit) {
          let tx = log.get(i);
          var isRelevant = false;
          var fromAccount : ?Account = null;
          var toAccount : ?Account = null;
          var amount : ?Tokens = null;
          var operationType = "";
          
          switch (tx.operation) {
            case (#Transfer(args)) {
              if (principalInAccount(merchantPrincipal, args.from) or principalInAccount(merchantPrincipal, args.to)) {
                isRelevant := true;
                fromAccount := ?args.from;
                toAccount := ?args.to;
                amount := ?args.amount;
                operationType := "transfer";
              };
            };
            case (#Mint(args)) {
              if (principalInAccount(merchantPrincipal, args.to)) {
                isRelevant := true;
                fromAccount := ?args.from;
                toAccount := ?args.to;
                amount := ?args.amount;
                operationType := "mint";
              };
            };
            case (#Burn(args)) {
              if (principalInAccount(merchantPrincipal, args.from)) {
                isRelevant := true;
                fromAccount := ?args.from;
                toAccount := ?args.to;
                amount := ?args.amount;
                operationType := "burn";
              };
            };
            case (#Approve(args)) {
              if (principalInAccount(merchantPrincipal, args.from) or principalInAccount(merchantPrincipal, args.spender)) {
                isRelevant := true;
                fromAccount := ?args.from;
                toAccount := ?args.spender;
                amount := ?args.amount;
                operationType := "approve";
              };
            };
          };
          
          if (isRelevant) {
            totalMatches += 1;
            let entry : TransactionHistoryEntry = {
              tx_index = i;
              operation_type = operationType;
              from_account = fromAccount;
              to_account = toAccount;
              amount = amount;
              fee = tx.fee;
              timestamp = tx.timestamp;
              memo = switch (tx.operation) {
                case (#Transfer(args)) args.memo;
                case (#Mint(args)) args.memo;
                case (#Burn(args)) args.memo;
                case (#Approve(args)) args.memo;
              };
            };
            buffer.add(entry);
            count += 1;
          };
          i += 1;
        };
        
        ?{
          transactions = Buffer.toArray(buffer);
          total_count = totalMatches;
          merchant_info = merchant;
        };
      };
      case (null) { null };
    };
  };

  // Get total transaction count
  public query func getTotalTransactionCount() : async Nat {
    log.size();
  };

  // Get platform statistics
  public query func getPlatformStats() : async {
    total_transactions : Nat;
    total_merchants : Nat;
    total_supply : Tokens;
    token_name : Text;
    token_symbol : Text;
    token_created : Bool;
  } {
    {
      total_transactions = log.size();
      total_merchants = merchants.size();
      total_supply = totalSupply(log);
      token_name = init.token_name;
      token_symbol = init.token_symbol;
      token_created = created;
    };
  };
};