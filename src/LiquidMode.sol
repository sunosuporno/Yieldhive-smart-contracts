// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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
    int24 public BOTTOM_TICK = -3360;
    int24 public TOP_TICK = 3360;

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
    uint256 public accumulatedStrategistFee;
    uint256 public lastManagementFeeCollection;
    uint256 public liquiditySlippageTolerance = 500; // 5% default for liquidity operations
    uint256 public swapSlippageTolerance = 200; // 2% default for swaps
    uint256 public strategistFeePercentage = 500; // 5% with 2 decimal places

    address public strategist;
    address public treasury;

    // New state variables
    address public token0;
    address public token1;
    address public currentPool;
    address public token0EthProxy;
    address public token1EthProxy;
    address public poolAddress;

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
        uint256 receivedToken0 = _swapForToken(amount / 2, address(WETH), token0);
        uint256 receivedToken1 = _swapForToken(amount / 2, address(WETH), token1);
        if (kimPosition.tokenId == 0) {
            _createKIMPosition(receivedToken0, receivedToken1);
        } else {
            _addLiquidityToKIMPosition(receivedToken0, receivedToken1);
        }
    }

    function _createKIMPosition(uint256 amount0, uint256 amount1)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 depositedAmount0, uint256 depositedAmount1)
    {
        IERC20(token0).approve(address(nonfungiblePositionManager), amount0);
        IERC20(token1).approve(address(nonfungiblePositionManager), amount1);

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
        IERC20(token0).approve(address(nonfungiblePositionManager), amount0);
        IERC20(token1).approve(address(nonfungiblePositionManager), amount1);

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
            liquidity: kimLiquidity, // Use the updated total liquidity
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
            liquidity: kimLiquidity, // Use the updated total liquidity
            amount0: kimPosition.amount0 > removedAmount0 ? kimPosition.amount0 - removedAmount0 : 0,
            amount1: kimPosition.amount1 > removedAmount1 ? kimPosition.amount1 - removedAmount1 : 0
        });

        return (removedAmount0, removedAmount1);
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

    function _withdrawFunds(uint256 amount) internal returns (uint256 totalWETH) {
        // Get the price feeds
        (int224 _token0Price,) = readDataFeed(token0EthProxy);
        uint256 token0Price = uint256(uint224(_token0Price));
        (int224 _token1Price,) = readDataFeed(token1EthProxy);
        uint256 token1Price = uint256(uint224(_token1Price));

        uint256 token0Amount = (amount * 1e18) / (token0Price * 2);
        uint256 token1Amount = (amount * 1e18) / (token1Price * 2);

        // Take out liquidity from KIM position
        (uint256 removedAmount0, uint256 removedAmount1) = _removeLiquidityFromKIMPosition(token0Amount, token1Amount);

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
            uint256 expectedAmountOut = ((amountIn * 1e18) / tokenOutPrice) / 1e18;
            amountOutMinimum = (expectedAmountOut * (10000 - swapSlippageTolerance)) / 10000;
        } else if (tokenOut == address(WETH)) {
            (int224 _tokenInPrice,) = readDataFeed(tokenIn == token1 ? token1EthProxy : token0EthProxy);
            uint256 tokenInPrice = uint256(uint224(_tokenInPrice));
            uint256 expectedAmountOut = (amountIn * tokenInPrice) / 1e18;
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

    function harvestReinvestAndReport() external nonReentrant onlyRole(HARVESTER_ROLE) {
        (uint256 amount0, uint256 amount1) = _collectKIMFees(0, 0);
        if (amount0 > 0 || amount1 > 0) {
            //convert the amount of token1 and token2 to ETH
            (int224 _token0Price,) = readDataFeed(token0EthProxy);
            uint256 token0Price = uint256(uint224(_token0Price));
            (int224 _token1Price,) = readDataFeed(token1EthProxy);
            uint256 token1Price = uint256(uint224(_token1Price));

            uint256 amount0InETH = amount0 > 0 ? (amount0 * token0Price) / 10 ** 18 : 0;
            uint256 amount1InETH = amount1 > 0 ? (amount1 * token1Price) / 10 ** 18 : 0;
            uint256 token0ToReinvest;
            uint256 token1ToReinvest;

            if (amount0InETH > amount1InETH) {
                (uint256 amountToSwapInToken, uint256 amountOutForLowerToken) =
                    _balanceAssets(amount0InETH, amount1InETH, token0Price, token0, token1);
                token0ToReinvest = amount0 - amountToSwapInToken;
                token1ToReinvest = amount1 + amountOutForLowerToken;
            } else if (amount1InETH > amount0InETH) {
                (uint256 amountToSwapInToken, uint256 amountOutForLowerToken) =
                    _balanceAssets(amount1InETH, amount0InETH, token1Price, token1, token0);
                token0ToReinvest = amount0 + amountOutForLowerToken;
                token1ToReinvest = amount1 - amountToSwapInToken;
            }

            uint256 token0ToReinvestInETH = token0ToReinvest * token0Price / 10 ** 18;
            uint256 token1ToReinvestInETH = token1ToReinvest * token1Price / 10 ** 18;

            uint256 totalProfit = token0ToReinvestInETH + token1ToReinvestInETH;
            uint256 performanceFee = (totalProfit * strategistFeePercentage) / 10000;
            accumulatedStrategistFee += performanceFee;
            _totalAccountedAssets += totalProfit - performanceFee;

            (uint128 reinvestedLiquidity,,) = _addLiquidityToKIMPosition(token0ToReinvest, token1ToReinvest);

            emit HarvestReinvestReport(
                amount0, amount1, token0ToReinvest, token1ToReinvest, totalProfit, performanceFee, reinvestedLiquidity
            );
        }
    }

    function performMaintenance() external nonReentrant onlyRole(HARVESTER_ROLE) {
        // Check balances
        uint256 wethBalance = WETH.balanceOf(address(this));
        uint256 token1EthBalance = IERC20(token1).balanceOf(address(this));
        uint256 token0EthBalance = IERC20(token0).balanceOf(address(this));

        // Convert WETH to wrsETH and ezETH if necessary
        if (wethBalance > 0) {
            uint256 halfWETH = wethBalance / 2;

            // Swap WETH for wrsETH

            uint256 token1Received = _swapForToken(halfWETH, address(WETH), token1);
            token1EthBalance += token1Received;

            // Swap WETH for ezETH
            uint256 token0Received = _swapForToken(halfWETH, address(WETH), token0);
            token0EthBalance += token0Received;
        }

        // Get price feeds
        (int224 _token0Price,) = readDataFeed(token0EthProxy);
        uint256 token0Price = uint256(uint224(_token0Price));
        (int224 _token1Price,) = readDataFeed(token1EthProxy);
        uint256 token1Price = uint256(uint224(_token1Price));

        // Convert balances to ETH value
        uint256 token1ValueInETH = (token1EthBalance * token1Price) / 10 ** 18;
        uint256 token0ValueInETH = (token0EthBalance * token0Price) / 10 ** 18;

        // Balance assets if necessary
        if (token1ValueInETH > token0ValueInETH) {
            _balanceAssets(token1ValueInETH, token0ValueInETH, token1Price, token1, token0);
        } else if (token0ValueInETH > token1ValueInETH) {
            _balanceAssets(token0ValueInETH, token1ValueInETH, token0Price, token0, token1);
        }

        // Add liquidity to KIM position
        uint256 finalToken1Balance = IERC20(token1).balanceOf(address(this));
        uint256 finalToken0Balance = IERC20(token0).balanceOf(address(this));
        uint128 reinvestedLiquidity;
        if (finalToken1Balance > 0 && finalToken0Balance > 0) {
            (reinvestedLiquidity,,) = _addLiquidityToKIMPosition(finalToken0Balance, finalToken1Balance);
        }
        emit MaintenancePerformed(wethBalance, finalToken0Balance, finalToken1Balance, reinvestedLiquidity);
    }

    function _balanceAssets(
        uint256 higherAmount,
        uint256 lowerAmount,
        uint256 higherPrice,
        address tokenIn,
        address tokenOut
    ) internal returns (uint256 amountToSwapInToken, uint256 amountOutForLowerToken) {
        uint256 difference = higherAmount - lowerAmount;
        uint256 amountToSwapInETH = difference / 2;
        amountToSwapInToken = amountToSwapInETH * 10 ** 18 / higherPrice;
        amountOutForLowerToken = _swapForToken(amountToSwapInToken, tokenIn, tokenOut);
    }

    function claimStrategistFees(uint256 amount) external nonReentrant onlyRole(STRATEGIST_ROLE) {
        require(amount <= accumulatedStrategistFee, "Insufficient fees to claim");

        accumulatedStrategistFee -= amount;
        uint256 wethWithdrawn = _withdrawFunds(amount);
        SafeERC20.safeTransfer(IERC20(asset()), strategist, wethWithdrawn);
        emit StrategistFeeClaimed(wethWithdrawn, accumulatedStrategistFee);
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

        _burn(owner, shares);

        uint256 wethWithdrawn = _withdrawFunds(assets);
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
        require(accumulatedStrategistFee == 0, "Pending strategist fees must be claimed");

        token0 = newToken0;
        token0EthProxy = newToken0EthProxy;
        token1 = newToken1;
        token1EthProxy = newToken1EthProxy;
        poolAddress = newPoolAddress;
    }
}
