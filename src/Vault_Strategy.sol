// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
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
import {IAaveOracle} from "./interfaces/IAaveOracle.sol";

contract VaultStrategy is ERC4626, Ownable2Step, AccessControl {
    using Math for uint256;
    using SafeERC20 for IERC20;
    IPyth pyth;
    IPoolAave aavePool;
    IAaveOracle aaveOracle;
    IPoolDataProvider aaveProtocolDataProvider;
    IPoolAerodrome aerodromePool;
    IPythPriceUpdater public pythPriceUpdater;
    ISwapRouter02 public immutable swapRouter;

    address public constant swapRouterAddress =
        0x2626664c2603336E57B271c5C0b26F421741e481;
    address public constant cbETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    address public constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address public constant WETH9 = 0x4200000000000000000000000000000000000006;
    address public constant aUSDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address public constant variableDebtCbETH =
        0x1DabC36f19909425f654777249815c073E8Fd79F;
    uint256 public _totalAccountedAssets;
    bytes32 public constant usdcUsdPriceFeedId =
        0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 public constant cbEthUsdPriceFeedId =
        0x15ecddd26d49e1a8f1de9376ebebc03916ede873447c1255d2d5891b92ce5717;
    bytes32 public constant aeroUsdPriceFeedId =
        0x9db37f4d5654aad3e37e2e14ffd8d53265fb3026d1d8f91146539eebaa2ef45f;

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

    constructor(
        IERC20 asset_,
        uint256 _initialDeposit,
        address initialOwner,
        string memory name_,
        string memory symbol_,
        address pythContract,
        address aavePoolContract,
        address aaveProtocolDataProviderContract,
        address aerodromePoolContract,
        address pythPriceUpdaterContract,
        address aaveOracleContract,
        address _strategist
    ) ERC4626(asset_) ERC20(name_, symbol_) Ownable(initialOwner) {
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(REBALANCER_ROLE, initialOwner);

        // asset_.safeTransferFrom(msg.sender, address(this), _initialDeposit);
        pyth = IPyth(pythContract);
        aavePool = IPoolAave(aavePoolContract);
        aaveProtocolDataProvider = IPoolDataProvider(
            aaveProtocolDataProviderContract
        );
        aerodromePool = IPoolAerodrome(aerodromePoolContract);
        pythPriceUpdater = IPythPriceUpdater(pythPriceUpdaterContract);
        swapRouter = ISwapRouter02(swapRouterAddress);
        aaveOracle = IAaveOracle(aaveOracleContract);
        strategist = _strategist;
    }

    // New internal function that includes priceUpdate
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
        _investFunds(assets, assetAddress);

        emit Deposit(caller, receiver, assets, shares);
    }

    function _withdrawFunds(uint256 amount) internal {
        uint256 maxWithdrawable = getMaxWithdrawableAmount();

        if (amount <= maxWithdrawable) {
            // Normal flow for amounts within maxWithdrawable
            aavePool.withdraw(asset(), amount, address(this));

            // Check and rebalance if necessary
            uint256 healthFactor = calculateHealthFactor();
            uint256 currentHealthFactor4Dec = healthFactor / 1e14;
            uint256 bufferedTargetHealthFactor = TARGET_HEALTH_FACTOR +
                HEALTH_FACTOR_BUFFER;

            if (currentHealthFactor4Dec < bufferedTargetHealthFactor) {
                _rebalancePosition(0);
            }
        } else {
            // Handle case where amount exceeds maxWithdrawable
            aavePool.withdraw(asset(), maxWithdrawable, address(this));

            uint256 additionalAmountNeeded = amount - maxWithdrawable;
            _rebalancePosition(additionalAmountNeeded);

            // After rebalancing, try to withdraw any remaining amount
            uint256 newMaxWithdrawable = getMaxWithdrawableAmount();
            uint256 remainingWithdrawal = Math.min(
                additionalAmountNeeded,
                newMaxWithdrawable
            );
            if (remainingWithdrawal > 0) {
                aavePool.withdraw(asset(), remainingWithdrawal, address(this));
            }
        }

        // Update total accounted assets
        _totalAccountedAssets -= amount;
    }

    function _investFunds(uint256 amount, address assetAddress) internal {
        // Get the price of the assets in USD from Pyth Network
        bytes32[] memory priceFeedIds = new bytes32[](2);
        priceFeedIds[0] = usdcUsdPriceFeedId;
        priceFeedIds[1] = cbEthUsdPriceFeedId;
        uint256[] memory prices = getPricePyth(priceFeedIds);
        uint256 usdcPriceInUSD = prices[0];
        uint256 cbEthPriceInUSD = prices[1];
        // approve and supply the asset USDC to the Aave pool
        IERC20(assetAddress).approve(address(aavePool), amount);
        aavePool.supply(assetAddress, amount, address(this), 0);

        // Convert the amount of USDC supplied to 18 decimals
        uint256 usdcAmountIn18Decimals = amount * 10 ** 12;
        // Finding total price of the asset supplied in USD (now correctly using 10**8)
        uint256 usdcAmountIn18DecimalsInUSD = (usdcAmountIn18Decimals *
            usdcPriceInUSD) / 10 ** 8;
        // Fetching LTV of USDC from Aave
        (, uint256 ltv, , , , , , , , ) = aaveProtocolDataProvider
            .getReserveConfigurationData(assetAddress);
        // Calculating the maximum loan amount in USD
        uint256 maxLoanAmountIn18DecimalsInUSD = (usdcAmountIn18DecimalsInUSD *
            ltv) / 10 ** 4;
        // Calculating the maximum amount of cbETH that can be borrowed (now correctly using 10**8)
        uint256 cbEthAbleToBorrow = (maxLoanAmountIn18DecimalsInUSD * 10 ** 8) /
            cbEthPriceInUSD;
        // Borrowing cbETH after calculating a safe amount
        uint256 safeAmount = (cbEthAbleToBorrow * 95) / 100;
        aavePool.borrow(cbETH, safeAmount, 2, 0, address(this));
        uint256 cbEthBalance = IERC20(cbETH).balanceOf(address(this));
        (uint256 usdcReceived, uint256 aeroReceived) = _swapcbETHToUSDCAndAERO(
            cbEthBalance
        );
        IERC20(asset()).safeTransfer(address(aerodromePool), usdcReceived);
        IERC20(AERO).safeTransfer(address(aerodromePool), aeroReceived);
        aerodromePool.mint(address(this));
        aerodromePool.skim(address(this));

        // Add accounting for _totalAccountedAssets
        _totalAccountedAssets += amount;
    }

    function _rebalancePosition(uint256 additionalAmountNeeded) internal {
        bytes32[] memory priceFeedIds = new bytes32[](3);
        priceFeedIds[0] = cbEthUsdPriceFeedId;
        priceFeedIds[1] = usdcUsdPriceFeedId;
        priceFeedIds[2] = aeroUsdPriceFeedId;
        uint256[] memory prices = getPricePyth(priceFeedIds);
        uint256 cbEthPriceInUsd = prices[0];
        uint256 usdcPriceInUsd = prices[1];
        uint256 aeroPriceInUsd = prices[2];

        uint256 amountToFreeUp = additionalAmountNeeded > 0
            ? additionalAmountNeeded
            : 0;

        if (amountToFreeUp == 0) {
            // Original rebalancing logic
            (
                uint256 totalCollateralBase,
                uint256 totalDebtBase,
                ,
                uint256 currentLiquidationThreshold,
                ,

            ) = aavePool.getUserAccountData(address(this));

            uint256 bufferedTargetHealthFactor = TARGET_HEALTH_FACTOR +
                HEALTH_FACTOR_BUFFER;

            amountToFreeUp =
                totalDebtBase -
                (totalCollateralBase * currentLiquidationThreshold) /
                bufferedTargetHealthFactor;
        }

        // Convert amountToFreeUp from USDC to cbETH
        uint256 cbEthEquivalent = (amountToFreeUp * 1e18 * usdcPriceInUsd) /
            (cbEthPriceInUsd * 1e6);

        // Calculate how much to withdraw from Aerodrome Pool
        uint256 lpTokensToBurn = _calculateLPTokensToWithdraw(
            cbEthEquivalent,
            usdcPriceInUsd,
            aeroPriceInUsd
        );

        IERC20(address(aerodromePool)).transfer(
            address(aerodromePool),
            lpTokensToBurn
        );
        (uint256 usdc, uint256 aero) = aerodromePool.burn(address(this));

        // Swap USDC and AERO to cbETH
        uint256 cbEthReceived = _swapUSDCAndAEROToCbETH(usdc, aero);

        // Repay cbETH debt
        IERC20(cbETH).approve(address(aavePool), cbEthReceived);
        aavePool.repay(cbETH, cbEthReceived, 2, address(this));
    }

    function calculateHealthFactor() internal view returns (uint256) {
        (, , , , , uint256 healthFactor) = aavePool.getUserAccountData(
            address(this)
        );

        return healthFactor;
    }

    function checkAndRebalance() external payable onlyRole(REBALANCER_ROLE) {
        uint256 healthFactor = calculateHealthFactor();
        uint256 currentHealthFactor4Dec = healthFactor / 1e14;
        uint256 bufferedTargetHealthFactor = TARGET_HEALTH_FACTOR +
            HEALTH_FACTOR_BUFFER;
        uint256 maxHealthFactor = TARGET_HEALTH_FACTOR * 2; // Example: 2.2 (twice the target)

        if (currentHealthFactor4Dec < bufferedTargetHealthFactor) {
            _rebalancePosition(0);
        } else if (currentHealthFactor4Dec > maxHealthFactor) {
            _investIdleFunds();
        }
    }

    function _investIdleFunds() internal {
        (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            ,
            uint256 currentLtv,
            ,

        ) = aavePool.getUserAccountData(address(this));

        uint256 targetDebtBase = (totalCollateralBase * currentLtv) / 10000;
        uint256 additionalBorrowBase = targetDebtBase - totalDebtBase;

        if (additionalBorrowBase > 0) {
            bytes32[] memory priceFeedIds = new bytes32[](2);
            priceFeedIds[0] = usdcUsdPriceFeedId;
            priceFeedIds[1] = cbEthUsdPriceFeedId;
            uint256[] memory prices = getPricePyth(priceFeedIds);
            uint256 usdcPriceInUSD = prices[0];
            uint256 cbEthPriceInUSD = prices[1];

            uint256 cbEthToBorrow = (additionalBorrowBase * usdcPriceInUSD) /
                cbEthPriceInUSD;
            uint256 safeAmount = (cbEthToBorrow * 95) / 100;

            aavePool.borrow(cbETH, safeAmount, 2, 0, address(this));
            uint256 cbEthBalance = IERC20(cbETH).balanceOf(address(this));
            (
                uint256 usdcReceived,
                uint256 aeroReceived
            ) = _swapcbETHToUSDCAndAERO(cbEthBalance);

            IERC20(asset()).safeTransfer(address(aerodromePool), usdcReceived);
            IERC20(AERO).safeTransfer(address(aerodromePool), aeroReceived);
            aerodromePool.mint(address(this));
            aerodromePool.skim(address(this));

            _totalAccountedAssets += usdcReceived;
        }
    }

    // @audit - check the amnount returned by this function in tests

    function _calculateLPTokensToWithdraw(
        uint256 cbEthValueInUsd,
        uint256 usdcPriceInUsd,
        uint256 aeroPriceInUsd
    ) internal view returns (uint256 sharesToBurn) {
        (uint256 reserve0, , ) = aerodromePool.getReserves();
        uint256 totalSupplyPoolToken = IERC20(address(aerodromePool))
            .totalSupply();

        // Calculate desired amounts, dividing by 2 to split equally between USDC and AERO
        uint256 halfCbEthValueInUsd = cbEthValueInUsd / 2;
        uint256 desiredUsdc = (halfCbEthValueInUsd * 1e6) / usdcPriceInUsd; // Convert to USDC with 6 decimals
        // uint256 desiredAero = (halfCbEthValueInUsd * 1e18) / aeroPriceInUsd; // Convert to AERO with 18 decimals

        // Calculate the amount of LP tokens to burn
        sharesToBurn = (desiredUsdc * totalSupplyPoolToken) / reserve0;
    }

    function harvestReinvestAndReport() external onlyOwner {
        // Get prices from Pyth Network
        bytes32[] memory priceFeedIds = new bytes32[](3);
        priceFeedIds[0] = cbEthUsdPriceFeedId;
        priceFeedIds[1] = usdcUsdPriceFeedId;
        priceFeedIds[2] = aeroUsdPriceFeedId;
        uint256[] memory prices = getPricePyth(priceFeedIds);
        uint256 cbETHPrice = prices[0];
        uint256 usdcPrice = prices[1];
        uint256 aeroPriceInUSD = prices[2];

        // Get current balances
        uint256 currentAUSDCBalance = IERC20(aUSDC).balanceOf(address(this));
        uint256 currentVariableDebtBalance = IERC20(variableDebtCbETH)
            .balanceOf(address(this));

        // Calculate the change in balances
        uint256 borrowedCbETHChange = currentVariableDebtBalance -
            previousVariableDebtBalance;

        // Calculate the net gain in Aave
        uint256 suppliedUSDCValueChange = currentAUSDCBalance -
            previousAUSDCBalance;
        uint256 borrowedCbETHValueChangeInUSD = (cbETHPrice *
            borrowedCbETHChange) / (usdcPrice * 10 ** 12);

        int256 aaveNetGain = int256(suppliedUSDCValueChange) -
            int256(borrowedCbETHValueChangeInUSD);

        // Update the previous balances
        previousAUSDCBalance = currentAUSDCBalance;
        previousVariableDebtBalance = currentVariableDebtBalance;

        // Get initial balances
        uint256 initialAeroBalance = IERC20(AERO).balanceOf(address(this));
        uint256 initialUsdcBalance = IERC20(asset()).balanceOf(address(this));

        // Claim fees from Aerodrome Pool
        aerodromePool.claimFees();

        uint256 currentAeroBalance = IERC20(AERO).balanceOf(address(this));
        uint256 currentUSDCBalance = IERC20(asset()).balanceOf(address(this));

        // Calculate claimed rewards
        uint256 claimedAero = currentAeroBalance - initialAeroBalance;
        uint256 claimedUsdc = currentUSDCBalance - initialUsdcBalance;

        if (currentAeroBalance > 0) {
            currentUSDCBalance += _swapAEROToUSDC(currentAeroBalance);
        }

        // Calculate total rewards in USDC
        uint256 finalAeroBalance = IERC20(AERO).balanceOf(address(this));
        uint256 finalUsdcBalance = IERC20(asset()).balanceOf(address(this));
        uint256 totalRewardsInUSDC = (finalUsdcBalance - initialUsdcBalance) +
            ((aeroPriceInUSD * (finalAeroBalance - initialAeroBalance)) /
                (usdcPrice * 10 ** 12));

        // Calculate total profit, including Aerodrome rewards and Aave net gain
        int256 totalProfit = int256(totalRewardsInUSDC) + aaveNetGain;

        // Only apply fee if there's a positive profit
        uint256 strategistFee = 0;
        if (totalProfit > 0) {
            strategistFee =
                (uint256(totalProfit) * STRATEGIST_FEE_PERCENTAGE) /
                10000;
            accumulatedStrategistFee += strategistFee;
        }

        // Calculate net profit after fee
        uint256 netProfit = totalProfit > 0
            ? uint256(totalProfit) - strategistFee
            : 0;

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
            IERC20(asset()).safeTransfer(
                address(aerodromePool),
                totalRewardsInUSDC / 2
            );
            aerodromePool.mint(address(this));
        }

        // Skim any excess assets from Aerodrome Pool
        aerodromePool.skim(address(this));

        emit HarvestReport(
            uint256(totalProfit),
            netProfit,
            strategistFee,
            totalRewardsInUSDC,
            aaveNetGain,
            claimedAero,
            claimedUsdc
        );
    }

    function claimStrategistFees(uint256 amount) external {
        require(msg.sender == strategist, "Only strategist can claim fees");
        require(
            accumulatedStrategistFee > 0 && amount < accumulatedStrategistFee,
            "No fees to claim"
        );

        (uint256 reserve0, , ) = aerodromePool.getReserves();
        uint256 totalSupplyPoolToken = IERC20(address(aerodromePool))
            .totalSupply();

        uint256 sharesToBurn = (amount * totalSupplyPoolToken) / reserve0;

        IERC20(address(aerodromePool)).transfer(
            address(aerodromePool),
            sharesToBurn
        );
        (uint256 usdc, uint256 aero) = aerodromePool.burn(address(this));

        uint256 usdcAmount = _swapAEROToUSDC(aero) + usdc;

        IERC20(asset()).safeTransfer(strategist, usdcAmount);

        accumulatedStrategistFee -= amount;

        // emit StrategistFeeClaimed(, accumulatedStrategistFee);
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

    function _swapcbETHToUSDCAndAERO(
        uint256 amountIn
    ) internal returns (uint256 amountOutUSDC, uint256 amountOutAERO) {
        address assetAddress = asset();
        // Swap half of cbETH to AERO
        amountOutAERO = _swap(cbETH, AERO, 500, 3000, amountIn / 2);

        // Swap the other half of cbETH to USDC
        amountOutUSDC = _swap(cbETH, assetAddress, 500, 500, amountIn / 2);

        return (amountOutUSDC, amountOutAERO);
    }

    function _swapUSDCAndAEROToCbETH(
        uint256 amountInUSDC,
        uint256 amountInAERO
    ) internal returns (uint256) {
        address assetAddress = asset();
        // Swap USDC to cbETH
        uint256 amountOutcbETH1 = _swap(
            assetAddress,
            cbETH,
            500,
            500,
            amountInUSDC
        );
        uint256 amountOutcbETH2 = _swap(AERO, cbETH, 3000, 500, amountInAERO);
        return amountOutcbETH1 + amountOutcbETH2;
    }

    function _swapAEROToUSDC(
        uint256 amountIn
    ) internal returns (uint256 amountOut) {
        amountOut = _swap(AERO, asset(), 3000, 500, amountIn);
    }

    function _swapUSDCToAERO(
        uint256 amountIn
    ) internal returns (uint256 amountOut) {
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

    // Function to grant the rebalancer role
    function grantRebalancerRole(address account) external onlyOwner {
        grantRole(REBALANCER_ROLE, account);
    }

    // Function to revoke the rebalancer role
    function revokeRebalancerRole(address account) external onlyOwner {
        revokeRole(REBALANCER_ROLE, account);
    }

    function getMaxWithdrawableAmount() public view returns (uint256) {
        // Get the available (unborrowed) liquidity
        uint256 availableLiquidity = IERC20(aUSDC).balanceOf(address(asset()));

        (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            ,
            uint256 currentLiquidationThreshold,
            ,

        ) = aavePool.getUserAccountData(address(this));

        // Calculate the maximum amount that can be withdrawn without risking liquidation
        uint256 maxWithdrawBase = totalCollateralBase -
            ((totalDebtBase * 10000) / currentLiquidationThreshold);

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

    event HarvestReport(
        uint256 totalProfit,
        uint256 netProfit,
        uint256 strategistFee,
        uint256 aerodromeRewards,
        int256 aaveNetGain,
        uint256 claimedAero,
        uint256 claimedUsdc
    );

    event StrategistFeeClaimed(uint256 claimedAmount, uint256 remainingFees);
}
