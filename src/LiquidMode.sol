// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/console.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";
import "@api3/contracts/api3-server-v1/proxies/interfaces/IProxy.sol";
import "@cryptoalgebra/integral-core/contracts/interfaces/IAlgebraPool.sol";
import "@cryptoalgebra/integral-core/contracts/libraries/TickMath.sol";

import "@cryptoalgebra/integral-periphery/contracts/libraries/TransferHelper.sol";
import "@cryptoalgebra/integral-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@cryptoalgebra/integral-periphery/contracts/base/LiquidityManagement.sol";

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import "@cryptoalgebra/integral-periphery/contracts/libraries/LiquidityAmounts.sol";
import "@cryptoalgebra/integral-periphery/contracts/libraries/PoolAddress.sol";
import "@cryptoalgebra/integral-periphery/contracts/libraries/PoolInteraction.sol";
import {TransferHelper} from "@cryptoalgebra/integral-periphery/contracts/libraries/TransferHelper.sol";
import {ISwapRouter} from "@cryptoalgebra/integral-periphery/contracts/interfaces/ISwapRouter.sol";

contract LiquidMode is
    ERC4626,
    Ownable,
    AccessControl,
    ReentrancyGuard,
    Pausable,
    IERC721Receiver,
    LiquidityManagement
{
    using Math for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    ISwapRouter public immutable swapRouter;

    INonfungiblePositionManager public immutable nonfungiblePositionManager;
    address public immutable EZETH;
    address public immutable WRSETH;

    uint256 public kimTokenId;
    uint128 public kimLiquidity;

    bytes32 public constant HARVESTER_ROLE = keccak256("HARVESTER_ROLE");

    address public strategist;
    uint256 public accumulatedStrategistFee;
    uint256 public lastManagementFeeCollection;

    uint256 public totalDeposits;
    uint256 public _totalAccountedAssets;
    address public ezETHwrsETHPool;
    address public ezEthEthProxy;
    address public wrsEthEthProxy;
    address public treasury;

    event StrategistFeeClaimed(uint256 claimedAmount, uint256 remainingFees);
    event AnnualManagementFeeCollected(uint256 feeAmount);
    event StrategistFeePercentageUpdated(uint256 newPercentage);
    event ManagementFeePercentageUpdated(uint256 newPercentage);

    struct KIMPosition {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
    }

    KIMPosition public kimPosition;

    IWETH9 public immutable WETH;

    uint256 public liquiditySlippageTolerance = 500; // 5% default for liquidity operations
    uint256 public swapSlippageTolerance = 200; // 2% default for swaps
    uint256 public strategistFeePercentage = 2000; // 20% with 2 decimal places
    uint256 public managementFeePercentage = 100; // 1% annual fee with 2 decimal places
    uint256 public constant MAX_STRATEGIST_FEE_PERCENTAGE = 3000; // 30% maximum
    uint256 public constant MAX_MANAGEMENT_FEE_PERCENTAGE = 500; // 5% maximum
    uint256 public constant MANAGEMENT_FEE_INTERVAL = 365 days;
    int24 public constant BOTTOM_TICK = -3360;
    int24 public constant TOP_TICK = 3360;

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address initialOwner,
        address _strategist,
        INonfungiblePositionManager _nonfungiblePositionManager,
        address _factory,
        address _poolDeployer,
        address _EZETH,
        address _WRSETH,
        address _WETH,
        address _ezETHwrsETHPool,
        ISwapRouter _swapRouter,
        address _treasury,
        address _ezEthEthProxy,
        address _wrsEthEthProxy
    )
        ERC4626(asset_)
        ERC20(name_, symbol_)
        Ownable(initialOwner)
        PeripheryImmutableState(_factory, _WETH, _poolDeployer)
    {
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(HARVESTER_ROLE, initialOwner);

        strategist = _strategist;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        EZETH = _EZETH;
        WRSETH = _WRSETH;
        WETH = IWETH9(_WETH);
        ezETHwrsETHPool = _ezETHwrsETHPool;
        swapRouter = _swapRouter;
        treasury = _treasury;
        ezEthEthProxy = _ezEthEthProxy;
        wrsEthEthProxy = _wrsEthEthProxy;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        address assetAddress = asset();
        SafeERC20.safeTransferFrom(IERC20(assetAddress), caller, address(this), assets);

        // Unwrap WETH to ETH
        // WETH.withdraw(assets);
        console.log("runnning0");
        _mint(receiver, shares);
        console.log("runnning1");
        totalDeposits += assets;
        _totalAccountedAssets += assets;
        console.log("runnning2");
        _investFunds(assets);
        console.log("runnning3");
        emit Deposit(caller, receiver, assets, shares);
    }

    function _investFunds(uint256 amount) internal {
        // uint256 receivedEzETH = xRenzoDeposit.depositETH{value: amount / 2}(0, block.timestamp);
        // rSETHPoolV2.deposit{value: amount / 2}("");
        console.log("runnning2-1");
        uint256 receivedEzETH = _swapForToken(amount / 2, address(WETH), EZETH);
        console.log("runnning2-2");
        uint256 receivedWRSETH = _swapForToken(amount / 2, address(WETH), WRSETH);
        console.log("runnning2-3");
        console.log("receivedEzETH", receivedEzETH);
        console.log("receivedWRSETH", receivedWRSETH);
        if (kimPosition.tokenId == 0) {
            _createKIMPosition(receivedEzETH, receivedWRSETH);
        } else {
            _addLiquidityToKIMPosition(receivedEzETH, receivedWRSETH);
        }
    }

    function _createKIMPosition(uint256 amount0, uint256 amount1)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 depositedAmount0, uint256 depositedAmount1)
    {
        IERC20(EZETH).approve(address(nonfungiblePositionManager), amount0);
        IERC20(WRSETH).approve(address(nonfungiblePositionManager), amount1);

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: EZETH,
            token1: WRSETH,
            tickLower: BOTTOM_TICK,
            tickUpper: TOP_TICK,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: amount0 * (10000 - liquiditySlippageTolerance) / 10000,
            amount1Min: amount1 * (10000 - liquiditySlippageTolerance) / 10000,
            recipient: address(this),
            deadline: block.timestamp
        });

        (tokenId, liquidity, depositedAmount0, depositedAmount1) = nonfungiblePositionManager.mint(params);

        kimTokenId = tokenId;
        kimLiquidity = liquidity;

        // Store the details in the struct
        kimPosition =
            KIMPosition({tokenId: tokenId, liquidity: liquidity, amount0: depositedAmount0, amount1: depositedAmount1});
    }

    function _addLiquidityToKIMPosition(uint256 amount0, uint256 amount1)
        internal
        returns (uint128 liquidity, uint256 addedAmount0, uint256 addedAmount1)
    {
        IERC20(EZETH).approve(address(nonfungiblePositionManager), amount0);
        IERC20(WRSETH).approve(address(nonfungiblePositionManager), amount1);

        INonfungiblePositionManager.IncreaseLiquidityParams memory params = INonfungiblePositionManager
            .IncreaseLiquidityParams({
            tokenId: kimPosition.tokenId,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: (amount0 * (10000 - liquiditySlippageTolerance)) / 10000,
            amount1Min: (amount1 * (10000 - liquiditySlippageTolerance)) / 10000,
            deadline: block.timestamp
        });

        (liquidity, addedAmount0, addedAmount1) = nonfungiblePositionManager.increaseLiquidity(params);

        // Update the total liquidity
        kimLiquidity += liquidity;

        // Update the struct
        kimPosition = KIMPosition({
            tokenId: kimTokenId,
            liquidity: kimLiquidity,  // Use the updated total liquidity
            amount0: kimPosition.amount0 + addedAmount0,
            amount1: kimPosition.amount1 + addedAmount1
        });

        return (liquidity, addedAmount0, addedAmount1);
    }

    function _removeLiquidityFromKIMPosition(uint256 amount0, uint256 amount1)
        internal
        returns (uint256 removedAmount0, uint256 removedAmount1)
    {
        uint128 _liquidity = _getLiquidityForAmounts(amount0, amount1);
        console.log("liquidity", _liquidity);
        console.log("amount0", amount0);
        console.log("amount1", amount1);
        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager
            .DecreaseLiquidityParams({
            tokenId: kimPosition.tokenId,
            liquidity: _liquidity,
            amount0Min: (amount0 * (10000 - liquiditySlippageTolerance)) / 10000,
            amount1Min: (amount1 * (10000 - liquiditySlippageTolerance)) / 10000,
            deadline: block.timestamp
        });

        (removedAmount0, removedAmount1) = nonfungiblePositionManager.decreaseLiquidity(params);

        // Update the total liquidity
        require(kimLiquidity >= _liquidity, "Insufficient liquidity");
        kimLiquidity -= _liquidity;

        // Update the struct
        kimPosition = KIMPosition({
            tokenId: kimPosition.tokenId,
            liquidity: kimLiquidity,  // Use the updated total liquidity
            amount0: kimPosition.amount0 > removedAmount0 ? kimPosition.amount0 - removedAmount0 : 0,
            amount1: kimPosition.amount1 > removedAmount1 ? kimPosition.amount1 - removedAmount1 : 0
        });

        return (removedAmount0, removedAmount1);
    }

    function _getLiquidityForAmounts(uint256 amount0, uint256 amount1) internal view returns (uint128 liquidity) {
        //get position details
        (,,,, int24 tickLower, int24 tickUpper,,,,,) = nonfungiblePositionManager.positions(kimPosition.tokenId);
        uint160 sqrtPriceX96 = PoolInteraction._getSqrtPrice(IAlgebraPool(ezETHwrsETHPool));
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        liquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, amount0, amount1);
    }

    function _collectKIMFees(uint256 amount0Desired, uint256 amount1Desired)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
            tokenId: kimPosition.tokenId,
            recipient: address(this),
            amount0Max: amount0Desired == 0 ? type(uint128).max : uint128(amount0Desired),
            amount1Max: amount1Desired == 0 ? type(uint128).max : uint128(amount1Desired)
        });

        return nonfungiblePositionManager.collect(params);
    }

    function _withdrawFunds(uint256 amount) internal nonReentrant returns (uint256 totalWETH) {
        // Get the price feeds
        (int224 _ezETHPrice,) = readDataFeed(ezEthEthProxy);
        uint256 ezETHPrice = uint256(uint224(_ezETHPrice));
        (int224 _wrsETHPrice,) = readDataFeed(wrsEthEthProxy);
        uint256 wrsETHPrice = uint256(uint224(_wrsETHPrice));
        console.log("ezETHPrice", ezETHPrice);
        console.log("wrsETHPrice", wrsETHPrice);

        console.log("amount", amount);
        uint256 ezETHAmount = (amount * 1e18) / (ezETHPrice * 2);
        uint256 wrsETHAmount = (amount * 1e18) / (wrsETHPrice * 2);
        console.log("ezETHAmount", ezETHAmount);
        console.log("wrsETHAmount", wrsETHAmount);

        //take out liquidity from KIM position
        (uint256 removedAmount0, uint256 removedAmount1) = _removeLiquidityFromKIMPosition(ezETHAmount, wrsETHAmount);

        console.log("decreasing liquidity successfull");

        (uint256 receivedAmount0, uint256 receivedAmount1)=_collectKIMFees(removedAmount0, removedAmount1);
        console.log("receivedAmount0", receivedAmount0);
        console.log("receivedAmount1", receivedAmount1);

        uint256 balEzEth = IERC20(EZETH).balanceOf(address(this));
        uint256 balWrsEth = IERC20(WRSETH).balanceOf(address(this));
        console.log("balEzEth", balEzEth);
        console.log("balWrsEth", balWrsEth);
        //swap ezETH for ETH
        uint256 wethForEZETH = _swapForToken(receivedAmount0, EZETH, address(WETH));
        uint256 wethForWRSETH = _swapForToken(receivedAmount1, WRSETH, address(WETH));

        console.log("wethForEZETH", wethForEZETH);
        console.log("wethForWRSETH", wethForWRSETH);

        totalWETH = wethForEZETH + wethForWRSETH;
        console.log("totalWETH", totalWETH);
    }

    function _swapForToken(uint256 amountIn, address tokenIn, address tokenOut) internal returns (uint256 amountOut) {
        TransferHelper.safeApprove(tokenIn, address(swapRouter), amountIn);

        uint256 amountOutMinimum;
        if (tokenIn == address(WETH)) {
            // If WETH is the input token, use the price feed of the output token
            (int224 _tokenOutPrice,) = readDataFeed(tokenOut == EZETH ? ezEthEthProxy : wrsEthEthProxy);
            uint256 tokenOutPrice = uint256(uint224(_tokenOutPrice));
            uint256 expectedAmountOut = ((amountIn * 1e18) / tokenOutPrice) / 1e18;
            amountOutMinimum = (expectedAmountOut * (10000 - swapSlippageTolerance)) / 10000;
        } else if( tokenOut == address(WETH)) {
            console.log("tokenIn", tokenIn);
            // Original logic for non-WETH input tokens
            uint256 balanceEzETH = IERC20(EZETH).balanceOf(address(this));
            console.log("balanceEzETH", balanceEzETH);
            (int224 _tokenInPrice,) = readDataFeed(tokenIn == EZETH ? ezEthEthProxy : wrsEthEthProxy);
            uint256 tokenInPrice = uint256(uint224(_tokenInPrice));
            uint256 expectedAmountOut = (amountIn * tokenInPrice) / 1e18;
            amountOutMinimum = (expectedAmountOut * (10000 - swapSlippageTolerance)) / 10000;
        } else {
            // Original logic for non-WETH input tokens
            (int224 _tokenInPrice,) = readDataFeed(tokenIn == EZETH ? ezEthEthProxy : wrsEthEthProxy);
            uint256 tokenInPrice = uint256(uint224(_tokenInPrice));
            (int224 _tokenOutPrice,) = readDataFeed(tokenOut == EZETH ? ezEthEthProxy : wrsEthEthProxy);
            uint256 tokenOutPrice = uint256(uint224(_tokenOutPrice));


            uint256 amountInInETH = amountIn * tokenInPrice / 1e18;
            uint256 expectedAmountOut = (amountInInETH * 1e18) / tokenOutPrice;
            amountOutMinimum = (expectedAmountOut * (10000 - swapSlippageTolerance)) / 10000;
        }
        uint256 ezEThbalance = IERC20(EZETH).balanceOf(address(this));
        console.log(ezEThbalance);
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum,
            limitSqrtPrice: 0
        });

        amountOut = swapRouter.exactInputSingle(params);
    }

    function _swapBeforeReinvest(uint256 amountIn, bytes memory path, uint256 amountInInTokenOut, address tokenIn)
        internal
        returns (uint256 amountOut)
    {
        TransferHelper.safeApprove(tokenIn, address(swapRouter), amountIn);

        ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
            path: path,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: (amountInInTokenOut * (10000 - swapSlippageTolerance)) / 10000
        });
        console.log("amountOutMinimum", (amountInInTokenOut * (10000 - swapSlippageTolerance)) / 10000);
       amountOut = swapRouter.exactInput(params);
    }

    function harvestReinvestAndReport() external nonReentrant onlyRole(HARVESTER_ROLE) {
        (uint256 amount0, uint256 amount1) = _collectKIMFees(0, 0);
        uint256 initialBalanceEzETH = IERC20(EZETH).balanceOf(address(this));
        uint256 initialBalanceWrsETH = IERC20(WRSETH).balanceOf(address(this));
        console.log("initialBalanceEzETH", initialBalanceEzETH);
        console.log("initialBalanceWrsETH", initialBalanceWrsETH);
        console.log("amount0", amount0);
        console.log("amount1", amount1);
        if (amount0 > 0 || amount1 > 0) {
            //convert the amount of ezETH and wrsETH to ETH
            (int224 _ezETHPrice,) = readDataFeed(ezEthEthProxy);
            uint256 ezETHPrice = uint256(uint224(_ezETHPrice));
            (int224 _wrsETHPrice,) = readDataFeed(wrsEthEthProxy);
            uint256 wrsETHPrice = uint256(uint224(_wrsETHPrice));

            uint256 amount0InETH = amount0 > 0 ? (amount0 * ezETHPrice) / 10 ** 18 : 0;
            uint256 amount1InETH = amount1 > 0 ? (amount1 * wrsETHPrice) / 10 ** 18 : 0;
            console.log("amount0InETH", amount0InETH);
            console.log("amount1InETH", amount1InETH);
            uint256 ezETHToReinvest;
            uint256 wrsETHToReinvest;


            if (amount0InETH > amount1InETH) {
                (uint256 amountToSwapInToken, uint256 amountOutForLowerToken) = _balanceAssets(amount0InETH, amount1InETH, ezETHPrice, wrsETHPrice, EZETH, WRSETH);
                ezETHToReinvest = amount0 - amountToSwapInToken;
                wrsETHToReinvest = amount1 + amountOutForLowerToken;
            } else if (amount1InETH > amount0InETH) {
                (uint256 amountToSwapInToken, uint256 amountOutForLowerToken) = _balanceAssets(amount1InETH, amount0InETH, wrsETHPrice, ezETHPrice, WRSETH, EZETH);
                console.log("amountToSwapInToken", amountToSwapInToken);
                console.log("amountOutForLowerToken", amountOutForLowerToken);
                ezETHToReinvest = amount0 + amountOutForLowerToken;
                console.log("ezETHToReinvest", ezETHToReinvest);
                wrsETHToReinvest = amount1 - amountToSwapInToken;
                console.log("wrsETHToReinvest", wrsETHToReinvest);
            }

            // uint256 currentEzETHBalance = IERC20(EZETH).balanceOf(address(this));
            // uint256 currentWrsETHBalance = IERC20(WRSETH).balanceOf(address(this));

            // Calculate and accrue performance fee
            uint256 ezETHToReinvestInETH = ezETHToReinvest * ezETHPrice / 10 ** 18;
            uint256 wrsETHToReinvestInETH = wrsETHToReinvest * wrsETHPrice / 10 ** 18;
            console.log("ezETHToReinvestInETH", ezETHToReinvestInETH);
            console.log("wrsETHToReinvestInETH", wrsETHToReinvestInETH);

            uint256 totalProfit = ezETHToReinvestInETH + wrsETHToReinvestInETH;
            console.log("totalProfit", totalProfit);
            uint256 performanceFee = (totalProfit * strategistFeePercentage) / 10000;
            console.log("performanceFee", performanceFee);
            accumulatedStrategistFee += performanceFee;
            console.log("accumulatedStrategistFee", accumulatedStrategistFee);
            _totalAccountedAssets += totalProfit - performanceFee;
            console.log("_totalAccountedAssets", _totalAccountedAssets);
            uint256 balanceEzETH = IERC20(EZETH).balanceOf(address(this));
            uint256 balanceWrsETH = IERC20(WRSETH).balanceOf(address(this));
            console.log("balanceEzETH", balanceEzETH);
            console.log("balanceWrsETH", balanceWrsETH);

            _addLiquidityToKIMPosition(ezETHToReinvest, wrsETHToReinvest);
        }
    }

    function performMaintenance() external nonReentrant onlyRole(HARVESTER_ROLE) {
        // Check balances
        uint256 wethBalance = WETH.balanceOf(address(this));
        uint256 wrsETHBalance = IERC20(WRSETH).balanceOf(address(this));
        uint256 ezETHBalance = IERC20(EZETH).balanceOf(address(this));

        // Convert WETH to wrsETH and ezETH if necessary
        if (wethBalance > 0) {
            uint256 halfWETH = wethBalance / 2;

            // Swap WETH for wrsETH

            uint256 wrsETHReceived = _swapForToken(halfWETH, address(WETH), WRSETH);
            wrsETHBalance += wrsETHReceived;

            // Swap WETH for ezETH
            uint256 ezETHReceived = _swapForToken(halfWETH, address(WETH), EZETH);
            ezETHBalance += ezETHReceived;
        }

        // Get price feeds
        (int224 _ezETHPrice,) = readDataFeed(ezEthEthProxy);
        uint256 ezETHPrice = uint256(uint224(_ezETHPrice));
        (int224 _wrsETHPrice,) = readDataFeed(wrsEthEthProxy);
        uint256 wrsETHPrice = uint256(uint224(_wrsETHPrice));

        // Convert balances to ETH value
        uint256 wrsETHValueInETH = (wrsETHBalance * wrsETHPrice) / 10 ** 18;
        uint256 ezETHValueInETH = (ezETHBalance * ezETHPrice) / 10 ** 18;

        // Balance assets if necessary
        if (wrsETHValueInETH > ezETHValueInETH) {
            _balanceAssets(wrsETHValueInETH, ezETHValueInETH, wrsETHPrice, ezETHPrice, WRSETH, EZETH);
        } else if (ezETHValueInETH > wrsETHValueInETH) {
            _balanceAssets(ezETHValueInETH, wrsETHValueInETH, ezETHPrice, wrsETHPrice, EZETH, WRSETH);
        }

        // Add liquidity to KIM position
        uint256 finalWrsETHBalance = IERC20(WRSETH).balanceOf(address(this));
        uint256 finalEzETHBalance = IERC20(EZETH).balanceOf(address(this));
        if (finalWrsETHBalance > 0 && finalEzETHBalance > 0) {
            _addLiquidityToKIMPosition(finalEzETHBalance, finalWrsETHBalance);
        }
    }

    function _balanceAssets(
        uint256 higherAmount,
        uint256 lowerAmount,
        uint256 higherPrice,
        uint256 lowerPrice,
        address tokenIn,
        address tokenOut
    ) internal returns (uint256 amountToSwapInToken, uint256 amountOutForLowerToken) {
        uint256 difference = higherAmount - lowerAmount;
        console.log("difference", difference);
        uint256 amountToSwapInETH = difference / 2;
        console.log("amountToSwapInETH", amountToSwapInETH);
        amountToSwapInToken = amountToSwapInETH * 10 ** 18 / higherPrice;
        console.log("amountToSwapInToken", amountToSwapInToken);
        uint256 sameAmountInOtherToken = amountToSwapInETH * 10 ** 18 / lowerPrice;
        console.log("sameAmountInOtherToken", sameAmountInOtherToken);
        bytes memory path = abi.encodePacked(tokenIn, WETH, tokenOut);
        // amountOutForLowerToken = _swapBeforeReinvest(amountToSwapInToken, path, sameAmountInOtherToken, tokenIn);
        amountOutForLowerToken = _swapForToken(amountToSwapInToken, tokenIn, tokenOut);
    }

    function claimStrategistFees(uint256 amount) external nonReentrant {
        require(msg.sender == strategist, "Only strategist can claim fees");
        require(amount <= accumulatedStrategistFee, "Insufficient fees to claim");

        accumulatedStrategistFee -= amount;
        _withdrawFunds(amount);
        SafeERC20.safeTransfer(IERC20(asset()), strategist, amount);
        emit StrategistFeeClaimed(amount, accumulatedStrategistFee);
    }

    function totalAssets() public view override returns (uint256) {
        return _totalAccountedAssets;
    }

    function grantRebalancerRole(address account) external onlyOwner {
        grantRole(HARVESTER_ROLE, account);
    }

    function revokeRebalancerRole(address account) external onlyOwner {
        revokeRole(HARVESTER_ROLE, account);
    }

    function setStrategist(address _strategist) external onlyOwner {
        strategist = _strategist;
    }

    function setEzEthEthProxy(address _ezEthEthProxy) external onlyOwner {
        ezEthEthProxy = _ezEthEthProxy;
    }

    function setWrsEthEthProxy(address _wrsEthEthProxy) external onlyOwner {
        wrsEthEthProxy = _wrsEthEthProxy;
    }

    function setLiquiditySlippageTolerance(uint256 _newTolerance) external onlyOwner {
        require(_newTolerance <= 1000, "Liquidity slippage tolerance cannot exceed 10%");
        liquiditySlippageTolerance = _newTolerance;
    }

    function setSwapSlippageTolerance(uint256 _newTolerance) external onlyOwner {
        require(_newTolerance <= 1000, "Swap slippage tolerance cannot exceed 10%");
        swapSlippageTolerance = _newTolerance;
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    function setStrategistFeePercentage(uint256 _newPercentage) external onlyOwner {
        require(_newPercentage <= MAX_STRATEGIST_FEE_PERCENTAGE, "Fee exceeds maximum allowed");
        strategistFeePercentage = _newPercentage;
        emit StrategistFeePercentageUpdated(_newPercentage);
    }

    function setManagementFeePercentage(uint256 _newPercentage) external onlyOwner {
        require(_newPercentage <= MAX_MANAGEMENT_FEE_PERCENTAGE, "Fee exceeds maximum allowed");
        managementFeePercentage = _newPercentage;
        emit ManagementFeePercentageUpdated(_newPercentage);
    }

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

    function withdraw(uint256 assets, address receiver, address owner)
        public
        virtual
        override
        whenNotPaused
        returns (uint256)
    {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        virtual
        override
        whenNotPaused
        returns (uint256)
    {
        return super.redeem(shares, receiver, owner);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        _burn(owner, shares);

        uint256 wethWithdrawn = _withdrawFunds(assets);
        _totalAccountedAssets -= wethWithdrawn;
        SafeERC20.safeTransfer(IERC20(asset()), receiver, wethWithdrawn);

        emit Withdraw(caller, receiver, owner, wethWithdrawn, shares);
    }

    function readDataFeed(address proxy) public view returns (int224 value, uint32 timestamp) {
        (value, timestamp) = IProxy(proxy).read();
    }

    function onERC721Received(address operator, address, uint256 tokenId, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        // get position information

        // _createDeposit(operator, tokenId);

        return this.onERC721Received.selector;
    }

    function collectAnnualManagementFee() external {
        require(msg.sender == strategist, "Only strategist can collect fees");
        require(block.timestamp >= lastManagementFeeCollection + MANAGEMENT_FEE_INTERVAL, "Fee collection not yet due");

        // Calculate annual management fee
        uint256 annualManagementFee = (totalAssets() * managementFeePercentage) / 10000;

        accumulatedStrategistFee += annualManagementFee;
        _totalAccountedAssets -= annualManagementFee;

        emit AnnualManagementFeeCollected(annualManagementFee);
    }

    function getKimPosition() public view returns (uint256, uint128, uint256, uint256) {
        return (kimPosition.tokenId, kimPosition.liquidity, kimPosition.amount0, kimPosition.amount1);
    }
}