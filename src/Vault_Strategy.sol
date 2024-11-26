// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IPool as IPoolAave} from "./interfaces/IPool.sol";
import {IPool as IPoolAerodrome} from "./interfaces/IPoolAerodrome.sol";
import {IPoolDataProvider} from "./interfaces/IPoolDataProvider.sol";
import {TransferHelper} from "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import {ISwapRouter02, IV3SwapRouter} from "./interfaces/ISwapRouter.sol";
import {IAaveOracle} from "./interfaces/IAaveOracle.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {console} from "forge-std/Test.sol";

contract VaultStrategy is
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

    // Define the target health factor with 4 decimal places
    uint256 public constant TARGET_HEALTH_FACTOR = 11000; // 1.1 with 4 decimal places
    uint256 public constant HEALTH_FACTOR_BUFFER = 500; // 0.05 with 4 decimal places

    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");

    // Add strategist address and fee percentage
    address public strategist;
    uint256 public accumulatedStrategistFee;
    uint256 public constant STRATEGIST_FEE_PERCENTAGE = 2000; // 20% with 2 decimal places

    // Add this state variable
    uint256 public accumulatedDeposits;

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

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

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

    function _withdrawFunds(uint256 amount) internal returns (uint256 withdrawnAmount) {
        console.log("withdrawing funds");
        uint256 maxWithdrawable = getMaxWithdrawableAmount();
        console.log("maxWithdrawable", maxWithdrawable);

        if (amount <= maxWithdrawable) {
            // Normal flow for amounts within maxWithdrawable
            console.log("withdrawing from Aave");
            aavePool.withdraw(asset(), amount, address(this));
            withdrawnAmount = amount;

            // Check and rebalance if necessary
            uint256 healthFactor = calculateHealthFactor();
            uint256 currentHealthFactor4Dec = healthFactor / 1e14;
            uint256 bufferedTargetHealthFactor = TARGET_HEALTH_FACTOR + HEALTH_FACTOR_BUFFER;
            console.log("currentHealthFactor4Dec", currentHealthFactor4Dec);
            if (currentHealthFactor4Dec < bufferedTargetHealthFactor) {
                console.log("rebalancing position");
                _rebalancePosition(0);
            }
        } else {
            console.log("withdrawing more than maxWithdrawable");
            // Handle case where amount exceeds maxWithdrawable
            aavePool.withdraw(asset(), maxWithdrawable, address(this));
            withdrawnAmount = maxWithdrawable;
            console.log("withdrew from Aave");
            uint256 additionalAmountNeeded = amount - maxWithdrawable;
            console.log("additionalAmountNeeded", additionalAmountNeeded);
            _rebalancePosition(additionalAmountNeeded);
            console.log("rebalanced position");
            // After rebalancing, try to withdraw any remaining amount
            uint256 newMaxWithdrawable = getMaxWithdrawableAmount();
            console.log("newMaxWithdrawable", newMaxWithdrawable);
            uint256 remainingWithdrawal = Math.min(additionalAmountNeeded, newMaxWithdrawable);
            console.log("remainingWithdrawal", remainingWithdrawal);
            if (remainingWithdrawal > 0) {
                console.log("withdrawing remaining amount");
                aavePool.withdraw(asset(), remainingWithdrawal, address(this));
                withdrawnAmount += remainingWithdrawal;
            }
        }

        // Update total accounted assets
        _totalAccountedAssets -= amount;
    }

    function _investFunds(uint256 amount, address assetAddress) internal {
        // Get the price of the assets in USD from Pyth Network
        address[] memory dataFeedAddresses = new address[](2);
        dataFeedAddresses[0] = usdcUsdDataFeedAddress;
        dataFeedAddresses[1] = cbEthUsdDataFeedAddress;
        uint256[] memory prices = getChainlinkDataFeedLatestAnswer(dataFeedAddresses);
        uint256 usdcPriceInUSD = prices[0];
        uint256 cbEthPriceInUSD = prices[1];
        // approve and supply the asset USDC to the Aave pool
        IERC20(assetAddress).approve(address(aavePool), amount);
        aavePool.supply(assetAddress, amount, address(this), 0);

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
        console.log("borrowed cbETH");
        uint256 cbEthBalance = IERC20(cbETH).balanceOf(address(this));
        (uint256 usdcReceived, uint256 aeroReceived) = _swapcbETHToUSDCAndAERO(cbEthBalance);
        console.log("swapped cbETH to USDC and AERO");
        IERC20(asset()).safeTransfer(address(aerodromePool), usdcReceived);
        IERC20(AERO).safeTransfer(address(aerodromePool), aeroReceived);
        aerodromePool.mint(address(this));
        aerodromePool.skim(address(this));
    }

    function _rebalancePosition(uint256 additionalAmountNeeded) internal {
        address[] memory dataFeedAddresses = new address[](3);
        dataFeedAddresses[0] = cbEthUsdDataFeedAddress;
        dataFeedAddresses[1] = usdcUsdDataFeedAddress;
        dataFeedAddresses[2] = aeroUsdDataFeedAddress;
        uint256[] memory prices = getChainlinkDataFeedLatestAnswer(dataFeedAddresses);
        uint256 cbEthPriceInUsd = prices[0];
        uint256 usdcPriceInUsd = prices[1];
        uint256 aeroPriceInUsd = prices[2];

        uint256 amountToFreeUp = additionalAmountNeeded > 0 ? additionalAmountNeeded : 0;

        if (amountToFreeUp == 0) {
            // Original rebalancing logic
            (uint256 totalCollateralBase, uint256 totalDebtBase,, uint256 currentLiquidationThreshold,,) =
                aavePool.getUserAccountData(address(this));

            uint256 bufferedTargetHealthFactor = TARGET_HEALTH_FACTOR + HEALTH_FACTOR_BUFFER;

            amountToFreeUp =
                totalDebtBase - (totalCollateralBase * currentLiquidationThreshold) / bufferedTargetHealthFactor;
        }

        uint256 cbEthEquivalent = (amountToFreeUp * 1e18 * usdcPriceInUsd) / (cbEthPriceInUsd * 1e6);
        console.log("cbEthEquivalent", cbEthEquivalent);

        // Convert cbEthEquivalent to USD value with 8 decimals
        uint256 cbEthValueInUsd = (cbEthEquivalent * cbEthPriceInUsd) / 1e18;

        // Calculate how much to withdraw from Aerodrome Pool
        uint256 lpTokensToBurn = _calculateLPTokensToWithdraw(cbEthValueInUsd, usdcPriceInUsd, aeroPriceInUsd);
        console.log("lpTokensToBurn", lpTokensToBurn);
        IERC20(address(aerodromePool)).transfer(address(aerodromePool), lpTokensToBurn);
        (uint256 usdc, uint256 aero) = aerodromePool.burn(address(this));
        console.log("usdc received", usdc);
        console.log("aero received", aero);

        // Swap USDC and AERO to cbETH
        uint256 cbEthReceived = _swapUSDCAndAEROToCbETH(usdc, aero);
        console.log("cbEthReceived", cbEthReceived);

        // Repay cbETH debt
        IERC20(cbETH).approve(address(aavePool), cbEthReceived);
        aavePool.repay(cbETH, cbEthReceived, 2, address(this));

        // Emit the rebalancing event
        emit PositionRebalanced(additionalAmountNeeded, amountToFreeUp, lpTokensToBurn, usdc, aero, cbEthReceived);
    }

    function calculateHealthFactor() internal view returns (uint256) {
        (,,,,, uint256 healthFactor) = aavePool.getUserAccountData(address(this));

        return healthFactor;
    }

    function checkAndRebalance() external payable onlyRole(REBALANCER_ROLE) {
        uint256 healthFactor = calculateHealthFactor();
        uint256 currentHealthFactor4Dec = healthFactor / 1e14;
        uint256 bufferedTargetHealthFactor = TARGET_HEALTH_FACTOR + HEALTH_FACTOR_BUFFER;
        uint256 maxHealthFactor = TARGET_HEALTH_FACTOR * 2; // Example: 2.2 (twice the target)

        if (currentHealthFactor4Dec < bufferedTargetHealthFactor) {
            _rebalancePosition(0);
        } else if (currentHealthFactor4Dec > maxHealthFactor) {
            _investIdleFunds();
        }
    }

    function _investIdleFunds() internal {
        (uint256 totalCollateralBase, uint256 totalDebtBase,, uint256 currentLtv,,) =
            aavePool.getUserAccountData(address(this));

        uint256 targetDebtBase = (totalCollateralBase * currentLtv) / 10000;
        uint256 additionalBorrowBase = targetDebtBase - totalDebtBase;

        if (additionalBorrowBase > 0) {
            address[] memory dataFeedAddresses = new address[](2);
            dataFeedAddresses[0] = usdcUsdDataFeedAddress;
            dataFeedAddresses[1] = cbEthUsdDataFeedAddress;
            uint256[] memory prices = getChainlinkDataFeedLatestAnswer(dataFeedAddresses);
            uint256 usdcPriceInUSD = prices[0];
            uint256 cbEthPriceInUSD = prices[1];

            uint256 cbEthToBorrow = (additionalBorrowBase * usdcPriceInUSD) / cbEthPriceInUSD;
            uint256 safeAmount = (cbEthToBorrow * 95) / 100;

            aavePool.borrow(cbETH, safeAmount, 2, 0, address(this));
            uint256 cbEthBalance = IERC20(cbETH).balanceOf(address(this));
            (uint256 usdcReceived, uint256 aeroReceived) = _swapcbETHToUSDCAndAERO(cbEthBalance);

            IERC20(asset()).safeTransfer(address(aerodromePool), usdcReceived);
            IERC20(AERO).safeTransfer(address(aerodromePool), aeroReceived);
            aerodromePool.mint(address(this));
            aerodromePool.skim(address(this));

            _totalAccountedAssets += usdcReceived;
        }
    }

    // @audit - check the amnount returned by this function in tests

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

        // Calculate the total pool value in USD
        uint256 usdcValueInPool = (reserve0 * usdcPriceInUsd) / 1e6; // USDC has 6 decimals
        uint256 aeroValueInPool = (reserve1 * aeroPriceInUsd) / 1e18; // AERO has 18 decimals

        uint256 totalPoolValueInUsd = usdcValueInPool + aeroValueInPool;

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
        uint256 aeroPriceInUSD = prices[2];

        // Get current balances
        uint256 currentAUSDCBalance = IERC20(aUSDC).balanceOf(address(this));
        uint256 currentVariableDebtBalance = IERC20(variableDebtCbETH).balanceOf(address(this));

        // Calculate the change in balances
        uint256 borrowedCbETHChange = currentVariableDebtBalance - previousVariableDebtBalance;

        // Calculate the net gain in Aave
        uint256 suppliedUSDCValueChange = currentAUSDCBalance - previousAUSDCBalance;
        uint256 borrowedCbETHValueChangeInUSD = (cbETHPrice * borrowedCbETHChange) / (usdcPrice * 10 ** 12);

        int256 aaveNetGain = int256(suppliedUSDCValueChange) - int256(borrowedCbETHValueChangeInUSD);

        // Update the previous balances
        previousAUSDCBalance = currentAUSDCBalance;
        previousVariableDebtBalance = currentVariableDebtBalance;

        // Get initial balances
        uint256 initialAeroBalance = IERC20(AERO).balanceOf(address(this));
        uint256 initialUsdcBalance = IERC20(asset()).balanceOf(address(this)) - accumulatedDeposits;

        // Claim fees from Aerodrome Pool
        aerodromePool.claimFees();

        uint256 currentAeroBalance = IERC20(AERO).balanceOf(address(this));
        uint256 currentUSDCBalance = IERC20(asset()).balanceOf(address(this)) - accumulatedDeposits;

        // Calculate claimed rewards
        uint256 claimedAero = currentAeroBalance - initialAeroBalance;
        uint256 claimedUsdc = currentUSDCBalance - initialUsdcBalance;

        if (currentAeroBalance > 0) {
            currentUSDCBalance += _swapAEROToUSDC(currentAeroBalance);
        }

        // Calculate total rewards in USDC
        uint256 finalAeroBalance = IERC20(AERO).balanceOf(address(this));
        uint256 finalUsdcBalance = IERC20(asset()).balanceOf(address(this)) - accumulatedDeposits;
        uint256 totalRewardsInUSDC = (finalUsdcBalance - initialUsdcBalance)
            + ((aeroPriceInUSD * (finalAeroBalance - initialAeroBalance)) / (usdcPrice * 10 ** 12));

        // Calculate total profit, including Aerodrome rewards and Aave net gain
        int256 totalProfit = int256(totalRewardsInUSDC) + aaveNetGain;

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
            uint256 aeroAmount = _swapUSDCToAERO(totalRewardsInUSDC / 2);

            IERC20(AERO).safeTransfer(address(aerodromePool), aeroAmount);
            IERC20(asset()).safeTransfer(address(aerodromePool), totalRewardsInUSDC / 2);
            aerodromePool.mint(address(this));
        }

        // Skim any excess assets from Aerodrome Pool
        aerodromePool.skim(address(this));

        emit HarvestReport(
            uint256(totalProfit), netProfit, strategistFee, totalRewardsInUSDC, aaveNetGain, claimedAero, claimedUsdc
        );
    }

    function claimStrategistFees(uint256 amount) external nonReentrant {
        require(msg.sender == strategist, "Only strategist can claim fees");
        require(accumulatedStrategistFee > 0 && amount < accumulatedStrategistFee, "No fees to claim");

        (uint256 reserve0,,) = aerodromePool.getReserves();
        uint256 totalSupplyPoolToken = IERC20(address(aerodromePool)).totalSupply();

        uint256 sharesToBurn = (amount * totalSupplyPoolToken) / reserve0;

        IERC20(address(aerodromePool)).transfer(address(aerodromePool), sharesToBurn);
        (uint256 usdc, uint256 aero) = aerodromePool.burn(address(this));

        uint256 usdcAmount = _swapAEROToUSDC(aero) + usdc;

        IERC20(asset()).safeTransfer(strategist, usdcAmount);

        accumulatedStrategistFee -= amount;

        emit StrategistFeeClaimed(amount, accumulatedStrategistFee);
    }

    function _swap(address tokenIn, address tokenOut, uint256 fee1, uint256 fee2, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        TransferHelper.safeApprove(tokenIn, address(swapRouter), amountIn);

        // Get price feed IDs for both input and output tokens
        address inPriceFeedId = getDataFeedAddress(tokenIn);
        address outPriceFeedId = getDataFeedAddress(tokenOut);

        address[] memory dataFeedAddresses = new address[](2);
        dataFeedAddresses[0] = inPriceFeedId;
        dataFeedAddresses[1] = outPriceFeedId;
        uint256[] memory prices = getChainlinkDataFeedLatestAnswer(dataFeedAddresses);
        uint256 inPrice = prices[0];
        uint256 outPrice = prices[1];
        console.log("Price calculated for swap");

        // Calculate the expected amount out
        uint256 expectedAmountOut = (amountIn * inPrice) / outPrice;

        // Adjust for decimal differences if necessary
        uint256 inDecimals = IERC20Metadata(tokenIn).decimals();
        uint256 outDecimals = IERC20Metadata(tokenOut).decimals();
        if (inDecimals != outDecimals) {
            expectedAmountOut = (expectedAmountOut * (10 ** outDecimals)) / (10 ** inDecimals);
        }

        // Calculate the minimum amount out with 2% slippage tolerance
        uint256 amountOutMinimum = (expectedAmountOut * 98) / 100;
        console.log("Amount out minimum calculated");

        bytes memory path = abi.encodePacked(tokenIn, uint24(fee1), WETH9, uint24(fee2), tokenOut);

        IV3SwapRouter.ExactInputParams memory params = IV3SwapRouter.ExactInputParams({
            path: path,
            recipient: address(this),
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum
        });
        console.log("Params set for swap");

        amountOut = swapRouter.exactInput(params);
        console.log("Swap executed");
    }

    function getDataFeedAddress(address token) internal view returns (address) {
        if (token == address(asset())) {
            return usdcUsdDataFeedAddress;
        } else if (token == cbETH) {
            return cbEthUsdDataFeedAddress;
        } else if (token == AERO) {
            return aeroUsdDataFeedAddress;
        } else {
            revert("Unsupported token");
        }
    }

    function _swapcbETHToUSDCAndAERO(uint256 amountIn)
        internal
        returns (uint256 amountOutUSDC, uint256 amountOutAERO)
    {
        address assetAddress = asset();
        console.log("swapping cbETH to USDC and AERO");
        // Swap half of cbETH to AERO
        amountOutAERO = _swap(cbETH, AERO, 500, 3000, amountIn / 2);
        console.log("swapped cbETH to AERO");
        // Swap the other half of cbETH to USDC
        amountOutUSDC = _swap(cbETH, assetAddress, 500, 500, amountIn / 2);
        console.log("swapped cbETH to USDC");
        return (amountOutUSDC, amountOutAERO);
    }

    function _swapUSDCAndAEROToCbETH(uint256 amountInUSDC, uint256 amountInAERO) internal returns (uint256) {
        address assetAddress = asset();
        // Swap USDC to cbETH
        uint256 amountOutcbETH1 = _swap(assetAddress, cbETH, 500, 500, amountInUSDC);
        uint256 amountOutcbETH2 = _swap(AERO, cbETH, 3000, 500, amountInAERO);
        return amountOutcbETH1 + amountOutcbETH2;
    }

    function _swapAEROToUSDC(uint256 amountIn) internal returns (uint256 amountOut) {
        amountOut = _swap(AERO, asset(), 3000, 500, amountIn);
    }

    function _swapUSDCToAERO(uint256 amountIn) internal returns (uint256 amountOut) {
        amountOut = _swap(asset(), AERO, 500, 3000, amountIn);
    }

    // function _swapUSDCToCbETH(
    //     uint256 amountIn
    // ) internal returns (uint256 amountOut) {
    //     amountOut = _swap(asset(), cbETH, 500, 500, amountIn);
    // }

    function totalAssets() public view override returns (uint256) {
        return _totalAccountedAssets;
    }

    // function getPricePyth(bytes32[] memory dataFeedAddresses) public payable returns (uint256[] memory) {
    //     bytes[] memory priceUpdate = pythPriceUpdater.getPricePyth();
    //     uint256 fee = pyth.getUpdateFee(priceUpdate);
    //     pyth.updatePriceFeeds{value: fee}(priceUpdate);

    //     uint256[] memory prices = new uint256[](priceFeedIds.length);

    //     // Read the current price from each price feed if it is less than 60 seconds old.
    //     for (uint256 i = 0; i < priceFeedIds.length; i++) {
    //         PythStructs.Price memory pythPrice = pyth.getPriceNoOlderThan(priceFeedIds[i], 120);

    //         // Convert the price to a uint256 value
    //         // The price is stored as a signed integer with a specific exponent
    //         // We need to adjust it to get the actual price in a common unit (e.g., 18 decimals)
    //         int64 price = pythPrice.price;

    //         // Convert the price to a positive value with 18 decimals
    //         uint256 adjustedPrice = uint256(uint64(price));

    //         prices[i] = adjustedPrice;
    //     }

    //     return prices;
    // }

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

    // Add a new function to invest accumulated funds
    // function investAccumulatedFunds() external onlyOwner nonReentrant {
    //     require(accumulatedDeposits > 0, "No accumulated deposits to invest");

    //     uint256 amountToInvest = accumulatedDeposits;
    //     accumulatedDeposits = 0;

    //     _investFunds(amountToInvest, asset());
    // }

    // function processWithdrawalRequests() external onlyOwner nonReentrant {
    //     uint256 totalAssetsToWithdraw = 0;
    //     uint256 availableAssets = 0;

    //     // Calculate total assets to withdraw
    //     for (uint256 i = 0; i < withdrawalRequestors.length(); i++) {
    //         address requestor = withdrawalRequestors.at(i);
    //         WithdrawalRequest storage request = withdrawalRequests[requestor];

    //         if (!request.fulfilled) {
    //             totalAssetsToWithdraw += request.assets;
    //         }
    //     }

    //     // Withdraw funds if needed
    //     if (totalAssetsToWithdraw > 0) {
    //         _withdrawFunds(totalAssetsToWithdraw);
    //         availableAssets = IERC20(asset()).balanceOf(address(this)) - accumulatedDeposits;
    //     }

    //     uint256 j = 0;
    //     while (j < withdrawalRequestors.length() && totalAssetsToWithdraw > 0 && availableAssets > 0) {
    //         address requestor = withdrawalRequestors.at(j);
    //         WithdrawalRequest storage request = withdrawalRequests[requestor];

    //         if (!request.fulfilled) {
    //             uint256 toDistribute = Math.min(request.assets, Math.min(totalAssetsToWithdraw, availableAssets));

    //             availableAssets -= toDistribute;
    //             totalAssetsToWithdraw -= toDistribute;
    //             IERC20(asset()).safeTransfer(requestor, toDistribute);
    //             if (toDistribute == request.assets) {
    //                 request.fulfilled = true;
    //                 withdrawalRequestors.remove(requestor);
    //                 // Don't increment i as we've removed an element
    //             } else {
    //                 request.assets -= toDistribute;
    //                 j++;
    //             }
    //         } else {
    //             j++;
    //         }
    //     }
    // }

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

        _burn(owner, shares);

        // Directly withdraw funds
        uint256 withdrawnAmount = _withdrawFunds(assets);

        // Transfer assets to receiver
        SafeERC20.safeTransfer(IERC20(asset()), receiver, withdrawnAmount);

        emit Withdraw(caller, receiver, owner, withdrawnAmount, shares);
    }
}
