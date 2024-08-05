// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPool} from "./interfaces/IPool.sol";
import {IPoolDataProvider} from "./interfaces/IPoolDataProvider.sol";

contract VaultStrategy is ERC4626, Ownable {
    using Math for uint256;
    using SafeERC20 for IERC20;
    IPool aavePool;
    IPoolDataProvider aaveProtocolDataProvider;

    constructor(
        IERC20 asset_,
        uint256 _initialDeposit,
        address initialOwner,
        string memory name_,
        string memory symbol_,
        address aavePoolContract,
        address aaveProtocolDataProviderContract
    )
        // address _cometAddress
        ERC4626(asset_)
        ERC20(name_, symbol_)
        Ownable(initialOwner)
    {
        asset_.safeTransferFrom(msg.sender, address(this), _initialDeposit);
        aavePool = IPool(aavePoolContract);
        aaveProtocolDataProvider = IPoolDataProvider(
            aaveProtocolDataProviderContract
        );
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
        // approve and supply the asset USDC to the Aave pool
        IERC20(assetAddress).approve(address(aavePool), amount);
        aavePool.supply(assetAddress, amount, address(this), 0);
    }
}
