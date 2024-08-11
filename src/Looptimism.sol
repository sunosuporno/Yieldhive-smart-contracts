// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPool as IPoolAave} from "./interfaces/IPool.sol";
import {IPool as IPoolAerodrome} from "./interfaces/IPoolAerodrome.sol";
import {IPoolDataProvider} from "./interfaces/IPoolDataProvider.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {TransferHelper} from "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import {IPythPriceUpdater} from "./interfaces/IPythPriceUpdater.sol";
import {ISwapRouter02, IV3SwapRouter} from "./interfaces/ISwapRouter.sol";

contract Looptimism is ERC4626, Ownable {
    using Math for uint256;
    using SafeERC20 for IERC20;
    IPyth pyth;
    IPoolAave aavePool;
    IPoolDataProvider aaveProtocolDataProvider;
    IPoolAerodrome aerodromePool;
    IPythPriceUpdater public pythPriceUpdater;
    ISwapRouter02 public immutable swapRouter;

    uint256 public _totalAccountedAssets;
    bytes32 public constant usdcUsdPriceFeedId =
        0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 public constant wbtcPriceFeedId =
        0xc9d8b075a5c69303365ae23633d4e085199bf5c520a3b90fed1322a0342ffc33;
    address public constant swapRouterAddress =
        0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address public constant usdc = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address public constant wbtc = 0x68f180fcCe6836688e9084f035309E29Bf0A2095;
    address public constant WETH9 = 0x4200000000000000000000000000000000000006;
    address public constant aUSDC = 0x38d693cE1dF5AaDF7bC62595A37D667aD57922e5;
    address public constant variableDebtWbtc =
        0x92b42c66840C7AD907b4BF74879FF3eF7c529473;
    uint256 public previousAUSDCBalance;
    uint256 public previousVariableDebtBalance;

    constructor(
        IERC20 asset_,
        uint256 _initialDeposit,
        address initialOwner,
        string memory name_,
        string memory symbol_,
        address pythContract,
        address aavePoolContract,
        address aaveProtocolDataProviderContract,
        address pythPriceUpdaterContract
    ) ERC4626(asset_) ERC20(name_, symbol_) Ownable(initialOwner) {
        // asset_.safeTransferFrom(msg.sender, address(this), _initialDeposit);
        pyth = IPyth(pythContract);
        aavePool = IPoolAave(aavePoolContract);
        aaveProtocolDataProvider = IPoolDataProvider(
            aaveProtocolDataProviderContract
        );
        pythPriceUpdater = IPythPriceUpdater(pythPriceUpdaterContract);
        swapRouter = ISwapRouter02(swapRouterAddress);
    }

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        address assetAddress = asset();
        // Transfer the assets from the caller to this contract
        SafeERC20.safeTransferFrom(
            IERC20(assetAddress),
            caller,
            address(this),
            assets
        );

        // Mint shares to the receiver
        _mint(receiver, shares);

        // Call the internal function to invest the funds
        _investFunds(assets);

        emit Deposit(caller, receiver, assets, shares);
    }

    function totalAssets() public view override returns (uint256) {
        return _totalAccountedAssets;
    }

    function _investFunds(uint256 amount) internal {
        for (uint256 i = 0; i < 3; i++) {
            bool shouldBorrow = (i != 2);
            amount = _investLoop(amount, shouldBorrow);
        }
    }

    function _investLoop(
        uint256 usdcAmount,
        bool shouldBorrow
    ) internal returns (uint256) {
        bytes32[] memory priceFeedIds = new bytes32[](2);
        priceFeedIds[0] = wbtcPriceFeedId;
        priceFeedIds[1] = usdcUsdPriceFeedId;
        uint256[] memory prices = getPricePyth(priceFeedIds);
        uint256 wbtcPriceInUSD = prices[0];
        uint256 usdcPriceInUSD = prices[1];

        // 1. Supply USDC to Aave
        IERC20(usdc).approve(address(aavePool), usdcAmount);
        aavePool.supply(address(usdc), usdcAmount, address(this), 0);

        if (shouldBorrow) {
            uint256 usdcAmountIn8Decimals = usdcAmount * 10 ** 2;
            // Finding total price of the asset supplied in USD
            uint256 usdcAmountIn8DecimalsInUSD = (usdcAmountIn8Decimals *
                (usdcPriceInUSD)) / 10 ** 8;
            // Fetching LTV of USDC from Aave
            (, uint256 ltv, , , , , , , , ) = aaveProtocolDataProvider
                .getReserveConfigurationData(address(usdc));
            // Calculating the maximum loan amount in USD
            uint256 maxLoanAmountIn8DecimalsInUSD = (usdcAmountIn8DecimalsInUSD *
                    ltv) / 10 ** 4;
            // Calculating the maximum amount of cbETH that can be borrowed
            uint256 wbtcAbleToBorrow = (maxLoanAmountIn8DecimalsInUSD *
                10 ** 8) / wbtcPriceInUSD;
            // Borrowing cbETH after calculating a safe amount
            uint256 safeAmount = (wbtcAbleToBorrow * 95) / 100;
            aavePool.borrow(address(wbtc), safeAmount, 2, 0, address(this));

            // 5. Swap wbtc for USDC using Uniswap
            uint256 usdcReceived = _swapwbtcToUSDC(safeAmount);

            return usdcReceived;
        }

        return usdcAmount;
    }

    function harvest() external onlyOwner {
        bytes32[] memory priceFeedIds = new bytes32[](2);
        priceFeedIds[0] = wbtcPriceFeedId;
        priceFeedIds[1] = usdcUsdPriceFeedId;
        uint256[] memory prices = getPricePyth(priceFeedIds);
        uint256 wbtcPriceInUSD = prices[0];
        uint256 usdcPriceInUSD = prices[1];

        // Get current balances
        uint256 currentAUSDCBalance = IERC20(aUSDC).balanceOf(address(this));
        uint256 currentVariableDebtBalance = IERC20(variableDebtWbtc).balanceOf(
            address(this)
        );

        // Calculate the change in balances
        uint256 borrowedWbtcChange = currentVariableDebtBalance -
            previousVariableDebtBalance;

        // Calculate the net gain in Aave
        uint256 suppliedUSDCValueChange = currentAUSDCBalance -
            previousAUSDCBalance;
        uint256 borrowedWbtcValueChangeInUSDC = (wbtcPriceInUSD *
            borrowedWbtcChange) / (usdcPriceInUSD * 10 ** 2);

        int256 aaveNetGain = int256(suppliedUSDCValueChange) -
            int256(borrowedWbtcValueChangeInUSDC);

        // Update the previous balances
        previousAUSDCBalance = currentAUSDCBalance;
        previousVariableDebtBalance = currentVariableDebtBalance;

        // UPdate with totalaccountedAssets
        if (aaveNetGain > 0) {
            _totalAccountedAssets += uint256(aaveNetGain);
        } else {
            _totalAccountedAssets -= uint256(-aaveNetGain);
        }
    }

    function _swap(
        address tokenIn,
        address tokenOut,
        uint256 fee1,
        uint256 fee2,
        uint256 amountIn
    ) internal returns (uint256 amountOut) {
        TransferHelper.safeApprove(tokenIn, address(swapRouter), amountIn);

        bytes memory path = abi.encodePacked(
            tokenIn,
            uint24(fee1),
            WETH9,
            uint24(fee2),
            tokenOut
        );

        IV3SwapRouter.ExactInputParams memory params = IV3SwapRouter
            .ExactInputParams({
                path: path,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: 0
            });

        amountOut = swapRouter.exactInput(params);
    }

    function _swapwbtcToUSDC(
        uint256 amountIn
    ) internal returns (uint256 amountOut) {
        amountOut = _swap(wbtc, asset(), 500, 500, amountIn);
    }

    function getPricePyth(
        bytes32[] memory priceFeedIds
    ) public payable returns (uint256[] memory) {
        bytes[] memory priceUpdate = pythPriceUpdater.getPricePyth();
        uint fee = pyth.getUpdateFee(priceUpdate);
        pyth.updatePriceFeeds{value: fee}(priceUpdate);

        uint256[] memory prices = new uint256[](priceFeedIds.length);

        // Read the current price from each price feed if it is less than 60 seconds old.
        for (uint i = 0; i < priceFeedIds.length; i++) {
            PythStructs.Price memory pythPrice = pyth.getPriceNoOlderThan(
                priceFeedIds[i],
                120
            );

            // Convert the price to a uint256 value
            // The price is stored as a signed integer with a specific exponent
            // We need to adjust it to get the actual price in a common unit (e.g., 18 decimals)
            int64 price = pythPrice.price;

            // Convert the price to a positive value with 18 decimals
            uint256 adjustedPrice = uint256(uint64(price));

            prices[i] = adjustedPrice;
        }

        return prices;
    }
}
