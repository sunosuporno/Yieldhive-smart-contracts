// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPool as IPoolAave} from "../interfaces/IPool.sol";
import {IPoolDataProvider} from "../interfaces/IPoolDataProvider.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TransferHelper} from "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

contract OptimismStrategy is Ownable {
    using SafeERC20 for IERC20;

    IPoolAave public immutable aavePool;
    IPoolDataProvider public immutable aaveProtocolDataProvider;
    IERC20 public immutable usdc;
    IERC20 public immutable weth;

    address public constant swapRouter =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address public constant aUSDC = 0x625E7708f30cA75bfd92586e17077590C60eb4cD;
    address public constant variableDebtWETH =
        0x0c84331e39d6658Cd6e6b9ba04736cC4c4734351;

    uint256 private constant PRICE_DENOMINATOR = 1e8;
    uint256 private constant USDC_DECIMALS = 6;
    uint256 private constant WETH_DECIMALS = 18;

    constructor(
        address _aavePool,
        address _aaveProtocolDataProvider,
        address _usdc,
        address _weth
    ) {
        aavePool = IPoolAave(_aavePool);
        aaveProtocolDataProvider = IPoolDataProvider(_aaveProtocolDataProvider);
        usdc = IERC20(_usdc);
        weth = IERC20(_weth);
    }

    function investInAave(
        address assetAddress,
        uint256 amount
    ) external onlyOwner {
        require(assetAddress == address(usdc), "Only USDC is supported");

        // Transfer USDC from the sender to this contract
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Perform the investment loop 3 times
        for (uint256 i = 0; i < 3; i++) {
            amount = _investLoop(amount);
        }
    }

    function _investLoop(uint256 usdcAmount) internal returns (uint256) {
        // 1. Supply USDC to Aave
        usdc.approve(address(aavePool), usdcAmount);
        aavePool.supply(address(usdc), usdcAmount, address(this), 0);

        // 2. Calculate borrowing capacity
        (, uint256 ltv, , , , , , , , ) = aaveProtocolDataProvider
            .getReserveConfigurationData(address(usdc));
        uint256 borrowCapacityUSDC = (usdcAmount * ltv) / 1e4; // LTV is in basis points (1e4)

        // 3. Calculate WETH amount to borrow (95% of capacity)
        uint256 wethPrice = getWETHPrice();
        uint256 wethToBorrow = (borrowCapacityUSDC * 95 * PRICE_DENOMINATOR) /
            (100 * wethPrice);

        // 4. Borrow WETH from Aave
        aavePool.borrow(address(weth), wethToBorrow, 2, 0, address(this));

        // 5. Swap WETH for USDC using Uniswap
        uint256 usdcReceived = _swapWETHToUSDC(wethToBorrow);

        return usdcReceived;
    }

    function _swapWETHToUSDC(
        uint256 amountIn
    ) internal returns (uint256 amountOut) {
        TransferHelper.safeApprove(address(weth), swapRouter, amountIn);

        bytes memory path = abi.encodePacked(
            address(weth),
            uint24(3000), // 0.3% fee tier
            address(usdc)
        );

        bytes memory data = abi.encodeWithSignature(
            "exactInput((bytes,address,uint256,uint256))",
            abi.encode(path, address(this), amountIn, 0)
        );

        (bool success, bytes memory result) = swapRouter.call(data);
        require(success, "Swap failed");
        amountOut = abi.decode(result, (uint256));
    }

    function getWETHPrice() public view returns (uint256) {
        // In a real-world scenario, you would use an oracle here.
        // For simplicity, we're using a hardcoded price.
        return 2000 * PRICE_DENOMINATOR; // Assuming 1 WETH = 2000 USDC
    }

    function withdrawAll() external onlyOwner {
        // Withdraw all USDC from Aave
        uint256 aUSDCBalance = IERC20(aUSDC).balanceOf(address(this));
        if (aUSDCBalance > 0) {
            aavePool.withdraw(address(usdc), type(uint256).max, address(this));
        }

        // Repay all WETH debt
        uint256 wethDebt = IERC20(variableDebtWETH).balanceOf(address(this));
        if (wethDebt > 0) {
            weth.approve(address(aavePool), wethDebt);
            aavePool.repay(address(weth), type(uint256).max, 2, address(this));
        }

        // Transfer all USDC to the owner
        uint256 usdcBalance = usdc.balanceOf(address(this));
        if (usdcBalance > 0) {
            usdc.safeTransfer(owner(), usdcBalance);
        }
    }
}
