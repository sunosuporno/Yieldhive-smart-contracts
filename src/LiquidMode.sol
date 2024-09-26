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
import {IxRenzoDeposit} from "./interfaces/IxRenzoDeposit.sol";
import {IRSETHPoolV2} from "./interfaces/IRSETHPoolV2.sol";
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

    IxRenzoDeposit public immutable xRenzoDeposit;
    IRSETHPoolV2 public immutable rSETHPoolV2;
    ISwapRouter public immutable swapRouter;

    INonfungiblePositionManager public immutable nonfungiblePositionManager;
    address public immutable EZETH;
    address public immutable WRSETH;
    uint24 public immutable KIM_FEE;

    uint256 public kimTokenId;
    uint128 public kimLiquidity;

    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");

    address public strategist;
    uint256 public accumulatedStrategistFee;
    uint256 public constant STRATEGIST_FEE_PERCENTAGE = 2000; // 20% with 2 decimal places

    uint256 public accumulatedDeposits;
    uint256 public _totalAccountedAssets;
    address public ezETHwrsETHPool;
    address public ezEthEthProxy;
    address public wrsEthEthProxy;

    event StrategistFeeClaimed(uint256 claimedAmount, uint256 remainingFees);

    struct KIMPosition {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
    }

    KIMPosition public kimPosition;

    IWETH9 public immutable WETH;

    uint256 public liquiditySlippageTolerance = 200; // 2% default for liquidity operations
    uint256 public swapSlippageTolerance = 100; // 1% default for swaps

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address initialOwner,
        address _strategist,
        address _xRenzoDeposit,
        address _rSETHPoolV2,
        INonfungiblePositionManager _nonfungiblePositionManager,
        address _factory,
        address _poolDeployer,
        address _EZETH,
        address _WRSETH,
        uint24 _kimFee,
        address _WETH,
        address _ezETHwrsETHPool,
        ISwapRouter _swapRouter
    )
        ERC4626(asset_)
        ERC20(name_, symbol_)
        Ownable(initialOwner)
        PeripheryImmutableState(_factory, _WETH, _poolDeployer)
    {
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(REBALANCER_ROLE, initialOwner);

        strategist = _strategist;
        xRenzoDeposit = IxRenzoDeposit(_xRenzoDeposit);
        rSETHPoolV2 = IRSETHPoolV2(_rSETHPoolV2);

        nonfungiblePositionManager = _nonfungiblePositionManager;
        EZETH = _EZETH;
        WRSETH = _WRSETH;
        KIM_FEE = _kimFee;
        WETH = IWETH9(_WETH);
        ezETHwrsETHPool = _ezETHwrsETHPool;
        swapRouter = _swapRouter;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        address assetAddress = asset();
        SafeERC20.safeTransferFrom(IERC20(assetAddress), caller, address(this), assets);

        // Unwrap WETH to ETH
        WETH.deposit{value: assets}();

        _mint(receiver, shares);

        accumulatedDeposits += assets;

        _investFunds(assets);
        emit Deposit(caller, receiver, assets, shares);
    }

    function _investFunds(uint256 amount) internal {
        uint256 receivedEzETH = xRenzoDeposit.depositETH{value: amount / 2}(0, block.timestamp);
        rSETHPoolV2.deposit{value: amount / 2}("");
        uint256 receivedWRSETH = IERC20(WRSETH).balanceOf(address(this));
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
            tickLower: TickMath.MIN_TICK,
            tickUpper: TickMath.MAX_TICK,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: (amount0 * (10000 - liquiditySlippageTolerance)) / 10000,
            amount1Min: (amount1 * (10000 - liquiditySlippageTolerance)) / 10000,
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

    function _collectKIMFees() internal returns (uint256 amount0, uint256 amount1) {
        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
            tokenId: kimPosition.tokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        return nonfungiblePositionManager.collect(params);
    }

    function _withdrawFunds(uint256 amount) internal nonReentrant returns (uint256 totalWETH) {
        // Get the price feeds
        (int224 _ezETHPrice,) = readDataFeed(ezEthEthProxy);
        uint256 ezETHPrice = uint256(uint224(_ezETHPrice));
        (int224 _wrsETHPrice,) = readDataFeed(wrsEthEthProxy);
        uint256 wrsETHPrice = uint256(uint224(_wrsETHPrice));

        uint256 ezETHAmount = (amount * 10 ** 18) / (ezETHPrice * 2);
        uint256 wrsETHAmount = (amount * 10 ** 18) / (wrsETHPrice * 2);
        //Convert to amount / 2 to wrsETH and ezETH
        uint256 ezETHAmountPrecise = ezETHAmount / 10 ** 18;
        uint256 wrsETHAmountPrecise = wrsETHAmount / 10 ** 18;

        //take out liquidity from KIM position
        (uint256 removedAmount0, uint256 removedAmount1) =
            _removeLiquidityFromKIMPosition(ezETHAmountPrecise, wrsETHAmountPrecise);

        //swap ezETH for ETH
        uint256 wethForEZETH = _swapForETH(removedAmount0, EZETH);
        uint256 wethForWRSETH = _swapForETH(removedAmount1, WRSETH);

        totalWETH = wethForEZETH + wethForWRSETH;

        _totalAccountedAssets -= totalWETH;
    }

    function _swapForETH(uint256 amountIn, address tokenIn) internal returns (uint256 amountOut) {
        TransferHelper.safeApprove(tokenIn, address(swapRouter), amountIn);

        (int224 _tokenInPrice,) = readDataFeed(tokenIn);
        uint256 tokenInPrice = uint256(uint224(_tokenInPrice));
        uint256 expectedAmountOut = (amountIn * 10 ** 18) / tokenInPrice;
        uint256 amountOutMinimum = (expectedAmountOut * (10000 - swapSlippageTolerance)) / 10000;

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: address(WETH),
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum,
            limitSqrtPrice: 0
        });

        amountOut = swapRouter.exactInputSingle(params);
    }

    function _swapBeforeReinvest(uint256 amountIn, bytes memory path, uint256 amountOutMinimum, address tokenIn)
        internal
        returns (uint256 amountOut)
    {
        TransferHelper.safeApprove(tokenIn, address(swapRouter), amountIn);

        ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
            path: path,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: (amountOutMinimum * (10000 - swapSlippageTolerance)) / 10000
        });

        swapRouter.exactInput(params);
    }

    function _investIdleFunds() internal {}

    function harvestReinvestAndReport() external onlyOwner nonReentrant {
        (uint256 amount0, uint256 amount1) = _collectKIMFees();

        if (amount0 > 0 || amount1 > 0) {
            //convert the amount of ezETH and wrsETH to ETH
            (int224 _ezETHPrice,) = readDataFeed(ezEthEthProxy);
            uint256 ezETHPrice = uint256(uint224(_ezETHPrice));
            (int224 _wrsETHPrice,) = readDataFeed(wrsEthEthProxy);
            uint256 wrsETHPrice = uint256(uint224(_wrsETHPrice));

            uint256 amount0InETH = (amount0 * ezETHPrice) / 10 ** 18;
            uint256 amount1InETH = (amount1 * wrsETHPrice) / 10 ** 18;

            _totalAccountedAssets += amount0InETH + amount1InETH;

            if (amount0InETH > amount1InETH) {
                _balanceAssets(amount0InETH, amount1InETH, ezETHPrice, wrsETHPrice, EZETH, WRSETH);
            } else if (amount1InETH > amount0InETH) {
                _balanceAssets(amount1InETH, amount0InETH, wrsETHPrice, ezETHPrice, WRSETH, EZETH);
            }

            uint256 currentEzETHBalance = IERC20(EZETH).balanceOf(address(this));
            uint256 currentWrsETHBalance = IERC20(WRSETH).balanceOf(address(this));

            _addLiquidityToKIMPosition(currentEzETHBalance, currentWrsETHBalance);
        }
    }

    function _balanceAssets(
        uint256 higherAmount,
        uint256 lowerAmount,
        uint256 higherPrice,
        uint256 lowerPrice,
        address tokenIn,
        address tokenOut
    ) internal {
        uint256 difference = higherAmount - lowerAmount;
        uint256 amountToSwapInETH = difference / 2;
        uint256 amountToSwapInToken = amountToSwapInETH * 10 ** 18 / higherPrice;
        uint256 sameAmountInOtherToken = amountToSwapInETH * 10 ** 18 / lowerPrice;
        bytes memory path = abi.encodePacked(tokenIn, WETH, tokenOut);
        _swapBeforeReinvest(amountToSwapInToken / 10 ** 18, path, sameAmountInOtherToken / 10 ** 18, tokenIn);
    }

    function claimStrategistFees(uint256 amount) external nonReentrant {}

    function totalAssets() public view override returns (uint256) {
        return _totalAccountedAssets;
    }

    function grantRebalancerRole(address account) external onlyOwner {
        grantRole(REBALANCER_ROLE, account);
    }

    function revokeRebalancerRole(address account) external onlyOwner {
        revokeRole(REBALANCER_ROLE, account);
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
        require(_newTolerance <= 500, "Swap slippage tolerance cannot exceed 5%");
        swapSlippageTolerance = _newTolerance;
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
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        return super.withdraw(assets, receiver, owner);
    }

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
}
