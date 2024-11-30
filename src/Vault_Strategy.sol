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
import {Uniswap} from "./Integrations/Uniswap.sol";

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
        address[] memory dataFeedAddresses = new address[](3);
        dataFeedAddresses[0] = usdcUsdDataFeedAddress;
        dataFeedAddresses[1] = cbEthUsdDataFeedAddress;
        dataFeedAddresses[2] = aeroUsdDataFeedAddress;
        uint256[] memory prices = getChainlinkDataFeedLatestAnswer(dataFeedAddresses);

        (previousAUSDCBalance, previousVariableDebtBalance) =
            Aave.supplyAndBorrow(amount, address(this), prices[0], prices[1]);
        console.log("previousAUSDCBalance", previousAUSDCBalance);
        console.log("previousVariableDebtBalance", previousVariableDebtBalance);
        uint256 cbEthBalance = IERC20(cbETH).balanceOf(address(this));
        console.log("cbEthBalance", cbEthBalance);

        // Continue with Aerodrome integration
        (uint256 usdcReceived, uint256 aeroReceived) =
            Uniswap.swapcbETHToUSDCAndAERO(cbEthBalance, prices[0], prices[1], prices[2]);
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
                uint256 cbEthReceived = Uniswap.swapUSDCAndAEROToCbETH(usdc, aero, prices[0], prices[1], prices[2]);

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
            address[] memory dataFeedAddresses = new address[](3);
            dataFeedAddresses[0] = usdcUsdDataFeedAddress;
            dataFeedAddresses[1] = cbEthUsdDataFeedAddress;
            dataFeedAddresses[2] = aeroUsdDataFeedAddress;
            uint256[] memory prices = getChainlinkDataFeedLatestAnswer(dataFeedAddresses);
            uint256 usdcPriceInUSD = prices[0];
            uint256 cbEthPriceInUSD = prices[1];

            uint256 cbEthToBorrow = (additionalBorrowBase * usdcPriceInUSD) / cbEthPriceInUSD;
            uint256 safeAmount = (cbEthToBorrow * 95) / 100;

            aavePool.borrow(cbETH, safeAmount, 2, 0, address(this));
            uint256 cbEthBalance = IERC20(cbETH).balanceOf(address(this));
            (uint256 usdcReceived, uint256 aeroReceived) =
                Uniswap.swapcbETHToUSDCAndAERO(cbEthBalance, prices[0], prices[1], prices[2]);

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
        // Get prices
        address[] memory dataFeedAddresses = new address[](3);
        dataFeedAddresses[0] = cbEthUsdDataFeedAddress;
        dataFeedAddresses[1] = usdcUsdDataFeedAddress;
        dataFeedAddresses[2] = aeroUsdDataFeedAddress;
        uint256[] memory prices = getChainlinkDataFeedLatestAnswer(dataFeedAddresses);
        console.log("previousAUSDCBalance", previousAUSDCBalance);
        console.log("previousVariableDebtBalance", previousVariableDebtBalance);

        // Get Aave profits
        Aave.HarvestResult memory aaveResult = Aave.harvest(
            Aave.HarvestParams({
                pool: aavePool,
                aToken: aUSDC,
                debtToken: variableDebtCbETH,
                user: address(this),
                previousAUSDCBalance: previousAUSDCBalance,
                previousDebtBalance: previousVariableDebtBalance,
                cbEthPriceUSD: prices[0],
                usdcPriceUSD: prices[1]
            })
        );

        // Update stored balances
        previousAUSDCBalance = aaveResult.newAUSDCBalance;
        previousVariableDebtBalance = aaveResult.newDebtBalance;

        // Handle Aerodrome rewards
        (uint256 claimedUsdc, uint256 claimedAero) = aerodromePool.claimFees();
        uint256 aeroValueInUsd = (claimedAero * prices[2]) / 1e18;
        uint256 usdcValueInUsd = (claimedUsdc * prices[1]) / 1e6;
        uint256 totalRewardsInUSDC = ((usdcValueInUsd + aeroValueInUsd) * 1e6) / prices[1];

        // Calculate total profit and fees
        int256 totalProfit = int256(totalRewardsInUSDC) + aaveResult.aaveNetGain;
        uint256 strategistFee = 0;
        if (totalProfit > 0) {
            strategistFee = (uint256(totalProfit) * STRATEGIST_FEE_PERCENTAGE) / 10000;
            accumulatedStrategistFee += strategistFee;
        }

        // Update accounting
        uint256 netProfit = totalProfit > 0 ? uint256(totalProfit) - strategistFee : 0;
        if (totalProfit > 0) {
            _totalAccountedAssets += netProfit;
        } else if (totalProfit < 0) {
            _totalAccountedAssets -= uint256(-totalProfit);
        }

        // Reinvest rewards
        if (totalRewardsInUSDC > 0) {
            uint256 aeroBal = IERC20(AERO).balanceOf(address(this));
            if (aeroBal > 0) Uniswap.swapAEROToUSDC(aeroBal, prices[1], prices[2]);
            uint256 usdcBalance = IERC20(asset()).balanceOf(address(this));
            _investFunds(usdcBalance, address(asset()));
        }

        emit HarvestReport(
            uint256(totalProfit),
            netProfit,
            strategistFee,
            totalRewardsInUSDC,
            aaveResult.aaveNetGain,
            claimedAero,
            claimedUsdc
        );
    }

    function claimStrategistFees(uint256 amount) external nonReentrant {
        require(msg.sender == strategist, "Only strategist can claim fees");
        require(accumulatedStrategistFee > 0 && amount < accumulatedStrategistFee, "No fees to claim");

        address[] memory dataFeedAddresses = new address[](3);
        dataFeedAddresses[0] = usdcUsdDataFeedAddress;
        dataFeedAddresses[1] = aeroUsdDataFeedAddress;
        uint256[] memory prices = getChainlinkDataFeedLatestAnswer(dataFeedAddresses);

        (uint256 reserve0,,) = aerodromePool.getReserves();
        uint256 totalSupplyPoolToken = IERC20(address(aerodromePool)).totalSupply();

        uint256 sharesToBurn = (amount * totalSupplyPoolToken) / reserve0;

        IERC20(address(aerodromePool)).transfer(address(aerodromePool), sharesToBurn);
        (uint256 usdc, uint256 aero) = aerodromePool.burn(address(this));

        uint256 usdcAmount = Uniswap.swapAEROToUSDC(aero, prices[0], prices[1]) + usdc;

        IERC20(asset()).safeTransfer(strategist, usdcAmount);

        accumulatedStrategistFee -= amount;

        emit StrategistFeeClaimed(amount, accumulatedStrategistFee);
    }

    // function swapcbETHToUSDCAndAERO(uint256 amountIn) internal returns (uint256 amountOutUSDC, uint256 amountOutAERO) {
    //     Uniswap.SwapParams memory params = Uniswap.SwapParams({
    //         router: swapRouter,
    //         tokenIn: cbETH,
    //         tokenOut: address(asset()),
    //         WETH9: WETH9,
    //         fee1: 500,
    //         fee2: 500,
    //         amountIn: amountIn,
    //         priceFeedIn: cbEthUsdDataFeedAddress,
    //         priceFeedOut: usdcUsdDataFeedAddress
    //     });

    //     Uniswap.TokenSwapResult memory result = Uniswap.swapCbETHToUSDCAndAERO(params, address(asset()), AERO);

    //     return (result.amountOutUSDC, result.amountOutAERO);
    // }

    // function _swapUSDCAndAEROToCbETH(uint256 amountInUSDC, uint256 amountInAERO) internal returns (uint256) {
    //     Uniswap.SwapParams memory params = Uniswap.SwapParams({
    //         router: swapRouter,
    //         tokenIn: address(asset()),
    //         tokenOut: cbETH,
    //         WETH9: WETH9,
    //         fee1: 500,
    //         fee2: 500,
    //         amountIn: amountInUSDC,
    //         priceFeedIn: usdcUsdDataFeedAddress,
    //         priceFeedOut: cbEthUsdDataFeedAddress
    //     });

    //     return Uniswap.swapUSDCAndAEROToCbETH(params, amountInUSDC, amountInAERO);
    // }

    // function _swapAEROToUSDC(uint256 amountIn) internal returns (uint256 amountOut) {
    //     Uniswap.SwapParams memory params = Uniswap.SwapParams({
    //         router: swapRouter,
    //         tokenIn: AERO,
    //         tokenOut: address(asset()),
    //         WETH9: WETH9,
    //         fee1: 3000,
    //         fee2: 500,
    //         amountIn: amountIn,
    //         priceFeedIn: aeroUsdDataFeedAddress,
    //         priceFeedOut: usdcUsdDataFeedAddress
    //     });

    //     amountOut = Uniswap.swap(params);
    // }

    // function _swapUSDCToAERO(uint256 amountIn) internal returns (uint256 amountOut) {
    //     Uniswap.SwapParams memory params = Uniswap.SwapParams({
    //         router: swapRouter,
    //         tokenIn: asset(),
    //         tokenOut: AERO,
    //         WETH9: WETH9,
    //         fee1: 500,
    //         fee2: 3000,
    //         amountIn: amountIn,
    //         priceFeedIn: usdcUsdDataFeedAddress,
    //         priceFeedOut: aeroUsdDataFeedAddress
    //     });

    //     amountOut = Uniswap.swap(params);
    // }

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
