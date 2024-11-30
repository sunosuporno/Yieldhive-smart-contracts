// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/Test.sol";
import {IPool as IPoolAave} from "../interfaces/IPool.sol";
import {IPoolDataProvider} from "../interfaces/IPoolDataProvider.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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

    function supplyAndBorrow(SupplyAndBorrowParams memory params)
        external
        returns (SupplyAndBorrowResult memory result)
    {
        console.log("\nSupply and Borrow Running");
        // 1. Supply asset
        IERC20(params.assetToSupply).approve(address(params.pool), params.supplyAmount);
        params.pool.supply(params.assetToSupply, params.supplyAmount, params.onBehalfOf, 0);

        // 2. Calculate borrow amount
        uint256 supplyAmountIn18Decimals = params.supplyAmount * 10 ** 12; // Convert USDC to 18 decimals
        uint256 supplyAmountInUSD = (supplyAmountIn18Decimals * params.supplyPriceUSD) / 10 ** 8;

        // 3. Get LTV from Aave
        (, uint256 ltv,,,,,,,,) = params.dataProvider.getReserveConfigurationData(params.assetToSupply);

        // 4. Calculate maximum borrow amount
        uint256 maxLoanAmountInUSD = (supplyAmountInUSD * ltv) / 10 ** 4;
        uint256 assetAbleToBorrow = (maxLoanAmountInUSD * 10 ** 8) / params.borrowPriceUSD;
        uint256 safeAmount = (assetAbleToBorrow * params.safetyFactor) / 100;

        // 5. Borrow asset
        params.pool.borrow(params.assetToBorrow, safeAmount, 2, 0, params.onBehalfOf);

        // 6. Get final balances
        result.suppliedAmount = params.supplyAmount;
        result.borrowedAmount = safeAmount;
        result.aTokenBalance = IERC20(params.assetToSupply).balanceOf(params.onBehalfOf);
        result.debtTokenBalance = IERC20(params.assetToBorrow).balanceOf(params.onBehalfOf);

        return result;
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
