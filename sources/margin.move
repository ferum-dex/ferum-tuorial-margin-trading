module perimeter::margin {
    use aptos_framework::coin;
    use aptos_framework::aptos_coin::AptosCoin;
    use ferum::test_coins::USDF;
    use ferum_std::fixed_point_64::{Self, FixedPoint64};
    use std::signer::address_of;
    use aptos_std::type_info;
    use aptos_framework::account;
    use perimeter::admin;

    const ERR_ALREADY_REGISTERED: u64 = 1;
    const ERR_NOT_REGISTERED: u64 = 2;
    const ERR_INVALID_TYPE: u64 = 3;
    const ERR_LTV_EXCEEDED: u64 = 4;
    const ERR_NOT_ALLOWED: u64 = 5;

    // Struct holding protocol assets which users borrow.
    struct AssetTreasury<phantom T> has key {
        coins: coin::Coin<T>,
    }

    // Tracks debts for a margin account.
    struct AccountDebt<phantom T> has key {
        amount: FixedPoint64,
    }

    // Represents a users margin account.
    struct MarginAccount has key {
        // The address of the user this account belongs to.
        owner: address,
        // The signing capability used to take actions as this account.
        signingCap: account::SignerCapability,
    }

    // Called by Perimeter admins to deposit treasury assets into the protocol.
    public entry fun deposit_treasury_assets<T>(owner: &signer, amt: u64) acquires AssetTreasury {
        let ownerAddr = address_of(owner);
        assert_valid_type<T>();
        assert!(ownerAddr == @perimeter, ERR_NOT_ALLOWED);
        let treasury = borrow_global_mut<AssetTreasury<T>>(@perimeter);
        let assets = coin::withdraw<T>(owner, amt);
        coin::merge(&mut treasury.coins, assets);
    }

    // Called by users to create a margin account, balances, and debts.
    public entry fun register(owner: &signer) {
        let ownerAddr = address_of(owner);
        assert!(!exists<MarginAccount>(ownerAddr), ERR_ALREADY_REGISTERED);

        let signingCap = admin::create_margin_account();

        move_to(owner, MarginAccount{
            owner: ownerAddr,
            signingCap,
        });
        move_to(owner, AccountDebt<USDF>{
            amount: fixed_point_64::zero(),
        });
        move_to(owner, AccountDebt<AptosCoin>{
            amount: fixed_point_64::zero(),
        });
    }

    // Called by users to borrow assets from the protocol.
    // amt is a fixed point number with the same number of decimal places as the underlying asset.
    public entry fun borrow<T>(owner: &signer, amtRaw: u64)
        acquires MarginAccount, AssetTreasury, AccountDebt {

        assert_valid_type<T>();
        let ownerAddr = address_of(owner);
        assert_inited(ownerAddr);

        let marginAccountAddr = get_margin_account_address(ownerAddr);

        let amt = fixed_point_64::from_u64(amtRaw, coin::decimals<T>());
        borrow_asset<T>(ownerAddr, marginAccountAddr, amt);

        // Make sure we haven't exceeded the max LTV.
        assert_ltv_ok(ownerAddr);
    }

    // Called by users to borrow assets from the protocol.
    // amt is a fixed point number with the same number of decimal places as the underlying asset.
    public entry fun repay<T>(owner: &signer, amtRaw: u64)
        acquires MarginAccount, AssetTreasury, AccountDebt {

        assert_valid_type<T>();
        let ownerAddr = address_of(owner);
        assert_inited(ownerAddr);

        let marginAccountSigner = get_margin_account_signer(ownerAddr);

        let amt = fixed_point_64::from_u64(amtRaw, coin::decimals<T>());
        repay_asset<T>(ownerAddr, &marginAccountSigner, amt);

        // No need to check if we've exceeded max LTV.
    }

    // Called by users to deposit assets to the margin account.
    // amt is a fixed point number with the same number of decimal places as the underlying asset.
    public entry fun deposit<T>(owner: &signer, amt: u64) acquires MarginAccount {
        assert_valid_type<T>();
        let ownerAddr = address_of(owner);
        assert_inited(ownerAddr);

        let marginAccountAddr = get_margin_account_address(ownerAddr);

        // Withdraw assets from user account and add it to the MarginAccount.
        coin::transfer<T>(owner, marginAccountAddr, amt);

        // No need to check if we've exceeded max LTV.
    }

    // Called by users to withdraw assets from the margin account.
    // amt is a fixed point number with the same number of decimal places as the asset being withdrawn.
    public entry fun withdraw<T>(owner: &signer, amt: u64) acquires MarginAccount, AccountDebt {
        assert_valid_type<T>();
        let ownerAddr = address_of(owner);
        assert_inited(ownerAddr);

        let marginAccountSigner = get_margin_account_signer(ownerAddr);

        // Withdraw assets from margin account and add it to user acocunt.
        coin::transfer<T>(&marginAccountSigner, ownerAddr, amt);

        // Make sure we haven't exceeded the max LTV.
        assert_ltv_ok(ownerAddr);
    }

    public fun assert_ltv_ok(ownerAddr: address) acquires AccountDebt {
        let maxLTV = admin::get_max_ltv();
        assert!(fixed_point_64::gte(maxLTV, get_ltv(ownerAddr)), ERR_LTV_EXCEEDED);
    }

    public fun assert_inited(owner: address) {
        assert!(exists<MarginAccount>(owner), ERR_NOT_REGISTERED);
        admin::assert_inited();
    }

    public fun  get_margin_account_signer(owner: address): signer acquires MarginAccount {
        let marginAccountCap = &borrow_global<MarginAccount>(owner).signingCap;
        account::create_signer_with_capability(marginAccountCap)
    }

    public fun  get_margin_account_address(owner: address): address acquires MarginAccount {
        let marginAccountCap = &borrow_global<MarginAccount>(owner).signingCap;
        account::get_signer_capability_address(marginAccountCap)
    }

    // Returns the loan to value ratio, which indicates what the total value of the user's loan is as a
    // percentage of the supplied collateral.
    public fun get_ltv(owner: address): FixedPoint64 acquires AccountDebt {
        let totalValue = get_account_total_value(owner);
        let totalDebt = get_account_total_debt(owner);
        // We would rather be conservative so we round up if
        // the number of decimal places exceeds the max precision
        fixed_point_64::divide_round_up(totalDebt, totalValue)
    }

    fun get_account_total_value(owner: address): FixedPoint64 {
        // USDF Balance Value.
        let usdfBalanceAmt = get_coin_balance<USDF>(owner);
        let usdfBalanceValue = get_usdf_value(usdfBalanceAmt);

        // APT Balance Value.
        let aptBalanceAmt = get_coin_balance<AptosCoin>(owner);
        let aptBalanceValue = get_apt_value(aptBalanceAmt);

        fixed_point_64::add(usdfBalanceValue, aptBalanceValue)
    }

    fun get_account_total_debt(owner: address): FixedPoint64 acquires AccountDebt {
        // USDF Debt.
        let usdfDebtAmt = borrow_global<AccountDebt<USDF>>(owner).amount;
        let usdfDebtValue = get_usdf_value(usdfDebtAmt);

        // APT Debt.
        let aptDebtAmt = borrow_global<AccountDebt<USDF>>(owner).amount;
        let aptDebtValue = get_apt_value(aptDebtAmt);

        fixed_point_64::add(usdfDebtValue, aptDebtValue)
    }

    fun get_apt_value(amt: FixedPoint64): FixedPoint64 {
        // We'll assume APT always has a value of 2. In an actual application, we should
        // hook into an oracle to get the actual price of APT.
        fixed_point_64::multiply_trunc(amt, fixed_point_64::from_u64(2, 0))
    }

    fun get_usdf_value(amt: FixedPoint64): FixedPoint64 {
        // We'll assume USDF always has a value of 1. In an actual application, we should
        // hook into an oracle to get the actual price of USDF.
        amt
    }

    fun get_coin_balance<T>(marginAccountAddr: address): FixedPoint64 {
        let balance = coin::balance<AptosCoin>(marginAccountAddr);
        let coinDecimals = coin::decimals<T>();
        fixed_point_64::from_u64(balance, coinDecimals)
    }

    fun borrow_asset<T>(
        userAddr: address,
        marginAccountAddr: address,
        amt: FixedPoint64,
    ) acquires AssetTreasury, AccountDebt {
        let assetTreasury = borrow_global_mut<AssetTreasury<T>>(marginAccountAddr);
        let coinDecimals = coin::decimals<T>();
        let coinAmt = fixed_point_64::to_u64(amt, coinDecimals);

        let borrowedAssets = coin::extract(&mut assetTreasury.coins, coinAmt);
        coin::deposit(marginAccountAddr, borrowedAssets);

        // Increase user's debt for this asset.
        let debt = borrow_global_mut<AccountDebt<T>>(userAddr);
        debt.amount = fixed_point_64::add(debt.amount, amt);
    }

    fun repay_asset<T>(
        userAddr: address,
        marginAccount: &signer,
        amt: FixedPoint64,
    ) acquires AssetTreasury, AccountDebt {
        let marginAccountAddr = address_of(marginAccount);
        let assetTreasury = borrow_global_mut<AssetTreasury<T>>(marginAccountAddr);
        let coinDecimals = coin::decimals<T>();
        let debt = borrow_global_mut<AccountDebt<T>>(userAddr);
        let repayAmt = fixed_point_64::min(debt.amount, amt);
        let coinAmt = fixed_point_64::to_u64(repayAmt, coinDecimals);

        let repaidAssets = coin::withdraw(marginAccount, coinAmt);
        coin::merge(&mut assetTreasury.coins, repaidAssets);

        // Decrease user's debt for this asset.
        let debt = borrow_global_mut<AccountDebt<T>>(userAddr);
        debt.amount = fixed_point_64::sub(debt.amount, repayAmt);
    }

    fun assert_valid_type<T>() {
        let isUSDF = type_info::type_of<T>() == type_info::type_of<USDF>();
        let isAPT = type_info::type_of<T>() == type_info::type_of<AptosCoin>();
        assert!(isUSDF || isAPT, ERR_INVALID_TYPE);
    }
}