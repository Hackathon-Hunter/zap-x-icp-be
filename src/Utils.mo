// Utils.mo - Common utility functions for the Zap system

import Principal "mo:base/Principal";
import Types "Types";
import Array "mo:base/Array";
import Time "mo:base/Time";
import Option "mo:base/Option";

module {
    // Convert Principal to Account
    public func principalToAccount(p : Principal) : Types.Account {
        { owner = p; subaccount = null }
    };

    // Check if a principal is in a list of principals
    public func isPrincipalInList(principal : Principal, list : [Principal]) : Bool {
        for (item in list.vals()) {
            if (item == principal) {
                return true;
            };
        };
        false
    };

    // Merge merchant data preserving existing values
    public func mergeMerchantData(existingData : Types.MerchantData, newData : Types.MerchantData) : Types.MerchantData {
        {
            name = switch (newData.name) {
                case (?name) ?name;
                case (null) existingData.name;
            };
            email = switch (newData.email) {
                case (?email) ?email;
                case (null) existingData.email;
            };
            location = switch (newData.location) {
                case (?location) ?location;
                case (null) existingData.location;
            };
            businessType = switch (newData.businessType) {
                case (?businessType) ?businessType;
                case (null) existingData.businessType;
            };
            icpAddress = switch (newData.icpAddress) {
                case (?icpAddress) ?icpAddress;
                case (null) existingData.icpAddress;
            };
            website = switch (newData.website) {
                case (?website) ?website;
                case (null) existingData.website;
            };
            phoneNumber = switch (newData.phoneNumber) {
                case (?phoneNumber) ?phoneNumber;
                case (null) existingData.phoneNumber;
            };
            registrationDate = switch (newData.registrationDate) {
                case (?date) ?date;
                case (null) existingData.registrationDate;
            };
        }
    };

    // Create a new merchant data with defaults
    public func createMerchantData(data : Types.MerchantData) : Types.MerchantData {
        let currentTime = Time.now();
        {
            data with 
            registrationDate = switch (data.registrationDate) {
                case (null) ?currentTime;
                case (?date) ?date;
            };
        }
    };
} 