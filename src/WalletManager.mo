// WalletManager.mo - Manages wallet imports for token holders
import Principal "mo:base/Principal";
import HashMap "mo:base/HashMap";
import Array "mo:base/Array";
import Iter "mo:base/Iter";
import Time "mo:base/Time";
import Nat "mo:base/Nat";
import Hash "mo:base/Hash";
import Text "mo:base/Text";
import Option "mo:base/Option";
import Result "mo:base/Result";
import Types "./Types";

actor class WalletManager(
    _owner : Principal,
    _ckIdrCanisterId : Text,
    _ckUsdCanisterId : Text
) = this {
    // Types for wallet information
    public type WalletInfo = {
        principal : Principal;
        walletCanisterId : Text;
        tokenBalances : [(Text, Nat)];
        importedAt : Int;
        lastUpdated : Int;
    };

    // State variables
    private stable let owner : Principal = _owner;
    private stable let ckIdrCanisterId : Text = _ckIdrCanisterId;
    private stable let ckUsdCanisterId : Text = _ckUsdCanisterId;

    // Wallets storage
    private var wallets = HashMap.HashMap<Principal, WalletInfo>(10, Principal.equal, Principal.hash);
    private stable var walletEntries : [(Principal, WalletInfo)] = [];

    // Minimum token balance required to import wallet
    private stable var minimumTokenBalance : Nat = 1; // Can be changed by owner

    // System upgrade hooks
    system func preupgrade() {
        walletEntries := Iter.toArray(wallets.entries());
    };

    system func postupgrade() {
        wallets := HashMap.fromIter(walletEntries.vals(), walletEntries.size(), Principal.equal, Principal.hash);
        walletEntries := [];
    };

    // Set minimum token balance required
    public shared(msg) func setMinimumTokenBalance(newMinimum : Nat) : async Bool {
        if (msg.caller != owner) {
            return false;
        };
        
        minimumTokenBalance := newMinimum;
        true;
    };

    // Check if a user has enough tokens to import wallet
    public func hasEnoughTokens(user : Principal) : async Bool {
        let ckIdrBalance = await getTokenBalance(user, ckIdrCanisterId);
        let ckUsdBalance = await getTokenBalance(user, ckUsdCanisterId);
        
        return ckIdrBalance >= minimumTokenBalance or ckUsdBalance >= minimumTokenBalance;
    };

    // Helper to get token balance
    private func getTokenBalance(user : Principal, tokenCanisterId : Text) : async Nat {
        try {
            let token : actor {
                balanceOf : (Principal) -> async Nat;
            } = actor (tokenCanisterId);
            
            await token.balanceOf(user);
        } catch (err) {
            0 // Return 0 if there's an error
        };
    };

    // Import wallet
    public shared(msg) func importWallet(walletCanisterId : Text) : async Result.Result<WalletInfo, Text> {
        // Check if user has enough tokens
        let hasTokens = await hasEnoughTokens(msg.caller);
        
        if (not hasTokens) {
            return #err("Insufficient token balance. You need at least " # Nat.toText(minimumTokenBalance) # " tokens to import a wallet.");
        };
        
        // Get token balances
        let ckIdrBalance = await getTokenBalance(msg.caller, ckIdrCanisterId);
        let ckUsdBalance = await getTokenBalance(msg.caller, ckUsdCanisterId);
        
        let tokenBalances = [
            ("CkIDr", ckIdrBalance),
            ("CkUsd", ckUsdBalance)
        ];
        
        // Create wallet info
        let walletInfo : WalletInfo = {
            principal = msg.caller;
            walletCanisterId = walletCanisterId;
            tokenBalances = tokenBalances;
            importedAt = Time.now();
            lastUpdated = Time.now();
        };
        
        wallets.put(msg.caller, walletInfo);
        
        #ok(walletInfo);
    };

    // Update wallet info (refresh token balances)
    public shared(msg) func updateWalletInfo() : async Result.Result<WalletInfo, Text> {
        switch (wallets.get(msg.caller)) {
            case null {
                return #err("Wallet not found. Please import your wallet first.");
            };
            case (?walletInfo) {
                // Get current token balances
                let ckIdrBalance = await getTokenBalance(msg.caller, ckIdrCanisterId);
                let ckUsdBalance = await getTokenBalance(msg.caller, ckUsdCanisterId);
                
                let tokenBalances = [
                    ("CkIDr", ckIdrBalance),
                    ("CkUsd", ckUsdBalance)
                ];
                
                // Update wallet info
                let updatedWalletInfo : WalletInfo = {
                    principal = walletInfo.principal;
                    walletCanisterId = walletInfo.walletCanisterId;
                    tokenBalances = tokenBalances;
                    importedAt = walletInfo.importedAt;
                    lastUpdated = Time.now();
                };
                
                wallets.put(msg.caller, updatedWalletInfo);
                
                #ok(updatedWalletInfo);
            };
        };
    };

    // Remove wallet (user can remove their own wallet)
    public shared(msg) func removeWallet() : async Bool {
        switch (wallets.get(msg.caller)) {
            case null { false };
            case (?_) {
                wallets.delete(msg.caller);
                true;
            };
        };
    };

    // Admin can remove any wallet
    public shared(msg) func adminRemoveWallet(user : Principal) : async Bool {
        if (msg.caller != owner) {
            return false;
        };
        
        switch (wallets.get(user)) {
            case null { false };
            case (?_) {
                wallets.delete(user);
                true;
            };
        };
    };

    // Query functions
    public query func getWalletInfo(user : Principal) : async ?WalletInfo {
        wallets.get(user);
    };

    public query func getMyWalletInfo(caller : Principal) : async ?WalletInfo {
        wallets.get(caller);
    };

    public query func getAllWallets() : async [(Principal, WalletInfo)] {
        Iter.toArray(wallets.entries());
    };

    public query func getMinimumTokenBalance() : async Nat {
        minimumTokenBalance;
    };
}; 