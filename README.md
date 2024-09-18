# Armadillo Contracts Integration

The following readme describes the methods to integration to CVI's Impermanent Loss product directly using the contracts as dapp.

Here by we describe the relevant contract methods:

----------------


| Contract Name          | Contract Address |
|------------------------|------------------|
| `ILProtectionConfig`     |`0x7EE45B011Aea24c8078bE0Fa15a02DcD2c142F25`|
| `TokenPairRepository`    |     `0x282f2EBd973a893C5C10670e2EC6b5aA0f81988A`             |
| `ILProtectionController` |      `0xdD6fD32434eac75FA2dDfFe8629966E43e608282`            |


-----

1. Get supported protections periods:

* Contract Name: `ILProtectionConfig`
* Method Name: `getPolicyPeriodsInSeconds`
* Input: None 
* Output: array of periods in seconds  
* Output In Decimals: 0
* Comments: get all protection periods for IL: 14,30,60 

----------------

2. Get supported pairs:

* Contract Name: `TokenPairRepository`
* Method Name: `getPairs`
* Input: None 
* Output:
    ```typescript
    {
        token1Symbol: string,
        token2Symbol: string
    }[]
    ```
* Output In Decimals: -
* Comments: `WETH-USDC`,`WETH-DAI`,`WETH-USDT`

---------------------

3. Calculate Premium Price In USDC:

* Contract Name: `ILProtectionController`
* Method Name: `calculatePremiumAndMaxAmountToBePaid`
* Input:
    ```typescript
    _token1Symbol: string,
    _token2Symbol: string,
    _lpTokensWorthAtBuyTimeUSD: BigNumberish, // 6 decimals
    _policyPeriod: BigNumberish, // 0 decimals
    ```
* Output:
    ```typescript
    [premiumPriceUsdc: BigNumber, maxAmountToBePaid: BigNumber]
    ```
* Output In Decimals: `premiumPriceUsdc` - 6, `maxAmountToBePaid` - 6
* Comments: Calculate the cost of the premium without really paying something.

----------------------

4. Buy Protection:

* Contract Name: `ILProtectionController`
* Method Name: `buyProtection`
* Input:
    ```typescript
    _token1Symbol: string,
    _token2Symbol: string,
    _lpTokensWorthAtBuyTimeUSD: BigNumberish, // 6 decimals
    _maxPremiumCostUSD: BigNumberish, // 6 decimals
    _policyPeriod: BigNumberish, // 0 decimals
    ```
* Output: None
* Output In Decimals: None
* Comments: Buy Protection


