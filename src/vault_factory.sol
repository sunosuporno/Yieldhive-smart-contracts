// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPool as IPoolAave} from "./interfaces/IPool.sol";
import {IPool as IPoolAerodrome} from "./interfaces/IPoolAerodrome.sol";
import {IPoolDataProvider} from "./interfaces/IPoolDataProvider.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {TransferHelper} from "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

contract VaultStrategy is ERC4626, Ownable {
    using Math for uint256;
    using SafeERC20 for IERC20;
    IPyth pyth;
    IPoolAave aavePool;
    IPoolDataProvider aaveProtocolDataProvider;
    IPoolAerodrome aerodromePool;

    address public constant swapRouter =
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

    constructor(
        IERC20 asset_,
        uint256 _initialDeposit,
        address initialOwner,
        string memory name_,
        string memory symbol_,
        address pythContract,
        address aavePoolContract,
        address aaveProtocolDataProviderContract,
        address aerodromePoolContract
    )
        // address _cometAddress
        ERC4626(asset_)
        ERC20(name_, symbol_)
        Ownable(initialOwner)
    {
        asset_.safeTransferFrom(msg.sender, address(this), _initialDeposit);
        pyth = IPyth(pythContract);
        aavePool = IPoolAave(aavePoolContract);
        aaveProtocolDataProvider = IPoolDataProvider(
            aaveProtocolDataProviderContract
        );
        aerodromePool = IPoolAerodrome(aerodromePoolContract);
        // commetAddress = _cometAddress;
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

    function _investFunds(uint256 amount, address assetAddress) internal {
        // Get the price of the assets in USD from Pyth Network
        int64 usdcPriceInUSD = getPricePyth(usdcUsdPriceFeedId).price;
        int64 cbEthPriceInUSD = getPricePyth(cbEthUsdPriceFeedId).price;
        // approve and supply the asset USDC to the Aave pool
        IERC20(assetAddress).approve(address(aavePool), amount);
        aavePool.supply(assetAddress, amount, address(this), 0);

        // Convert the amount of USDC supplied in 18 decimals
        uint256 usdcAmountIn18Decimals = amount * 10 ** 12;
        // Finding total price of the asset supplied in USD
        uint256 usdcAmountIn18DecimalsInUSD = (usdcAmountIn18Decimals *
            (uint64(usdcPriceInUSD))) / 10 ** 8;
        // Fetching LTV of USDC from Aave
        (, uint256 ltv, , , , , , , , ) = aaveProtocolDataProvider
            .getReserveConfigurationData(assetAddress);
        // Calculating the maximum loan amount in USD
        uint256 maxLoanAmountIn18DecimalsInUSD = (usdcAmountIn18DecimalsInUSD *
            ltv) / 10 ** 5;
        // Calculating the maximum amount of cbETH that can be borrowed
        uint256 cbEthAbleToBorrow = (maxLoanAmountIn18DecimalsInUSD * 10 ** 8) /
            uint64(cbEthPriceInUSD);
        // Borrowing cbETH after calculating a safe amount
        uint256 safeAmount = (cbEthAbleToBorrow * 95) / 100;
        aavePool.borrow(cbETH, safeAmount, 2, 0, address(this));
        uint256 cbEthBalance = IERC20(cbETH).balanceOf(address(this));
        (uint usdcReceived, uint aeroReceived) = _swapcbETHToUSDCAndAERO(
            cbEthBalance
        );
        IERC20(asset()).safeTransfer(address(aerodromePool), usdcReceived);
        IERC20(AERO).safeTransfer(address(aerodromePool), aeroReceived);
        aerodromePool.mint(address(this));
        aerodromePool.skim(address(this));
    }

    function _harvestReinvestAndReport() internal {
        //Get prices from Pyth Network
        int64 cbETHPrice = getPricePyth(cbEthUsdPriceFeedId).price;
        int64 usdcPrice = getPricePyth(usdcUsdPriceFeedId).price;
        int64 aeroPriceInUSD = getPricePyth(aeroUsdPriceFeedId).price;

        // Calculate net gains/loss in Aave

        // uint256 normalizedIncome = aavePool.getReserveNormalizedIncome(asset());

        // Calculate the value of USDC supplied plus the interest accrued
        uint256 aUSDCBalance = IERC20(aUSDC).balanceOf(address(this));
        uint256 suppliedUSDCValue = aUSDCBalance;

        // uint256 normalizedVariableDebt = aavePool
        //     .getReserveNormalizedVariableDebt(cbETH);

        // Calculate the value of cbETH borrowed plus the interest owed
        uint256 variableDebtBalance = IERC20(variableDebtCbETH).balanceOf(
            address(this)
        );
        uint256 cbETHDebtValue = variableDebtBalance;
        // Calculate the value of cbETH borrowed in USDC token
        uint256 cbETHAmountInUSDC = (uint64(cbETHPrice) * cbETHDebtValue) /
            (uint64(usdcPrice) * 10 ** 12);

        // claim rewards and reInvest from Aerodrome Pool

        //claim fees from Aerodrome Pool
        aerodromePool.claimFees();
        uint256 aeroBalance = IERC20(AERO).balanceOf(address(this));
        uint256 usdcBalance = IERC20(asset()).balanceOf(address(this));
        // Get AERO and USDC balance in USD to see which one is more in value
        uint256 aeroAmountInUsd = ((uint64(aeroPriceInUSD) * aeroBalance) /
            10) ^ 12;
        uint256 usdcAmountInUsd = (uint64(usdcPrice) * usdcBalance);
        uint256 aeroAmountToReInvest;
        uint256 usdcAmountToReInvest;

        // Swap AERO to USDC if AERO is more in value or vice versa
        if (aeroAmountInUsd > usdcAmountInUsd) {
            uint256 aeroToSwap = ((aeroAmountInUsd - usdcAmountInUsd) *
                10 ** 12) / (uint64(aeroPriceInUSD) * 2);
            aeroAmountToReInvest = _swapAEROToUSDC(aeroToSwap);
        } else if (aeroAmountInUsd < usdcAmountInUsd) {
            uint256 usdcToSwap = (usdcAmountInUsd - aeroAmountInUsd) /
                (uint64(usdcPrice) * 2);
            usdcAmountToReInvest = _swapUSDCToAERO(usdcToSwap);
        }

        // Reinvest the AERO and USDC in Aerodrome Pool
        IERC20(AERO).safeTransfer(address(aerodromePool), aeroAmountToReInvest);
        IERC20(asset()).safeTransfer(
            address(aerodromePool),
            usdcAmountToReInvest
        );
        aerodromePool.mint(address(this));

        // Skim any excess assets from Aerodrome Pool
        aerodromePool.skim(address(this));

        // Check if skimmed results in AERO or USDC (if there is any)
        uint256 usdcBalanceAfterHarvest;
        if (IERC20(AERO).balanceOf(address(this)) > 0) {
            usdcBalanceAfterHarvest = _swapAEROToUSDC(
                IERC20(AERO).balanceOf(address(this))
            );
        } else if (IERC20(asset()).balanceOf(address(this)) > 0) {
            usdcBalanceAfterHarvest = IERC20(asset()).balanceOf(address(this));
        }

        // Calculate net gains/loss in Aerodrome
        uint256 myLPBalance = IERC20(address(aerodromePool)).balanceOf(
            address(this)
        );
        uint256 totalLPSupply = IERC20(address(aerodromePool)).totalSupply();
        (uint256 reserve0, uint256 reserve1, ) = aerodromePool.getReserves();

        // Get current amount value of invested assets
        uint256 myUSDCAmount = (reserve0 * myLPBalance) / totalLPSupply;
        uint256 myAEROAmount = (reserve1 * myLPBalance) / totalLPSupply;

        // Get AERO and USDC balance in USD
        uint256 aeroAmountInUSDC = (uint64(aeroPriceInUSD) * myAEROAmount) /
            (uint64(usdcPrice) * 10 ** 12);

        // Final check to see if any USDC is left in the contract

        _totalAccountedAssets =
            suppliedUSDCValue +
            cbETHAmountInUSDC +
            usdcBalanceAfterHarvest +
            myUSDCAmount +
            aeroAmountInUSDC;
    }

    function _swap(
        address tokenIn,
        address tokenOut,
        uint256 fee1,
        uint256 fee2,
        uint256 amountIn
    ) internal returns (uint256 amountOut) {
        TransferHelper.safeApprove(tokenIn, swapRouter, amountIn);
        bytes memory path = abi.encodePacked(
            tokenIn,
            uint24(fee1),
            WETH9,
            uint24(fee2),
            tokenOut
        );

        bytes memory data = abi.encodeWithSignature(
            "exactInput((bytes,address,uint256,uint256))",
            abi.encode(path, address(this), amountIn, 0)
        );

        (bool success, bytes memory result) = swapRouter.call(data);
        require(success, "Swap failed");
        amountOut = abi.decode(result, (uint256));
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

    function totalAssets() public view override returns (uint256) {
        return _totalAccountedAssets;
    }

    function getPricePyth(
        bytes32 priceFeedId
    ) public view returns (PythStructs.Price memory) {
        PythStructs.Price memory price = pyth.getPrice(priceFeedId);
        return price;
    }
}
