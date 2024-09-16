pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {VaultStrategy} from "../src/Vault_Strategy.sol";
import {PythPriceUpdater} from "../src/PythPriceUpdater.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

contract Vault_StrategyTest is Test {
    VaultStrategy public vaultStrategy;
    PythPriceUpdater public pythPriceUpdater;
    IERC20 public usdc;
    address public user;
    address public owner;

    // Constants from the deployment script
    address constant ASSET = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // USDC
    uint256 constant INITIAL_DEPOSIT = 100;
    string constant NAME = "YieldHive Prime USDC";
    string constant SYMBOL = "ypUSDC";
    address constant PYTH_CONTRACT = 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a;
    address constant AAVE_POOL_CONTRACT = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant AAVE_PROTOCOL_DATA_PROVIDER_CONTRACT = 0x793177a6Cf520C7fE5B2E45660EBB48132184BBC;
    address constant AERODROME_POOL_CONTRACT = 0x6cDcb1C4A4D1C3C6d054b27AC5B77e89eAFb971d;
    address constant AAVE_ORACLE_CONTRACT = 0x2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156;

    function setUp() public {
        // Remove the line: vm.createSelectFork("optimism");

        // Set up accounts
        owner = makeAddr("owner");
        user = makeAddr("user");

        // Deploy PythPriceUpdater
        pythPriceUpdater = new PythPriceUpdater();

        // Deploy VaultStrategy implementation
        VaultStrategy vaultStrategyImplementation = new VaultStrategy();

        // Deploy ProxyAdmin
        ProxyAdmin proxyAdmin = new ProxyAdmin(owner);

        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            VaultStrategy.initialize.selector,
            IERC20(ASSET),
            INITIAL_DEPOSIT,
            owner,
            NAME,
            SYMBOL,
            PYTH_CONTRACT,
            AAVE_POOL_CONTRACT,
            AAVE_PROTOCOL_DATA_PROVIDER_CONTRACT,
            AERODROME_POOL_CONTRACT,
            address(pythPriceUpdater),
            AAVE_ORACLE_CONTRACT,
            owner // strategist
        );

        // Deploy TransparentUpgradeableProxy
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(vaultStrategyImplementation), address(proxyAdmin), initData);

        // Assign the proxy address to vaultStrategy
        vaultStrategy = VaultStrategy(address(proxy));

        // Assign 20 ETH to the Vault_Strategy contract
        vm.deal(address(vaultStrategy), 20 ether);

        // Set up USDC for the user
        usdc = IERC20(ASSET);
        deal(address(usdc), user, 1000 * 10 ** 6); // 1000 USDC (6 decimals)

        // Approve VaultStrategy to spend user's USDC
        vm.prank(user);
        usdc.approve(address(vaultStrategy), type(uint256).max);
    }

    // Add your test functions here
    function testInitialSetup() public {
        assertEq(vaultStrategy.name(), NAME);
        assertEq(vaultStrategy.symbol(), SYMBOL);
        assertEq(address(vaultStrategy.asset()), ASSET);
        assertEq(vaultStrategy.owner(), owner);
        assertEq(address(vaultStrategy.pythPriceUpdater()), address(pythPriceUpdater));
        assertEq(usdc.balanceOf(user), 1000 * 10 ** 6);
        assertEq(usdc.allowance(user, address(vaultStrategy)), type(uint256).max);
        assertEq(address(vaultStrategy).balance, 20 ether);
    }

    // Add more test functions as needed
    function testDeposit() public {
        vm.startPrank(user);
        uint256 initalBalance = usdc.balanceOf(user);
        vaultStrategy.deposit(100_000_000, user);
        uint256 finalBalance = usdc.balanceOf(user);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(vaultStrategy)), 100_000_000);
        assertEq(vaultStrategy.balanceOf(user), 100_000_000);
        assertEq(finalBalance, initalBalance - 100_000_000);
        assertEq(vaultStrategy.accumulatedDeposits(), 100_000_000);
    }

    function testMultipleDeposits() public {
        address user2 = makeAddr("user2");
        address user3 = makeAddr("user3");

        // Give USDC to user2 and user3
        deal(address(usdc), user2, 1000 * 10 ** 6);
        deal(address(usdc), user3, 1000 * 10 ** 6);

        // Approve VaultStrategy for user2 and user3
        vm.prank(user2);
        usdc.approve(address(vaultStrategy), type(uint256).max);
        vm.prank(user3);
        usdc.approve(address(vaultStrategy), type(uint256).max);

        // User deposits
        vm.prank(user);
        vaultStrategy.deposit(50_000_000, user);

        // User2 deposits
        vm.prank(user2);
        vaultStrategy.deposit(75_000_000, user2);

        // User3 deposits
        vm.prank(user3);
        vaultStrategy.deposit(100_000_000, user3);

        // Check individual balances
        assertEq(vaultStrategy.balanceOf(user), 50_000_000);
        assertEq(vaultStrategy.balanceOf(user2), 75_000_000);
        assertEq(vaultStrategy.balanceOf(user3), 100_000_000);

        // Check total accumulated deposits
        assertEq(vaultStrategy.accumulatedDeposits(), 225_000_000);

        // Check USDC balance of the vault
        assertEq(usdc.balanceOf(address(vaultStrategy)), 225_000_000);
    }
}
