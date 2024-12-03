// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IPool as IPoolAave} from "../../src/interfaces/IPool.sol";
import {IPool as IPoolAerodrome} from "../../src/interfaces/IPoolAerodrome.sol";
import {IPoolDataProvider} from "../../src/interfaces/IPoolDataProvider.sol";
import {TransferHelper} from "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import {ISwapRouter02, IV3SwapRouter} from "../../src/interfaces/ISwapRouter.sol";
import {IAaveOracle} from "../../src/interfaces/IAaveOracle.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {console} from "forge-std/Test.sol";
import {Uniswap} from "../../src/Integrations/Uniswap.sol";

contract VaultStrategyV2 is
    Initializable,
    ERC4626Upgradeable,
    Ownable2StepUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable
{
    using Math for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    IPoolAave aavePool;
    IAaveOracle aaveOracle;
    IPoolDataProvider aaveProtocolDataProvider;
    IPoolAerodrome public aerodromePool;
    ISwapRouter02 public swapRouter;
    AggregatorV3Interface public priceFeed;
    address public constant swapRouterAddress = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address public constant cbETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    address public constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address public constant WETH9 = 0x4200000000000000000000000000000000000006;
    address public constant aUSDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address public constant variableDebtCbETH = 0x1DabC36f19909425f654777249815c073E8Fd79F;
    uint256 public _totalAccountedAssets;
    address public constant usdcUsdDataFeedAddress = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address public constant cbEthUsdDataFeedAddress = 0xd7818272B9e248357d13057AAb0B417aF31E817d;
    address public constant aeroUsdDataFeedAddress = 0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0;

    // Add new state variables to keep track of the previous balances
    uint256 public previousAUSDCBalance;
    uint256 public previousVariableDebtBalance;
    int256 public netDepositedUSDC;
    int256 public netBorrowedCbETH;
    uint256 public lastHarvestAUSDCBalance;
    uint256 public lastHarvestDebtBalance;

    // Define the target health factor with 4 decimal places
    uint256 public constant TARGET_HEALTH_FACTOR = 10300; // 1.03 with 4 decimal places
    uint256 public constant HEALTH_FACTOR_BUFFER = 300; // 0.03 with 4 decimal places

    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");

    // Add strategist address and fee percentage
    address public strategist;
    uint256 public accumulatedStrategistFee;
    uint256 public constant STRATEGIST_FEE_PERCENTAGE = 2000; // 20% with 2 decimal places

    // Add this state variable
    uint256 public accumulatedDeposits;

    uint256 public dummyVariable;

    event StrategistFeeClaimed(uint256 claimedAmount, uint256 remainingFees);

    event PositionRebalanced(
        uint256 additionalAmountNeeded,
        uint256 amountFreedUp,
        uint256 lpTokensBurned,
        uint256 usdcReceived,
        uint256 aeroReceived,
        uint256 cbEthRepaid
    );

    event HarvestReport(
        uint256 totalProfit,
        uint256 netProfit,
        uint256 strategistFee,
        uint256 aerodromeRewards,
        int256 aaveNetGain,
        uint256 claimedAero,
        uint256 claimedUsdc
    );

    // Add this to track library address
    address public aaveLibrary;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        IERC20 asset_,
        uint256 _initialDeposit,
        address initialOwner,
        string memory name_,
        string memory symbol_,
        address aavePoolContract,
        address aaveProtocolDataProviderContract,
        address aaveOracleContract,
        address _strategist,
        address aerodromePoolContract
    ) public initializer {
        __ERC4626_init(asset_);
        __ERC20_init(name_, symbol_);
        __Ownable_init(initialOwner);
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(REBALANCER_ROLE, initialOwner);
        aavePool = IPoolAave(aavePoolContract);
        aaveProtocolDataProvider = IPoolDataProvider(aaveProtocolDataProviderContract);
        swapRouter = ISwapRouter02(swapRouterAddress);
        aaveOracle = IAaveOracle(aaveOracleContract);
        strategist = _strategist;
        aerodromePool = IPoolAerodrome(aerodromePoolContract);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        // Additional upgrade authorization logic can go here
    }

    // New internal function that includes priceUpdate
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        address assetAddress = asset();
        // Transfer the assets from the caller to this contract
        SafeERC20.safeTransferFrom(IERC20(assetAddress), caller, address(this), assets);

        // Mint shares to the receiver
        _mint(receiver, shares);

        // Add accounting for _totalAccountedAssets
        _totalAccountedAssets += assets;
        console.log("Accumulated deposits", accumulatedDeposits);
        console.log("Assets", assets);
        _investFunds(assets, assetAddress);

        emit Deposit(caller, receiver, assets, shares);
    }

    function _withdrawFunds(uint256 amount, bool isStrategistFee) internal returns (uint256 withdrawnAmount) {
        console.log("withdrawing funds");
        uint256 maxWithdrawable = getMaxWithdrawableAmount();
        console.log("maxWithdrawable", maxWithdrawable);

        if (amount <= maxWithdrawable) {
            // Get balance before withdrawal
            uint256 balanceBefore = IERC20(asset()).balanceOf(address(this));

            console.log("withdrawing from Aave");
            aavePool.withdraw(asset(), amount, address(this));
            if (!isStrategistFee) {
                netDepositedUSDC -= int256(amount);
            }
            console.log("netDepositedUSDC", netDepositedUSDC);
            // Calculate actual withdrawn amount
            withdrawnAmount = IERC20(asset()).balanceOf(address(this)) - balanceBefore;

            // Check and rebalance if necessary
            uint256 healthFactor = this.calculateHealthFactor();
            uint256 currentHealthFactor4Dec = healthFactor / 1e14;
            console.log("currentHealthFactor4Dec", currentHealthFactor4Dec);
            uint256 bufferedTargetHealthFactor = TARGET_HEALTH_FACTOR + HEALTH_FACTOR_BUFFER;
            console.log("currentHealthFactor4Dec", currentHealthFactor4Dec);
            if (currentHealthFactor4Dec < bufferedTargetHealthFactor) {
                console.log("rebalancing position");
                _rebalancePosition(0, isStrategistFee);
            }
        } else {
            console.log("withdrawing more than maxWithdrawable");
            // Get balance before withdrawal
            uint256 balanceBefore = IERC20(asset()).balanceOf(address(this));

            aavePool.withdraw(asset(), (maxWithdrawable - 10), address(this));
            if (!isStrategistFee) {
                netDepositedUSDC -= int256(maxWithdrawable - 10);
            }
            console.log("netDepositedUSDC", netDepositedUSDC);
            // Calculate actual withdrawn amount
            withdrawnAmount = IERC20(asset()).balanceOf(address(this)) - balanceBefore;

            console.log("withdrawnAmount", withdrawnAmount);
            console.log("withdrew from Aave");
            uint256 additionalAmountNeeded = amount - withdrawnAmount;
            console.log("additionalAmountNeeded", additionalAmountNeeded);
            _rebalancePosition(additionalAmountNeeded, isStrategistFee);
            console.log("rebalanced position");

            // After rebalancing, try to withdraw any remaining amount
            uint256 newMaxWithdrawable = getMaxWithdrawableAmount();
            console.log("newMaxWithdrawable", newMaxWithdrawable);
            uint256 remainingWithdrawal = Math.min(additionalAmountNeeded, newMaxWithdrawable);
            console.log("remainingWithdrawal", remainingWithdrawal);
            if (remainingWithdrawal > 0) {
                console.log("withdrawing remaining amount");

                aavePool.withdraw(asset(), (remainingWithdrawal - 10), address(this));
                console.log("withdraw done");
                if (!isStrategistFee) {
                    netDepositedUSDC -= int256(amount);
                }
                console.log("netDepositedUSDC", netDepositedUSDC);
                // Add actual withdrawn amount to previous withdrawnAmount
                withdrawnAmount += remainingWithdrawal - 10;
                console.log("withdrawnAmount", withdrawnAmount);
                console.log("withdrawn remaining amount", withdrawnAmount);
                uint256 balanceofContract = IERC20(asset()).balanceOf(address(this));
                console.log("balanceofContract", balanceofContract);
            }
        }
    }

    function _investFunds(uint256 amount, address assetAddress) internal {
        // Get the price of the assets in USD from Pyth Network
        address[] memory dataFeedAddresses = new address[](3);
        dataFeedAddresses[0] = usdcUsdDataFeedAddress;
        dataFeedAddresses[1] = cbEthUsdDataFeedAddress;
        dataFeedAddresses[2] = aeroUsdDataFeedAddress;
        uint256[] memory prices = getChainlinkDataFeedLatestAnswer(dataFeedAddresses);
        uint256 usdcPriceInUSD = prices[0];
        uint256 cbEthPriceInUSD = prices[1];
        uint256 aeroPriceInUSD = prices[2];
        // approve and supply the asset USDC to the Aave pool
        IERC20(assetAddress).approve(address(aavePool), amount);
        aavePool.supply(assetAddress, amount, address(this), 0);
        netDepositedUSDC += int256(amount);
        console.log("netDepositedUSDC", netDepositedUSDC);
        console.log("invested in Aave");

        // Convert the amount of USDC supplied to 18 decimals
        uint256 usdcAmountIn18Decimals = amount * 10 ** 12;
        // Finding total price of the asset supplied in USD (now correctly using 10**8)
        uint256 usdcAmountIn18DecimalsInUSD = (usdcAmountIn18Decimals * usdcPriceInUSD) / 10 ** 8;
        // Fetching LTV of USDC from Aave
        (, uint256 ltv,,,,,,,,) = aaveProtocolDataProvider.getReserveConfigurationData(assetAddress);
        // Calculating the maximum loan amount in USD
        uint256 maxLoanAmountIn18DecimalsInUSD = (usdcAmountIn18DecimalsInUSD * ltv) / 10 ** 4;
        // Calculating the maximum amount of cbETH that can be borrowed (now correctly using 10**8)
        uint256 cbEthAbleToBorrow = (maxLoanAmountIn18DecimalsInUSD * 10 ** 8) / cbEthPriceInUSD;
        // Borrowing cbETH after calculating a safe amount
        uint256 safeAmount = (cbEthAbleToBorrow * 95) / 100;
        aavePool.borrow(cbETH, safeAmount, 2, 0, address(this));
        netBorrowedCbETH += int256(safeAmount);
        console.log("netBorrowedCbETH", netBorrowedCbETH);
        console.log("borrowed cbETH");
        //calculate aToken And debtToken balances
        previousAUSDCBalance = IERC20(aUSDC).balanceOf(address(this));
        previousVariableDebtBalance = IERC20(variableDebtCbETH).balanceOf(address(this));

        uint256 cbEthBalance = IERC20(cbETH).balanceOf(address(this));
        (uint256 usdcReceived, uint256 aeroReceived) =
            Uniswap.swapcbETHToUSDCAndAERO(cbEthBalance, usdcPriceInUSD, cbEthPriceInUSD, aeroPriceInUSD);
        console.log("swapped cbETH to USDC and AERO");
        IERC20(asset()).safeTransfer(address(aerodromePool), usdcReceived);
        IERC20(AERO).safeTransfer(address(aerodromePool), aeroReceived);
        aerodromePool.mint(address(this));
        aerodromePool.skim(address(this));
    }

    function _rebalancePosition(uint256 additionalAmountNeeded, bool isStrategistFee) internal {
        // Only proceed with rebalancing if we actually need additional funds
        if (additionalAmountNeeded == 0) {
            console.log("No rebalancing needed - sufficient funds in Aave");
            return;
        }

        address[] memory dataFeedAddresses = new address[](3);
        dataFeedAddresses[0] = cbEthUsdDataFeedAddress;
        dataFeedAddresses[1] = usdcUsdDataFeedAddress;
        dataFeedAddresses[2] = aeroUsdDataFeedAddress;
        uint256[] memory prices = getChainlinkDataFeedLatestAnswer(dataFeedAddresses);
        uint256 cbEthPriceInUsd = prices[0];
        uint256 usdcPriceInUsd = prices[1];
        uint256 aeroPriceInUsd = prices[2];

        uint256 amountToFreeUp = additionalAmountNeeded;
        console.log("amountToFreeUp", amountToFreeUp);

        // Check if we need to rebalance for health factor
        (uint256 totalCollateralBase, uint256 totalDebtBase,, uint256 currentLiquidationThreshold,,) =
            aavePool.getUserAccountData(address(this));

        console.log("totalCollateralBase", totalCollateralBase);
        console.log("totalDebtBase", totalDebtBase);
        console.log("currentLiquidationThreshold", currentLiquidationThreshold);

        uint256 bufferedTargetHealthFactor = TARGET_HEALTH_FACTOR + HEALTH_FACTOR_BUFFER;
        console.log("bufferedTargetHealthFactor", bufferedTargetHealthFactor);

        // Fix: Adjust calculation order and decimal handling
        uint256 healthFactorAdjustment = (
            (totalDebtBase * bufferedTargetHealthFactor) - (totalCollateralBase * currentLiquidationThreshold)
        ) / (bufferedTargetHealthFactor * 100);

        // If health factor needs adjustment, add it to amount to free up
        if (healthFactorAdjustment > 0) {
            console.log("Additional rebalancing needed for health factor:", healthFactorAdjustment);
            amountToFreeUp += healthFactorAdjustment;
            console.log("amountToFreeUp after health factor adjustment", amountToFreeUp);
        }

        // Only proceed with LP operations if we need to free up funds
        if (amountToFreeUp > 0) {
            uint256 cbEthEquivalent = (amountToFreeUp * 1e18 * usdcPriceInUsd) / (cbEthPriceInUsd * 1e6);
            console.log("cbEthEquivalent", cbEthEquivalent);

            // Convert cbEthEquivalent to USD value with 8 decimals
            uint256 cbEthValueInUsd = (cbEthEquivalent * cbEthPriceInUsd) / 1e18;
            console.log("cbEthValueInUsd", cbEthValueInUsd);

            // Calculate how much to withdraw from Aerodrome Pool
            uint256 lpTokensToBurn = _calculateLPTokensToWithdraw(cbEthValueInUsd, usdcPriceInUsd, aeroPriceInUsd);
            console.log("lpTokensToBurn", lpTokensToBurn);

            if (lpTokensToBurn > 0) {
                IERC20(address(aerodromePool)).transfer(address(aerodromePool), lpTokensToBurn);
                (uint256 usdc, uint256 aero) = aerodromePool.burn(address(this));
                console.log("usdc received", usdc);
                console.log("aero received", aero);

                // Swap USDC and AERO to cbETH
                uint256 cbEthReceived =
                    Uniswap.swapUSDCAndAEROToCbETH(usdc, aero, cbEthPriceInUsd, usdcPriceInUsd, aeroPriceInUsd);
                console.log("cbEthReceived", cbEthReceived);

                // Repay cbETH debt
                IERC20(cbETH).approve(address(aavePool), cbEthReceived);
                aavePool.repay(cbETH, cbEthReceived, 2, address(this));
                if (!isStrategistFee) {
                    netBorrowedCbETH -= int256(cbEthReceived);
                }

                // Emit the rebalancing event
                emit PositionRebalanced(
                    additionalAmountNeeded, amountToFreeUp, lpTokensToBurn, usdc, aero, cbEthReceived
                );
            }
        }
    }

    function checkAndRebalance() external payable onlyRole(REBALANCER_ROLE) {
        uint256 healthFactor = this.calculateHealthFactor();
        uint256 currentHealthFactor4Dec = healthFactor / 1e14;
        uint256 bufferedTargetHealthFactor = TARGET_HEALTH_FACTOR + HEALTH_FACTOR_BUFFER;

        if (currentHealthFactor4Dec < bufferedTargetHealthFactor) {
            // Calculate how much we need to rebalance based on current position
            (uint256 totalCollateralBase, uint256 totalDebtBase,, uint256 currentLiquidationThreshold,,) =
                aavePool.getUserAccountData(address(this));

            uint256 healthFactorAdjustment = (
                (totalDebtBase * bufferedTargetHealthFactor) - (totalCollateralBase * currentLiquidationThreshold)
            ) / (bufferedTargetHealthFactor * 100);

            _rebalancePosition(healthFactorAdjustment, false);
        }
    }

    function calculateHealthFactor() external view returns (uint256) {
        (,,,,, uint256 healthFactor) = aavePool.getUserAccountData(address(this));

        return healthFactor;
    }

    function _calculateLPTokensToWithdraw(uint256 cbEthValueInUsd, uint256 usdcPriceInUsd, uint256 aeroPriceInUsd)
        internal
        view
        returns (uint256 sharesToBurn)
    {
        console.log("calculating LP tokens to withdraw");

        // Get pool reserves and total supply
        (uint256 reserve0, uint256 reserve1,) = aerodromePool.getReserves();
        console.log("reserve0", reserve0);
        console.log("reserve1", reserve1);
        uint256 totalSupplyPoolToken = IERC20(address(aerodromePool)).totalSupply();
        console.log("totalSupplyPoolToken", totalSupplyPoolToken);
        uint256 ourLPBalance = IERC20(address(aerodromePool)).balanceOf(address(this));
        console.log("ourLPBalance", ourLPBalance);
        // Calculate the total pool value in USD
        uint256 usdcValueInPool = (reserve0 * usdcPriceInUsd) / 1e6; // USDC has 6 decimals
        uint256 aeroValueInPool = (reserve1 * aeroPriceInUsd) / 1e18; // AERO has 18 decimals

        uint256 totalPoolValueInUsd = usdcValueInPool + aeroValueInPool;
        console.log("totalPoolValueInUsd", totalPoolValueInUsd);

        uint256 halfCbEthValueInUsd = cbEthValueInUsd / 2;
        console.log("halfCbEthValueInUsd", halfCbEthValueInUsd);
        uint256 desiredUsdc = (halfCbEthValueInUsd * 1e6) / usdcPriceInUsd;
        console.log("desiredUsdc", desiredUsdc);

        // Calculate what portion of the pool we need to withdraw
        uint256 sharesToBurnBig = (cbEthValueInUsd * totalSupplyPoolToken) / totalPoolValueInUsd;

        // Make sure we don't try to burn more than we have
        sharesToBurn = Math.min(sharesToBurnBig, ourLPBalance);
        console.log("sharesToBurn", sharesToBurn);
    }

    function harvestReinvestAndReport() external onlyOwner nonReentrant {
        // Get prices from Pyth Network
        address[] memory dataFeedAddresses = new address[](3);
        dataFeedAddresses[0] = cbEthUsdDataFeedAddress;
        dataFeedAddresses[1] = usdcUsdDataFeedAddress;
        dataFeedAddresses[2] = aeroUsdDataFeedAddress;
        uint256[] memory prices = getChainlinkDataFeedLatestAnswer(dataFeedAddresses);
        uint256 cbETHPrice = prices[0];
        uint256 usdcPrice = prices[1];
        uint256 aeroPrice = prices[2];

        console.log("\nHarvest Running");

        // Get current balances
        uint256 currentAUSDCBalance = IERC20(aUSDC).balanceOf(address(this));
        uint256 currentVariableDebtBalance = IERC20(variableDebtCbETH).balanceOf(address(this));
        console.log("currentAUSDCBalance", currentAUSDCBalance);
        console.log("currentVariableDebtBalance", currentVariableDebtBalance);
        // Calculate changes since last harvest (could be negative)
        int256 aUSDCBalanceChange = int256(currentAUSDCBalance) - int256(lastHarvestAUSDCBalance);
        int256 debtBalanceChange = int256(currentVariableDebtBalance) - int256(lastHarvestDebtBalance);
        console.log("aUSDCBalanceChange", aUSDCBalanceChange);
        console.log("debtBalanceChange", debtBalanceChange);
        // Calculate net deposits/borrows since last harvest (could be negative)
        int256 netDepositChange = int256(netDepositedUSDC) - int256(lastHarvestAUSDCBalance);
        int256 netBorrowChange = int256(netBorrowedCbETH) - int256(lastHarvestDebtBalance);
        console.log("netDepositChange", netDepositChange);
        console.log("netBorrowChange", netBorrowChange);
        // Calculate actual interest earned/paid
        int256 actualUSDCInterest = aUSDCBalanceChange - netDepositChange;
        int256 actualDebtIncrease = debtBalanceChange - netBorrowChange;
        console.log("actualUSDCInterest", actualUSDCInterest);
        console.log("actualDebtIncrease", actualDebtIncrease);
        // Convert debt to USDC terms (convert to positive uint256 first if negative)
        uint256 debtIncreaseInUSDC;
        if (actualDebtIncrease > 0) {
            debtIncreaseInUSDC = (uint256(actualDebtIncrease) * cbETHPrice) / (usdcPrice * 10 ** 12);
            console.log("debtIncreaseInUSDC", debtIncreaseInUSDC);
        } else {
            debtIncreaseInUSDC = (uint256(-actualDebtIncrease) * cbETHPrice) / (usdcPrice * 10 ** 12);
            console.log("debtIncreaseInUSDC", debtIncreaseInUSDC);
        }

        // Calculate net gain
        int256 aaveNetGain =
            actualUSDCInterest - (actualDebtIncrease > 0 ? int256(debtIncreaseInUSDC) : -int256(debtIncreaseInUSDC));
        console.log("aaveNetGain", aaveNetGain);
        // Update state for next harvest
        lastHarvestAUSDCBalance = currentAUSDCBalance;
        lastHarvestDebtBalance = currentVariableDebtBalance;

        // Claim fees from Aerodrome Pool
        (uint256 claimedUsdc, uint256 claimedAero) = aerodromePool.claimFees();
        console.log("claimedUsdc", claimedUsdc);
        console.log("claimedAero", claimedAero);

        uint256 aeroValueInUsd = (claimedAero * aeroPrice) / (10 ** 18); // Adjust for AERO's 18 decimals
        uint256 usdcValueInUsd = (claimedUsdc * usdcPrice) / (10 ** 6); // Adjust for USDC's 6 decimals
        console.log("aeroValueInUsd", aeroValueInUsd);
        console.log("usdcValueInUsd", usdcValueInUsd);

        // Calculate total rewards in USDC terms using the claimed amounts directly
        uint256 totalRewardsInUSDC = (usdcValueInUsd + aeroValueInUsd) * 1e6 / (usdcPrice);
        console.log("totalRewardsInUSDC", totalRewardsInUSDC);

        // Calculate total profit, including Aerodrome rewards and Aave net gain
        int256 totalProfit = int256(totalRewardsInUSDC) + aaveNetGain;
        console.log("totalProfit", totalProfit);
        // Only apply fee if there's a positive profit
        uint256 strategistFee = 0;
        if (totalProfit > 0) {
            strategistFee = (uint256(totalProfit) * STRATEGIST_FEE_PERCENTAGE) / 10000;
            accumulatedStrategistFee += strategistFee;
        }

        // Calculate net profit after fee
        uint256 netProfit = totalProfit > 0 ? uint256(totalProfit) - strategistFee : 0;

        // Update total accounted assets
        if (totalProfit > 0) {
            _totalAccountedAssets += netProfit;
        } else if (totalProfit < 0) {
            _totalAccountedAssets -= uint256(-totalProfit);
        }

        // Reinvest all rewards in Aerodrome Pool
        if (totalRewardsInUSDC > 0) {
            // swap all rewards to USDC
            uint256 aeroBal = IERC20(AERO).balanceOf(address(this));
            if (aeroBal > 0) Uniswap.swapAEROToUSDC(aeroBal, usdcPrice, aeroPrice);
            uint256 usdcBalance = IERC20(asset()).balanceOf(address(this));
            _investFunds(usdcBalance, address(asset()));
        }

        // After reinvestment, withdraw and transfer strategist fee if any
        if (strategistFee > 0) {
            uint256 withdrawnAmount = _withdrawFunds(strategistFee, true);
            IERC20(asset()).safeTransfer(strategist, withdrawnAmount);
        }

        emit HarvestReport(
            uint256(totalProfit), netProfit, strategistFee, totalRewardsInUSDC, aaveNetGain, claimedAero, claimedUsdc
        );
    }

    function totalAssets() public view override returns (uint256) {
        return _totalAccountedAssets;
    }

    function getChainlinkDataFeedLatestAnswer(address[] memory dataFeeds) public payable returns (uint256[] memory) {
        // Create array to store prices
        uint256[] memory prices = new uint256[](dataFeeds.length);

        // Get prices for each feed
        for (uint256 i = 0; i < dataFeeds.length; i++) {
            // Get latest round data
            (
                /* uint80 roundID */
                ,
                int256 answer,
                uint256 startedAt,
                uint256 timeStamp,
                /* uint80 answeredInRound */
            ) = AggregatorV3Interface(dataFeeds[i]).latestRoundData();

            // Convert to uint256 and store in prices array
            prices[i] = uint256(answer);
        }

        return prices;
    }

    // Function to grant the rebalancer role
    function grantRebalancerRole(address account) external onlyOwner {
        grantRole(REBALANCER_ROLE, account);
    }

    // Function to revoke the rebalancer role
    function revokeRebalancerRole(address account) external onlyOwner {
        revokeRole(REBALANCER_ROLE, account);
    }

    function getMaxWithdrawableAmount() public view returns (uint256) {
        // Get the available (unborrowed) liquidity - fix the address here
        uint256 availableLiquidity = IERC20(aUSDC).balanceOf(address(this));

        (uint256 totalCollateralBase, uint256 totalDebtBase,, uint256 currentLiquidationThreshold,,) =
            aavePool.getUserAccountData(address(this));

        // Calculate the maximum amount that can be withdrawn without risking liquidation
        uint256 maxWithdrawBase = totalCollateralBase - ((totalDebtBase * 10000) / currentLiquidationThreshold);

        // Get the price feed from AaveOracle
        uint256 usdcPriceInUSD = aaveOracle.getAssetPrice(address(asset()));

        // Convert maxWithdrawBase to USDC
        // maxWithdrawBase is in ETH with 18 decimals, usdcPriceInUSD is in USD with 8 decimals
        // We want the result in USDC with 6 decimals
        uint256 maxWithdrawAsset = (maxWithdrawBase * 1e6) / usdcPriceInUSD;

        // Return the minimum of availableLiquidity and maxWithdrawAsset
        return Math.min(availableLiquidity, maxWithdrawAsset);
    }

    // Function to set the strategist address
    function setStrategist(address _strategist) external onlyOwner {
        strategist = _strategist;
    }

    // Override the deposit function to include the nonReentrant modifier
    function deposit(uint256 assets, address receiver)
        public
        virtual
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        return super.deposit(assets, receiver);
    }

    // Override the mint function to include the nonReentrant modifier
    function mint(uint256 shares, address receiver)
        public
        virtual
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        return super.mint(shares, receiver);
    }

    // Override the withdraw function to include the nonReentrant modifier
    function withdraw(uint256 assets, address receiver, address owner)
        public
        virtual
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        return super.withdraw(assets, receiver, owner);
    }

    // Override the redeem function to include the nonReentrant modifier
    function redeem(uint256 shares, address receiver, address owner)
        public
        virtual
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        return super.redeem(shares, receiver, owner);
    }

    // Add pause and unpause functions
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Override the internal _withdraw function from ERC4626
     */
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        // Update total assets, ensuring we don't leave dust
        if (shares == totalSupply()) {
            console.log("full withdrawal");
            // If this is a full withdrawal, set total assets to 0
            _totalAccountedAssets = 0;
        } else {
            console.log("partial withdrawal");
            _totalAccountedAssets -= assets;
        }

        _burn(owner, shares);

        // Directly withdraw funds
        console.log("withdrawing", assets);
        uint256 withdrawnAmount = _withdrawFunds(assets, false);

        console.log("shares burned", shares);

        // Transfer assets to receiver
        SafeERC20.safeTransfer(IERC20(asset()), receiver, withdrawnAmount);

        emit Withdraw(caller, receiver, owner, withdrawnAmount, shares);
    }

    function dummy(uint256 _dummy) public returns (uint256) {
        dummyVariable += _dummy;
        return dummyVariable;
    }
}
