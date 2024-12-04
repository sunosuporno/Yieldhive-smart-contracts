// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {VaultStrategy} from "../src/Vault_Strategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IPool} from "../src/interfaces/IPoolAerodrome.sol";
import {IPool as IPoolAave} from "../src/interfaces/IPool.sol";
import {VaultStrategyV2} from "./Mocks/Vault_StrategyV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/src/Upgrades.sol";
import {IUpgradeableProxy} from "openzeppelin-foundry-upgrades/src/internal/interfaces/IUpgradeableProxy.sol";

contract Vault_StrategyTest is Test {
    VaultStrategy public vaultStrategy;
    VaultStrategyV2 public vaultStrategyV2;
    ProxyAdmin public proxyAdmin;
    // TransparentUpgradeableProxy public proxy;
    IERC20 public usdc;
    address public user;
    address public owner;

    // Constants from the deployment script
    address constant ASSET = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // USDC
    uint256 constant INITIAL_DEPOSIT = 100;
    string constant NAME = "YieldHive Prime USDC";
    string constant SYMBOL = "ypUSDC";
    address constant AAVE_POOL_CONTRACT = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant AAVE_PROTOCOL_DATA_PROVIDER_CONTRACT = 0x793177a6Cf520C7fE5B2E45660EBB48132184BBC;
    address constant AERODROME_POOL_CONTRACT = 0x6cDcb1C4A4D1C3C6d054b27AC5B77e89eAFb971d;
    address constant AAVE_ORACLE_CONTRACT = 0x2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156;
    address constant WETH9 = 0x4200000000000000000000000000000000000006;
    address proxy;

    function setUp() public {
        // Remove the line: vm.createSelectFork("optimism");

        // Set up accounts
        owner = makeAddr("owner");
        console.log("Owner address:", owner);
        user = makeAddr("user");

        // Deploy VaultStrategy implementation
        VaultStrategy vaultStrategyImplementation = new VaultStrategy();

        // Prepare initialization data
        bytes memory initData = abi.encodeCall(
            VaultStrategy.initialize,
            (
                IERC20(ASSET),
                INITIAL_DEPOSIT,
                owner, // Make sure this is set as the owner
                NAME,
                SYMBOL,
                AAVE_POOL_CONTRACT,
                AAVE_PROTOCOL_DATA_PROVIDER_CONTRACT,
                AAVE_ORACLE_CONTRACT,
                owner, // strategist
                AERODROME_POOL_CONTRACT
            )
        );

        // Deploy proxy using UnsafeUpgrades
        proxy = UnsafeUpgrades.deployUUPSProxy(address(vaultStrategyImplementation), initData);

        vaultStrategy = VaultStrategy(proxy);

        // Verify ownership
        assertEq(vaultStrategy.owner(), owner, "Owner should be set correctly");

        // Set up USDC for the user
        usdc = IERC20(ASSET);
        deal(address(usdc), user, 10000 * 10 ** 6); // 1000 USDC (6 decimals)

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
        assertEq(usdc.balanceOf(user), 10000 * 10 ** 6);
        assertEq(usdc.allowance(user, address(vaultStrategy)), type(uint256).max);
        assertEq(address(vaultStrategy.aerodromePool()), AERODROME_POOL_CONTRACT);
    }

    // Add more test functions as needed
    function testDepositOnly() public {
        // Record initial states
        uint256 initialUserBalance = usdc.balanceOf(user);
        uint256 initialVaultBalance = usdc.balanceOf(address(vaultStrategy));
        uint256 initialTotalSupply = vaultStrategy.totalSupply();
        uint256 initialTotalAssets = vaultStrategy.totalAssets();

        // Perform deposit
        vm.startPrank(user);
        vaultStrategy.deposit(100_000_000, user);
        vm.stopPrank();

        // Check user-side effects
        assertEq(vaultStrategy.balanceOf(user), 100_000_000, "Incorrect shares for user");
        assertEq(usdc.balanceOf(user), initialUserBalance - 100_000_000, "Incorrect USDC balance after deposit");

        // Check vault-side effects
        assertEq(vaultStrategy.totalSupply(), initialTotalSupply + 100_000_000, "Total supply not increased correctly");
        assertEq(vaultStrategy.totalAssets(), initialTotalAssets + 100_000_000, "Total assets not increased correctly");

        // Check if funds were properly invested
        assertTrue(IERC20(vaultStrategy.aUSDC()).balanceOf(address(vaultStrategy)) > 0, "No aUSDC tokens received");
        assertTrue(
            IERC20(address(vaultStrategy.aerodromePool())).balanceOf(address(vaultStrategy)) > 0,
            "No Aerodrome LP tokens received"
        );

        // Verify exchange rate consistency
        assertEq(
            vaultStrategy.convertToAssets(vaultStrategy.balanceOf(user)),
            100_000_000,
            "Share to asset conversion mismatch"
        );
    }

    function testMultipleDeposits() public {
        address user2 = makeAddr("user2");
        address user3 = makeAddr("user3");

        // Give USDC to user2 and user3
        deal(address(usdc), user2, 1000 * 10 ** 6);
        deal(address(usdc), user3, 1000 * 10 ** 6);

        // Record initial balances
        uint256 initialUser1Balance = usdc.balanceOf(user);
        uint256 initialUser2Balance = usdc.balanceOf(user2);
        uint256 initialUser3Balance = usdc.balanceOf(user3);

        // Approve VaultStrategy for user2 and user3
        vm.prank(user2);
        usdc.approve(address(vaultStrategy), type(uint256).max);
        vm.prank(user3);
        usdc.approve(address(vaultStrategy), type(uint256).max);

        // User deposits
        vm.prank(user);
        vaultStrategy.deposit(50_000_000, user);

        // Check first deposit
        assertEq(vaultStrategy.balanceOf(user), 50_000_000, "Incorrect shares for user1");
        assertEq(usdc.balanceOf(user), initialUser1Balance - 50_000_000, "Incorrect USDC balance after user1 deposit");
        assertEq(vaultStrategy.totalAssets(), 50_000_000, "Incorrect total assets after first deposit");

        // User2 deposits
        vm.prank(user2);
        vaultStrategy.deposit(75_000_000, user2);

        // Check second deposit
        assertEq(vaultStrategy.balanceOf(user2), 75_000_000, "Incorrect shares for user2");
        assertEq(usdc.balanceOf(user2), initialUser2Balance - 75_000_000, "Incorrect USDC balance after user2 deposit");
        assertEq(vaultStrategy.totalAssets(), 125_000_000, "Incorrect total assets after second deposit");

        // User3 deposits
        vm.prank(user3);
        vaultStrategy.deposit(100_000_000, user3);

        // Check third deposit
        assertEq(vaultStrategy.balanceOf(user3), 100_000_000, "Incorrect shares for user3");
        assertEq(usdc.balanceOf(user3), initialUser3Balance - 100_000_000, "Incorrect USDC balance after user3 deposit");
        assertEq(vaultStrategy.totalAssets(), 225_000_000, "Incorrect total assets after third deposit");

        // Check if funds were properly invested in Aave
        assertEq(IERC20(vaultStrategy.aUSDC()).balanceOf(address(vaultStrategy)) > 0, true, "No aUSDC tokens received");

        // Check if Aerodrome LP tokens were received
        assertEq(
            IERC20(address(vaultStrategy.aerodromePool())).balanceOf(address(vaultStrategy)) > 0,
            true,
            "No Aerodrome LP tokens received"
        );

        // After deposits complete
        uint256 aUsdcBalance = IERC20(vaultStrategy.aUSDC()).balanceOf(address(vaultStrategy));
        uint256 lpBalance = IERC20(address(vaultStrategy.aerodromePool())).balanceOf(address(vaultStrategy));

        assertTrue(aUsdcBalance > 0, "No aUSDC balance");
        assertTrue(lpBalance > 0, "No LP tokens");
    }

    function testDepositWhenPaused() public {
        uint256 depositAmount = 100 * 10 ** 6;

        // Setup: Record initial states
        uint256 initialUserBalance = usdc.balanceOf(user);
        uint256 initialVaultBalance = usdc.balanceOf(address(vaultStrategy));
        uint256 initialTotalSupply = vaultStrategy.totalSupply();

        // Verify initial pause state
        assertFalse(vaultStrategy.paused(), "Vault should not be paused initially");

        // Test pause permissions
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        vaultStrategy.pause();

        // Pause the contract as owner
        vm.prank(owner);
        vaultStrategy.pause();
        assertTrue(vaultStrategy.paused(), "Vault should be paused");

        // Attempt deposit while paused
        vm.prank(user);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vaultStrategy.deposit(depositAmount, user);

        // Verify no state changes occurred during failed deposit
        assertEq(vaultStrategy.balanceOf(user), 0, "User should have no shares");
        assertEq(usdc.balanceOf(user), initialUserBalance, "User balance should be unchanged");
        assertEq(vaultStrategy.totalSupply(), initialTotalSupply, "Total supply should be unchanged");
        assertEq(usdc.balanceOf(address(vaultStrategy)), initialVaultBalance, "Vault balance should be unchanged");

        // Test unpause permissions
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        vaultStrategy.unpause();

        // Unpause the contract as owner
        vm.prank(owner);
        vaultStrategy.unpause();
        assertFalse(vaultStrategy.paused(), "Vault should be unpaused");

        // Verify deposit works after unpausing
        vm.prank(user);
        vaultStrategy.deposit(depositAmount, user);

        // Verify final state after successful deposit
        assertEq(vaultStrategy.balanceOf(user), depositAmount, "Incorrect shares for user");
        assertEq(usdc.balanceOf(user), initialUserBalance - depositAmount, "Incorrect user balance after deposit");
        assertEq(
            vaultStrategy.totalSupply(), initialTotalSupply + depositAmount, "Incorrect total supply after deposit"
        );
        assertTrue(IERC20(vaultStrategy.aUSDC()).balanceOf(address(vaultStrategy)) > 0, "No aUSDC tokens received");
    }

    // function testInvestAccumulatedFunds() public {
    //     address user2 = makeAddr("user2");
    //     // Setup: Give users some USDC and approve the vault
    //     deal(address(usdc), user, 1000 * 10 ** 6);
    //     deal(address(usdc), user2, 1000 * 10 ** 6);

    //     vm.startPrank(user);
    //     usdc.approve(address(vaultStrategy), type(uint256).max);
    //     vaultStrategy.deposit(500 * 10 ** 6, user);
    //     vm.stopPrank();

    //     vm.startPrank(user2);
    //     usdc.approve(address(vaultStrategy), type(uint256).max);
    //     vaultStrategy.deposit(300 * 10 ** 6, user2);
    //     vm.stopPrank();

    //     // Verify accumulated deposits
    //     assertEq(vaultStrategy.accumulatedDeposits(), 800 * 10 ** 6);

    //     // Get initial balances
    //     uint256 initialVaultBalance = usdc.balanceOf(address(vaultStrategy));
    //     uint256 initialAUSDCBalance = IERC20(vaultStrategy.aUSDC()).balanceOf(address(vaultStrategy));

    //     // Invest accumulated funds
    //     vm.prank(owner);
    //     vaultStrategy.investAccumulatedFunds();

    //     // Verify accumulated deposits are reset
    //     assertEq(vaultStrategy.accumulatedDeposits(), 0);

    //     // Verify USDC balance of vault has decreased
    //     assertLt(usdc.balanceOf(address(vaultStrategy)), initialVaultBalance);

    //     // Verify aUSDC balance has increased
    //     assertGt(IERC20(vaultStrategy.aUSDC()).balanceOf(address(vaultStrategy)), initialAUSDCBalance);

    //     // Verify total assets haven't changed significantly (allowing for small differences due to rounding)
    //     uint256 totalAssetsAfterInvest = vaultStrategy.totalAssets();
    //     assertApproxEqRel(totalAssetsAfterInvest, 800 * 10 ** 6, 1e16); // 1% tolerance
    // }

    function testDoubleDeposit() public {
        // Initial deposit
        uint256 firstDepositAmount = 50_000_000; // 50 USDC
        vm.startPrank(user);
        vaultStrategy.deposit(firstDepositAmount, user);

        // Record state after first deposit
        uint256 sharesAfterFirst = vaultStrategy.balanceOf(user);
        uint256 assetsAfterFirst = vaultStrategy.totalAssets();
        assertEq(sharesAfterFirst, firstDepositAmount, "Incorrect shares after first deposit");
        assertEq(assetsAfterFirst, firstDepositAmount, "Incorrect assets after first deposit");

        // Second deposit
        uint256 secondDepositAmount = 30_000_000; // 30 USDC
        vaultStrategy.deposit(secondDepositAmount, user);
        vm.stopPrank();

        // Verify final state
        uint256 finalShares = vaultStrategy.balanceOf(user);
        uint256 finalAssets = vaultStrategy.totalAssets();
        assertEq(finalShares, firstDepositAmount + secondDepositAmount, "Incorrect final shares");
        assertEq(finalAssets, firstDepositAmount + secondDepositAmount, "Incorrect final assets");

        // Verify exchange rate consistency
        assertEq(
            vaultStrategy.convertToAssets(finalShares),
            firstDepositAmount + secondDepositAmount,
            "Share to asset conversion mismatch"
        );
    }

    function testDoubleMint() public {
        // Initial mint
        uint256 firstMintShares = 50_000_000; // 50 shares
        vm.startPrank(user);
        uint256 firstAssets = vaultStrategy.mint(firstMintShares, user);

        // Record state after first mint
        uint256 sharesAfterFirst = vaultStrategy.balanceOf(user);
        uint256 assetsAfterFirst = vaultStrategy.totalAssets();
        assertEq(sharesAfterFirst, firstMintShares, "Incorrect shares after first mint");
        assertEq(assetsAfterFirst, firstAssets, "Incorrect assets after first mint");

        // Second mint
        uint256 secondMintShares = 30_000_000; // 30 shares
        uint256 secondAssets = vaultStrategy.mint(secondMintShares, user);
        vm.stopPrank();

        // Verify final state
        uint256 finalShares = vaultStrategy.balanceOf(user);
        uint256 finalAssets = vaultStrategy.totalAssets();
        assertEq(finalShares, firstMintShares + secondMintShares, "Incorrect final shares");
        assertEq(finalAssets, firstAssets + secondAssets, "Incorrect final assets");

        // Verify exchange rate consistency
        assertEq(vaultStrategy.convertToShares(finalAssets), finalShares, "Asset to share conversion mismatch");
    }

    function testFuzzDeposit(uint256 depositAmount) public {
        // Bound the deposit amount between 1 USDC and 100,000 USDC
        // Using a smaller upper bound to avoid large swaps that might fail due to slippage
        depositAmount = bound(depositAmount, 1e6, 50_000e6);

        // Setup: Give user enough USDC for the deposit
        deal(address(usdc), user, depositAmount);

        // Record initial states
        uint256 initialUserBalance = usdc.balanceOf(user);
        uint256 initialVaultShares = vaultStrategy.totalSupply();
        uint256 initialVaultAssets = vaultStrategy.totalAssets();

        // Perform deposit
        vm.startPrank(user);
        usdc.approve(address(vaultStrategy), depositAmount);
        vaultStrategy.deposit(depositAmount, user);
        vm.stopPrank();

        // Verify final states
        assertEq(vaultStrategy.balanceOf(user), depositAmount, "Incorrect shares minted");
        assertEq(usdc.balanceOf(user), initialUserBalance - depositAmount, "Incorrect USDC balance after deposit");
        assertEq(
            vaultStrategy.totalSupply(), initialVaultShares + depositAmount, "Incorrect total supply after deposit"
        );
        assertEq(
            vaultStrategy.totalAssets(), initialVaultAssets + depositAmount, "Incorrect total assets after deposit"
        );

        // Verify exchange rate consistency
        assertEq(
            vaultStrategy.convertToAssets(vaultStrategy.balanceOf(user)),
            depositAmount,
            "Share to asset conversion mismatch"
        );

        // Verify investment - using greater than zero check instead of specific amounts
        assertTrue(IERC20(vaultStrategy.aUSDC()).balanceOf(address(vaultStrategy)) > 0, "No aUSDC tokens received");
        assertTrue(
            IERC20(address(vaultStrategy.aerodromePool())).balanceOf(address(vaultStrategy)) > 0,
            "No Aerodrome LP tokens received"
        );
    }

    function testDepositWithWrongToken() public {
        // Use WETH as the wrong token (any ERC20 on Base other than USDC will do)
        IERC20 wrongToken = IERC20(WETH9);

        // Give some WETH to the user
        deal(address(wrongToken), user, 1000 * 10 ** 18);

        // Try to deposit wrong token
        vm.startPrank(user);
        wrongToken.approve(address(vaultStrategy), type(uint256).max);

        // This should fail because the vault only accepts USDC
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vaultStrategy.deposit(100 * 10 ** 18, user);
        vm.stopPrank();

        // Verify no state changes occurred
        assertEq(vaultStrategy.balanceOf(user), 0, "User should have no shares");
        assertEq(vaultStrategy.totalSupply(), 0, "Total supply should be unchanged");
    }

    function testPartialWithdraw() public {
        // Initial deposit
        uint256 initialUserBalance = usdc.balanceOf(user);
        console.log("initialUserBalance", initialUserBalance);
        uint256 depositAmount = 100_000_000; // 100 USDC
        vm.startPrank(user);
        vaultStrategy.deposit(depositAmount, user);

        // Record state before withdrawal
        uint256 afterDepositUserBalance = usdc.balanceOf(user);
        console.log("afterDepositUserBalance", afterDepositUserBalance);
        uint256 afterDepositVaultShares = vaultStrategy.balanceOf(user);
        uint256 afterDepositVaultAssets = vaultStrategy.totalAssets();
        uint256 afterDepositTotalSupply = vaultStrategy.totalSupply();
        console.log("afterDepositTotalSupply", afterDepositTotalSupply);

        // Withdraw half of the deposit
        uint256 withdrawAmount = depositAmount / 2; // 50 USDC
        console.log("withdrawAmount", withdrawAmount);
        uint256 lpTokensBeforeWithdraw =
            IERC20(address(vaultStrategy.aerodromePool())).balanceOf(address(vaultStrategy));
        console.log("lpTokensBeforeWithdraw", lpTokensBeforeWithdraw);
        vaultStrategy.withdraw(withdrawAmount, user, user);
        vm.stopPrank();

        uint256 afterWithdrawUserBalance = usdc.balanceOf(user);
        uint256 afterWithdrawTotalSupply = vaultStrategy.totalSupply();
        uint256 afterWithdrawTotalAssets = vaultStrategy.totalAssets();
        console.log("afterWithdrawUserBalance", afterWithdrawUserBalance);
        console.log("afterWithdrawTotalSupply", afterWithdrawTotalSupply);
        console.log("afterWithdrawTotalAssets", afterWithdrawTotalAssets);

        // Verify final states
        assertApproxEqRel(
            usdc.balanceOf(user),
            afterDepositUserBalance + withdrawAmount,
            0.01e18,
            "Incorrect USDC balance after withdrawal"
        );
        assertEq(
            vaultStrategy.balanceOf(user), afterDepositVaultShares - withdrawAmount, "Incorrect shares after withdrawal"
        );
        assertEq(
            vaultStrategy.totalAssets(),
            afterDepositVaultAssets - withdrawAmount,
            "Incorrect total assets after withdrawal"
        );
        assertEq(
            afterWithdrawTotalSupply,
            afterDepositTotalSupply - withdrawAmount,
            "Incorrect total supply after withdrawal"
        );

        // Verify remaining investment positions
        assertTrue(IERC20(vaultStrategy.aUSDC()).balanceOf(address(vaultStrategy)) > 0, "No aUSDC tokens remaining");
        assertTrue(
            IERC20(address(vaultStrategy.aerodromePool())).balanceOf(address(vaultStrategy)) > 0,
            "No Aerodrome LP tokens remaining"
        );
    }

    function testFullWithdraw() public {
        // Initial deposit
        uint256 initialUserBalance = usdc.balanceOf(user);
        console.log("initialUserBalance", initialUserBalance);
        uint256 depositAmount = 100_000_000; // 100 USDC
        vm.startPrank(user);
        vaultStrategy.deposit(depositAmount, user);

        // Record state before withdrawal
        uint256 afterDepositUserBalance = usdc.balanceOf(user);
        console.log("afterDepositUserBalance", afterDepositUserBalance);
        uint256 afterDepositVaultShares = vaultStrategy.balanceOf(user);
        uint256 afterDepositVaultAssets = vaultStrategy.totalAssets();
        uint256 afterDepositTotalSupply = vaultStrategy.totalSupply();
        console.log("afterDepositTotalSupply", afterDepositTotalSupply);

        // Full withdrawal
        uint256 lpTokensBeforeWithdraw =
            IERC20(address(vaultStrategy.aerodromePool())).balanceOf(address(vaultStrategy));
        console.log("lpTokensBeforeWithdraw", lpTokensBeforeWithdraw);
        vaultStrategy.withdraw(depositAmount, user, user);
        vm.stopPrank();

        uint256 afterWithdrawUserBalance = usdc.balanceOf(user);
        uint256 afterWithdrawTotalSupply = vaultStrategy.totalSupply();
        console.log("afterWithdrawUserBalance", afterWithdrawUserBalance);
        console.log("afterWithdrawTotalSupply", afterWithdrawTotalSupply);

        // Verify final states
        assertApproxEqRel(
            usdc.balanceOf(user),
            initialUserBalance,
            0.01e18, // 1% tolerance
            "User should have approximately their original balance back"
        );
        assertEq(vaultStrategy.balanceOf(user), 0, "User should have no shares remaining");
        assertEq(vaultStrategy.totalAssets(), 0, "Vault should have no assets remaining");
        assertEq(afterWithdrawTotalSupply, 0, "Total supply should be zero");

        // Verify investment positions are empty
        assertEq(
            IERC20(address(vaultStrategy.aerodromePool())).balanceOf(address(vaultStrategy)),
            0,
            "Aerodrome LP tokens should be zero"
        );

        // Check remaining aUSDC balance
        uint256 remainingAUSDC = IERC20(vaultStrategy.aUSDC()).balanceOf(address(vaultStrategy));
        console.log("Remaining aUSDC balance:", remainingAUSDC);

        // Instead of expecting exact zero, check if it's negligible
        assertLe(
            remainingAUSDC,
            1_000_000, // Allow for dust (1 USDC or less)
            "aUSDC tokens should be effectively zero"
        );

        assertEq(
            IERC20(address(vaultStrategy.aerodromePool())).balanceOf(address(vaultStrategy)),
            0,
            "Aerodrome LP tokens should be zero"
        );
    }

    function testVariousDeposits() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 35e6; // Minimum (35 USDC instead of 1)
        amounts[1] = 25_000e6; // Mid-range
        amounts[2] = 50_000e6; // Maximum for our test environment

        for (uint256 i = 0; i < amounts.length; i++) {
            console.log("\namounts[i]", amounts[i]);
            deal(address(usdc), user, amounts[i]);

            vm.startPrank(user);
            usdc.approve(address(vaultStrategy), amounts[i]);
            vaultStrategy.deposit(amounts[i], user);
            vm.stopPrank();
            uint256 userShareBalAfterDeposit = vaultStrategy.balanceOf(user);
            console.log("userShareBalAfterDeposit", userShareBalAfterDeposit);

            assertEq(vaultStrategy.balanceOf(user), amounts[i], "Deposit amount mismatch");

            // Reset for next iteration
            vm.prank(user);
            vaultStrategy.withdraw(amounts[i], user, user);
            uint256 userShareBal = vaultStrategy.balanceOf(user);
            console.log("userShareBal", userShareBal);
            uint256 balContract = usdc.balanceOf(address(vaultStrategy));
            console.log("balContract", balContract);
            uint256 totalAssets = vaultStrategy.totalAssets();
            console.log("totalAssets", totalAssets);
        }
    }

    function testWithdrawMoreThanDeposited() public {
        // Initial deposit
        uint256 depositAmount = 100_000_000; // 100 USDC

        vm.startPrank(user);
        vaultStrategy.deposit(depositAmount, user);

        // Try to withdraw more than deposited
        uint256 withdrawAmount = depositAmount + 1e6; // 101 USDC

        // Expect the OpenZeppelin error
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector, user, withdrawAmount, depositAmount
            )
        );
        vaultStrategy.withdraw(withdrawAmount, user, user);

        vm.stopPrank();

        // Verify state hasn't changed
        assertEq(vaultStrategy.balanceOf(user), depositAmount, "User shares should remain unchanged");
        assertEq(vaultStrategy.totalSupply(), depositAmount, "Total supply should remain unchanged");
    }

    function testFindLowerLimit() public {
        uint256 startAmount = 100e6; // Start with 100 USDC
        uint256 decrement = 10e6; // Decrease by 10 USDC each time
        uint256 minAmount = 10e6; // Test down to 10 USDC

        for (uint256 amount = startAmount; amount >= minAmount; amount -= decrement) {
            console.log("\nTesting deposit/withdraw of %s USDC", amount / 1e6);

            deal(address(usdc), user, amount);

            vm.startPrank(user);
            usdc.approve(address(vaultStrategy), amount);
            vaultStrategy.deposit(amount, user);

            try vaultStrategy.withdraw(amount, user, user) {
                console.log("Success at %s USDC", amount / 1e6);
            } catch Error(string memory reason) {
                console.log("Failed at %s USDC with reason: %s", amount / 1e6, reason);
                break; // Stop testing at first failure
            }

            vm.stopPrank();

            // Reset for next iteration
            vm.deal(user, 0);
        }
    }

    function testDoubleWithdraw() public {
        // Initial deposit
        uint256 depositAmount = 100_000_000; // 100 USDC

        vm.startPrank(user);
        vaultStrategy.deposit(depositAmount, user);

        // First withdrawal (full amount)
        vaultStrategy.withdraw(depositAmount, user, user);

        // Verify state after full withdrawal
        assertEq(vaultStrategy.balanceOf(user), 0, "User should have no shares after full withdrawal");
        assertEq(vaultStrategy.totalSupply(), 0, "Total supply should be zero after full withdrawal");

        // Try to withdraw again
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector,
                user,
                depositAmount, // Trying to withdraw the same amount again
                0 // But max withdrawable is 0 since user has no shares
            )
        );
        vaultStrategy.withdraw(depositAmount, user, user);

        vm.stopPrank();

        // Verify state hasn't changed after failed withdrawal
        assertEq(vaultStrategy.balanceOf(user), 0, "User shares should still be zero");
        assertEq(vaultStrategy.totalSupply(), 0, "Total supply should still be zero");
    }

    function testMultiplePartialWithdrawals() public {
        // Initial deposit
        uint256 depositAmount = 2500e6;
        uint256[] memory withdrawAmounts = new uint256[](3);
        withdrawAmounts[0] = 100e6; // 100 USDC
        withdrawAmounts[1] = 400e6; // 400 USDC
        withdrawAmounts[2] = 530e6; // 530 USDC

        // Record initial state
        uint256 initialUserBalance = usdc.balanceOf(user);
        console.log("initialUserBalance", initialUserBalance);

        vm.startPrank(user);
        vaultStrategy.deposit(depositAmount, user);

        // Log initial LP token balance after deposit
        console.log(
            "\nInitial LP token balance after deposit:",
            IERC20(address(vaultStrategy.aerodromePool())).balanceOf(address(vaultStrategy))
        );

        // Record post-deposit state
        uint256 remainingShares = depositAmount;
        uint256 totalWithdrawn = 0;

        // Perform multiple partial withdrawals
        for (uint256 i = 0; i < withdrawAmounts.length; i++) {
            console.log("\nWithdrawal %s: %s USDC", i + 1, withdrawAmounts[i] / 1e6);

            // Log LP token balance before withdrawal
            console.log(
                "LP token balance before withdrawal:",
                IERC20(address(vaultStrategy.aerodromePool())).balanceOf(address(vaultStrategy))
            );

            uint256 preWithdrawBalance = usdc.balanceOf(user);
            uint256 preWithdrawShares = vaultStrategy.balanceOf(user);
            uint256 preWithdrawTotalSupply = vaultStrategy.totalSupply();
            uint256 preWithdrawTotalAssets = vaultStrategy.totalAssets();

            // Perform withdrawal
            vaultStrategy.withdraw(withdrawAmounts[i], user, user);
            totalWithdrawn += withdrawAmounts[i];
            remainingShares -= withdrawAmounts[i];

            // Log LP token balance after withdrawal
            console.log(
                "LP token balance after withdrawal:",
                IERC20(address(vaultStrategy.aerodromePool())).balanceOf(address(vaultStrategy))
            );

            // Verify user's USDC balance increased by withdrawal amount
            assertApproxEqRel(
                usdc.balanceOf(user),
                preWithdrawBalance + withdrawAmounts[i],
                0.01e18,
                "Incorrect USDC balance after withdrawal"
            );

            // Verify user's share balance decreased by withdrawal amount
            assertEq(
                vaultStrategy.balanceOf(user),
                preWithdrawShares - withdrawAmounts[i],
                "Incorrect share balance after withdrawal"
            );

            // Verify total supply decreased by withdrawal amount
            assertEq(
                vaultStrategy.totalSupply(),
                preWithdrawTotalSupply - withdrawAmounts[i],
                "Incorrect total supply after withdrawal"
            );

            // Verify total assets decreased by withdrawal amount
            assertEq(
                vaultStrategy.totalAssets(),
                preWithdrawTotalAssets - withdrawAmounts[i],
                "Incorrect total assets after withdrawal"
            );

            // Verify remaining shares matches expected
            assertEq(vaultStrategy.balanceOf(user), remainingShares, "Incorrect remaining shares");

            console.log("Remaining shares: %s", remainingShares / 1e6);
            console.log("Total withdrawn so far: %s USDC", totalWithdrawn / 1e6);
        }

        vm.stopPrank();

        // Final state verification
        console.log("\nFinal State Verification:");
        console.log("User USDC balance:", usdc.balanceOf(user) / 1e6, "USDC");
        console.log("Expected balance:", (initialUserBalance - depositAmount + totalWithdrawn) / 1e6, "USDC");
        console.log(
            "LP tokens balance:", IERC20(address(vaultStrategy.aerodromePool())).balanceOf(address(vaultStrategy))
        );

        assertEq(
            usdc.balanceOf(user), initialUserBalance - depositAmount + totalWithdrawn, "Final USDC balance incorrect"
        );

        console.log("User shares:", vaultStrategy.balanceOf(user) / 1e6, "shares");
        console.log("Expected shares:", (depositAmount - totalWithdrawn) / 1e6, "shares");

        assertEq(vaultStrategy.balanceOf(user), depositAmount - totalWithdrawn, "Final shares balance incorrect");

        // Verify we can still withdraw remaining balance
        uint256 remainingBalance = depositAmount - totalWithdrawn;
        console.log("\nFinal Withdrawal:");
        console.log("Remaining balance to withdraw:", remainingBalance / 1e6, "USDC");
        console.log(
            "LP tokens before final withdrawal:",
            IERC20(address(vaultStrategy.aerodromePool())).balanceOf(address(vaultStrategy))
        );

        vm.startPrank(user);
        vaultStrategy.withdraw(remainingBalance, user, user);
        vm.stopPrank();

        // Verify final state after complete withdrawal
        console.log("\nPost-Final Withdrawal State:");
        console.log("Final user USDC balance:", usdc.balanceOf(user) / 1e6, "USDC");
        console.log("Initial user USDC balance:", initialUserBalance / 1e6, "USDC");
        console.log("Final shares balance:", vaultStrategy.balanceOf(user));
        console.log(
            "Final LP tokens balance:", IERC20(address(vaultStrategy.aerodromePool())).balanceOf(address(vaultStrategy))
        );

        assertApproxEqRel(
            usdc.balanceOf(user),
            initialUserBalance,
            0.01e18, // 1% tolerance
            "Should have received back approximately initial balance"
        );
        assertEq(vaultStrategy.balanceOf(user), 0, "Should have no shares remaining");
    }

    function testUnauthorizedWithdraw() public {
        // Setup: User1 deposits funds
        uint256 depositAmount = 100_000_000; // 100 USDC
        vm.prank(user);
        vaultStrategy.deposit(depositAmount, user);

        // Create a random user who has no deposits or approvals
        address randomUser = makeAddr("randomUser");

        // Attempt unauthorized withdrawal
        vm.startPrank(randomUser);

        // Should revert with ERC20InsufficientAllowance error
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, randomUser, 0, depositAmount)
        );
        vaultStrategy.withdraw(depositAmount, randomUser, user);

        vm.stopPrank();

        // Verify state remains unchanged
        assertEq(vaultStrategy.balanceOf(user), depositAmount, "User balance should remain unchanged");
        assertEq(vaultStrategy.balanceOf(randomUser), 0, "Random user should have no shares");
    }

    function testWithdrawOnBehalf() public {
        // Setup: User1 deposits funds
        uint256 depositAmount = 100_000_000; // 100 USDC
        vm.prank(user);
        vaultStrategy.deposit(depositAmount, user);

        // Create a second user who will withdraw on behalf
        address authorizedUser = makeAddr("authorizedUser");

        // Initial state checks
        assertEq(vaultStrategy.balanceOf(user), depositAmount, "Initial user balance incorrect");
        assertEq(vaultStrategy.balanceOf(authorizedUser), 0, "Authorized user should have no initial balance");

        // User approves authorizedUser to spend their shares
        vm.prank(user);
        vaultStrategy.approve(authorizedUser, depositAmount);

        // AuthorizedUser withdraws on behalf of the original user
        vm.prank(authorizedUser);
        vaultStrategy.withdraw(
            depositAmount, // amount to withdraw
            authorizedUser, // recipient of the assets
            user // owner of the shares
        );

        // Verify final state
        assertEq(vaultStrategy.balanceOf(user), 0, "User should have no remaining shares");
        assertApproxEqRel(
            usdc.balanceOf(authorizedUser),
            depositAmount,
            0.01e18, // 1% tolerance
            "Authorized user should have received the assets"
        );
        assertEq(vaultStrategy.allowance(user, authorizedUser), 0, "Allowance should be spent");
    }

    function testWithdrawExceedingAllowance() public {
        // Setup: User1 deposits funds
        uint256 depositAmount = 1_000_000_000; // 1000 USDC
        vm.prank(user);
        vaultStrategy.deposit(depositAmount, user);

        // Create a second user who will be partially authorized
        address authorizedUser = makeAddr("authorizedUser");

        // User approves authorizedUser to spend only part of their shares
        uint256 approvedAmount = 500_000_000; // 500 USDC
        uint256 attemptedWithdrawal = 650_000_000; // 650 USDC

        vm.prank(user);
        vaultStrategy.approve(authorizedUser, approvedAmount);

        // AuthorizedUser attempts to withdraw more than approved
        vm.startPrank(authorizedUser);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, authorizedUser, approvedAmount, attemptedWithdrawal
            )
        );
        vaultStrategy.withdraw(
            attemptedWithdrawal, // trying to withdraw more than approved
            authorizedUser, // recipient of the assets
            user // owner of the shares
        );

        vm.stopPrank();

        // Verify state remains unchanged
        assertEq(vaultStrategy.balanceOf(user), depositAmount, "User balance should remain unchanged");
        assertEq(vaultStrategy.allowance(user, authorizedUser), approvedAmount, "Allowance should remain unchanged");
        assertEq(usdc.balanceOf(authorizedUser), 0, "Authorized user should not have received any assets");
    }

    function testWithdrawWhenPaused() public {
        // Setup: Initial deposit
        uint256 depositAmount = 100 * 10 ** 6;
        vm.prank(user);
        vaultStrategy.deposit(depositAmount, user);

        // Record initial states
        uint256 initialUserBalance = usdc.balanceOf(user);
        uint256 initialVaultBalance = usdc.balanceOf(address(vaultStrategy));
        uint256 initialTotalSupply = vaultStrategy.totalSupply();
        uint256 initialUserShares = vaultStrategy.balanceOf(user);

        // Verify initial pause state
        assertFalse(vaultStrategy.paused(), "Vault should not be paused initially");

        // Test pause permissions
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        vaultStrategy.pause();

        // Pause the contract as owner
        vm.prank(owner);
        vaultStrategy.pause();
        assertTrue(vaultStrategy.paused(), "Vault should be paused");

        // Attempt withdrawal while paused
        vm.prank(user);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vaultStrategy.withdraw(depositAmount, user, user);

        // Verify no state changes occurred during failed withdrawal
        assertEq(vaultStrategy.balanceOf(user), initialUserShares, "User shares should be unchanged");
        assertEq(usdc.balanceOf(user), initialUserBalance, "User balance should be unchanged");
        assertEq(vaultStrategy.totalSupply(), initialTotalSupply, "Total supply should be unchanged");
        assertEq(usdc.balanceOf(address(vaultStrategy)), initialVaultBalance, "Vault balance should be unchanged");

        // Test unpause permissions
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        vaultStrategy.unpause();

        // Unpause the contract as owner
        vm.prank(owner);
        vaultStrategy.unpause();
        assertFalse(vaultStrategy.paused(), "Vault should be unpaused");

        // Verify withdrawal works after unpausing
        vm.prank(user);
        vaultStrategy.withdraw(depositAmount, user, user);

        // Verify final state after successful withdrawal
        assertEq(vaultStrategy.balanceOf(user), 0, "User should have no remaining shares");
        assertApproxEqRel(
            usdc.balanceOf(user),
            initialUserBalance + depositAmount,
            0.01e18, // 1% tolerance
            "Incorrect user balance after withdrawal"
        );
        assertEq(
            vaultStrategy.totalSupply(), initialTotalSupply - depositAmount, "Incorrect total supply after withdrawal"
        );
    }

    function testZeroWithdraw() public {
        // Setup: Initial deposit to have some funds in the vault
        uint256 depositAmount = 100_000_000; // 100 USDC
        vm.prank(user);
        vaultStrategy.deposit(depositAmount, user);

        // Record initial states
        uint256 initialUserBalance = usdc.balanceOf(user);
        uint256 initialUserShares = vaultStrategy.balanceOf(user);
        uint256 initialTotalSupply = vaultStrategy.totalSupply();

        // Attempt to withdraw zero amount
        vm.prank(user);
        vm.expectRevert();
        vaultStrategy.withdraw(0, user, user);

        // Verify no state changes
        assertEq(vaultStrategy.balanceOf(user), initialUserShares, "User shares should remain unchanged");
        assertEq(usdc.balanceOf(user), initialUserBalance, "User USDC balance should remain unchanged");
        assertEq(vaultStrategy.totalSupply(), initialTotalSupply, "Total supply should remain unchanged");
    }

    function testFuzzWithdraw(uint256 depositAmount, uint256 withdrawAmount) public {
        // Bound deposit amount between 35 USDC and 50K USDC
        depositAmount = bound(depositAmount, 35e6, 50_000e6);
        // Bound withdraw to be no more than deposit
        withdrawAmount = bound(withdrawAmount, 5e6, depositAmount);

        // Give user some USDC
        deal(address(usdc), user, depositAmount);

        uint256 preDepositBalance = usdc.balanceOf(user);
        console.log("preDepositBalance", preDepositBalance);
        // Initial deposit
        vm.startPrank(user);
        vaultStrategy.deposit(depositAmount, user);

        // Record state before withdrawal
        uint256 preWithdrawBalance = usdc.balanceOf(user);
        console.log("Balance before withdrawal", preWithdrawBalance);
        uint256 preWithdrawShares = vaultStrategy.balanceOf(user);
        console.log("Shares before withdrawal", preWithdrawShares);

        // Perform withdrawal
        if (withdrawAmount == 0) {
            vm.expectRevert();
        }
        vaultStrategy.withdraw(withdrawAmount, user, user);

        // Verify state after withdrawal
        if (withdrawAmount > 0) {
            assertApproxEqRel(
                usdc.balanceOf(user),
                preWithdrawBalance + withdrawAmount,
                0.01e18, // 1% tolerance
                "Incorrect USDC balance after withdrawal"
            );
            assertEq(
                vaultStrategy.balanceOf(user),
                preWithdrawShares - withdrawAmount,
                "Incorrect share balance after withdrawal"
            );
        }

        vm.stopPrank();
    }

    function testHarvestReinvestAndReports() public {
        // Initial setup - deposit 10,000 USDC
        uint256 depositAmount = 10_000e6; // 10,000 USDC
        deal(address(usdc), user, depositAmount);

        vm.startPrank(user);
        usdc.approve(address(vaultStrategy), depositAmount);
        vaultStrategy.deposit(depositAmount, user);
        vm.stopPrank();

        // Get actual initial balances after deposit
        uint256 initialAUSDCBalance = IERC20(vaultStrategy.aUSDC()).balanceOf(address(vaultStrategy));
        uint256 initialDebtBalance = IERC20(vaultStrategy.variableDebtCbETH()).balanceOf(address(vaultStrategy));

        console.log("Initial aUSDC Balance:", initialAUSDCBalance);
        console.log("Initial Debt Balance:", initialDebtBalance);

        // Fast forward time to accumulate rewards (7 days)
        vm.warp(block.timestamp + 30 days);

        // Mock aUSDC balance increase (15% APY)
        uint256 increaseInSupply = (initialAUSDCBalance * 15) / (12 * 100); // Monthly rate for simplicity => 125
        uint256 newAUSDCBalance = initialAUSDCBalance + increaseInSupply;
        console.log("aUSDC interest earned:", newAUSDCBalance - initialAUSDCBalance);
        vm.mockCall(
            vaultStrategy.aUSDC(),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(vaultStrategy)),
            abi.encode(newAUSDCBalance)
        );

        // Mock variable debt balance (2.5% APY for cbETH borrow)
        uint256 increaseInDebt = (initialDebtBalance * 25) / (12 * 1000); // $13.89
        uint256 newDebtBalance = initialDebtBalance + increaseInDebt;
        console.log("cbETH debt increase:", newDebtBalance - initialDebtBalance);
        vm.mockCall(
            vaultStrategy.variableDebtCbETH(),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(vaultStrategy)),
            abi.encode(newDebtBalance)
        );

        // Get real prices from Chainlink
        address[] memory dataFeeds = new address[](3);
        dataFeeds[0] = vaultStrategy.cbEthUsdDataFeedAddress();
        dataFeeds[1] = vaultStrategy.usdcUsdDataFeedAddress();
        dataFeeds[2] = vaultStrategy.aeroUsdDataFeedAddress();

        uint256[] memory prices = vaultStrategy.getChainlinkDataFeedLatestAnswer(dataFeeds);

        // Calculate rewards
        uint256 monthlyRewardValue = (depositAmount * 45) / (12 * 100); // 375
        uint256 usdcRewards = monthlyRewardValue / 2; // Half in USDC

        // Convert USDC rewards to AERO tokens
        // monthlyRewardValue/2 (6 decimals) * USDC price (8 decimals) * 1e18 / AERO price (8 decimals)
        uint256 aeroRewards = ((monthlyRewardValue / 2) * prices[1] * 1e18) / (prices[2] * 1e6);
        console.log("Monthly Aerodrome rewards in USDC:", usdcRewards);
        console.log("Monthly Aerodrome rewards in AERO tokens:", aeroRewards);

        // Setup mock for claimFees
        vm.mockCall(
            address(vaultStrategy.aerodromePool()),
            abi.encodeWithSelector(IPool.claimFees.selector),
            abi.encode(usdcRewards, aeroRewards)
        );

        // Mock AERO balance after claiming
        deal(address(vaultStrategy.AERO()), address(vaultStrategy), aeroRewards);
        // Mock additional USDC balance from fees
        deal(address(usdc), address(vaultStrategy), usdcRewards);

        // Record state before harvest
        uint256 totalAssetsBefore = vaultStrategy.totalAssets();
        console.log("Total assets before harvest:", totalAssetsBefore);

        // Call harvest as owner
        vm.prank(owner);
        vaultStrategy.harvestReinvestAndReport();

        uint256 totalAssetsAfter = vaultStrategy.totalAssets();
        console.log("Total assets after harvest:", totalAssetsAfter);
        console.log("Asset increase:", totalAssetsAfter - totalAssetsBefore);

        // Verify total assets increased
        assertGt(totalAssetsAfter, totalAssetsBefore, "Total assets should increase after harvest");

        // Verify strategist fee accumulation
        assertGt(vaultStrategy.accumulatedStrategistFee(), 0, "Should have accumulated strategist fee");
    }

    function testHarvestReinvestAndReportWithLoss() public {
        // Initial setup - deposit 10,000 USDC
        uint256 depositAmount = 10_000e6; // 10,000 USDC
        deal(address(usdc), user, depositAmount);

        vm.startPrank(user);
        usdc.approve(address(vaultStrategy), depositAmount);
        vaultStrategy.deposit(depositAmount, user);
        vm.stopPrank();

        // Get actual initial balances after deposit
        uint256 initialAUSDCBalance = IERC20(vaultStrategy.aUSDC()).balanceOf(address(vaultStrategy));
        uint256 initialDebtBalance = IERC20(vaultStrategy.variableDebtCbETH()).balanceOf(address(vaultStrategy));

        console.log("Initial aUSDC Balance:", initialAUSDCBalance);
        console.log("Initial Debt Balance:", initialDebtBalance);

        // Fast forward time to accumulate rewards (30 days)
        vm.warp(block.timestamp + 30 days);

        // Mock aUSDC balance increase (5% APY - lower than normal)
        uint256 increaseInSupply = (initialAUSDCBalance * 5) / (12 * 100); // Monthly rate => ~42
        uint256 newAUSDCBalance = initialAUSDCBalance + increaseInSupply;
        console.log("aUSDC interest earned:", newAUSDCBalance - initialAUSDCBalance);
        vm.mockCall(
            vaultStrategy.aUSDC(),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(vaultStrategy)),
            abi.encode(newAUSDCBalance)
        );

        // Mock variable debt balance (8% APY for cbETH borrow - higher than normal)
        uint256 increaseInDebt = (initialDebtBalance * 60) / (12 * 100); // ~$44.44
        uint256 newDebtBalance = initialDebtBalance + increaseInDebt;
        console.log("cbETH debt increase:", newDebtBalance - initialDebtBalance);
        vm.mockCall(
            vaultStrategy.variableDebtCbETH(),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(vaultStrategy)),
            abi.encode(newDebtBalance)
        );

        // Get real prices from Chainlink
        address[] memory dataFeeds = new address[](3);
        dataFeeds[0] = vaultStrategy.cbEthUsdDataFeedAddress();
        dataFeeds[1] = vaultStrategy.usdcUsdDataFeedAddress();
        dataFeeds[2] = vaultStrategy.aeroUsdDataFeedAddress();

        uint256[] memory prices = vaultStrategy.getChainlinkDataFeedLatestAnswer(dataFeeds);

        // Calculate reduced rewards (15% of normal)
        uint256 monthlyRewardValue = (depositAmount * 45) / (12 * 100); // Normal monthly reward
        monthlyRewardValue = monthlyRewardValue * 15 / 100; // Take only 15% of normal rewards
        uint256 usdcRewards = monthlyRewardValue / 2; // Half in USDC

        // Convert USDC rewards to AERO tokens
        uint256 aeroRewards = ((monthlyRewardValue / 2) * prices[1] * 1e18) / (prices[2] * 1e6);
        console.log("Monthly Aerodrome rewards in USDC:", usdcRewards);
        console.log("Monthly Aerodrome rewards in AERO tokens:", aeroRewards);

        // Setup mock for claimFees with reduced rewards
        vm.mockCall(
            address(vaultStrategy.aerodromePool()),
            abi.encodeWithSelector(IPool.claimFees.selector),
            abi.encode(usdcRewards, aeroRewards)
        );

        // Mock AERO balance after claiming
        deal(address(vaultStrategy.AERO()), address(vaultStrategy), aeroRewards);
        // Mock additional USDC balance from fees
        deal(address(usdc), address(vaultStrategy), usdcRewards);

        // Record state before harvest
        uint256 totalAssetsBefore = vaultStrategy.totalAssets();
        console.log("Total assets before harvest:", totalAssetsBefore);

        // Call harvest as owner
        vm.prank(owner);
        vaultStrategy.harvestReinvestAndReport();

        uint256 totalAssetsAfter = vaultStrategy.totalAssets();
        console.log("Total assets after harvest:", totalAssetsAfter);
        console.log("Asset change:", int256(totalAssetsAfter) - int256(totalAssetsBefore));

        // Verify total assets decreased
        assertLt(totalAssetsAfter, totalAssetsBefore, "Total assets should decrease after harvest");

        // Verify no strategist fee was accumulated (since there was a loss)
        assertEq(vaultStrategy.accumulatedStrategistFee(), 0, "Should not have accumulated strategist fee");
    }

    function testConsecutiveHarvestsWithAlternatingRewards() public {
        // Initial setup - deposit 10,000 USDC
        uint256 depositAmount = 10_000e6; // 10,000 USDC
        deal(address(usdc), user, depositAmount);

        vm.startPrank(user);
        usdc.approve(address(vaultStrategy), depositAmount);
        vaultStrategy.deposit(depositAmount, user);
        vm.stopPrank();

        // Get actual initial balances after deposit
        uint256 initialAUSDCBalance = IERC20(vaultStrategy.aUSDC()).balanceOf(address(vaultStrategy));
        uint256 initialDebtBalance = IERC20(vaultStrategy.variableDebtCbETH()).balanceOf(address(vaultStrategy));

        console.log("\n=== Initial State ===");
        console.log("Initial aUSDC Balance:", initialAUSDCBalance);
        console.log("Initial Debt Balance:", initialDebtBalance);

        // First Harvest (with zero USDC rewards) =====================
        console.log("\n=== First Harvest (Zero USDC Rewards) ===");

        // Fast forward 15 days
        vm.warp(block.timestamp + 15 days);

        // Mock aUSDC balance increase (15% APY)
        uint256 increaseInSupply1 = (initialAUSDCBalance * 15) / (24 * 100); // Half-monthly rate
        uint256 newAUSDCBalance1 = initialAUSDCBalance + increaseInSupply1;
        console.log("aUSDC interest earned (1st):", newAUSDCBalance1 - initialAUSDCBalance);
        vm.mockCall(
            vaultStrategy.aUSDC(),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(vaultStrategy)),
            abi.encode(newAUSDCBalance1)
        );

        // Mock variable debt balance (2.5% APY for cbETH borrow)
        uint256 increaseInDebt1 = (initialDebtBalance * 25) / (24 * 1000); // Half-monthly rate
        uint256 newDebtBalance1 = initialDebtBalance + increaseInDebt1;
        console.log("cbETH debt increase (1st):", newDebtBalance1 - initialDebtBalance);
        vm.mockCall(
            vaultStrategy.variableDebtCbETH(),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(vaultStrategy)),
            abi.encode(newDebtBalance1)
        );

        // Get prices from Chainlink
        address[] memory dataFeeds = new address[](3);
        dataFeeds[0] = vaultStrategy.cbEthUsdDataFeedAddress();
        dataFeeds[1] = vaultStrategy.usdcUsdDataFeedAddress();
        dataFeeds[2] = vaultStrategy.aeroUsdDataFeedAddress();
        uint256[] memory prices = vaultStrategy.getChainlinkDataFeedLatestAnswer(dataFeeds);

        // Calculate rewards (only AERO, no USDC)
        uint256 monthlyRewardValue1 = (depositAmount * 45) / (24 * 100); // Half-month reward
        uint256 aeroRewards1 = ((monthlyRewardValue1) * prices[1] * 1e18) / (prices[2] * 1e6);
        console.log("First harvest AERO rewards:", aeroRewards1);
        console.log("First harvest USDC rewards: 0");

        // Setup mock for claimFees (zero USDC rewards)
        vm.mockCall(
            address(vaultStrategy.aerodromePool()),
            abi.encodeWithSelector(IPool.claimFees.selector),
            abi.encode(0, aeroRewards1)
        );

        // Mock AERO balance
        deal(address(vaultStrategy.AERO()), address(vaultStrategy), aeroRewards1);

        // Record state and perform first harvest
        uint256 totalAssetsBeforeFirst = vaultStrategy.totalAssets();
        console.log("Total assets before first harvest:", totalAssetsBeforeFirst);

        vm.prank(owner);
        vaultStrategy.harvestReinvestAndReport();

        uint256 totalAssetsAfterFirst = vaultStrategy.totalAssets();
        console.log("Total assets after first harvest:", totalAssetsAfterFirst);
        console.log("Asset change (first):", int256(totalAssetsAfterFirst) - int256(totalAssetsBeforeFirst));

        // Second Harvest (with zero AERO rewards) =====================
        console.log("\n=== Second Harvest (Zero AERO Rewards) ===");

        // Fast forward another 15 days
        vm.warp(block.timestamp + 15 days);

        // Mock aUSDC balance increase for second period
        uint256 increaseInSupply2 = (newAUSDCBalance1 * 15) / (24 * 100);
        uint256 newAUSDCBalance2 = newAUSDCBalance1 + increaseInSupply2;
        console.log("aUSDC interest earned (2nd):", newAUSDCBalance2 - newAUSDCBalance1);
        vm.mockCall(
            vaultStrategy.aUSDC(),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(vaultStrategy)),
            abi.encode(newAUSDCBalance2)
        );

        // Mock variable debt balance increase for second period
        uint256 increaseInDebt2 = (newDebtBalance1 * 25) / (24 * 1000);
        uint256 newDebtBalance2 = newDebtBalance1 + increaseInDebt2;
        console.log("cbETH debt increase (2nd):", newDebtBalance2 - newDebtBalance1);
        vm.mockCall(
            vaultStrategy.variableDebtCbETH(),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(vaultStrategy)),
            abi.encode(newDebtBalance2)
        );

        // Calculate rewards (only USDC, no AERO)
        uint256 monthlyRewardValue2 = (depositAmount * 45) / (24 * 100);
        uint256 usdcRewards2 = monthlyRewardValue2;
        console.log("Second harvest AERO rewards: 0");
        console.log("Second harvest USDC rewards:", usdcRewards2);

        // Setup mock for claimFees (zero AERO rewards)
        vm.mockCall(
            address(vaultStrategy.aerodromePool()),
            abi.encodeWithSelector(IPool.claimFees.selector),
            abi.encode(usdcRewards2, 0)
        );

        // Mock USDC balance
        deal(address(usdc), address(vaultStrategy), usdcRewards2);

        // Record state and perform second harvest
        uint256 totalAssetsBeforeSecond = vaultStrategy.totalAssets();
        console.log("Total assets before second harvest:", totalAssetsBeforeSecond);

        vm.prank(owner);
        vaultStrategy.harvestReinvestAndReport();

        uint256 totalAssetsAfterSecond = vaultStrategy.totalAssets();
        console.log("Total assets after second harvest:", totalAssetsAfterSecond);
        console.log("Asset change (second):", int256(totalAssetsAfterSecond) - int256(totalAssetsBeforeSecond));

        // Final assertions
        assertGt(totalAssetsAfterFirst, totalAssetsBeforeFirst, "First harvest should increase total assets");
        assertGt(totalAssetsAfterSecond, totalAssetsBeforeSecond, "Second harvest should increase total assets");
        assertGt(vaultStrategy.accumulatedStrategistFee(), 0, "Should have accumulated strategist fees");

        // Compare the two harvests
        uint256 firstHarvestGain = totalAssetsAfterFirst - totalAssetsBeforeFirst;
        uint256 secondHarvestGain = totalAssetsAfterSecond - totalAssetsBeforeSecond;
        console.log("\n=== Harvest Comparison ===");
        console.log("First harvest gain:", firstHarvestGain);
        console.log("Second harvest gain:", secondHarvestGain);
    }

    function testFullFlowDepositHarvestWithdraw() public {
        // Initial setup - deposit 10,000 USDC
        uint256 depositAmount = 10_000e6; // 10,000 USDC
        deal(address(usdc), user, depositAmount);

        console.log("\n=== Initial Deposit ===");
        console.log("User USDC balance before deposit:", usdc.balanceOf(user));

        vm.startPrank(user);
        usdc.approve(address(vaultStrategy), depositAmount);
        uint256 sharesReceived = vaultStrategy.deposit(depositAmount, user);
        vm.stopPrank();

        console.log("Shares received:", sharesReceived);
        console.log("User USDC balance after deposit:", usdc.balanceOf(user));
        console.log("Vault total assets:", vaultStrategy.totalAssets());

        // Get initial balances after deposit
        uint256 initialAUSDCBalance = IERC20(vaultStrategy.aUSDC()).balanceOf(address(vaultStrategy));
        uint256 initialDebtBalance = IERC20(vaultStrategy.variableDebtCbETH()).balanceOf(address(vaultStrategy));
        uint256 initialLPBalance = IERC20(address(vaultStrategy.aerodromePool())).balanceOf(address(vaultStrategy));

        console.log("\n=== Initial Position ===");
        console.log("Initial aUSDC Balance:", initialAUSDCBalance);
        console.log("Initial Debt Balance:", initialDebtBalance);
        console.log("Initial LP Balance:", initialLPBalance);

        // Fast forward time to accumulate rewards (30 days)
        vm.warp(block.timestamp + 30 days);

        // Mock aUSDC balance increase (15% APY)
        uint256 increaseInSupply = (initialAUSDCBalance * 15) / (12 * 100); // Monthly rate
        uint256 newAUSDCBalance = initialAUSDCBalance + increaseInSupply;
        console.log("\n=== Aave Yields ===");
        console.log("aUSDC interest earned:", newAUSDCBalance - initialAUSDCBalance);
        vm.mockCall(
            vaultStrategy.aUSDC(),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(vaultStrategy)),
            abi.encode(newAUSDCBalance)
        );

        // Mock variable debt balance (2.5% APY for cbETH borrow)
        uint256 increaseInDebt = (initialDebtBalance * 25) / (12 * 1000);
        uint256 newDebtBalance = initialDebtBalance + increaseInDebt;
        console.log("cbETH debt increase:", newDebtBalance - initialDebtBalance);
        vm.mockCall(
            vaultStrategy.variableDebtCbETH(),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(vaultStrategy)),
            abi.encode(newDebtBalance)
        );

        // Get Chainlink prices
        address[] memory dataFeeds = new address[](3);
        dataFeeds[0] = vaultStrategy.cbEthUsdDataFeedAddress();
        dataFeeds[1] = vaultStrategy.usdcUsdDataFeedAddress();
        dataFeeds[2] = vaultStrategy.aeroUsdDataFeedAddress();
        uint256[] memory prices = vaultStrategy.getChainlinkDataFeedLatestAnswer(dataFeeds);

        // Calculate Aerodrome rewards
        uint256 monthlyRewardValue = (depositAmount * 45) / (12 * 100); // 3.75% monthly reward rate
        uint256 usdcRewards = monthlyRewardValue / 2; // Half in USDC
        uint256 aeroRewards = ((monthlyRewardValue / 2) * prices[1] * 1e18) / (prices[2] * 1e6);

        console.log("\n=== Aerodrome Rewards ===");
        console.log("Monthly Aerodrome rewards in USDC:", usdcRewards);
        console.log("Monthly Aerodrome rewards in AERO tokens:", aeroRewards);

        // Setup mock for claimFees
        vm.mockCall(
            address(vaultStrategy.aerodromePool()),
            abi.encodeWithSelector(IPool.claimFees.selector),
            abi.encode(usdcRewards, aeroRewards)
        );

        // Mock rewards balances
        deal(address(vaultStrategy.AERO()), address(vaultStrategy), aeroRewards);
        deal(address(usdc), address(vaultStrategy), usdcRewards);

        // Record state before harvest
        uint256 totalAssetsBeforeHarvest = vaultStrategy.totalAssets();
        console.log("\n=== Pre-Harvest State ===");
        console.log("Total assets before harvest:", totalAssetsBeforeHarvest);
        console.log("Share price before harvest:", vaultStrategy.convertToAssets(1e6));

        // Perform harvest
        vm.prank(owner);
        vaultStrategy.harvestReinvestAndReport();

        uint256 totalAssetsAfterHarvest = vaultStrategy.totalAssets();
        uint256 shareValueAfterHarvest = vaultStrategy.convertToAssets(1e6);

        console.log("\n=== Post-Harvest State ===");
        console.log("Total assets after harvest:", totalAssetsAfterHarvest);
        console.log("Asset increase:", totalAssetsAfterHarvest - totalAssetsBeforeHarvest);
        console.log("Share price after harvest:", shareValueAfterHarvest);
        console.log("Strategist fee accumulated:", vaultStrategy.accumulatedStrategistFee());

        // Verify harvest results
        assertGt(totalAssetsAfterHarvest, totalAssetsBeforeHarvest, "Total assets should increase after harvest");
        assertGt(shareValueAfterHarvest, 1e6, "Share value should increase after harvest");

        // Perform withdrawal
        console.log("\n=== Withdrawal ===");
        uint256 userShares = vaultStrategy.balanceOf(user);
        console.log("User shares before withdrawal:", userShares);
        console.log("Share value at withdrawal:", vaultStrategy.convertToAssets(1e6));
        uint256 expectedAssets = vaultStrategy.convertToAssets(userShares);
        console.log("Expected assets to receive:", expectedAssets);

        vm.startPrank(user);
        uint256 assetsReceived = vaultStrategy.redeem(userShares, user, user);
        vm.stopPrank();

        console.log("\n=== Final State ===");
        console.log("Assets received:", assetsReceived);
        console.log("Final user USDC balance:", usdc.balanceOf(user));
        console.log("Final user shares:", vaultStrategy.balanceOf(user));
        console.log("Final vault total assets:", vaultStrategy.totalAssets());

        // Final assertions
        assertEq(vaultStrategy.balanceOf(user), 0, "User should have no shares left");
        assertGt(usdc.balanceOf(user), depositAmount, "User should receive more than deposited");
        assertApproxEqRel(
            assetsReceived,
            expectedAssets,
            0.01e18, // 1% tolerance
            "Assets received should match expected amount"
        );
    }

    function testUnauthorizedHarvestAttempt() public {
        // Initial setup - deposit 10,000 USDC
        uint256 depositAmount = 10_000e6;
        deal(address(usdc), user, depositAmount);

        vm.startPrank(user);
        usdc.approve(address(vaultStrategy), depositAmount);
        vaultStrategy.deposit(depositAmount, user);
        vm.stopPrank();

        // Fast forward time
        vm.warp(block.timestamp + 30 days);

        // Mock some yields to make sure there's something to harvest
        uint256 initialAUSDCBalance = IERC20(vaultStrategy.aUSDC()).balanceOf(address(vaultStrategy));
        uint256 newAUSDCBalance = initialAUSDCBalance + (initialAUSDCBalance * 15) / (12 * 100);
        vm.mockCall(
            vaultStrategy.aUSDC(),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(vaultStrategy)),
            abi.encode(newAUSDCBalance)
        );

        // Record state before attempted harvest
        uint256 totalAssetsBefore = vaultStrategy.totalAssets();

        // Attempt harvest as unauthorized user
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        vaultStrategy.harvestReinvestAndReport();

        // Verify no state changes occurred
        assertEq(vaultStrategy.totalAssets(), totalAssetsBefore, "Total assets should remain unchanged");
        assertEq(vaultStrategy.accumulatedStrategistFee(), 0, "No strategist fee should be accumulated");
    }

    function testInvariantTotalAssetsZeroWhenNoShares() public {
        // Initial deposit
        uint256 depositAmount = 100_000_000; // 100 USDC
        vm.startPrank(user);
        vaultStrategy.deposit(depositAmount, user);

        // Verify initial state
        assertGt(vaultStrategy.totalSupply(), 0, "Should have shares after deposit");
        assertGt(vaultStrategy.totalAssets(), 0, "Should have assets after deposit");

        // Full withdrawal
        vaultStrategy.withdraw(depositAmount, user, user);
        vm.stopPrank();

        // Verify invariant: totalAssets should be 0 when totalSupply is 0
        assertEq(vaultStrategy.totalSupply(), 0, "Total supply should be 0 after full withdrawal");
        assertEq(vaultStrategy.totalAssets(), 0, "Total assets should be 0 when total supply is 0");
    }

    // Additional test to verify the invariant holds after multiple operations
    function testInvariantTotalAssetsZeroAfterMultipleOperations() public {
        address user2 = makeAddr("user2");
        address user3 = makeAddr("user3");

        // Setup multiple users with USDC
        deal(address(usdc), user, 1000 * 10 ** 6);
        deal(address(usdc), user2, 1000 * 10 ** 6);
        deal(address(usdc), user3, 1000 * 10 ** 6);

        // Approve vault for all users
        vm.prank(user2);
        usdc.approve(address(vaultStrategy), type(uint256).max);
        vm.prank(user3);
        usdc.approve(address(vaultStrategy), type(uint256).max);

        // Multiple deposits and withdrawals
        vm.startPrank(user);
        vaultStrategy.deposit(100 * 10 ** 6, user);
        vm.stopPrank();

        vm.prank(user2);
        vaultStrategy.deposit(200 * 10 ** 6, user2);

        vm.prank(user3);
        vaultStrategy.deposit(300 * 10 ** 6, user3);

        // Partial withdrawals
        vm.prank(user);
        vaultStrategy.withdraw(50 * 10 ** 6, user, user);

        vm.prank(user2);
        vaultStrategy.withdraw(100 * 10 ** 6, user2, user2);

        // Full withdrawals
        vm.prank(user);
        vaultStrategy.withdraw(50 * 10 ** 6, user, user);

        vm.prank(user2);
        vaultStrategy.withdraw(100 * 10 ** 6, user2, user2);

        vm.prank(user3);
        vaultStrategy.withdraw(300 * 10 ** 6, user3, user3);

        // Verify invariant after all operations
        assertEq(vaultStrategy.totalSupply(), 0, "Total supply should be 0 after all withdrawals");
        assertEq(vaultStrategy.totalAssets(), 0, "Total assets should be 0 when total supply is 0");
    }

    // Test invariant after harvest operations
    function testInvariantTotalAssetsZeroAfterHarvest() public {
        // Initial deposit
        uint256 depositAmount = 100_000_000; // 100 USDC
        vm.startPrank(user);
        vaultStrategy.deposit(depositAmount, user);
        vm.stopPrank();

        // Simulate time passing and perform harvest
        vm.warp(block.timestamp + 30 days);
        vm.prank(owner);
        vaultStrategy.harvestReinvestAndReport();

        // Full withdrawal after harvest
        vm.startPrank(user);
        uint256 shares = vaultStrategy.balanceOf(user);
        vaultStrategy.redeem(shares, user, user);
        vm.stopPrank();

        // Verify invariant after harvest and withdrawal
        assertEq(vaultStrategy.totalSupply(), 0, "Total supply should be 0 after full withdrawal");
        assertEq(vaultStrategy.totalAssets(), 0, "Total assets should be 0 when total supply is 0");
    }

    function testCheckAndRebalanceOnly() public {
        // Initial setup - deposit some funds
        uint256 depositAmount = 10_000e6;
        deal(address(usdc), user, depositAmount);
        vm.startPrank(user);
        usdc.approve(address(vaultStrategy), depositAmount);
        vaultStrategy.deposit(depositAmount, user);
        vm.stopPrank();

        // Grant rebalancer role to test address
        address rebalancer = makeAddr("rebalancer");
        vm.prank(owner);
        vaultStrategy.grantRebalancerRole(rebalancer);

        // Test Case 1: Health factor is good (above target + buffer)
        uint256 goodHealthFactor = 1.5e18; // 1.5

        uint256 currentHealthFactor = vaultStrategy.calculateHealthFactor();
        vm.mockCall(
            AAVE_POOL_CONTRACT,
            abi.encodeWithSelector(IPoolAave.getUserAccountData.selector, address(vaultStrategy)),
            abi.encode(0, 0, 0, 0, 0, goodHealthFactor)
        );

        vm.prank(rebalancer);
        vaultStrategy.checkAndRebalance(); // Should not trigger rebalance

        // Clear mock and verify health factor remained unchanged
        vm.clearMockedCalls();
        assertEq(
            vaultStrategy.calculateHealthFactor(),
            currentHealthFactor,
            "Health factor should remain unchanged when good"
        );

        // Test Case 2: Health factor is below target + buffer
        uint256 lowHealthFactor = 1.01e18; // 1.01
        vm.mockCall(
            AAVE_POOL_CONTRACT,
            abi.encodeWithSelector(IPoolAave.getUserAccountData.selector, address(vaultStrategy)),
            abi.encode(0, 0, 0, 0, 0, lowHealthFactor)
        );

        vm.prank(rebalancer);
        vaultStrategy.checkAndRebalance(); // Should trigger rebalance

        // Mock the improved health factor after rebalance
        vm.clearMockedCalls();
        assertGt(
            vaultStrategy.calculateHealthFactor(), lowHealthFactor, "Health factor should improve after rebalancing"
        );
        // uint256 improvedHealthFactor = 1.2e18; // Expected improvement after rebalance
        // vm.mockCall(
        //     AAVE_POOL_CONTRACT,
        //     abi.encodeWithSelector(IPoolAave.getUserAccountData.selector, address(vaultStrategy)),
        //     abi.encode(0, 0, 0, 0, 0, improvedHealthFactor)
        // );

        // Test Case 3: Unauthorized caller
        vm.expectRevert(); // Should revert without rebalancer role
        vm.prank(user);
        vaultStrategy.checkAndRebalance();

        // Test Case 4: Very low health factor (near liquidation)
        uint256 criticalHealthFactor = 1.001e18; // 1.001
        vm.mockCall(
            AAVE_POOL_CONTRACT,
            abi.encodeWithSelector(IPoolAave.getUserAccountData.selector, address(vaultStrategy)),
            abi.encode(0, 0, 0, 0, 0, criticalHealthFactor)
        );

        vm.prank(rebalancer);
        vaultStrategy.checkAndRebalance(); // Should trigger rebalance

        // Mock the improved health factor after critical rebalance
        vm.clearMockedCalls();
        assertGt(
            vaultStrategy.calculateHealthFactor(),
            criticalHealthFactor,
            "Health factor should significantly improve after critical rebalancing"
        );
    }

    // Test with zero total assets
    function testCheckAndRebalanceWithZeroAssets() public {
        address rebalancer = makeAddr("rebalancer");
        vm.prank(owner);
        vaultStrategy.grantRebalancerRole(rebalancer);

        // Verify initial state
        assertEq(vaultStrategy.totalAssets(), 0, "Initial total assets should be 0");
        assertEq(vaultStrategy.totalSupply(), 0, "Initial total supply should be 0");

        // Record initial balances of relevant tokens
        uint256 initialAUsdcBalance = IERC20(vaultStrategy.aUSDC()).balanceOf(address(vaultStrategy));
        uint256 initialLpBalance = IERC20(address(vaultStrategy.aerodromePool())).balanceOf(address(vaultStrategy));
        uint256 initialCbEthBalance = IERC20(vaultStrategy.cbETH()).balanceOf(address(vaultStrategy));

        vm.prank(rebalancer);
        vaultStrategy.checkAndRebalance(); // Should not revert but also not trigger rebalance

        // Verify nothing changed after checkAndRebalance
        assertEq(vaultStrategy.totalAssets(), 0, "Total assets  should remain 0");
        assertEq(vaultStrategy.totalSupply(), 0, "Total supply should remain 0");
        assertEq(
            IERC20(vaultStrategy.aUSDC()).balanceOf(address(vaultStrategy)),
            initialAUsdcBalance,
            "aUSDC balance should not change"
        );
        assertEq(
            IERC20(address(vaultStrategy.aerodromePool())).balanceOf(address(vaultStrategy)),
            initialLpBalance,
            "LP token balance should not change"
        );
        assertEq(
            IERC20(vaultStrategy.cbETH()).balanceOf(address(vaultStrategy)),
            initialCbEthBalance,
            "cbETH balance should not change"
        );
    }

    function testUpgradeAndFunctionality() public {
        // Initial deposit
        uint256 depositAmount = 10_000e6;
        vm.startPrank(user);
        vaultStrategy.deposit(depositAmount, user);
        vm.stopPrank();

        // Deploy V2 implementation
        VaultStrategyV2 implementationV2 = new VaultStrategyV2();

        console.log("Owner address:", vaultStrategy.owner());
        console.log("Expected owner:", owner);
        console.log("Test contract address:", address(this));

        // Make sure we're using the correct owner address
        assertEq(vaultStrategy.owner(), owner, "Owner check before upgrade");

        // Upgrade to V2 using IUpgradeableProxy interface
        vm.prank(owner);
        IUpgradeableProxy(address(proxy)).upgradeToAndCall(
            address(implementationV2),
            "" // No initialization data needed
        );

        // Cast proxy to V2 to access new functions
        VaultStrategyV2 proxyV2 = VaultStrategyV2(address(proxy));

        // Test new functionality
        uint256 dummyResult = proxyV2.dummy(42);
        assertEq(dummyResult, 42, "Dummy function should return the input value");

        // Verify existing functionality still works
        vm.startPrank(user);
        uint256 shares = proxyV2.balanceOf(user);
        proxyV2.redeem(shares, user, user);
        vm.stopPrank();

        assertEq(proxyV2.balanceOf(user), 0, "User should have no shares remaining");
        assertEq(proxyV2.totalSupply(), 0, "Total supply should be zero");
    }

    function testCompleteVaultFlow() public {
        // Setup additional test users
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address charlie = makeAddr("charlie");
        address dave = makeAddr("dave");
        address eve = makeAddr("eve");

        // Initial deposits (First wave)
        uint256 aliceDeposit = 10_000e6; // 10,000 USDC
        uint256 bobDeposit = 15_000e6; // 15,000 USDC
        uint256 charlieDeposit = 8_000e6; // 8,000 USDC

        deal(address(usdc), alice, aliceDeposit);
        deal(address(usdc), bob, bobDeposit);
        deal(address(usdc), charlie, charlieDeposit);

        console.log("\n=== First Wave of Deposits ===");

        // Alice deposits
        vm.startPrank(alice);
        usdc.approve(address(vaultStrategy), aliceDeposit);
        vaultStrategy.deposit(aliceDeposit, alice);
        vm.stopPrank();

        uint256 totalAssetsAfterAlice = vaultStrategy.totalAssets();
        uint256 totalSupplyAfterAlice = vaultStrategy.totalSupply();
        console.log("Total Assets after Alice:", totalAssetsAfterAlice);
        console.log("Total Supply after Alice:", totalSupplyAfterAlice);

        // Bob deposits
        vm.startPrank(bob);
        usdc.approve(address(vaultStrategy), bobDeposit);
        vaultStrategy.deposit(bobDeposit, bob);
        vm.stopPrank();

        // Charlie deposits
        vm.startPrank(charlie);
        usdc.approve(address(vaultStrategy), charlieDeposit);
        vaultStrategy.deposit(charlieDeposit, charlie);
        vm.stopPrank();

        uint256 totalAssetsAfterFirstWave = vaultStrategy.totalAssets();
        uint256 totalSupplyAfterFirstWave = vaultStrategy.totalSupply();
        console.log("Total Assets after first wave:", totalAssetsAfterFirstWave);
        console.log("Total Supply after first wave:", totalSupplyAfterFirstWave);

        // First Harvest (after 30 days)
        vm.warp(block.timestamp + 30 days);

        // Get initial balances for harvest
        uint256 initialAUSDCBalance = IERC20(vaultStrategy.aUSDC()).balanceOf(address(vaultStrategy));
        uint256 initialDebtBalance = IERC20(vaultStrategy.variableDebtCbETH()).balanceOf(address(vaultStrategy));

        // Mock aUSDC balance increase (15% APY)
        uint256 increaseInSupply = (initialAUSDCBalance * 15) / (12 * 100); // Monthly rate
        uint256 newAUSDCBalance = initialAUSDCBalance + increaseInSupply;
        vm.mockCall(
            vaultStrategy.aUSDC(),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(vaultStrategy)),
            abi.encode(newAUSDCBalance)
        );

        // Mock variable debt balance (2.5% APY for cbETH borrow)
        uint256 increaseInDebt = (initialDebtBalance * 25) / (12 * 1000);
        uint256 newDebtBalance = initialDebtBalance + increaseInDebt;
        vm.mockCall(
            vaultStrategy.variableDebtCbETH(),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(vaultStrategy)),
            abi.encode(newDebtBalance)
        );

        // Setup mock for claimFees
        uint256 monthlyRewardValue = (totalAssetsAfterFirstWave * 45) / (12 * 100);
        uint256 usdcRewards = monthlyRewardValue / 2;

        // Get prices for conversion
        address[] memory dataFeeds = new address[](3);
        dataFeeds[0] = vaultStrategy.cbEthUsdDataFeedAddress();
        dataFeeds[1] = vaultStrategy.usdcUsdDataFeedAddress();
        dataFeeds[2] = vaultStrategy.aeroUsdDataFeedAddress();
        uint256[] memory prices = vaultStrategy.getChainlinkDataFeedLatestAnswer(dataFeeds);

        uint256 aeroRewards = ((monthlyRewardValue / 2) * prices[1] * 1e18) / (prices[2] * 1e6);

        vm.mockCall(
            address(vaultStrategy.aerodromePool()),
            abi.encodeWithSelector(IPool.claimFees.selector),
            abi.encode(usdcRewards, aeroRewards)
        );

        // Mock AERO balance and USDC rewards
        deal(address(vaultStrategy.AERO()), address(vaultStrategy), aeroRewards);
        deal(address(usdc), address(vaultStrategy), usdcRewards);

        console.log("\n=== First Harvest ===");
        vm.prank(owner);
        vaultStrategy.harvestReinvestAndReport();

        // Second wave of deposits
        uint256 daveDeposit = 20_000e6; // 20,000 USDC
        uint256 eveDeposit = 12_000e6; // 12,000 USDC
        uint256 aliceSecondDeposit = 5_000e6; // Alice deposits more

        // ... (continuing in next message due to length)
        // Second wave of deposits
        deal(address(usdc), dave, daveDeposit);
        deal(address(usdc), eve, eveDeposit);
        deal(address(usdc), alice, aliceSecondDeposit);

        console.log("\n=== Second Wave of Deposits ===");

        // Dave deposits
        vm.startPrank(dave);
        usdc.approve(address(vaultStrategy), daveDeposit);
        vaultStrategy.deposit(daveDeposit, dave);
        vm.stopPrank();

        // Eve deposits
        vm.startPrank(eve);
        usdc.approve(address(vaultStrategy), eveDeposit);
        vaultStrategy.deposit(eveDeposit, eve);
        vm.stopPrank();

        // Alice makes second deposit
        vm.startPrank(alice);
        usdc.approve(address(vaultStrategy), aliceSecondDeposit);
        vaultStrategy.deposit(aliceSecondDeposit, alice);
        vm.stopPrank();

        uint256 totalAssetsAfterSecondWave = vaultStrategy.totalAssets();
        uint256 totalSupplyAfterSecondWave = vaultStrategy.totalSupply();
        console.log("Total Assets after second wave:", totalAssetsAfterSecondWave);
        console.log("Total Supply after second wave:", totalSupplyAfterSecondWave);

        // First wave of withdrawals
        console.log("\n=== First Wave of Withdrawals ===");

        // Charlie withdraws half
        vm.startPrank(charlie);
        uint256 charlieShares = vaultStrategy.balanceOf(charlie);
        vaultStrategy.withdraw(charlieShares / 2, charlie, charlie);
        vm.stopPrank();

        // Bob withdraws everything
        vm.startPrank(bob);
        uint256 bobShares = vaultStrategy.balanceOf(bob);
        vaultStrategy.redeem(bobShares, bob, bob);
        vm.stopPrank();

        // Second Harvest (after another 30 days)
        vm.warp(block.timestamp + 30 days);

        // Get balances before second harvest
        initialAUSDCBalance = IERC20(vaultStrategy.aUSDC()).balanceOf(address(vaultStrategy));
        initialDebtBalance = IERC20(vaultStrategy.variableDebtCbETH()).balanceOf(address(vaultStrategy));

        // Mock higher aUSDC balance increase (18% APY due to more TVL)
        increaseInSupply = (initialAUSDCBalance * 18) / (12 * 100);
        newAUSDCBalance = initialAUSDCBalance + increaseInSupply;
        vm.mockCall(
            vaultStrategy.aUSDC(),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(vaultStrategy)),
            abi.encode(newAUSDCBalance)
        );

        // Mock variable debt balance (2.5% APY for cbETH borrow)
        increaseInDebt = (initialDebtBalance * 25) / (12 * 1000);
        newDebtBalance = initialDebtBalance + increaseInDebt;
        vm.mockCall(
            vaultStrategy.variableDebtCbETH(),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(vaultStrategy)),
            abi.encode(newDebtBalance)
        );

        // Setup mock for second harvest claimFees
        monthlyRewardValue = (totalAssetsAfterSecondWave * 50) / (12 * 100); // Higher rewards (50% APY)
        usdcRewards = monthlyRewardValue / 2;
        aeroRewards = ((monthlyRewardValue / 2) * prices[1] * 1e18) / (prices[2] * 1e6);

        vm.mockCall(
            address(vaultStrategy.aerodromePool()),
            abi.encodeWithSelector(IPool.claimFees.selector),
            abi.encode(usdcRewards, aeroRewards)
        );

        // Mock AERO balance and USDC rewards for second harvest
        deal(address(vaultStrategy.AERO()), address(vaultStrategy), aeroRewards);
        deal(address(usdc), address(vaultStrategy), usdcRewards);

        console.log("\n=== Second Harvest ===");
        vm.prank(owner);
        vaultStrategy.harvestReinvestAndReport();

        uint256 totalAssetsAfterSecondHarvest = vaultStrategy.totalAssets();
        uint256 totalSupplyAfterSecondHarvest = vaultStrategy.totalSupply();
        console.log("Total Assets after second harvest:", totalAssetsAfterSecondHarvest);
        console.log("Total Supply after second harvest:", totalSupplyAfterSecondHarvest);

        // Final withdrawals
        console.log("\n=== Final Withdrawals ===");

        // Eve withdraws 75%
        vm.startPrank(eve);
        uint256 eveShares = vaultStrategy.balanceOf(eve);
        vaultStrategy.withdraw((eveShares * 75) / 100, eve, eve);
        vm.stopPrank();

        // Dave withdraws everything
        vm.startPrank(dave);
        uint256 daveShares = vaultStrategy.balanceOf(dave);
        vaultStrategy.redeem(daveShares, dave, dave);
        vm.stopPrank();

        // Final state checks
        uint256 finalTotalAssets = vaultStrategy.totalAssets();
        uint256 finalTotalSupply = vaultStrategy.totalSupply();
        console.log("\n=== Final State ===");
        console.log("Final Total Assets:", finalTotalAssets);
        console.log("Final Total Supply:", finalTotalSupply);

        // Verify remaining balances
        console.log("Alice's final shares:", vaultStrategy.balanceOf(alice));
        console.log("Charlie's final shares:", vaultStrategy.balanceOf(charlie));
        console.log("Eve's final shares:", vaultStrategy.balanceOf(eve));

        // Verify Bob and Dave have fully withdrawn
        assertEq(vaultStrategy.balanceOf(bob), 0, "Bob should have no shares");
        assertEq(vaultStrategy.balanceOf(dave), 0, "Dave should have no shares");
    }

    function testCompareHarvestFunctions() public {
        // Initial setup - deposit 10,000 USDC
        uint256 depositAmount = 10_000e6; // 10,000 USDC
        deal(address(usdc), user, depositAmount);

        vm.startPrank(user);
        usdc.approve(address(vaultStrategy), depositAmount);
        vaultStrategy.deposit(depositAmount, user);
        vm.stopPrank();

        // Fast forward time to accumulate rewards (30 days)
        vm.warp(block.timestamp + 30 days);

        // Setup mocks for the first harvest
        // Mock aUSDC balance increase (15% APY)
        uint256 initialAUSDCBalance = IERC20(vaultStrategy.aUSDC()).balanceOf(address(vaultStrategy));
        uint256 increaseInSupply = (initialAUSDCBalance * 15) / (12 * 100);
        uint256 newAUSDCBalance = initialAUSDCBalance + increaseInSupply;
        vm.mockCall(
            vaultStrategy.aUSDC(),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(vaultStrategy)),
            abi.encode(newAUSDCBalance)
        );

        // Mock variable debt balance (2.5% APY)
        uint256 initialDebtBalance = IERC20(vaultStrategy.variableDebtCbETH()).balanceOf(address(vaultStrategy));
        uint256 increaseInDebt = (initialDebtBalance * 25) / (12 * 1000);
        uint256 newDebtBalance = initialDebtBalance + increaseInDebt;
        vm.mockCall(
            vaultStrategy.variableDebtCbETH(),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(vaultStrategy)),
            abi.encode(newDebtBalance)
        );

        // Setup Aerodrome rewards
        uint256 monthlyRewardValue = (depositAmount * 45) / (12 * 100);
        uint256 usdcRewards = monthlyRewardValue / 2;

        // Get prices for AERO reward calculation
        address[] memory dataFeeds = new address[](3);
        dataFeeds[0] = vaultStrategy.cbEthUsdDataFeedAddress();
        dataFeeds[1] = vaultStrategy.usdcUsdDataFeedAddress();
        dataFeeds[2] = vaultStrategy.aeroUsdDataFeedAddress();
        uint256[] memory prices = vaultStrategy.getChainlinkDataFeedLatestAnswer(dataFeeds);
        uint256 aeroRewards = ((monthlyRewardValue / 2) * prices[1] * 1e18) / (prices[2] * 1e6);

        // Setup mock for claimFees
        vm.mockCall(
            address(vaultStrategy.aerodromePool()),
            abi.encodeWithSelector(IPool.claimFees.selector),
            abi.encode(usdcRewards, aeroRewards)
        );

        // Mock balances
        deal(address(vaultStrategy.AERO()), address(vaultStrategy), aeroRewards);
        deal(address(usdc), address(vaultStrategy), usdcRewards);

        // Record state before first harvest
        uint256 totalAssetsBeforeOld = vaultStrategy.totalAssets();
        uint256 totalSupplyBeforeOld = vaultStrategy.totalSupply();

        // Run old harvest function
        vm.prank(owner);
        vaultStrategy.harvestReinvestAndReport();

        // Record results from old harvest
        uint256 totalAssetsAfterOld = vaultStrategy.totalAssets();
        console.log("Total Assets after old harvest:", totalAssetsAfterOld);
        uint256 totalSupplyAfterOld = vaultStrategy.totalSupply();
        console.log("Total Supply after old harvest:", totalSupplyAfterOld);
        uint256 strategistFeeOld = vaultStrategy.accumulatedStrategistFee();
        console.log("Strategist fee after old harvest:", strategistFeeOld);
        vm.clearMockedCalls();

        console.log("\n=== Full withdrawal to reset state ===");

        // Full withdrawal to reset state
        vm.startPrank(user);
        uint256 userShares = vaultStrategy.balanceOf(user);
        vaultStrategy.withdraw(vaultStrategy.convertToAssets(userShares), user, user);
        vm.stopPrank();

        console.log("\n=== Re-deposit for new harvest test ===");

        // Re-deposit for new harvest test
        vm.startPrank(user);
        usdc.approve(address(vaultStrategy), depositAmount);
        vaultStrategy.deposit(depositAmount, user);
        vm.stopPrank();

        uint256 reinvestmentAmount = usdcRewards + ((aeroRewards * prices[2] * 1e6) / (prices[1] * 1e18)); // Convert AERO to USDC
        uint256 expectedNewAUSDCBalance = newAUSDCBalance + reinvestmentAmount;

        // Setup same mocks for new harvest function
        vm.mockCall(
            vaultStrategy.aUSDC(),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(vaultStrategy)),
            abi.encode(newAUSDCBalance)
        );
        vm.mockCall(
            vaultStrategy.variableDebtCbETH(),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(vaultStrategy)),
            abi.encode(newDebtBalance)
        );
        vm.mockCall(
            address(vaultStrategy.aerodromePool()),
            abi.encodeWithSelector(IPool.claimFees.selector),
            abi.encode(usdcRewards, aeroRewards)
        );
        deal(address(vaultStrategy.AERO()), address(vaultStrategy), aeroRewards);
        deal(address(usdc), address(vaultStrategy), usdcRewards);

        // Record state before new harvest
        uint256 totalAssetsBeforeNew = vaultStrategy.totalAssets();
        console.log("Total Assets before new harvest:", totalAssetsBeforeNew);
        uint256 totalSupplyBeforeNew = vaultStrategy.totalSupply();
        console.log("Total Supply before new harvest:", totalSupplyBeforeNew);

        // Run new harvest function
        vm.prank(owner);
        vaultStrategy.newHarvestReinvestAndReport();

        // Record results from new harvest
        uint256 totalAssetsAfterNew = vaultStrategy.totalAssets();
        uint256 totalSupplyAfterNew = vaultStrategy.totalSupply();
        uint256 strategistFeeNew = vaultStrategy.accumulatedStrategistFee();

        // Compare results
        console.log("\n=== Comparing Harvest Results ===");
        console.log("Old Harvest - Total Assets Change:", totalAssetsAfterOld - totalAssetsBeforeOld);
        console.log("New Harvest - Total Assets Change:", totalAssetsAfterNew - totalAssetsBeforeNew);
        console.log("Old Harvest - Strategist Fee:", strategistFeeOld);
        console.log("New Harvest - Strategist Fee:", strategistFeeNew);
        console.log("Old Harvest - Total Supply:", totalSupplyAfterOld);
        console.log("New Harvest - Total Supply:", totalSupplyAfterNew);

        // Assert results are similar (within 1% tolerance)
        assertApproxEqRel(totalAssetsAfterNew, totalAssetsAfterOld, 0.01e18, "Total assets should be similar");
        assertApproxEqRel(strategistFeeNew, strategistFeeOld, 0.01e18, "Strategist fees should be similar");
        assertEq(totalSupplyAfterNew, totalSupplyAfterOld, "Total supply should be identical");
    }
}
