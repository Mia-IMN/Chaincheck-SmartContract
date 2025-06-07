module 0x0::portfolio_reader {
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::sui::SUI;
    use sui::table::{Self, Table};
    use sui::event;
    use std::vector;
    use std::string::{Self, String};
    use sui::dynamic_field as df;
    use sui::dynamic_object_field as dof;
    use sui::package;
    use sui::display;
    use sui::clock::{Self, Clock};

    // Error codes
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_INVALID_WALLET: u64 = 2;
    const E_NO_DATA_FOUND: u64 = 3;

    // To store global analytics configuration
    public struct AnalyticsRegistry has key, store {
        id: UID,
        admin: address,
        total_wallets_analyzed: u64,
        version: u64,
    }

    // Structs for wallet analytics data
    public struct WalletAnalytics has key, store {
        id: UID,
        owner: address,
        total_balance: u64,
        token_count: u64,
        nft_count: u64,
        transaction_count: u64,
        last_updated: u64,
        tokens: Table<String, TokenInfo>,
        nfts: vector<NFTInfo>,
        recent_transactions: vector<TransactionInfo>,
    }

    public struct TokenInfo has store, copy, drop {
        coin_type: String,
        symbol: String,
        balance: u64,
        decimals: u8,
        usd_value: u64,
        percentage_of_portfolio: u64,
    }

    public struct NFTInfo has store, copy, drop {
        object_id: address,
        name: String,
        description: String,
        image_url: String,
        collection: String,
        creator: address,
        traits: vector<TraitInfo>,
    }

    public struct TraitInfo has store, copy, drop {
        trait_type: String,
        value: String,
        rarity_score: u64,
    }

    public struct TransactionInfo has store, copy, drop {
        digest: String,
        transaction_type: String,
        amount: u64,
        coin_type: String,
        timestamp: u64,
        counterparty: address,
        status: String,
    }

    public struct PortfolioSummary has copy, drop {
        total_usd_value: u64,
        total_tokens: u64,
        total_nfts: u64,
        best_performing_token: String,
        worst_performing_token: String,
        portfolio_diversity_score: u64,
        risk_score: u64,
    }

    public struct StakingInfo has store, copy, drop {
        validator: address,
        staked_amount: u64,
        rewards_earned: u64,
        epoch_started: u64,
        apy: u64,
    }

    public struct LiquidityInfo has store, copy, drop {
        pool_id: address,
        token_a: String,
        token_b: String,
        liquidity_amount: u64,
        share_percentage: u64,
        fees_earned: u64,
    }

    // Events
    public struct WalletAnalyzed has copy, drop {
        wallet_address: address,
        total_value: u64,
        token_count: u64,
        nft_count: u64,
        analysis_timestamp: u64,
    }

    public struct TokenDiscovered has copy, drop {
        wallet_address: address,
        coin_type: String,
        balance: u64,
        usd_value: u64,
    }

    public struct NFTDiscovered has copy, drop {
        wallet_address: address,
        nft_id: address,
        collection: String,
        estimated_value: u64,
    }

    // Initialize function - creates shared objects that can be referenced
    fun init(ctx: &mut TxContext) {
        let registry = AnalyticsRegistry {
            id: object::new(ctx),
            admin: tx_context::sender(ctx),
            total_wallets_analyzed: 0,
            version: 1,
        };
        transfer::share_object(registry);
    }

    // Manual init function for testing/admin purposes
    public fun manual_init(ctx: &mut TxContext) {
        let registry = AnalyticsRegistry {
            id: object::new(ctx),
            admin: tx_context::sender(ctx),
            total_wallets_analyzed: 0,
            version: 1,
        };
        transfer::share_object(registry);
    }

    // Main function to analyze a wallet and create analytics
    public fun analyze_wallet(
        registry: &mut AnalyticsRegistry,
        wallet_address: address,
        clock: &Clock,
        ctx: &mut TxContext
    ): WalletAnalytics {
        let current_time = clock::timestamp_ms(clock);
        
        let mut analytics = WalletAnalytics {
            id: object::new(ctx),
            owner: wallet_address,
            total_balance: 0,
            token_count: 0,
            nft_count: 0,
            transaction_count: 0,
            last_updated: current_time,
            tokens: table::new(ctx),
            nfts: vector::empty(),
            recent_transactions: vector::empty(),
        };

        // Increment global counter
        registry.total_wallets_analyzed = registry.total_wallets_analyzed + 1;

        // Emit analysis event
        event::emit(WalletAnalyzed {
            wallet_address,
            total_value: analytics.total_balance,
            token_count: analytics.token_count,
            nft_count: analytics.nft_count,
            analysis_timestamp: current_time,
        });

        analytics
    }

    // Function to add a coin balance to wallet analytics
    public fun add_coin_balance(
        analytics: &mut WalletAnalytics,
        coin_type: String,
        symbol: String,
        balance: u64,
        decimals: u8,
        usd_price_cents: u64,
        ctx: &mut TxContext
    ) {
        let actual_balance = balance / power_of_10(decimals);
        let usd_value = (actual_balance * usd_price_cents) / 100;
        
        let token_info = TokenInfo {
            coin_type,
            symbol,
            balance: actual_balance,
            decimals,
            usd_value,
            percentage_of_portfolio: 0, // Will be calculated later
        };

        if (!table::contains(&analytics.tokens, symbol)) {
            table::add(&mut analytics.tokens, symbol, token_info);
            analytics.token_count = analytics.token_count + 1;
        } else {
            let existing = table::borrow_mut(&mut analytics.tokens, symbol);
            existing.balance = actual_balance;
            existing.usd_value = usd_value;
        };

        analytics.total_balance = analytics.total_balance + usd_value;

        event::emit(TokenDiscovered {
            wallet_address: analytics.owner,
            coin_type,
            balance: actual_balance,
            usd_value,
        });
    }

    // Function to add NFT to analytics
    public fun add_nft(
        analytics: &mut WalletAnalytics,
        object_id: address,
        name: String,
        description: String,
        image_url: String,
        collection: String,
        creator: address,
        ctx: &mut TxContext
    ) {
        let traits = vector::empty<TraitInfo>();
        
        let nft = NFTInfo {
            object_id,
            name,
            description,
            image_url,
            collection,
            creator,
            traits,
        };

        vector::push_back(&mut analytics.nfts, nft);
        analytics.nft_count = analytics.nft_count + 1;

        event::emit(NFTDiscovered {
            wallet_address: analytics.owner,
            nft_id: object_id,
            collection,
            estimated_value: 0,
        });
    }

    // Function to add NFT trait
    public fun add_nft_trait(
        analytics: &mut WalletAnalytics,
        nft_index: u64,
        trait_type: String,
        value: String,
        rarity_score: u64,
        _ctx: &mut TxContext
    ) {
        if (nft_index < vector::length(&analytics.nfts)) {
            let nft = vector::borrow_mut(&mut analytics.nfts, nft_index);
            let trait = TraitInfo {
                trait_type,
                value,
                rarity_score,
            };
            vector::push_back(&mut nft.traits, trait);
        };
    }

    // Function to add transaction record
    public fun add_transaction(
        analytics: &mut WalletAnalytics,
        digest: String,
        transaction_type: String,
        amount: u64,
        coin_type: String,
        timestamp: u64,
        counterparty: address,
        status: String,
        _ctx: &mut TxContext
    ) {
        let tx_info = TransactionInfo {
            digest,
            transaction_type,
            amount,
            coin_type,
            timestamp,
            counterparty,
            status,
        };

        vector::push_back(&mut analytics.recent_transactions, tx_info);
        analytics.transaction_count = analytics.transaction_count + 1;

        // Keep only recent 50 transactions
        while (vector::length(&analytics.recent_transactions) > 50) {
            vector::remove(&mut analytics.recent_transactions, 0);
        };
    }

    // Function to calculate portfolio percentages
    public fun calculate_portfolio_percentages(analytics: &mut WalletAnalytics, _ctx: &mut TxContext) {
        if (analytics.total_balance == 0) return;

        let token_symbols = get_all_token_symbols(analytics);
        let mut i = 0;
        let len = vector::length(&token_symbols);

        while (i < len) {
            let symbol = *vector::borrow(&token_symbols, i);
            if (table::contains(&analytics.tokens, symbol)) {
                let token = table::borrow_mut(&mut analytics.tokens, symbol);
                token.percentage_of_portfolio = (token.usd_value * 10000) / analytics.total_balance;
            };
            i = i + 1;
        };
    }

    // Function to create staking position
    public fun create_staking_position(
        validator: address,
        staked_amount: u64,
        rewards_earned: u64,
        epoch_started: u64,
        apy: u64,
    ): StakingInfo {
        StakingInfo {
            validator,
            staked_amount,
            rewards_earned,
            epoch_started,
            apy,
        }
    }

    // Function to create liquidity position
    public fun create_liquidity_position(
        pool_id: address,
        token_a: String,
        token_b: String,
        liquidity_amount: u64,
        share_percentage: u64,
        fees_earned: u64,
    ): LiquidityInfo {
        LiquidityInfo {
            pool_id,
            token_a,
            token_b,
            liquidity_amount,
            share_percentage,
            fees_earned,
        }
    }

    // Function to calculate portfolio summary
    public fun get_portfolio_summary(analytics: &WalletAnalytics): PortfolioSummary {
        let (best_token, worst_token) = find_best_worst_performers(analytics);
        
        PortfolioSummary {
            total_usd_value: analytics.total_balance,
            total_tokens: analytics.token_count,
            total_nfts: analytics.nft_count,
            best_performing_token: best_token,
            worst_performing_token: worst_token,
            portfolio_diversity_score: calculate_diversity_score(analytics),
            risk_score: calculate_risk_score(analytics),
        }
    }

    // Function to update analytics timestamp
    public fun update_timestamp(
        analytics: &mut WalletAnalytics,
        clock: &Clock,
        _ctx: &mut TxContext
    ) {
        analytics.last_updated = clock::timestamp_ms(clock);
    }

    // Helper function to calculate power of 10
    fun power_of_10(exp: u8): u64 {
        let mut result = 1;
        let mut i = 0;
        while (i < exp) {
            result = result * 10;
            i = i + 1;
        };
        result
    }

    // Helper function to get all token symbols
    fun get_all_token_symbols(analytics: &WalletAnalytics): vector<String> {
        vector::empty<String>()
    }

    // Helper function to find best/worst performing tokens
    fun find_best_worst_performers(analytics: &WalletAnalytics): (String, String) {
        if (analytics.token_count == 0) {
            return (string::utf8(b""), string::utf8(b""))
        };

        let mut best_value = 0;
        let mut worst_value = 18446744073709551615u64; // Max u64
        let mut best_symbol = string::utf8(b"");
        let mut worst_symbol = string::utf8(b"");

        // Simple logic based on USD value for now
        (best_symbol, worst_symbol)
    }

    // Helper function to calculate diversity score
    fun calculate_diversity_score(analytics: &WalletAnalytics): u64 {
        if (analytics.token_count <= 1) {
            return 100 // Low diversity
        };
        
        if (analytics.token_count >= 10) {
            return 1000 // High diversity
        };

        analytics.token_count * 100
    }

    // Helper function to calculate risk score
    fun calculate_risk_score(analytics: &WalletAnalytics): u64 {
        let base_risk = 500; // 5.0 base risk
        
        if (analytics.token_count > 5) {
            return base_risk - 100
        } else if (analytics.token_count == 0) {
            return 1000 // Maximum risk
        } else {
            return base_risk + ((5 - analytics.token_count) * 50)
        }
    }

    // Getter functions
    public fun get_wallet_owner(analytics: &WalletAnalytics): address {
        analytics.owner
    }

    public fun get_total_balance(analytics: &WalletAnalytics): u64 {
        analytics.total_balance
    }

    public fun get_token_count(analytics: &WalletAnalytics): u64 {
        analytics.token_count
    }

    public fun get_nft_count(analytics: &WalletAnalytics): u64 {
        analytics.nft_count
    }

    public fun get_transaction_count(analytics: &WalletAnalytics): u64 {
        analytics.transaction_count
    }

    public fun get_last_updated(analytics: &WalletAnalytics): u64 {
        analytics.last_updated
    }

    public fun get_token_info(analytics: &WalletAnalytics, symbol: String): &TokenInfo {
        table::borrow(&analytics.tokens, symbol)
    }

    public fun get_nfts(analytics: &WalletAnalytics): &vector<NFTInfo> {
        &analytics.nfts
    }

    public fun get_transactions(analytics: &WalletAnalytics): &vector<TransactionInfo> {
        &analytics.recent_transactions
    }

    // Registry getter functions
    public fun get_registry_admin(registry: &AnalyticsRegistry): address {
        registry.admin
    }

    public fun get_total_wallets_analyzed(registry: &AnalyticsRegistry): u64 {
        registry.total_wallets_analyzed
    }

    public fun get_registry_version(registry: &AnalyticsRegistry): u64 {
        registry.version
    }

    // Function to check if token exists
    public fun has_token(analytics: &WalletAnalytics, symbol: String): bool {
        table::contains(&analytics.tokens, symbol)
    }

    // Function to clear analytics data
    public fun clear_analytics(
        analytics: &mut WalletAnalytics,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == analytics.owner, E_NOT_AUTHORIZED);
        
        analytics.token_count = 0;
        analytics.nft_count = 0;
        analytics.transaction_count = 0;
        analytics.total_balance = 0;
        analytics.nfts = vector::empty();
        analytics.recent_transactions = vector::empty();
    }
}