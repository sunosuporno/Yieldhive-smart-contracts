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

    // Make the original functions private and override them
    // Override the original functions to revert
    function deposit(
        uint256 assets,
        address receiver
    ) public virtual override returns (uint256) {
        revert("Use deposit with priceUpdate instead");
    }

    function mint(
        uint256 shares,
        address receiver
    ) public virtual override returns (uint256) {
        revert("Use mint with priceUpdate instead");
    }

    // New public functions with the priceUpdate parameter
    function depositWithPriceUpdate(
        uint256 assets,
        address receiver,
        bytes[] calldata priceUpdate,
        bytes32[] calldata priceFeedId
    ) public virtual returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }

        uint256 shares = previewDeposit(assets);
        _depositWithPriceUpdate(
            _msgSender(),
            receiver,
            assets,
            shares,
            priceUpdate,
            priceFeedId
        );

        return shares;
    }

    function mintWithPriceUpdate(
        uint256 shares,
        address receiver,
        bytes[] calldata priceUpdate,
        bytes32[] calldata priceFeedId
    ) public virtual returns (uint256) {
        uint256 maxShares = maxMint(receiver);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
        }

        uint256 assets = previewMint(shares);
        _depositWithPriceUpdate(
            _msgSender(),
            receiver,
            assets,
            shares,
            priceUpdate,
            priceFeedId
        );

        return assets;
    }

    // New internal function that includes priceUpdate
    function _depositWithPriceUpdate(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares,
        bytes[] calldata priceUpdate,
        bytes32[] calldata priceFeedId
    ) internal virtual {
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
        _investFunds(assets, assetAddress, priceUpdate, priceFeedId);

        emit Deposit(caller, receiver, assets, shares);
    }

    function _investFunds(
        uint256 amount,
        address assetAddress,
        bytes[] calldata priceUpdate,
        bytes32[] calldata priceFeedId
    ) internal {
        // Get the price of the assets in USD from Pyth Network
        int64 usdcPriceInUSD = getPricePyth(priceUpdate, priceFeedId[0]).price;
        int64 cbEthPriceInUSD = getPricePyth(priceUpdate, priceFeedId[1]).price;
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

    function _swapcbETHToUSDCAndAERO(
        uint256 amountIn
    ) internal returns (uint256 amountOutUSDC, uint256 amountOutAERO) {
        address assetAddress = asset();
        // Approve the swapRouter to spend amountIn of cbETH
        TransferHelper.safeApprove(cbETH, swapRouter, amountIn / 2);

        // Encode the path for the swap
        bytes memory path = abi.encodePacked(
            cbETH,
            uint24(500), // 0.05% fee for cbETH -> ETH
            WETH9,
            uint24(3000), // 0.3% fee for ETH -> AERO
            AERO
        );
        // Encode the parameters for exactInput
        bytes memory data = abi.encodeWithSignature(
            "exactInput((bytes,address,uint256,uint256))",
            abi.encode(path, address(this), amountIn / 2, 0)
        );
        // Perform the low-level call to the swapRouter
        (bool success, bytes memory result) = swapRouter.call(data);
        require(success, "Swap failed");
        // Decode the result to get the amountOut
        amountOutAERO = abi.decode(result, (uint256));

        uint256 remainingcbETH = IERC20(cbETH).balanceOf(address(this));

        bytes memory path2 = abi.encodePacked(
            cbETH,
            uint24(500), // 0.05% fee for cbETH -> ETH
            WETH9,
            uint24(500), // 0.05% fee for ETH -> USDC
            assetAddress
        );

        bytes memory data2 = abi.encodeWithSignature(
            "exactInput((bytes,address,uint256,uint256))",
            abi.encode(path2, address(this), remainingcbETH, 0)
        );

        (bool success2, bytes memory result2) = swapRouter.call(data2);
        require(success2, "Swap failed");
        amountOutUSDC = abi.decode(result2, (uint256));

        return (amountOutUSDC, amountOutAERO);
    }

    function getPricePyth(
        bytes[] calldata priceUpdate,
        bytes32 priceFeedId
    ) public payable returns (PythStructs.Price memory) {
        uint fee = pyth.getUpdateFee(priceUpdate);
        pyth.updatePriceFeeds{value: fee}(priceUpdate);

        PythStructs.Price memory price = pyth.getPrice(priceFeedId);
        return price;
    }
}
