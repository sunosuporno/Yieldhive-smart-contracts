// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/Test.sol";
import {IPool as IPoolAave} from "../interfaces/IPool.sol";
import {IPoolDataProvider} from "../interfaces/IPoolDataProvider.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

library Aave {
    using SafeERC20 for IERC20;

    struct SupplyAndBorrowParams {
        IPoolAave pool;
        IPoolDataProvider dataProvider;
        address assetToSupply;
        address assetToBorrow;
        address onBehalfOf;
        uint256 supplyAmount;
        uint256 supplyPriceUSD;
        uint256 borrowPriceUSD;
        uint256 safetyFactor; // e.g., 95 for 95%
    }

    struct SupplyAndBorrowResult {
        uint256 suppliedAmount;
        uint256 borrowedAmount;
        uint256 aTokenBalance;
        uint256 debtTokenBalance;
    }

    struct RebalanceParams {
        IPoolAave pool;
        address assetToRepay;
        uint256 repayAmount;
        uint256 targetHealthFactor;
        uint256 healthFactorBuffer;
    }

    struct RebalanceResult {
        uint256 healthFactorAdjustment;
        uint256 totalAmountToFreeUp;
    }

    struct HarvestParams {
        IPoolAave pool;
        address aToken; // aUSDC address
        address debtToken; // variableDebtCbETH address
        address user; // Add this field for the vault address
        uint256 previousAUSDCBalance;
        uint256 previousDebtBalance;
        uint256 cbEthPriceUSD;
        uint256 usdcPriceUSD;
    }

    struct HarvestResult {
        int256 aaveNetGain;
        uint256 newAUSDCBalance;
        uint256 newDebtBalance;
    }

    address constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant AAVE_POOL_DATA_PROVIDER = 0x793177a6Cf520C7fE5B2E45660EBB48132184BBC;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant CBETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    address constant A_USDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address constant DEBT_CBETH = 0x1DabC36f19909425f654777249815c073E8Fd79F;
    address constant usdcUsdDataFeedAddress = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address constant cbEthUsdDataFeedAddress = 0xd7818272B9e248357d13057AAb0B417aF31E817d;
    address constant aeroUsdDataFeedAddress = 0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0;

    function supplyAndBorrow(uint256 amount, address recipient, uint256 usdcPriceInUSD, uint256 cbEthPriceInUSD)
        external
        returns (uint256 previousAUSDCBalance, uint256 previousVariableDebtBalance)
    {
        console.log("\nSupply and Borrow Running");
        console.log("supplying USDC to Aave");
        console.log("recipient", recipient);
        IERC20(USDC).approve(address(AAVE_POOL), amount);
        IPoolAave(AAVE_POOL).supply(USDC, amount, recipient, 0);

        console.log("invested in Aave");

        // Convert the amount of USDC supplied to 18 decimals
        uint256 usdcAmountIn18Decimals = amount * 10 ** 12;
        // Finding total price of the asset supplied in USD (now correctly using 10**8)
        uint256 usdcAmountIn18DecimalsInUSD = (usdcAmountIn18Decimals * usdcPriceInUSD) / 10 ** 8;
        // Fetching LTV of USDC from Aave
        (, uint256 ltv,,,,,,,,) = IPoolDataProvider(AAVE_POOL_DATA_PROVIDER).getReserveConfigurationData(USDC);
        // Calculating the maximum loan amount in USD
        uint256 maxLoanAmountIn18DecimalsInUSD = (usdcAmountIn18DecimalsInUSD * ltv) / 10 ** 4;
        // Calculating the maximum amount of cbETH that can be borrowed (now correctly using 10**8)
        uint256 cbEthAbleToBorrow = (maxLoanAmountIn18DecimalsInUSD * 10 ** 8) / cbEthPriceInUSD;
        // Borrowing cbETH after calculating a safe amount
        uint256 safeAmount = (cbEthAbleToBorrow * 95) / 100;
        console.log("safeAmount", safeAmount);
        IPoolAave(AAVE_POOL).borrow(CBETH, safeAmount, 2, 0, recipient);
        console.log("borrowed cbETH");
        //calculate aToken And debtToken balances
        previousAUSDCBalance = IERC20(A_USDC).balanceOf(recipient);
        previousVariableDebtBalance = IERC20(DEBT_CBETH).balanceOf(recipient);
    }

    function calculateRebalanceAmount(RebalanceParams memory params)
        external
        view
        returns (RebalanceResult memory result)
    {
        // Get user account data
        (uint256 totalCollateralBase, uint256 totalDebtBase,, uint256 currentLiquidationThreshold,,) =
            params.pool.getUserAccountData(msg.sender);

        uint256 bufferedTargetHealthFactor = params.targetHealthFactor + params.healthFactorBuffer;

        // Calculate health factor adjustment
        result.healthFactorAdjustment = (
            (totalDebtBase * bufferedTargetHealthFactor) - (totalCollateralBase * currentLiquidationThreshold)
        ) / (bufferedTargetHealthFactor * 100);

        result.totalAmountToFreeUp = params.repayAmount;
        if (result.healthFactorAdjustment > 0) {
            result.totalAmountToFreeUp += result.healthFactorAdjustment;
        }

        return result;
    }

    function repayDebt(IPoolAave pool, address asset, uint256 amount, address onBehalfOf) external {
        IERC20(asset).approve(address(pool), amount);
        pool.repay(asset, amount, 2, onBehalfOf);
    }

    function calculateHealthFactor(IPoolAave pool, address user) external view returns (uint256) {
        (,,,,, uint256 healthFactor) = pool.getUserAccountData(user);
        return healthFactor;
    }

    function harvest(HarvestParams memory params) external view returns (HarvestResult memory result) {
        console.log("\nHarvest Running");
        // Get current balances using the user address instead of msg.sender
        result.newAUSDCBalance = IERC20(params.aToken).balanceOf(params.user);
        console.log("newAUSDCBalance: %s", result.newAUSDCBalance);
        result.newDebtBalance = IERC20(params.debtToken).balanceOf(params.user);
        console.log("newDebtBalance: %s", result.newDebtBalance);
        // Calculate interest earned on USDC (in USDC terms)
        uint256 usdcInterestEarned = 0;
        if (result.newAUSDCBalance > params.previousAUSDCBalance) {
            usdcInterestEarned = result.newAUSDCBalance - params.previousAUSDCBalance;
            console.log("usdcInterestEarned: %s", usdcInterestEarned);
        }

        // Calculate debt increase (in cbETH terms)
        uint256 debtIncrease = 0;
        if (result.newDebtBalance > params.previousDebtBalance) {
            debtIncrease = result.newDebtBalance - params.previousDebtBalance;
            console.log("debtIncrease: %s", debtIncrease);
        }

        // Convert debt increase to USDC equivalent using price feeds
        uint256 debtIncreaseInUSDC = (debtIncrease * params.cbEthPriceUSD) / 1e18; // cbETH has 18 decimals
        debtIncreaseInUSDC = (debtIncreaseInUSDC * 1e6) / params.usdcPriceUSD; // Convert to USDC decimals
        console.log("debtIncreaseInUSDC: %s", debtIncreaseInUSDC);
        // Calculate net gain/loss in USDC terms
        if (usdcInterestEarned > debtIncreaseInUSDC) {
            result.aaveNetGain = int256(usdcInterestEarned - debtIncreaseInUSDC);
            console.log("aaveNetGain: %s", result.aaveNetGain);
        } else {
            result.aaveNetGain = -int256(debtIncreaseInUSDC - usdcInterestEarned);
            console.log("aaveNetGain: %s", result.aaveNetGain);
        }

        return result;
    }
}
