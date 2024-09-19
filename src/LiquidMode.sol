// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract VaultStrategy is
    Initializable,
    ERC4626Upgradeable,
    Ownable2StepUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable
{
    using Math for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");

    // Add strategist address and fee percentage
    address public strategist;
    uint256 public accumulatedStrategistFee;
    uint256 public constant STRATEGIST_FEE_PERCENTAGE = 2000; // 20% with 2 decimal places

    // Add this state variable
    uint256 public accumulatedDeposits;
    uint256 public _totalAccountedAssets;

    event StrategistFeeClaimed(uint256 claimedAmount, uint256 remainingFees);

    // event PositionRebalanced(
    //     uint256 additionalAmountNeeded,
    //     uint256 amountFreedUp,
    //     uint256 lpTokensBurned,
    //     uint256 usdcReceived,
    //     uint256 aeroReceived,
    //     uint256 cbEthRepaid
    // );

    // event HarvestReport(
    //     uint256 totalProfit,
    //     uint256 netProfit,
    //     uint256 strategistFee,
    //     uint256 aerodromeRewards,
    //     int256 aaveNetGain,
    //     uint256 claimedAero,
    //     uint256 claimedUsdc
    // );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        IERC20 asset_,
        uint256 _initialDeposit,
        address initialOwner,
        string memory name_,
        string memory symbol_,
        address _strategist
    ) public initializer {
        __ERC4626_init(asset_);
        __ERC20_init(name_, symbol_);
        __Ownable_init(initialOwner);
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(REBALANCER_ROLE, initialOwner);

        strategist = _strategist;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // New internal function that includes priceUpdate
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        address assetAddress = asset();
        // Transfer the assets from the caller to this contract
        SafeERC20.safeTransferFrom(IERC20(assetAddress), caller, address(this), assets);

        // Mint shares to the receiver
        _mint(receiver, shares);

        // Accumulate deposits instead of investing
        accumulatedDeposits += assets;

        emit Deposit(caller, receiver, assets, shares);
    }

    function _investFunds(uint256 amount, address assetAddress) internal {}

    function _withdrawFunds(uint256 amount) internal nonReentrant {}

    function _investIdleFunds() internal {}

    function harvestReinvestAndReport() external onlyOwner nonReentrant {}

    function claimStrategistFees(uint256 amount) external nonReentrant {}

    function totalAssets() public view override returns (uint256) {
        return _totalAccountedAssets;
    }

    // Function to grant the rebalancer role
    function grantRebalancerRole(address account) external onlyOwner {
        grantRole(REBALANCER_ROLE, account);
    }

    // Function to revoke the rebalancer role
    function revokeRebalancerRole(address account) external onlyOwner {
        revokeRole(REBALANCER_ROLE, account);
    }

    // Function to set the strategist address
    function setStrategist(address _strategist) external onlyOwner {
        strategist = _strategist;
    }

    // Override the deposit function to include the nonReentrant modifier
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

    // Override the mint function to include the nonReentrant modifier
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

    // Override the withdraw function to include the nonReentrant modifier
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

    // Override the redeem function to include the nonReentrant modifier
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

    // Add pause and unpause functions
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Override the internal _withdraw function from ERC4626
     */
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
}
