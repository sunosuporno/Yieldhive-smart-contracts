pragma solidity ^0.8.26;

interface IxRenzoDeposit {
    function depositETH(uint256 _minOut, uint256 _deadline) external payable returns (uint256);
    function sweep() external payable;

    function updatePrice(uint256 price, uint256 timestamp) external;
}
