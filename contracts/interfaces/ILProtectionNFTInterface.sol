// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8;

struct ProtectionNFTDetails {
  uint256 id;
  address owner;
  uint256 protectionStartTimestamp;
  uint256 protectionEndTimestamp;
  uint256 premiumCostUSD;
  uint256 lpTokensWorthAtBuyTimeUSD;
  string token1Symbol;
  string token2Symbol;
  uint256 policyPeriod;
}

interface ILProtectionNFTInterface {
  event ProtectionMint(
    uint256 indexed id,
    address indexed owner,
    uint256 protectionStartTimestamp,
    uint256 protectionEndTimestamp,
    uint256 premiumCostUSD,
    uint256 lpTokensWorthAtBuyTimeUSD,
    string token1Symbol,
    string token2Symbol,
    uint256 policyPeriod
  );

  function mint(
    address _owner,
    uint256 _protectionStartTimestamp,
    uint256 _protectionEndTimestamp,
    uint256 _premiumCostUSD,
    uint256 _lpTokensWorthAtBuyTimeUSD,
    string calldata _token1Symbol,
    string calldata _token2Symbol,
    uint256 _policyPeriod
  ) external;

  function tokenIdCounter() external returns (uint256);

  function getProtectionDetailsByOwnerAndIndex(address _owner, uint256 _index)
    external
    view
    returns (ProtectionNFTDetails memory);

  function getOwnerProtections(address _owner) external view returns (ProtectionNFTDetails[] memory);

  function getProtectionDetails(uint256 _id) external view returns (ProtectionNFTDetails memory);
}
