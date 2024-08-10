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
import {IPythPriceUpdater} from "./interfaces/IPythPriceUpdater.sol";

contract VaultStrategy is ERC4626, Ownable {
    using Math for uint256;
    using SafeERC20 for IERC20;
    IPyth pyth;
    IPoolAave aavePool;
    IPoolDataProvider aaveProtocolDataProvider;
    IPoolAerodrome aerodromePool;
    IPythPriceUpdater public pythPriceUpdater;

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

    // Add new state variables to keep track of the previous balances
    uint256 public previousAUSDCBalance;
    uint256 public previousVariableDebtBalance;

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
        address pythPriceUpdaterContract
    ) ERC4626(asset_) ERC20(name_, symbol_) Ownable(initialOwner) {
        // asset_.safeTransferFrom(msg.sender, address(this), _initialDeposit);
        pyth = IPyth(pythContract);
        aavePool = IPoolAave(aavePoolContract);
        aaveProtocolDataProvider = IPoolDataProvider(
            aaveProtocolDataProviderContract
        );
        aerodromePool = IPoolAerodrome(aerodromePoolContract);
        pythPriceUpdater = IPythPriceUpdater(pythPriceUpdaterContract);
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

    function _withdraw(
        address caller,
        address receiver,
        address _owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (caller != _owner) {
            _spendAllowance(_owner, caller, shares);
        }

        // Burn shares from _owner
        _burn(_owner, shares);

        // Withdraw funds
        _withdrawFunds(assets);

        // Transfer assets to receiver
        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);

        emit Withdraw(caller, receiver, _owner, assets, shares);
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

        // Convert the amount of USDC supplied in 18 decimals
        uint256 usdcAmountIn18Decimals = amount * 10 ** 12;
        // Finding total price of the asset supplied in USD
        uint256 usdcAmountIn18DecimalsInUSD = (usdcAmountIn18Decimals *
            usdcPriceInUSD) / 10 ** 18;
        // Fetching LTV of USDC from Aave
        (, uint256 ltv, , , , , , , , ) = aaveProtocolDataProvider
            .getReserveConfigurationData(assetAddress);
        // Calculating the maximum loan amount in USD
        uint256 maxLoanAmountIn18DecimalsInUSD = (usdcAmountIn18DecimalsInUSD *
            ltv) / 10 ** 5;
        // Calculating the maximum amount of cbETH that can be borrowed
        uint256 cbEthAbleToBorrow = (maxLoanAmountIn18DecimalsInUSD *
            10 ** 18) / cbEthPriceInUSD;
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

        // Add accounting for _totalAccountedAssets
        _totalAccountedAssets += amount;
    }

    function _withdrawFunds(uint256 amount) internal {
        // 1. Calculate the proportion of LP tokens to burn
        uint256 totalLPBalance = IERC20(address(aerodromePool)).balanceOf(
            address(this)
        );
        uint256 lpTokensToBurn = (amount * totalLPBalance) /
            _totalAccountedAssets;

        // 2. Transfer LP tokens to this contract
        IERC20(address(aerodromePool)).transfer(address(this), lpTokensToBurn);

        // 3. Burn LP tokens
        (uint256 usdc, uint256 aero) = aerodromePool.burn(address(this));

        // 4. Swap AERO to USDC if necessary
        if (aero > 0) {
            usdc += _swapAEROToUSDC(aero);
        }

        // 5. Repay cbETH debt on Aave if necessary
        uint256 cbEthDebt = IERC20(variableDebtCbETH).balanceOf(address(this));
        if (cbEthDebt > 0) {
            uint256 cbEthToRepay = (amount * cbEthDebt) / _totalAccountedAssets;
            uint256 usdcForCbEth = _swapUSDCToCbETH(cbEthToRepay);
            IERC20(cbETH).approve(address(aavePool), cbEthToRepay);
            aavePool.repay(cbETH, cbEthToRepay, 2, address(this));
            usdc -= usdcForCbEth;
        }

        // 6. Withdraw USDC from Aave if necessary
        uint256 usdcBalance = IERC20(asset()).balanceOf(address(this));
        if (usdcBalance + usdc < amount) {
            uint256 aUSDCBalance = IERC20(aUSDC).balanceOf(address(this));
            uint256 usdcToWithdraw = amount - (usdcBalance + usdc);
            if (usdcToWithdraw > aUSDCBalance) {
                usdcToWithdraw = aUSDCBalance;
            }
            aavePool.withdraw(asset(), usdcToWithdraw, address(this));
            usdc += usdcToWithdraw;
        }

        // 7. Ensure we have enough USDC to cover the withdrawal
        require(usdcBalance + usdc >= amount, "Insufficient USDC balance");

        // 8. Update total accounted assets
        _totalAccountedAssets -= amount;

        // Transfer the withdrawn amount to the user
        IERC20(asset()).transfer(msg.sender, amount);
    }

    function _calculateLPTokensToWithdraw(
        uint256 amount
    ) internal view returns (uint256) {
        uint256 totalLPBalance = IERC20(address(aerodromePool)).balanceOf(
            address(this)
        );
        return (amount * totalLPBalance) / _totalAccountedAssets;
    }

    function _swapUSDCToCbETH(uint256 cbEthAmount) internal returns (uint256) {
        bytes32[] memory priceFeedIds = new bytes32[](2);
        priceFeedIds[0] = cbEthUsdPriceFeedId;
        priceFeedIds[1] = usdcUsdPriceFeedId;
        uint256[] memory prices = getPricePyth(priceFeedIds);
        uint256 cbEthPrice = prices[0];
        uint256 usdcPrice = prices[1];
        uint256 usdcAmount = (cbEthPrice * cbEthAmount * 10 ** 12) / usdcPrice;
        return _swap(asset(), cbETH, 500, 500, usdcAmount);
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
        uint256 borrowedCbETHValueChangeInUSDC = (cbETHPrice *
            borrowedCbETHChange) / (usdcPrice * 10 ** 12);

        int256 aaveNetGain = int256(suppliedUSDCValueChange) -
            int256(borrowedCbETHValueChangeInUSDC);

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

        // Reinvest in Aerodrome Pool
        if (currentUSDCBalance > 0) {
            uint256 aeroAmount = _swapUSDCToAERO(currentUSDCBalance / 2);

            IERC20(AERO).safeTransfer(address(aerodromePool), aeroAmount);
            IERC20(asset()).safeTransfer(
                address(aerodromePool),
                currentUSDCBalance / 2
            );
            aerodromePool.mint(address(this));
        }

        // Skim any excess assets from Aerodrome Pool
        aerodromePool.skim(address(this));

        // Calculate total rewards in USDC
        uint256 finalAeroBalance = IERC20(AERO).balanceOf(address(this));
        uint256 finalUsdcBalance = IERC20(asset()).balanceOf(address(this));
        uint256 totalRewardsInUSDC = (finalUsdcBalance - initialUsdcBalance) +
            ((aeroPriceInUSD * (finalAeroBalance - initialAeroBalance)) /
                (usdcPrice * 10 ** 12));

        // Update total accounted assets
        if (aaveNetGain > 0) {
            _totalAccountedAssets += uint256(aaveNetGain);
        } else {
            _totalAccountedAssets -= uint256(-aaveNetGain);
        }
        _totalAccountedAssets += totalRewardsInUSDC;

        emit HarvestReport(
            totalRewardsInUSDC,
            aaveNetGain,
            claimedAero,
            claimedUsdc
        );
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

        bytes memory callData = abi.encodeWithSelector(
            bytes4(0xb858183f), // selector for exactInput(tuple)
            abi.encode(
                path,
                address(this),
                amountIn,
                0 // amountOutMinimum
            )
        );

        (bool success, bytes memory result) = swapRouter.call(callData);
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

    event HarvestReport(
        uint256 totalRewardsInUSDC,
        int256 aaveNetGain,
        uint256 claimedAero,
        uint256 claimedUsdc
    );
}
