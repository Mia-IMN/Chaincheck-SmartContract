/* TESTNET
 * This contract accepts $1 payments in SUI using simulated pricing :)
*/

module 0x0::payment_contract {
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::clock::{Self, Clock};
    use sui::event;
    use std::string::{Self, String};

    // Constants
    const MAX_PRICE_DEVIATION: u64 = 500;
    
    // Error codes
    const E_INSUFFICIENT_PAYMENT: u64 = 1;
    const E_CONTRACT_PAUSED: u64 = 4;
    const E_INVALID_PRICE: u64 = 5;

    // Structs
    public struct PaymentConfig has key, store {
        id: UID,
        admin: address,
        fee_percentage: u64,
        max_price_deviation: u64,
        last_price_update: u64,
        is_paused: bool,
        supported_dexs: vector<address>,
        min_payment_amount: u64,
    }

    public struct PriceData has store {
        sui_usd_price: u64,
        last_updated: u64,
        price_decimals: u8,
        source_dex: address,
        confidence_score: u64,
    }

    public struct PriceOracle has key, store {
        id: UID,
        current_price: PriceData,
        backup_prices: vector<PriceData>,
        update_frequency: u64,
    }
    
    // Events
    public struct PaymentMade has copy, drop {
        payer: address,
        sui_amount: u64,
        usd_equivalent: u64,
        timestamp: u64,
    }   

    public struct PriceQuote has store, copy, drop {
        price: u64,
        decimals: u8,
        timestamp: u64,
        source: String,
        liquidity: u64,
    }

    // Price function
    public fun get_simulated_price(
        clock: &Clock
    ): PriceQuote {
        let base_price = 3200000; // $3.20 base price in micro-dollars
        let timestamp = clock::timestamp_ms(clock);
        
        // Realistic price variation based on timestamp
        let variation = (timestamp % 100000) / 1000;
        let current_price = base_price + variation;
        
        PriceQuote {
            price: current_price,
            decimals: 6, 
            timestamp: timestamp,
            source: string::utf8(b"simulated_price"),
            liquidity: 50000000000, // Simulated liquidity
        }
    }

    // Get current price with validation
    public fun get_current_price(clock: &Clock): u64 {
        let price_quote = get_simulated_price(clock);

        // Basic sanity check (SUI should be between $0.10 and $100)
        assert!(price_quote.price >= 100000 && price_quote.price <= 100_000_000,
            E_INVALID_PRICE);
        
        price_quote.price
    }

    // Convert USD to SUI amount
    public fun usd_to_sui_amount(
        usd_amount_micro: u64,
        sui_usd_price: u64
    ): u64 {
        // I'm converting USD to SUI by using the math USD amount * SUI precision / USD price
        let sui_decimals_factor = 1000000000; // 10^9 for SUI decimals
        let sui_amount = (
            (usd_amount_micro as u128) *
            (sui_decimals_factor as u128)
        ) / (sui_usd_price as u128);

        (sui_amount as u64)
    }

    // Calculate how much SUI equals $1
    public fun one_dollar_in_sui(sui_usd_price: u64): u64 {
        usd_to_sui_amount(1_000_000, sui_usd_price) // $1.00 in micro-dollars
    }

    // Get SUI amount needed for $1 payment
    public fun get_payment_amount(clock: &Clock): u64 {
        let sui_usd_price = get_current_price(clock);
        one_dollar_in_sui(sui_usd_price)
    }

    // Safe math helpers
    public fun safe_multiply_div(a: u64, b: u64, c: u64): u64 {
        // Overflow protection
        let result = ((a as u128) * (b as u128)) / (c as u128);
        assert!(result <= 18446744073709551615, 0); // u64 max value
        (result as u64)
    }

    public fun round_up_division(numerator: u64, denominator: u64): u64 {
        (numerator + denominator - 1) / denominator
    }

    // Initialize function
    public entry fun manual_init(ctx: &mut TxContext) {
    let config = PaymentConfig {
        id: object::new(ctx),
        admin: tx_context::sender(ctx),
        fee_percentage: 0,
        max_price_deviation: MAX_PRICE_DEVIATION,
        last_price_update: 0,
        is_paused: false,
        supported_dexs: vector::empty(),
        min_payment_amount: 1000000,
    };

    let oracle = PriceOracle {
        id: object::new(ctx),
        current_price: PriceData {
            sui_usd_price: 3200000,
            last_updated: 0,
            price_decimals: 6,
            source_dex: @0x0,
            confidence_score: 100,
        },
        backup_prices: vector::empty(),
        update_frequency: 300000,
    };

    transfer::share_object(config);
    transfer::share_object(oracle);
    }


    // Main payment function
    public entry fun make_payment(
        config: &PaymentConfig,
        mut payment: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Check if contract is paused
        assert!(!config.is_paused, E_CONTRACT_PAUSED);

        // Get required SUI amount for $1
        let required_sui = get_payment_amount(clock);

        // Check payment amount
        let paid_amount = coin::value(&payment);
        assert!(paid_amount >= required_sui, E_INSUFFICIENT_PAYMENT);

        // Handle overpayment - return extra to sender (or should we not? :)
        if (paid_amount > required_sui) {
            let extra_amount = paid_amount - required_sui;
            let extra_coin = coin::split(&mut payment, extra_amount, ctx);
            transfer::public_transfer(extra_coin, tx_context::sender(ctx));
        };

        // Send payment to admin (treasury)
        transfer::public_transfer(payment, config.admin);

        // Emit payment event
        event::emit(PaymentMade {
            payer: tx_context::sender(ctx),
            sui_amount: required_sui,
            usd_equivalent: 1_000_000, // $1 in micro-dollars
            timestamp: clock::timestamp_ms(clock),
        });
    }

    // Helper function to check current payment amount (for UI)
    public fun check_payment_amount(clock: &Clock): u64 {
        get_payment_amount(clock)
    }

    // Admin functions
    public entry fun pause_contract(
        config: &mut PaymentConfig,
        ctx: &TxContext
    ) {
        assert!(tx_context::sender(ctx) == config.admin, E_INSUFFICIENT_PAYMENT);
        config.is_paused = true;
    }

    public entry fun unpause_contract(
        config: &mut PaymentConfig,
        ctx: &TxContext
    ) {
        assert!(tx_context::sender(ctx) == config.admin, E_INSUFFICIENT_PAYMENT);
        config.is_paused = false;
    }

    // View functions for testing
    public fun get_config_admin(config: &PaymentConfig): address {
        config.admin
    }

    public fun is_contract_paused(config: &PaymentConfig): bool {
        config.is_paused
    }
}
