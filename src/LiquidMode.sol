// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
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
import "@cryptoalgebra/integral-core/contracts/interfaces/IAlgebraPool.sol";
import "@cryptoalgebra/integral-core/contracts/libraries/TickMath.sol";

import "@cryptoalgebra/integral-periphery/contracts/libraries/TransferHelper.sol";
import "@cryptoalgebra/integral-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@cryptoalgebra/integral-periphery/contracts/base/LiquidityManagement.sol";

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract VaultStrategy is ERC4626, Ownable, AccessControl, ReentrancyGuard, Pausable, LiquidityManagement {
    using Math for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    IxRenzoDeposit public immutable xRenzoDeposit;
    IRSETHPoolV2 public immutable rSETHPoolV2;

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

    event StrategistFeeClaimed(uint256 claimedAmount, uint256 remainingFees);

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
        address _WNativeToken,
        address _poolDeployer,
        address _EZETH,
        address _WRSETH,
        uint24 _kimFee
    )
        ERC4626(asset_)
        ERC20(name_, symbol_)
        Ownable(initialOwner)
        LiquidityManagement(_factory, _WNativeToken, _poolDeployer)
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
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        address assetAddress = asset();
        SafeERC20.safeTransferFrom(IERC20(assetAddress), caller, address(this), assets);

        _mint(receiver, shares);

        accumulatedDeposits += assets;

        emit Deposit(caller, receiver, assets, shares);
    }

    function _investFunds(uint256 amount, address assetAddress) internal {
        uint256 receivedEzETH = xRenzoDeposit.depositETH{value: amount / 2}(0, block.timestamp);
        rSETHPoolV2.deposit{value: amount / 2}("");

        _createKIMPosition(receivedEzETH, receivedRSETH);
    }

    function _createKIMPosition(uint256 amount0, uint256 amount1) internal {
        IERC20(EZETH).approve(address(nonfungiblePositionManager), amount0);
        IERC20(RSETH).approve(address(nonfungiblePositionManager), amount1);

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: EZETH,
            token1: RSETH,
            tickLower: TickMath.MIN_TICK,
            tickUpper: TickMath.MAX_TICK,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId, uint128 liquidity,,) = nonfungiblePositionManager.mint(params);

        kimTokenId = tokenId;
        kimLiquidity = liquidity;
    }

    function collectKIMFees() internal returns (uint256 amount0, uint256 amount1) {
        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
            tokenId: kimTokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        return nonfungiblePositionManager.collect(params);
    }

    function _withdrawFunds(uint256 amount) internal nonReentrant {}

    function _investIdleFunds() internal {}

    function harvestReinvestAndReport() external onlyOwner nonReentrant {}

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

        _withdrawFunds(assets);

        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function WNativeToken() public view returns (address) {
        return WNativeToken;
    }
}
