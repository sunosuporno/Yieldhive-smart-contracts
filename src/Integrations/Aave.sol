// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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

    function supplyAndBorrow(SupplyAndBorrowParams memory params)
        external
        returns (SupplyAndBorrowResult memory result)
    {
        // 1. Supply asset
        IERC20(params.assetToSupply).approve(address(params.pool), params.supplyAmount);
        params.pool.supply(params.assetToSupply, params.supplyAmount, address(this), 0);

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
        params.pool.borrow(params.assetToBorrow, safeAmount, 2, 0, address(this));

        // 6. Get final balances
        result.suppliedAmount = params.supplyAmount;
        result.borrowedAmount = safeAmount;
        result.aTokenBalance = IERC20(params.assetToSupply).balanceOf(address(this));
        result.debtTokenBalance = IERC20(params.assetToBorrow).balanceOf(address(this));

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
}
