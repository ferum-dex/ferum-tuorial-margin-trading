module perimeter::trading {
    use aptos_framework::aptos_coin::AptosCoin;
    use ferum::market::{add_limit_order, get_market_decimals};
    use ferum::test_coins::USDF;
    use ferum_std::fixed_point_64::{Self};
    use std::signer::address_of;
    use std::string;
    use perimeter::margin;

    const ERR_NOT_ALLOWED: u64 = 1;
    const ERR_ALREADY_INITIALIZED: u64 = 2;
    const ERR_ALREADY_REGISTERED: u64 = 3;
    const ERR_NOT_INITIALIZED: u64 = 4;
    const ERR_NOT_REGISTERED: u64 = 5;
    const ERR_INVALID_TYPE: u64 = 6;

    // Let users trade on the APT/USDF market using their margin account on Ferum.
    // Price is a fixed point with the same number of decimal places as the underlying Ferum market.
    public entry fun trade(
        owner: &signer,
        side: u8,
        priceRaw: u64,
        qtyRaw: u64,
    ) {
        let ownerAddr = address_of(owner);
        margin::assert_inited(ownerAddr);

        let marginAccountSigner = margin::get_margin_account_signer(ownerAddr);

        // Convert price and qty to fixed point values.
        let (instrumentDecimals, quoteDecimals) = get_market_decimals<AptosCoin, USDF>();
        let price = fixed_point_64::from_u64(priceRaw, quoteDecimals);
        let qty = fixed_point_64::from_u64(qtyRaw, instrumentDecimals);

        let clientOrderID = string::utf8(b"");
        add_limit_order<AptosCoin, USDF>(
           &marginAccountSigner,
            side,
            price,
            qty,
            clientOrderID,
        );
    }
}

