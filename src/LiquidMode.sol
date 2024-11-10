// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console} from "forge-std/Test.sol";
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
    // Constants
    bytes32 public constant HARVESTER_ROLE = keccak256("HARVESTER_ROLE");
    bytes32 public constant STRATEGIST_ROLE = keccak256("STRATEGIST_ROLE");
    uint256 public constant MAX_STRATEGIST_FEE_PERCENTAGE = 3000; // 30% maximum
    uint256 public constant MAX_MANAGEMENT_FEE_PERCENTAGE = 500; // 5% maximum
    uint256 public constant MANAGEMENT_FEE_INTERVAL = 365 days;
    int24 public BOTTOM_TICK = -1020;
    int24 public TOP_TICK = 1020;

    // Immutable variables
    IWETH9 public immutable WETH;
    ISwapRouter public immutable swapRouter;
    INonfungiblePositionManager public immutable nonfungiblePositionManager;
    address public immutable EZETH;
    address public immutable WRSETH;

    // Storage variables (try to group similar types together)
    uint256 public kimTokenId;
    uint128 public kimLiquidity;
    uint256 public totalDeposits;
    uint256 public _totalAccountedAssets;
    uint256 public lastManagementFeeCollection;
    uint256 public liquiditySlippageTolerance = 500; // 5% default for liquidity operations
    uint256 public swapSlippageTolerance = 200; // 2% default for swaps
    uint256 public strategistFeePercentage = 500; // 5% with 2 decimal places

    address public strategist;
    address public treasury;

    // New state variables
    address public token0;
    address public token1;
    address public poolAddress;
    address public token0EthProxy;
    address public token1EthProxy;

    // Struct definition
    struct KIMPosition {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
    }

    // Complex types
    KIMPosition public kimPosition;

    // Events
    event StrategistFeeClaimed(uint256 claimedAmount, uint256 remainingFees);
    event StrategistFeePercentageUpdated(uint256 newPercentage);
    event HarvestReinvestReport(
        uint256 collectedEzETH,
        uint256 collectedWrsETH,
        uint256 ezETHToReinvest,
        uint256 wrsETHToReinvest,
        uint256 totalProfitInETH,
        uint256 performanceFee,
        uint128 reinvestedLiquidity
    );
    event MaintenancePerformed(
        uint256 initialWETHBalance, uint256 finalEzETHBalance, uint256 finalWrsETHBalance, uint128 addedLiquidity
    );
    event LiquidityFullyWithdrawn(uint256 tokenId, uint256 amount0, uint256 amount1);
    event NFTBurned(uint256 tokenId);
    event ReinvestedInNewPool(address newPool, uint256 amount0, uint256 amount1);

    // Library usage
    using Math for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address initialOwner,
        address _strategist,
        INonfungiblePositionManager _nonfungiblePositionManager,
        address _factory,
        address _poolDeployer,
        address _WETH,
        address _poolAddress,
        ISwapRouter _swapRouter,
        address _treasury,
        address _token0,
        address _token1,
        address _token0EthProxy,
        address _token1EthProxy
    )
        ERC4626(asset_)
        ERC20(name_, symbol_)
        Ownable(initialOwner)
        PeripheryImmutableState(_factory, _WETH, _poolDeployer)
    {
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(HARVESTER_ROLE, initialOwner);
        _grantRole(STRATEGIST_ROLE, _strategist);
        strategist = _strategist;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        WETH = IWETH9(_WETH);
        poolAddress = _poolAddress;
        swapRouter = _swapRouter;
        treasury = _treasury;
        token0 = _token0;
        token1 = _token1;
        token0EthProxy = _token0EthProxy;
        token1EthProxy = _token1EthProxy;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        address assetAddress = asset();
        SafeERC20.safeTransferFrom(IERC20(assetAddress), caller, address(this), assets);

        // Unwrap WETH to ETH
        // WETH.withdraw(assets);
        _mint(receiver, shares);
        totalDeposits += assets;
        _totalAccountedAssets += assets;
        _investFunds(assets);
        emit Deposit(caller, receiver, assets, shares);
    }

    function _investFunds(uint256 amount) internal {
        // uint256 receivedEzETH = xRenzoDeposit.depositETH{value: amount / 2}(0, block.timestamp);
        // rSETHPoolV2.deposit{value: amount / 2}("");
        (uint256 amount0, uint256 amount1) = _calculateOptimalRatio(amount);

        uint256 receivedToken0 = _swapForToken(amount0, address(WETH), token0);
        uint256 receivedToken1 = _swapForToken(amount1, address(WETH), token1);
        console.log("receivedToken0", receivedToken0);
        console.log("receivedToken1", receivedToken1);
        if (kimPosition.tokenId == 0) {
            _createKIMPosition(receivedToken0, receivedToken1);
        } else {
            _addLiquidityToKIMPosition(receivedToken0, receivedToken1, true, true);
        }
    }

    function _createKIMPosition(uint256 amount0, uint256 amount1)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 depositedAmount0, uint256 depositedAmount1)
    {
        IERC20(token0).approve(address(nonfungiblePositionManager), amount0);
        IERC20(token1).approve(address(nonfungiblePositionManager), amount1);

        console.log("amount0", amount0);
        console.log("amount1", amount1);
        console.log("minAmount0", amount0 * (10000 - liquiditySlippageTolerance) / 10000);
        console.log("minAmount1", amount1 * (10000 - liquiditySlippageTolerance) / 10000);

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
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

        nonfungiblePositionManager.approveForFarming(tokenId, false, address(0));

        kimTokenId = tokenId;
        kimLiquidity = liquidity;

        // Store the details in the struct
        kimPosition =
            KIMPosition({tokenId: tokenId, liquidity: liquidity, amount0: depositedAmount0, amount1: depositedAmount1});
    }

    function _addLiquidityToKIMPosition(uint256 amount0, uint256 amount1, bool minAmount0, bool minAmount1)
        internal
        returns (uint128 liquidity, uint256 addedAmount0, uint256 addedAmount1)
    {
        IERC20(token0).approve(address(nonfungiblePositionManager), amount0);
        IERC20(token1).approve(address(nonfungiblePositionManager), amount1);

        INonfungiblePositionManager.IncreaseLiquidityParams memory params = INonfungiblePositionManager
            .IncreaseLiquidityParams({
            tokenId: kimPosition.tokenId,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: minAmount0 ? (amount0 * (10000 - liquiditySlippageTolerance)) / 10000 : 0,
            amount1Min: minAmount1 ? (amount1 * (10000 - liquiditySlippageTolerance)) / 10000 : 0,
            deadline: block.timestamp
        });

        (liquidity, addedAmount0, addedAmount1) = nonfungiblePositionManager.increaseLiquidity(params);

        // Update the total liquidity
        kimLiquidity += liquidity;

        // Update the struct
        kimPosition = KIMPosition({
            tokenId: kimTokenId,
            liquidity: kimLiquidity, // Use the updated total liquidity
            amount0: kimPosition.amount0 + addedAmount0,
            amount1: kimPosition.amount1 + addedAmount1
        });

        return (liquidity, addedAmount0, addedAmount1);
    }

    function _removeLiquidityFromKIMPosition(uint256 amount0, uint256 amount1)
        internal
        returns (uint256 removedAmount0, uint256 removedAmount1, uint128 _liquidity)
    {
        console.log("running _removeLiquidityFromKIMPosition");
        console.log("amount0", amount0);
        console.log("amount1", amount1);
        _liquidity = _getLiquidityForAmounts(amount0, amount1);
        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager
            .DecreaseLiquidityParams({
            tokenId: kimPosition.tokenId,
            liquidity: _liquidity,
            amount0Min: (amount0 * (10000 - liquiditySlippageTolerance)) / 10000,
            amount1Min: (amount1 * (10000 - liquiditySlippageTolerance)) / 10000,
            deadline: block.timestamp
        });

        (removedAmount0, removedAmount1) = nonfungiblePositionManager.decreaseLiquidity(params);
        console.log("decreased liquidity", _liquidity);
        // Update the total liquidity
        require(kimLiquidity >= _liquidity, "Insufficient liquidity");
        console.log("removed liquidity", _liquidity);
        kimLiquidity -= _liquidity;
        console.log("new liquidity", kimLiquidity);

        // Update the struct
        kimPosition = KIMPosition({
            tokenId: kimPosition.tokenId,
            liquidity: kimLiquidity, // Use the updated total liquidity
            amount0: kimPosition.amount0 > removedAmount0 ? kimPosition.amount0 - removedAmount0 : 0,
            amount1: kimPosition.amount1 > removedAmount1 ? kimPosition.amount1 - removedAmount1 : 0
        });
        console.log("completed _removeLiquidityFromKIMPosition");
        return (removedAmount0, removedAmount1, _liquidity);
    }

    function _getLiquidityForAmounts(uint256 amount0, uint256 amount1) internal view returns (uint128 liquidity) {
        //get position details
        (,,,, int24 tickLower, int24 tickUpper,,,,,) = nonfungiblePositionManager.positions(kimPosition.tokenId);
        uint160 sqrtPriceX96 = PoolInteraction._getSqrtPrice(IAlgebraPool(poolAddress));
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

    function _withdrawFunds(uint256 amount, uint256 shares) internal returns (uint256 totalWETH) {
        // Get the price feeds
        (int224 _token0Price,) = readDataFeed(token0EthProxy);
        uint256 token0Price = uint256(uint224(_token0Price));
        (int224 _token1Price,) = readDataFeed(token1EthProxy);
        uint256 token1Price = uint256(uint224(_token1Price));

        console.log("totalSupply", totalSupply());

        uint256 token0Amount = (kimPosition.amount0 * shares) / totalSupply();
        uint256 token1Amount = (kimPosition.amount1 * shares) / totalSupply();

        // Take out liquidity from KIM position
        (uint256 removedAmount0, uint256 removedAmount1, uint128 _liquidity) =
            _removeLiquidityFromKIMPosition(token0Amount, token1Amount);

        // //update kim position
        // kimPosition = KIMPosition({
        //     tokenId: kimPosition.tokenId,
        //     liquidity: kimLiquidity - _liquidity,
        //     amount0: kimPosition.amount0 - removedAmount0,
        //     amount1: kimPosition.amount1 - removedAmount1
        // });

        (uint256 receivedAmount0, uint256 receivedAmount1) = _collectKIMFees(removedAmount0, removedAmount1);
        // Swap token0 for WETH
        uint256 wethForToken0 = _swapForToken(receivedAmount0, token0, address(WETH));
        // Swap token1 for WETH
        uint256 wethForToken1 = _swapForToken(receivedAmount1, token1, address(WETH));

        totalWETH = wethForToken0 + wethForToken1;
    }

    function _swapForToken(uint256 amountIn, address tokenIn, address tokenOut) internal returns (uint256 amountOut) {
        TransferHelper.safeApprove(tokenIn, address(swapRouter), amountIn);

        uint256 amountOutMinimum;
        if (tokenIn == address(WETH)) {
            // If WETH is the input token, use the price feed of the output token
            (int224 _tokenOutPrice,) = readDataFeed(tokenOut == token0 ? token0EthProxy : token1EthProxy);
            uint256 tokenOutPrice = uint256(uint224(_tokenOutPrice));
            uint256 expectedAmountOut = ((amountIn * 1e18) / tokenOutPrice);
            console.log("expectedAmountOut", expectedAmountOut);
            amountOutMinimum = (expectedAmountOut * (10000 - swapSlippageTolerance)) / 10000;
        } else if (tokenOut == address(WETH)) {
            (int224 _tokenInPrice,) = readDataFeed(tokenIn == token1 ? token1EthProxy : token0EthProxy);
            uint256 tokenInPrice = uint256(uint224(_tokenInPrice));
            uint256 expectedAmountOut = (amountIn * tokenInPrice) / 1e18;
            console.log("expectedAmountOutInETH", expectedAmountOut);
            amountOutMinimum = (expectedAmountOut * (10000 - swapSlippageTolerance)) / 10000;
        } else {
            // Original logic for non-WETH input tokens
            (int224 _tokenInPrice,) = readDataFeed(tokenIn == token1 ? token1EthProxy : token0EthProxy);
            uint256 tokenInPrice = uint256(uint224(_tokenInPrice));
            (int224 _tokenOutPrice,) = readDataFeed(tokenOut == token1 ? token1EthProxy : token0EthProxy);
            uint256 tokenOutPrice = uint256(uint224(_tokenOutPrice));

            uint256 amountInInETH = amountIn * tokenInPrice / 1e18;
            uint256 expectedAmountOut = (amountInInETH * 1e18) / tokenOutPrice;
            amountOutMinimum = (expectedAmountOut * (10000 - swapSlippageTolerance)) / 10000;
        }
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

    function _calculateOptimalRatio(uint256 amount) internal view returns (uint256 amount0, uint256 amount1) {
        (int224 _token0Price,) = readDataFeed(token0EthProxy);
        uint256 token0Price = uint256(uint224(_token0Price));
        (int224 _token1Price,) = readDataFeed(token1EthProxy);
        uint256 token1Price = uint256(uint224(_token1Price));

        // amount in ezETH terms
        uint256 ezETHAmount = amount * 1e18 / token0Price;

        uint160 sqrtPriceX96 = PoolInteraction._getSqrtPrice(IAlgebraPool(poolAddress));
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtRatioAtTick(BOTTOM_TICK);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtRatioAtTick(TOP_TICK);

        // Calculate liquidity for total amount (in WETH terms)
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceLowerX96, sqrtPriceUpperX96, ezETHAmount);

        // Get optimal token amounts for this liquidity
        (amount0, amount1) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity);
        console.log("Invested Amount", amount);
        console.log("amount0", amount0);
        console.log("amount1", amount1);
        //convert amount in terms of WETH
        amount0 = amount0 * token0Price / 1e18;
        amount1 = amount1 * token1Price / 1e18;
        console.log("amount0InETH", amount0);
        console.log("amount1InETH", amount1);
    }

    function harvestReinvestAndReport() external nonReentrant onlyRole(HARVESTER_ROLE) {
        (uint256 amount0, uint256 amount1) = _collectKIMFees(0, 0);
        if (amount0 > 0 || amount1 > 0) {
            // Convert amounts to ETH value for fee calculation
            (int224 _token0Price,) = readDataFeed(token0EthProxy);
            uint256 token0Price = uint256(uint224(_token0Price));
            (int224 _token1Price,) = readDataFeed(token1EthProxy);
            uint256 token1Price = uint256(uint224(_token1Price));

            uint256 amount0InETH = amount0 > 0 ? (amount0 * token0Price) / 10 ** 18 : 0;
            uint256 amount1InETH = amount1 > 0 ? (amount1 * token1Price) / 10 ** 18 : 0;

            // Calculate strategist's share
            uint256 totalProfitInETH = amount0InETH + amount1InETH;
            uint256 strategistShare = (totalProfitInETH * strategistFeePercentage) / 10000;
            uint256 netProfitInETH = totalProfitInETH - strategistShare;

            // Calculate token amounts for strategist
            uint256 strategistAmount0 = (amount0 * strategistFeePercentage) / 10000;
            uint256 strategistAmount1 = (amount1 * strategistFeePercentage) / 10000;

            // Transfer strategist's share directly
            if (strategistAmount0 > 0) IERC20(token0).transfer(strategist, strategistAmount0);
            if (strategistAmount1 > 0) IERC20(token1).transfer(strategist, strategistAmount1);

            uint256 remainingToken0 = IERC20(token0).balanceOf(address(this));
            uint256 remainingToken1 = IERC20(token1).balanceOf(address(this));

            uint256 remainingToken0InETH = remainingToken0 * token0Price / 1e18;
            uint256 remainingToken1InETH = remainingToken1 * token1Price / 1e18;

            console.log("remainingToken0InETH", remainingToken0InETH);
            console.log("remainingToken1InETH", remainingToken1InETH);

            (uint256 token0ToReinvestInETH, uint256 token1ToReinvestInETH) =
                _calculateOptimalRatio(remainingToken0InETH + remainingToken1InETH);

            uint256 token0ToReinvest = token0ToReinvestInETH * 1e18 / token0Price;
            uint256 token1ToReinvest = token1ToReinvestInETH * 1e18 / token1Price;

            console.log("token0ToReinvest", token0ToReinvest);
            console.log("token1ToReinvest", token1ToReinvest);

            console.log("remainingToken0", remainingToken0);
            console.log("remainingToken1", remainingToken1);

            _balanceAssets(token0ToReinvest, token1ToReinvest, remainingToken0, remainingToken1);

            uint256 newToken0Balance = IERC20(token0).balanceOf(address(this));
            uint256 newToken1Balance = IERC20(token1).balanceOf(address(this));

            console.log("newToken0Balance", newToken0Balance);
            console.log("newToken1Balance", newToken1Balance);

            // // Balance assets if needed
            // if (amount0InETH > amount1InETH) {
            //     (uint256 amountToSwapInToken, uint256 amountOutForLowerToken) =
            //         _balanceAssets(amount0InETH - strategistShare, amount1InETH, token0Price, token0, token1);
            //     token0ToReinvest -= amountToSwapInToken;
            //     token1ToReinvest += amountOutForLowerToken;
            // } else if (amount1InETH > amount0InETH) {
            //     (uint256 amountToSwapInToken, uint256 amountOutForLowerToken) =
            //         _balanceAssets(amount1InETH - strategistShare, amount0InETH, token1Price, token1, token0);
            //     token0ToReinvest += amountOutForLowerToken;
            //     token1ToReinvest -= amountToSwapInToken;
            // }

            // Update total assets (excluding strategist fee)
            _totalAccountedAssets += netProfitInETH;
            uint128 reinvestedLiquidity;

            if (newToken0Balance >= token0ToReinvest) {
                if (newToken1Balance >= token1ToReinvest) {
                    // Both tokens have sufficient balance, use normal slippage checks
                    (reinvestedLiquidity,,) = _addLiquidityToKIMPosition(token0ToReinvest, token1ToReinvest, true, true);
                } else {
                    // Token1 is short, remove token0's minimum amount check to allow pool to take less token0
                    (reinvestedLiquidity,,) = _addLiquidityToKIMPosition(
                        token0ToReinvest,
                        newToken1Balance,
                        false, // token0 min check removed
                        true // token1 keeps min check since it's the limiting factor
                    );
                }
            } else if (newToken1Balance >= token1ToReinvest) {
                if (newToken0Balance >= token0ToReinvest) {
                    // Both tokens have sufficient balance, use normal slippage checks
                    (reinvestedLiquidity,,) = _addLiquidityToKIMPosition(newToken0Balance, token1ToReinvest, true, true);
                } else {
                    // Token0 is short, remove token1's minimum amount check to allow pool to take less token1
                    (reinvestedLiquidity,,) = _addLiquidityToKIMPosition(
                        newToken0Balance,
                        token1ToReinvest,
                        true, // token0 keeps min check since it's the limiting factor
                        false // token1 min check removed
                    );
                }
            }

            // Reinvest remaining tokens

            // Update KIM position
            kimPosition = KIMPosition({
                tokenId: kimPosition.tokenId,
                liquidity: kimLiquidity + reinvestedLiquidity,
                amount0: kimPosition.amount0 + token0ToReinvest,
                amount1: kimPosition.amount1 + token1ToReinvest
            });

            emit HarvestReinvestReport(
                amount0,
                amount1,
                token0ToReinvest,
                token1ToReinvest,
                totalProfitInETH,
                strategistShare,
                reinvestedLiquidity
            );
        }
    }

    function _balanceAssets(
        uint256 token0ToReInvest,
        uint256 token1ToReInvest,
        uint256 currentToken0Amount,
        uint256 currentToken1Amount
    ) internal {
        if (currentToken0Amount > token0ToReInvest) {
            uint256 amount0ToSwap = currentToken0Amount - token0ToReInvest;
            _swapForToken(amount0ToSwap, token0, token1);
        } else if (currentToken0Amount < token0ToReInvest) {
            uint256 amount1ToSwap = currentToken1Amount - token1ToReInvest;
            _swapForToken(amount1ToSwap, token1, token0);
        }
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

    function setToken0EthProxy(address _token0EthProxy) external onlyOwner {
        token0EthProxy = _token0EthProxy;
    }

    function setToken1EthProxy(address _token1EthProxy) external onlyOwner {
        token1EthProxy = _token1EthProxy;
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
        nonReentrant
        returns (uint256)
    {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        virtual
        override
        whenNotPaused
        nonReentrant
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

        console.log("running _withdraw");
        uint256 wethWithdrawn = _withdrawFunds(assets, shares);
        _burn(owner, shares);
        _totalAccountedAssets -= assets;
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

    function getKimPosition() public view returns (uint256, uint128, uint256, uint256) {
        return (kimPosition.tokenId, kimPosition.liquidity, kimPosition.amount0, kimPosition.amount1);
    }

    // New functions
    function withdrawAllLiquidity() external onlyOwner nonReentrant {
        require(kimPosition.tokenId != 0, "No active position");

        // Collect any uncollected fees first
        _collectKIMFees(0, 0);

        // Remove all liquidity
        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager
            .DecreaseLiquidityParams({
            tokenId: kimPosition.tokenId,
            liquidity: kimPosition.liquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });

        (uint256 amount0, uint256 amount1) = nonfungiblePositionManager.decreaseLiquidity(params);

        // Collect the tokens
        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: kimPosition.tokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        nonfungiblePositionManager.collect(collectParams);

        // Update the position
        kimPosition.liquidity = 0;
        kimPosition.amount0 = 0;
        kimPosition.amount1 = 0;

        emit LiquidityFullyWithdrawn(kimPosition.tokenId, amount0, amount1);
    }

    function burnNFT() external onlyOwner nonReentrant {
        require(kimPosition.tokenId != 0, "No active position");
        require(kimPosition.liquidity == 0, "Liquidity not fully withdrawn");

        nonfungiblePositionManager.burn(kimPosition.tokenId);

        emit NFTBurned(kimPosition.tokenId);

        // Reset the position
        kimPosition = KIMPosition({tokenId: 0, liquidity: 0, amount0: 0, amount1: 0});
    }

    function reinvestInNewPool(int24 newBottomTick, int24 newTopTick) external onlyOwner nonReentrant {
        require(poolAddress != address(0), "Invalid pool address");
        require(kimPosition.tokenId == 0, "Existing position not closed");

        BOTTOM_TICK = newBottomTick;
        TOP_TICK = newTopTick;

        uint256 amount0 = IERC20(token0).balanceOf(address(this));
        uint256 amount1 = IERC20(token1).balanceOf(address(this));

        _createKIMPosition(amount0, amount1);

        emit ReinvestedInNewPool(poolAddress, amount0, amount1);
    }

    function updateTokensAndPool(
        address newToken0,
        address newToken0EthProxy,
        address newToken1,
        address newToken1EthProxy,
        address newPoolAddress
    ) external onlyOwner {
        require(newToken0 != address(0), "Invalid token0 address");
        require(newToken0EthProxy != address(0), "Invalid token0 proxy address");
        require(newToken1 != address(0), "Invalid token1 address");
        require(newToken1EthProxy != address(0), "Invalid token1 proxy address");
        require(newPoolAddress != address(0), "Invalid pool address");
        require(strategistFeePercentage == 0, "Strategist fees must be claimed");

        token0 = newToken0;
        token0EthProxy = newToken0EthProxy;
        token1 = newToken1;
        token1EthProxy = newToken1EthProxy;
        poolAddress = newPoolAddress;
    }
}
