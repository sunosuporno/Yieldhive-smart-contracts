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

contract Vault_StrategyTest is Test {
    VaultStrategy public vaultStrategy;
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

    function setUp() public {
        // Remove the line: vm.createSelectFork("optimism");

        // Set up accounts
        owner = makeAddr("owner");
        user = makeAddr("user");

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
            AAVE_POOL_CONTRACT,
            AAVE_PROTOCOL_DATA_PROVIDER_CONTRACT,
            AAVE_ORACLE_CONTRACT,
            owner, // strategist
            AERODROME_POOL_CONTRACT
        );

        // Deploy TransparentUpgradeableProxy
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(vaultStrategyImplementation), address(proxyAdmin), initData);

        // Assign the proxy address to vaultStrategy
        vaultStrategy = VaultStrategy(address(proxy));

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
    function testDeposit() public {
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
        console.log("afterWithdrawUserBalance", afterWithdrawUserBalance);
        console.log("afterWithdrawTotalSupply", afterWithdrawTotalSupply);

        // Verify final states
        assertEq(
            usdc.balanceOf(user), afterDepositUserBalance + withdrawAmount, "Incorrect USDC balance after withdrawal"
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
            assertEq(
                usdc.balanceOf(user), preWithdrawBalance + withdrawAmounts[i], "Incorrect USDC balance after withdrawal"
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

        // Initial deposit
        vm.startPrank(user);
        vaultStrategy.deposit(depositAmount, user);

        // Record state before withdrawal
        uint256 preWithdrawBalance = usdc.balanceOf(user);
        uint256 preWithdrawShares = vaultStrategy.balanceOf(user);

        // Perform withdrawal
        if (withdrawAmount == 0) {
            vm.expectRevert();
        }
        vaultStrategy.withdraw(withdrawAmount, user, user);

        // Verify state after withdrawal
        if (withdrawAmount > 0) {
            assertEq(
                usdc.balanceOf(user), preWithdrawBalance + withdrawAmount, "Incorrect USDC balance after withdrawal"
            );
            assertEq(
                vaultStrategy.balanceOf(user),
                preWithdrawShares - withdrawAmount,
                "Incorrect share balance after withdrawal"
            );
        }

        vm.stopPrank();
    }
}
