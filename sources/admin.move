module perimeter::admin {
    use aptos_framework::account;
    use ferum_std::fixed_point_64::{Self, FixedPoint64};
    use std::signer::address_of;
    use std::bcs;
    use std::vector;
    use aptos_framework::account::SignerCapability;

    const ERR_NOT_ALLOWED: u64 = 1;
    const ERR_ALREADY_INITIALIZED: u64 = 2;
    const ERR_NOT_INITIALIZED: u64 = 3;
    const ERR_INVALID_MAX_LTV: u64 = 3;

    const PERIMETER_ADMIN_ACCOUNT_SALT: vector<u8> = b"perimerter::trading::margin_admin";
    const PERIMETER_MARGIN_ACCOUNT_SALT: vector<u8> = b"perimerter::trading::margin_account";

    struct PerimeterConfig has key {
        // The signing capability used to generate margin accounts.
        // This capability itself is associated with a resource account
        // when Perimiter is initialized. We generate user accounts using this
        // to ensure that only the protocol has control over margin accounts.
        adminSigningCap: account::SignerCapability,
        // The max LTV that a user is allowed to have.
        maxLTV: FixedPoint64,
        // Used as part of the seed to generate margin accounts for users.
        // Each time a user creates an account, this is incremented, ensuring
        // that each user has a unique account.
        nonce: u128,
    }

    // Called to initialize Perimeter.
    //
    // maxLTV is an fixed point number with 2 decimal plaves (>0, <=1) representing the max loan to value percentage
    // a user's account is allowed to have.
    public entry fun init_perimeter(signer: &signer, maxLTV: u64) {
        let signerAddr = address_of(signer);
        assert!(signerAddr == @perimeter, ERR_NOT_ALLOWED);
        assert!(!exists<PerimeterConfig>(signerAddr), ERR_ALREADY_INITIALIZED);

        // Create an admin resource account. This account's signing capability will be used to
        // create margin accounts for users.
        let seed = bcs::to_bytes(&@perimeter);
        vector::append(&mut seed, PERIMETER_ADMIN_ACCOUNT_SALT);
        let (_, signingCap) = account::create_resource_account(signer, seed);

        assert!(maxLTV > 0 && maxLTV <= 1, ERR_INVALID_MAX_LTV);

        move_to(signer, PerimeterConfig{
            maxLTV: fixed_point_64::from_u64(maxLTV, 2),
            nonce: 0,
            adminSigningCap: signingCap,
        });
    }

    public fun create_margin_account(): SignerCapability acquires PerimeterConfig {
        let cfg = borrow_global_mut<PerimeterConfig>(@perimeter);
        let adminSigner = &account::create_signer_with_capability(&cfg.adminSigningCap);

        // Create margin account using admin resource account.
        let seed = bcs::to_bytes(&@perimeter);
        vector::append(&mut seed, bcs::to_bytes(&cfg.nonce));
        cfg.nonce = cfg.nonce + 1;
        vector::append(&mut seed, PERIMETER_MARGIN_ACCOUNT_SALT);
        let (_, signingCap) = account::create_resource_account(adminSigner, seed);
        signingCap
    }

    public fun get_max_ltv(): FixedPoint64 acquires PerimeterConfig {
        borrow_global<PerimeterConfig>(@perimeter).maxLTV
    }

    public fun assert_inited() {
        assert!(exists<PerimeterConfig>(@perimeter), ERR_NOT_INITIALIZED);
    }
}