// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8;

import './BaseController.sol';
import './interfaces/ILProtectionControllerInterface.sol';
import './libraries/ILUtils.sol';
import './libraries/PremiumCalculator.sol';
import './libraries/MathUtils.sol';

struct ILProtectionWithMetadata {
  uint256 protectionId;
  uint256 token1EntryPriceUSD;
  uint256 token2EntryPriceUSD;
  uint256 token1EndPriceUSD;
  uint256 token2EndPriceUSD;
  uint256 maxAmountToBePaid;
  uint256 amountPaidOnPolicyClose;
  uint256 mappingIdx;
  bool exists;
  uint256 fee;
  uint16 feeComponent;
}

contract ILProtectionController is ILProtectionControllerInterface, BaseController {
  bytes32 public constant LIQUIDITY_PROVIDER_ROLE = keccak256('LIQUIDITY_PROVIDER_ROLE');
  uint256 public constant CVI_DECIMALS_TRUNCATE = 1e16;

  ILProtectionNFTInterface public override protectionNFT;
  ILProtectionConfigInterface public override protectionConfig;
  ITokenPairRepository public override tokenPairRepository;
  ILiquidityController public override liquidityController;
  CVIOracle public override cviOracle;

  uint256 public override collateral;
  uint256 public override totalLPTokensWorthAtBuyTimeUSD;
  uint256[] public openProtectionsIds;
  mapping(uint256 => ILProtectionWithMetadata) public openProtectionsWithMetadata;
  mapping(uint256 => ILProtectionWithMetadata) public closedProtectionsWithMetadata;
  uint256 public maxProtectionsInUpkeep;
  uint256 public override cumulativeSumLPTokensWorthAtBuyTimeUSD;
  mapping(string => mapping(string => uint256)) public pairsCollaterals;

  modifier noOpenProtections() {
    require(openProtectionsIds.length == 0, 'Cannot change value with existing open protections');

    _;
  }

  function initialize(
    address _owner,
    ILProtectionConfigInterface _protectionConfig,
    ILiquidityController _liquidityController,
    ITokenPairRepository _tokenPairRepository,
    ILProtectionNFTInterface _protectionNFT,
    CVIOracle _cviOracle,
    uint256 _maxProtectionsInUpkeep
  ) external initializer {
    BaseController.initialize(_owner);

    protectionConfig = _protectionConfig;
    liquidityController = _liquidityController;
    tokenPairRepository = _tokenPairRepository;
    protectionNFT = _protectionNFT;
    cviOracle = _cviOracle;
    maxProtectionsInUpkeep = _maxProtectionsInUpkeep;
  }

  function addLiquidity(uint256 _amount) external override onlyRole(LIQUIDITY_PROVIDER_ROLE) {
    require(_amount > 0, 'Invalid liquidity amount');

    liquidityController.addLiquidity(msg.sender, _amount);
  }

  function withdrawLiquidity(uint256 _amount, address _to)
    external
    override
    onlyRole(LIQUIDITY_PROVIDER_ROLE)
    onlyValidAddress(_to)
  {
    uint256 liquidity = liquidityController.liquidity();

    require(_amount > 0 && _amount <= liquidity, 'Invalid amount to withdraw');
    require(collateral <= liquidity - _amount, 'Not enough collateral');

    liquidityController.withdrawLiquidity(_amount, _to);
  }

  function buyProtection(
    string calldata _token1Symbol,
    string calldata _token2Symbol,
    uint256 _lpTokensWorthAtBuyTimeUSD,
    uint256 _maxPremiumCostUSD,
    uint256 _policyPeriod
  ) external override {
    require(protectionConfig.policyPeriodExists(_policyPeriod), 'Invalid policy period');
    require(_lpTokensWorthAtBuyTimeUSD > 0, 'lpTokensWorthAtBuyTimeUSD value must be larger than 0');
    require(protectionConfig.buyILProtectionEnabled(), 'Buying protection is disabled');
    require(liquidityController.liquidity() > 0, 'No liquidity');

    TokenPair memory pair = tokenPairRepository.getOrderedTokenPairIfExists(_token1Symbol, _token2Symbol);

    totalLPTokensWorthAtBuyTimeUSD += _lpTokensWorthAtBuyTimeUSD;
    cumulativeSumLPTokensWorthAtBuyTimeUSD += _lpTokensWorthAtBuyTimeUSD;

    (uint256 premiumCost, uint256 fee, uint256 maxAmountToBePaid) = calculatePremiumDetailsAndMaxAmountToBePaid(
      pair.token1Symbol,
      pair.token2Symbol,
      _lpTokensWorthAtBuyTimeUSD,
      _policyPeriod
    );

    collateral += maxAmountToBePaid;

    require(premiumCost > 0, 'Premium cost is too low');

    require(premiumCost <= _maxPremiumCostUSD, 'Max premium cost exceeded');

    require(collateral < liquidityController.liquidity() + premiumCost, 'Not enough collateral to pay back buyer');

    validateAndUpdatePairCollateral(
      pair.token1Symbol,
      pair.token2Symbol,
      maxAmountToBePaid,
      liquidityController.liquidity() + premiumCost
    );

    uint256 createdProtectionId = protectionNFT.tokenIdCounter();

    if (fee > 0) {
      liquidityController.addLiquidityWithProtectionFee(
        createdProtectionId,
        msg.sender,
        premiumCost,
        fee,
        protectionConfig.feeComponent()
      );
    } else {
      liquidityController.addLiquidity(msg.sender, premiumCost);
    }

    uint256 premiumCostWithFee = premiumCost + fee;

    protectionNFT.mint(
      msg.sender,
      block.timestamp,
      calcPolicyPeriodEnd(_policyPeriod),
      premiumCostWithFee,
      _lpTokensWorthAtBuyTimeUSD,
      pair.token1Symbol,
      pair.token2Symbol,
      _policyPeriod
    );

    openProtectionsIds.push(createdProtectionId);

    openProtectionsWithMetadata[createdProtectionId] = ILProtectionWithMetadata({
      protectionId: createdProtectionId,
      token1EntryPriceUSD: tokenPairRepository.getTokenPrice(pair.token1Symbol, pair.token2Symbol, true),
      token2EntryPriceUSD: tokenPairRepository.getTokenPrice(pair.token1Symbol, pair.token2Symbol, false),
      token1EndPriceUSD: 0,
      token2EndPriceUSD: 0,
      amountPaidOnPolicyClose: 0,
      maxAmountToBePaid: maxAmountToBePaid,
      mappingIdx: openProtectionsIds.length - 1,
      exists: true,
      fee: fee,
      feeComponent: protectionConfig.feeComponent()
    });

    emit ProtectionBought(
      createdProtectionId,
      msg.sender,
      block.timestamp,
      calcPolicyPeriodEnd(_policyPeriod),
      premiumCostWithFee,
      pair.token1Symbol,
      pair.token2Symbol,
      _policyPeriod,
      openProtectionsWithMetadata[createdProtectionId].token1EntryPriceUSD,
      openProtectionsWithMetadata[createdProtectionId].token2EntryPriceUSD,
      collateral
    );

    emit CollateralUpdated(
      pair.token1Symbol,
      pair.token2Symbol,
      createdProtectionId,
      pairsCollaterals[pair.token1Symbol][pair.token2Symbol] - maxAmountToBePaid,
      pairsCollaterals[pair.token1Symbol][pair.token2Symbol],
      collateral - maxAmountToBePaid,
      collateral,
      liquidityController.liquidity() - premiumCost,
      liquidityController.liquidity()
    );
  }

  function closeProtections(uint256[] memory _protectionsIds) public override {
    require(_protectionsIds.length > 0, 'Protections Ids array is empty');

    for (uint256 i; i < _protectionsIds.length; i++) {
      ILProtectionWithMetadata storage protectionWithMetadata = openProtectionsWithMetadata[_protectionsIds[i]];

      if (!protectionWithMetadata.exists) {
        continue;
      }

      ProtectionNFTDetails memory protectionDetails = protectionNFT.getProtectionDetails(_protectionsIds[i]);

      if (protectionDetails.protectionEndTimestamp <= block.timestamp) {
        uint256 token1Price = tokenPairRepository.getTokenPrice(
          protectionDetails.token1Symbol,
          protectionDetails.token2Symbol,
          true
        );

        uint256 token2Price = tokenPairRepository.getTokenPrice(
          protectionDetails.token1Symbol,
          protectionDetails.token2Symbol,
          false
        );

        (uint256 amountToBePaid, bool isBelowMin) = calcAmountToBePaidWithProtectionDetails(
          protectionDetails,
          protectionWithMetadata,
          token1Price,
          token2Price
        );

        if (!isBelowMin) {
          liquidityController.withdrawLiquidity(amountToBePaid, protectionDetails.owner);
        }

        protectionWithMetadata.token1EndPriceUSD = token1Price;
        protectionWithMetadata.token2EndPriceUSD = token2Price;
        protectionWithMetadata.amountPaidOnPolicyClose = amountToBePaid;

        collateral -= protectionWithMetadata.maxAmountToBePaid;
        pairsCollaterals[protectionDetails.token1Symbol][protectionDetails.token2Symbol] -= protectionWithMetadata
          .maxAmountToBePaid;

        totalLPTokensWorthAtBuyTimeUSD -= protectionDetails.lpTokensWorthAtBuyTimeUSD;

        if (openProtectionsIds.length > 1) {
          uint256 topProtectionId = openProtectionsIds[openProtectionsIds.length - 1];
          openProtectionsIds[protectionWithMetadata.mappingIdx] = topProtectionId;
          openProtectionsWithMetadata[topProtectionId].mappingIdx = protectionWithMetadata.mappingIdx;
        }

        openProtectionsIds.pop();

        closedProtectionsWithMetadata[protectionDetails.id] = protectionWithMetadata;
        delete openProtectionsWithMetadata[protectionDetails.id];

        emit ProtectionClosed(
          amountToBePaid,
          protectionDetails.id,
          protectionDetails.owner,
          protectionDetails.protectionStartTimestamp,
          protectionDetails.protectionEndTimestamp,
          protectionDetails.premiumCostUSD,
          protectionDetails.token1Symbol,
          protectionDetails.token2Symbol,
          protectionDetails.policyPeriod,
          token1Price,
          token2Price,
          collateral
        );

        emit CollateralUpdated(
          protectionDetails.token1Symbol,
          protectionDetails.token2Symbol,
          protectionDetails.id,
          pairsCollaterals[protectionDetails.token1Symbol][protectionDetails.token2Symbol] +
            closedProtectionsWithMetadata[protectionDetails.id].maxAmountToBePaid,
          pairsCollaterals[protectionDetails.token1Symbol][protectionDetails.token2Symbol],
          collateral + closedProtectionsWithMetadata[protectionDetails.id].maxAmountToBePaid,
          collateral,
          liquidityController.liquidity() + amountToBePaid,
          liquidityController.liquidity()
        );
      }
    }
  }

  function checkUpkeep(
    bytes calldata /* _checkData*/
  ) external view override returns (bool upkeepNeeded, bytes memory performData) {
    uint256[] memory finalizedProtectionsIds = getFinalizedProtectionsIds();

    if (finalizedProtectionsIds.length > 0) {
      upkeepNeeded = true;

      uint256 safeProtectionsIdsLen = finalizedProtectionsIds.length > maxProtectionsInUpkeep
        ? maxProtectionsInUpkeep
        : finalizedProtectionsIds.length;

      uint256[] memory safeProtectionIds = new uint256[](safeProtectionsIdsLen);

      for (uint256 i = 0; i < safeProtectionsIdsLen; i++) {
        safeProtectionIds[i] = finalizedProtectionsIds[i];
      }

      performData = abi.encode(safeProtectionIds);
    } else {
      upkeepNeeded = false;
    }
  }

  function performUpkeep(bytes calldata _performData) external override {
    uint256[] memory protectionsIds = abi.decode(_performData, (uint256[]));

    closeProtections(protectionsIds);
  }

  function setMaxILProtected(uint16 _maxILProtected) external override onlyAdmin noOpenProtections {
    protectionConfig.setMaxILProtected(_maxILProtected);
  }

  function setMaxProtectionsInUpkeep(uint8 _maxProtectionsInUpkeep) external override onlyAdmin {
    require(_maxProtectionsInUpkeep > 0, 'invalid maxProtectionsInUpkeep value');

    emit MaxProtectionsInUpkeepChanged(maxProtectionsInUpkeep, _maxProtectionsInUpkeep);

    maxProtectionsInUpkeep = _maxProtectionsInUpkeep;
  }

  function getFinalizedProtectionsIds() public view override returns (uint256[] memory) {
    uint256[] memory finalizedProtectionIds = new uint256[](getNumOfFinalizedProtections());
    uint256 count;

    for (uint256 i; i < openProtectionsIds.length; i++) {
      ProtectionNFTDetails memory protectionDetails = protectionNFT.getProtectionDetails(openProtectionsIds[i]);

      if (protectionDetails.protectionEndTimestamp <= block.timestamp) {
        finalizedProtectionIds[count++] = openProtectionsIds[i];
      }
    }

    return finalizedProtectionIds;
  }

  function calculateParameterizedPremium(
    uint256 _lpTokensWorthAtBuyTimeUSD,
    uint256 _totalLPTokensWorthAtBuyTimeUSD,
    uint16 _expectedLPTokensValueGrowth,
    uint256 _liquidity,
    uint16 _maxILProtected,
    PremiumParams calldata _premiumParams,
    uint256 _cvi,
    uint256 _premiumGrowthStart,
    uint256 _premiumSlope
  ) public pure override returns (uint256) {
    require(_liquidity > 0, 'Liquidity must be larger than 0');

    uint256 estimatedCollateral = calcEstimatedAmountToBePaid(
      _totalLPTokensWorthAtBuyTimeUSD + _lpTokensWorthAtBuyTimeUSD,
      _expectedLPTokensValueGrowth,
      _maxILProtected
    );

    require(estimatedCollateral <= _liquidity, 'Collateral must be smaller than liquidity');

    return
      PremiumCalculator.calculatePremium(
        _lpTokensWorthAtBuyTimeUSD,
        estimatedCollateral,
        _liquidity,
        _premiumParams,
        _cvi,
        _premiumGrowthStart,
        _premiumSlope
      );
  }

  function calculatePremiumDetailsAndMaxAmountToBePaid(
    string memory _token1Symbol,
    string memory _token2Symbol,
    uint256 _lpTokensWorthAtBuyTimeUSD,
    uint256 _policyPeriod
  )
    public
    view
    override
    returns (
      uint256 premium,
      uint256 fee,
      uint256 maxAmountToBePaid
    )
  {
    require(
      _lpTokensWorthAtBuyTimeUSD <= calcMaxValueOfTokensWorthToProtect(_token1Symbol, _token2Symbol),
      'lpTokensWorthAtBuyTimeUSD > maxValueOfTokensWorthToProtect'
    );

    uint256 liquidity = liquidityController.liquidity();

    PremiumParams memory premiumParams = tokenPairRepository.getPremiumParams(
      _token1Symbol,
      _token2Symbol,
      _policyPeriod
    );

    maxAmountToBePaid = calcEstimatedAmountToBePaid(
      _lpTokensWorthAtBuyTimeUSD,
      protectionConfig.expectedLPTokensValueGrowth(),
      protectionConfig.maxILProtected()
    );

    premium = PremiumCalculator.calculatePremium(
      _lpTokensWorthAtBuyTimeUSD,
      collateral + maxAmountToBePaid,
      liquidity,
      premiumParams,
      getCVI(),
      protectionConfig.premiumGrowthStart(),
      protectionConfig.premiumSlope()
    );

    require(collateral + maxAmountToBePaid <= liquidity + premium, 'Updated collateral is larger than liquidity');

    fee = calculateFee(_lpTokensWorthAtBuyTimeUSD, protectionConfig.feeComponent());
  }

  function calcMaxValueOfTokensWorthToProtect(string memory _token1Symbol, string memory _token2Symbol)
    public
    view
    override
    returns (uint256)
  {
    TokenPair memory pair = tokenPairRepository.getOrderedTokenPairIfExists(_token1Symbol, _token2Symbol);

    uint256 tokensValueGrowth = protectionConfig.expectedLPTokensValueGrowth();

    uint256 denominator = (tokensValueGrowth * MAX_PRECISION) /
      (MAX_PRECISION - protectionConfig.maxILProtected()) -
      tokensValueGrowth;

    uint256 liquidity = liquidityController.liquidity();
    uint256 collateralCap = calcCollateralCap(liquidity, _token1Symbol, _token2Symbol);

    if (collateralCap > pairsCollaterals[pair.token1Symbol][pair.token2Symbol]) {
      uint256 liquidityDelta = MathUtils.min(
        collateralCap - pairsCollaterals[pair.token1Symbol][pair.token2Symbol],
        liquidity - collateral
      );

      return (liquidityDelta * MAX_PRECISION) / denominator;
    } else {
      return 0;
    }
  }

  function calcAmountToBePaidWithProtectionId(uint256 _protectionId) public view override returns (uint256) {
    require(openProtectionsWithMetadata[_protectionId].exists, "Protection is either closed or doesn't exist");

    ProtectionNFTDetails memory protection = protectionNFT.getProtectionDetails(_protectionId);
    ILProtectionWithMetadata storage protectionWithMetadata = openProtectionsWithMetadata[_protectionId];

    uint256 token1Price = tokenPairRepository.getTokenPrice(protection.token1Symbol, protection.token2Symbol, true);
    uint256 token2Price = tokenPairRepository.getTokenPrice(protection.token1Symbol, protection.token2Symbol, false);

    (uint256 amountToBePaid, ) = calcAmountToBePaidWithProtectionDetails(
      protection,
      protectionWithMetadata,
      token1Price,
      token2Price
    );

    return amountToBePaid;
  }

  function calcAmountToBePaid(
    uint256 _lpTokensWorthAtBuyTimeUSD,
    uint256 _token1EntryPrice,
    uint256 _token2EntryPrice,
    uint256 _token1EndPrice,
    uint256 _token2EndPrice
  ) public view override returns (uint256) {
    uint8 priceTokenDecimals = tokenPairRepository.priceTokenDecimals();

    uint16 impermanentLoss = calculateIL(_token1EntryPrice, _token2EntryPrice, _token1EndPrice, _token2EndPrice);

    uint256 pricesRatio = MathUtils.ratio(
      (MathUtils.ratio(_token1EndPrice, _token1EntryPrice, priceTokenDecimals) +
        MathUtils.ratio(_token2EndPrice, _token2EntryPrice, priceTokenDecimals)),
      2 * 10**priceTokenDecimals,
      priceTokenDecimals
    );

    uint256 lpTokensWorthIfHeldUSD = (_lpTokensWorthAtBuyTimeUSD * pricesRatio) / 10**priceTokenDecimals;

    return (lpTokensWorthIfHeldUSD * impermanentLoss) / MAX_PRECISION;
  }

  function calculateIL(
    uint256 _token1EntryPriceUSD,
    uint256 _token2EntryPriceUSD,
    uint256 _token1EndPriceUSD,
    uint256 _token2EndPriceUSD
  ) public pure override returns (uint16) {
    return
      ILUtils.calculateIL(
        _token1EntryPriceUSD,
        _token2EntryPriceUSD,
        _token1EndPriceUSD,
        _token2EndPriceUSD,
        MAX_PRECISION
      );
  }

  function calculateOpenProtectionIL(uint256 _protectionId) external view override returns (uint16) {
    require(openProtectionsWithMetadata[_protectionId].exists, "Protection is either closed or doesn't exist");
    ProtectionNFTDetails memory protectionDetails = protectionNFT.getProtectionDetails(_protectionId);

    uint256 token1Price = tokenPairRepository.getTokenPrice(
      protectionDetails.token1Symbol,
      protectionDetails.token2Symbol,
      true
    );
    uint256 token2Price = tokenPairRepository.getTokenPrice(
      protectionDetails.token1Symbol,
      protectionDetails.token2Symbol,
      false
    );

    return
      calculateIL(
        openProtectionsWithMetadata[_protectionId].token1EntryPriceUSD,
        openProtectionsWithMetadata[_protectionId].token2EntryPriceUSD,
        token1Price,
        token2Price
      );
  }

  function calcEstimatedAmountToBePaid(
    uint256 _lpTokensWorthAtBuyTimeUSD,
    uint16 _expectedLPTokensValueGrowth,
    uint16 _impermanentLoss
  ) public pure override returns (uint256) {
    uint256 estimatedTokensWorthAtEnd = (_lpTokensWorthAtBuyTimeUSD * _expectedLPTokensValueGrowth) / MAX_PRECISION;

    return (estimatedTokensWorthAtEnd * MAX_PRECISION) / (MAX_PRECISION - _impermanentLoss) - estimatedTokensWorthAtEnd;
  }

  function calculateFee(uint256 _lpTokensWorthAtBuyTimeUSD, uint16 _feeComponent)
    public
    pure
    override
    returns (uint256)
  {
    return (_lpTokensWorthAtBuyTimeUSD * _feeComponent) / MAX_PRECISION;
  }

  function validateAndUpdatePairCollateral(
    string memory _token1Symbol,
    string memory _token2Symbol,
    uint256 _additionalCollateral,
    uint256 _liquidity
  ) internal {
    uint256 cap = calcCollateralCap(_liquidity, _token1Symbol, _token2Symbol);

    require(
      cap >= pairsCollaterals[_token1Symbol][_token2Symbol] + _additionalCollateral,
      'Pair collateral cap has been reached'
    );

    pairsCollaterals[_token1Symbol][_token2Symbol] += _additionalCollateral;
  }

  function calcCollateralCap(
    uint256 _liquidity,
    string memory _token1Symbol,
    string memory _token2Symbol
  ) internal view returns (uint256) {
    return (_liquidity * tokenPairRepository.getCollateralCapComponent(_token1Symbol, _token2Symbol)) / MAX_PRECISION;
  }

  function calcAmountToBePaidWithProtectionDetails(
    ProtectionNFTDetails memory _protection,
    ILProtectionWithMetadata storage _protectionWithMetadata,
    uint256 _token1EndPrice,
    uint256 _token2EndPrice
  ) internal view returns (uint256, bool) {
    uint256 amountToBePaid = calcAmountToBePaid(
      _protection.lpTokensWorthAtBuyTimeUSD,
      _protectionWithMetadata.token1EntryPriceUSD,
      _protectionWithMetadata.token2EntryPriceUSD,
      _token1EndPrice,
      _token2EndPrice
    );

    bool isBelowMin = protectionConfig.minAmountToBePaid() > amountToBePaid;

    if (isBelowMin) {
      amountToBePaid = 0;
    } else if (amountToBePaid > _protectionWithMetadata.maxAmountToBePaid) {
      amountToBePaid = _protectionWithMetadata.maxAmountToBePaid;
    }

    return (amountToBePaid, isBelowMin);
  }

  function getNumOfFinalizedProtections() internal view returns (uint256 count) {
    for (uint256 i; i < openProtectionsIds.length; i++) {
      ProtectionNFTDetails memory protectionDetails = protectionNFT.getProtectionDetails(openProtectionsIds[i]);

      if (protectionDetails.protectionEndTimestamp <= block.timestamp) {
        count++;
      }
    }
  }

  function getCVI() internal view returns (uint256) {
    (
      uint16 cviValue, /*uint80 cviRoundId*/ /*uint256 cviTimestamp*/
      ,

    ) = cviOracle.getCVILatestRoundData();

    return uint256(cviValue) * CVI_DECIMALS_TRUNCATE;
  }

  function calcPolicyPeriodEnd(uint256 _policyPeriod) internal view returns (uint256) {
    return block.timestamp + _policyPeriod;
  }
}
