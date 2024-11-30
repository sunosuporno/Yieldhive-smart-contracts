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
import {Aave} from "./Integrations/Aave.sol";

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
    uint256 public constant TARGET_HEALTH_FACTOR = 10300; // 1.03 with 4 decimal places
    uint256 public constant HEALTH_FACTOR_BUFFER = 300; // 0.03 with 4 decimal places

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
            // Get balance before withdrawal
            uint256 balanceBefore = IERC20(asset()).balanceOf(address(this));

            console.log("withdrawing from Aave");
            aavePool.withdraw(asset(), amount, address(this));

            // Calculate actual withdrawn amount
            withdrawnAmount = IERC20(asset()).balanceOf(address(this)) - balanceBefore;

            // Check and rebalance if necessary
            uint256 healthFactor = Aave.calculateHealthFactor(aavePool, address(this));
            uint256 currentHealthFactor4Dec = healthFactor / 1e14;
            console.log("currentHealthFactor4Dec", currentHealthFactor4Dec);
            uint256 bufferedTargetHealthFactor = TARGET_HEALTH_FACTOR + HEALTH_FACTOR_BUFFER;
            console.log("currentHealthFactor4Dec", currentHealthFactor4Dec);
            if (currentHealthFactor4Dec < bufferedTargetHealthFactor) {
                console.log("rebalancing position");
                _rebalancePosition(0);
            }
        } else {
            console.log("withdrawing more than maxWithdrawable");
            // Get balance before withdrawal
            uint256 balanceBefore = IERC20(asset()).balanceOf(address(this));

            aavePool.withdraw(asset(), (maxWithdrawable - 10), address(this));

            // Calculate actual withdrawn amount
            withdrawnAmount = IERC20(asset()).balanceOf(address(this)) - balanceBefore;

            console.log("withdrawnAmount", withdrawnAmount);
            console.log("withdrew from Aave");
            uint256 additionalAmountNeeded = amount - withdrawnAmount;
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
                balanceBefore = IERC20(asset()).balanceOf(address(this));

                aavePool.withdraw(asset(), (remainingWithdrawal - 10), address(this));

                // Add actual withdrawn amount to previous withdrawnAmount
                withdrawnAmount += IERC20(asset()).balanceOf(address(this)) - balanceBefore;

                console.log("withdrawn remaining amount", withdrawnAmount);
                uint256 balanceofContract = IERC20(asset()).balanceOf(address(this));
                console.log("balanceofContract", balanceofContract);
            }
        }
    }

    function _investFunds(uint256 amount, address assetAddress) internal {
        // Get prices as before
        address[] memory dataFeedAddresses = new address[](2);
        dataFeedAddresses[0] = usdcUsdDataFeedAddress;
        dataFeedAddresses[1] = cbEthUsdDataFeedAddress;
        uint256[] memory prices = getChainlinkDataFeedLatestAnswer(dataFeedAddresses);

        // Use Aave library
        Aave.SupplyAndBorrowParams memory params = Aave.SupplyAndBorrowParams({
            pool: aavePool,
            dataProvider: aaveProtocolDataProvider,
            assetToSupply: assetAddress,
            assetToBorrow: cbETH,
            supplyAmount: amount,
            supplyPriceUSD: prices[0],
            borrowPriceUSD: prices[1],
            safetyFactor: 95
        });

        Aave.SupplyAndBorrowResult memory result = Aave.supplyAndBorrow(params);

        // Store previous balances
        previousAUSDCBalance = result.aTokenBalance;
        previousVariableDebtBalance = result.debtTokenBalance;

        // Continue with Aerodrome integration
        (uint256 usdcReceived, uint256 aeroReceived) = _swapcbETHToUSDCAndAERO(result.borrowedAmount);
        IERC20(asset()).safeTransfer(address(aerodromePool), usdcReceived);
        IERC20(AERO).safeTransfer(address(aerodromePool), aeroReceived);
        aerodromePool.mint(address(this));
        aerodromePool.skim(address(this));
    }

    function _rebalancePosition(uint256 additionalAmountNeeded) internal {
        if (additionalAmountNeeded == 0) {
            console.log("No rebalancing needed - sufficient funds in Aave");
            return;
        }

        // Get prices
        address[] memory dataFeedAddresses = new address[](3);
        dataFeedAddresses[0] = cbEthUsdDataFeedAddress;
        dataFeedAddresses[1] = usdcUsdDataFeedAddress;
        dataFeedAddresses[2] = aeroUsdDataFeedAddress;
        uint256[] memory prices = getChainlinkDataFeedLatestAnswer(dataFeedAddresses);

        // Calculate rebalance amounts
        Aave.RebalanceParams memory params = Aave.RebalanceParams({
            pool: aavePool,
            assetToRepay: cbETH,
            repayAmount: additionalAmountNeeded,
            targetHealthFactor: TARGET_HEALTH_FACTOR,
            healthFactorBuffer: HEALTH_FACTOR_BUFFER
        });

        Aave.RebalanceResult memory result = Aave.calculateRebalanceAmount(params);

        if (result.totalAmountToFreeUp > 0) {
            uint256 cbEthEquivalent = (result.totalAmountToFreeUp * 1e18 * prices[1]) / (prices[0] * 1e6);
            uint256 lpTokensToBurn =
                _calculateLPTokensToWithdraw((cbEthEquivalent * prices[0]) / 1e18, prices[1], prices[2]);

            if (lpTokensToBurn > 0) {
                IERC20(address(aerodromePool)).transfer(address(aerodromePool), lpTokensToBurn);
                (uint256 usdc, uint256 aero) = aerodromePool.burn(address(this));
                uint256 cbEthReceived = _swapUSDCAndAEROToCbETH(usdc, aero);

                Aave.repayDebt(aavePool, cbETH, cbEthReceived, address(this));

                emit PositionRebalanced(
                    additionalAmountNeeded, result.totalAmountToFreeUp, lpTokensToBurn, usdc, aero, cbEthReceived
                );
            }
        }
    }

    function checkAndRebalance() external payable onlyRole(REBALANCER_ROLE) {
        uint256 healthFactor = Aave.calculateHealthFactor(aavePool, address(this));
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

        console.log("\nPrices fetched from Chainlink");

        // Get current balances
        uint256 currentAUSDCBalance = IERC20(aUSDC).balanceOf(address(this));
        uint256 currentVariableDebtBalance = IERC20(variableDebtCbETH).balanceOf(address(this));
        console.log("currentAUSDCBalance", currentAUSDCBalance);
        console.log("currentVariableDebtBalance", currentVariableDebtBalance);
        // Calculate the change in balances
        uint256 borrowedCbETHChange = currentVariableDebtBalance - previousVariableDebtBalance;
        console.log("borrowedCbETHChange", borrowedCbETHChange);
        // Calculate the net gain in Aave
        uint256 suppliedUSDCValueChange = currentAUSDCBalance - previousAUSDCBalance;
        console.log("suppliedUSDCValueChange", suppliedUSDCValueChange);
        uint256 borrowedCbETHValueChangeInUSDC = (cbETHPrice * borrowedCbETHChange) / (usdcPrice * 10 ** 12);
        console.log("borrowedCbETHValueChangeInUSDC", borrowedCbETHValueChangeInUSDC);
        int256 aaveNetGain = int256(suppliedUSDCValueChange) - int256(borrowedCbETHValueChangeInUSDC);
        console.log("aaveNetGain", aaveNetGain);
        // Update the previous balances
        previousAUSDCBalance = currentAUSDCBalance;
        previousVariableDebtBalance = currentVariableDebtBalance;

        // // Get initial balances
        // uint256 initialAeroBalance = IERC20(AERO).balanceOf(address(this));
        // uint256 initialUsdcBalance = IERC20(asset()).balanceOf(address(this));
        // console.log("initialAeroBalance", initialAeroBalance);
        // console.log("initialUsdcBalance", initialUsdcBalance);

        // Claim fees from Aerodrome Pool
        (uint256 claimedUsdc, uint256 claimedAero) = aerodromePool.claimFees();
        console.log("claimedUsdc", claimedUsdc);
        console.log("claimedAero", claimedAero);

        uint256 aeroValueInUsd = (claimedAero * aeroPrice) / (10 ** 18); // Adjust for AERO's 18 decimals
        uint256 usdcValueInUsd = (claimedUsdc * usdcPrice) / (10 ** 6); // Adjust for USDC's 6 decimals
        console.log("aeroValueInUsd", aeroValueInUsd);
        console.log("usdcValueInUsd", usdcValueInUsd);

        // Target a 50-50 split between AERO and USDC
        uint256 totalValueInUsd = aeroValueInUsd + usdcValueInUsd;
        uint256 targetValuePerToken = totalValueInUsd / 2;

        // if (aeroValueInUsd > targetValuePerToken) {
        //     // We have too much AERO, swap the excess to USDC
        //     console.log("We have too much AERO, swap the excess to USDC");
        //     uint256 excessAeroValue = aeroValueInUsd - targetValuePerToken;
        //     uint256 aeroToSwap = (excessAeroValue * 10 ** 18) / aeroPrice;
        //     if (aeroToSwap > 0) {
        //         claimedUsdc += _swapAEROToUSDC(aeroToSwap);
        //     }
        // } else if (usdcValueInUsd > targetValuePerToken) {
        //     // We have too much USDC, swap the excess to AERO
        //     console.log("We have too much USDC, swap the excess to AERO");
        //     uint256 excessUsdcValue = usdcValueInUsd - targetValuePerToken;
        //     uint256 usdcToSwap = (excessUsdcValue * 10 ** 6) / usdcPrice;
        //     if (usdcToSwap > 0) {
        //         claimedAero += _swapUSDCToAERO(usdcToSwap);
        //     }
        // }

        // uint256 currentAeroBalance = IERC20(AERO).balanceOf(address(this));
        // uint256 currentUSDCBalance = IERC20(asset()).balanceOf(address(this));
        // console.log("currentAeroBalance", currentAeroBalance);
        // console.log("currentUSDCBalance", currentUSDCBalance);

        // // Calculate claimed rewards
        // uint256 claimedAero = currentAeroBalance - initialAeroBalance;
        // uint256 claimedUsdc = currentUSDCBalance - initialUsdcBalance;

        // if (currentAeroBalance > 0) {
        //     currentUSDCBalance += _swapAEROToUSDC(currentAeroBalance);
        // }

        // Calculate total rewards in USDC terms using the claimed amounts directly
        uint256 totalRewardsInUSDC = (usdcValueInUsd + aeroValueInUsd) * 1e6 / (usdcPrice);
        console.log("totalRewardsInUSDC", totalRewardsInUSDC);

        // Or even better, use the values we already calculated:
        // uint256 totalRewardsInUSDC = (usdcValueInUsd + aeroValueInUsd) * 1e6; // Convert back to USDC decimals

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
            if (aeroBal > 0) _swapAEROToUSDC(aeroBal);
            uint256 usdcBalance = IERC20(asset()).balanceOf(address(this));
            _investFunds(usdcBalance, address(asset()));
        }

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
        _totalAccountedAssets -= assets;

        // Transfer assets to receiver
        SafeERC20.safeTransfer(IERC20(asset()), receiver, withdrawnAmount);

        emit Withdraw(caller, receiver, owner, withdrawnAmount, shares);
    }

    function upgradeAaveLibrary(address newLibrary) external onlyOwner {
        aaveLibrary = newLibrary;
    }
}
