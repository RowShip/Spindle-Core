# Swap Sweep Vault V1 Core

A shared fungible (ERC20) Uniswap V3 Liquidity Position for decentralized liquidity aggregation, management and optimization. SSUniVault earned fees are auto-compounded by Gelato Network keepers, intermittently harvesting and reinvesting the earnings into the liquidity position. Liquidity position bounds are automatically recentered around the current market price on a weekly basis. The width of the recentered bounds is scaled according to the implied volatility of the pool such that there is 95 percent probability that the price will stay in bounds after one week.   

Vaults can be permissionlessly deployed by anyone on any existing Uniswap V3 pair, via the SSUniFactory contract.

(see [docs](*INSERT_DOCUMENTATION_LINK_HERE*) for more info)

# test

yarn

yarn compile

yarn test