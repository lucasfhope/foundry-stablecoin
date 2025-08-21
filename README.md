## Decentralized Stablecoin

1. Anchored or pegged (Relative stability)
    - Chainlink price feeds
    - Set a function to exchange ETH and BTC for $$$$ (the stablecoin)
    - Liquidation to buyout under-collateralized positions
2. Decantralized Algorithmic minting (Stability Mechanism)
    - people can only mint the stablecoin with enough collateral
3. Collateral: exogenous (crypto)
    - wETH
    - wBTC
  


This repository utilizes chainlink price feeds to calculate the colateral value and determine the health factor of a token holder. This protocol requires 200% collateralization. If a token holder has minted too much of the stablecoin or the price of the collateral dropped, breaking the health factor, the token holder can be liquidated by someone else. The liquidator will pay off the debt in the stablecoin and get the collateral value of the paid off debt, plus a 10% bonus. 

If at anytime the protocol does not receive data from the Chainlink Oracles, it will freeze and not perform any transactions.


IMPORTANT: The price of the stablecoin is vulnerable if the price of wETH and/or wBTC plummet as many positions could become extremely undercollateralized and lose its value.




Based on https://github.com/Cyfrin/foundry-defi-stablecoin-cu.git

---






## Set keystore wallet private key as environment variable, then remove it
- `source ./decryptKey.sh`
- `unset $PRIVATE_KEY`
