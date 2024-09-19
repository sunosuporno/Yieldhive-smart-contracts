pragma solidity ^0.8.21;

interface IRSETHPoolV2 {
    function deposit(string memory referralId) external payable;

    function viewSwapRsETHAmountAndFee(uint256 amount) external view returns (uint256 rsETHAmount, uint256 fee);
}
