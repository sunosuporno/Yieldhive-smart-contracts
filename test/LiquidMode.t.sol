// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {LiquidMode} from "../src/LiquidMode.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from
    "@cryptoalgebra/integral-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {ISwapRouter} from "@cryptoalgebra/integral-periphery/contracts/interfaces/ISwapRouter.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IAlgebraPoolActions} from "@cryptoalgebra/integral-core/contracts/interfaces/pool/IAlgebraPoolActions.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract LiquidModeTest is Test {
    LiquidMode public liquidMode;

    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant INITIAL_OWNER = 0x07a721260416e764618B059811eaf099a940Af14;
    address constant STRATEGIST = 0x6A0a7c97c3B6e9fBdA3626ED15A244aDa74A54CF;
    address constant NONFUNGIBLE_POSITION_MANAGER = 0x2e8614625226D26180aDf6530C3b1677d3D7cf10;
    address constant FACTORY = 0xB5F00c2C5f8821155D8ed27E31932CFD9DB3C5D5;
    address constant POOL_DEPLOYER = 0x6414A461B19726410E52488d9D5ff33682701635;
    address constant EZETH_WRSETH_POOL = 0xD9a06f63E523757973ffd1a4606A1260252636D2;
    address constant SWAP_ROUTER = 0xAc48FcF1049668B285f3dC72483DF5Ae2162f7e8;
    address constant TREASURY = 0x273dFa01f5605b8c41d6CE1146ed0911FDC5ad07;
    address constant EZETH = 0x2416092f143378750bb29b79eD961ab195CcEea5;
    address constant WRSETH = 0x4200000000000000000000000000000000000006;
    address constant EZETH_ETH_PROXY = 0x93Aa62C43a5cceb33682a267356117C4edbdc9b9;
    address constant WRSETH_ETH_PROXY = 0x4200000000000000000000000000000000000006;
    address public user;
    uint256 public constant INITIAL_USER_BALANCE = 1000 ether;

    function setUp() public {
        // Deploy the LiquidMode contract
        liquidMode = new LiquidMode(
            IERC20(WETH),
            "LiquidMode Token",
            "LMT",
            INITIAL_OWNER,
            STRATEGIST,
            INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER),
            FACTORY,
            POOL_DEPLOYER,
            WETH,
            EZETH_WRSETH_POOL,
            ISwapRouter(SWAP_ROUTER),
            TREASURY,
            EZETH,
            WRSETH,
            EZETH_ETH_PROXY,
            WRSETH_ETH_PROXY
        );

        user = makeAddr("user");

        // Give the user 1000 ETH
        vm.deal(user, INITIAL_USER_BALANCE);

        // Wrap ETH to WETH for the user
        vm.prank(user);
        IWETH9(WETH).deposit{value: INITIAL_USER_BALANCE}();

        uint256 userWETHBalance = IERC20(WETH).balanceOf(user);
        console.log("userWETHBalance", userWETHBalance);

        // Verify the user's WETH balance
        assertEq(IERC20(WETH).balanceOf(user), INITIAL_USER_BALANCE, "User should have 1000 WETH");
    }

    function testInitialSetup() public {
        assertEq(address(liquidMode.asset()), WETH, "Asset should be WETH");
        assertEq(liquidMode.name(), "LiquidMode Token", "Name should be set correctly");
        assertEq(liquidMode.symbol(), "LMT", "Symbol should be set correctly");
        assertEq(liquidMode.owner(), INITIAL_OWNER, "Owner should be set correctly");
        assertEq(liquidMode.strategist(), STRATEGIST, "Strategist should be set correctly");
        assertEq(
            address(liquidMode.nonfungiblePositionManager()),
            NONFUNGIBLE_POSITION_MANAGER,
            "NonfungiblePositionManager should be set correctly"
        );
        assertEq(liquidMode.token0(), EZETH, "EZETH should be set correctly");
        assertEq(liquidMode.token1(), WRSETH, "WRSETH should be set correctly");
        assertEq(address(liquidMode.WETH()), WETH, "WETH should be set correctly");
        assertEq(liquidMode.poolAddress(), EZETH_WRSETH_POOL, "poolAddress should be set correctly");
        assertEq(address(liquidMode.swapRouter()), SWAP_ROUTER, "SwapRouter should be set correctly");
        assertEq(liquidMode.treasury(), TREASURY, "Treasury should be set correctly");
    }

    function testDeposits() public {
        uint256 depositAmount = 10 ether;

        vm.startPrank(user);

        // Approve WETH spending
        IERC20(WETH).approve(address(liquidMode), depositAmount);

        // Get initial balances
        uint256 initialUserWETHBalance = IERC20(WETH).balanceOf(user);
        uint256 initialContractWETHBalance = IERC20(WETH).balanceOf(address(liquidMode));
        uint256 initialTotalAssets = liquidMode.totalAssets();
        uint256 initialUserShares = liquidMode.balanceOf(user);

        // Perform deposit
        uint256 sharesReceived = liquidMode.deposit(depositAmount, user);

        // Get final balances
        uint256 finalUserWETHBalance = IERC20(WETH).balanceOf(user);
        uint256 finalContractWETHBalance = IERC20(WETH).balanceOf(address(liquidMode));
        uint256 finalContractWRSETHBalance = IERC20(WRSETH).balanceOf(address(liquidMode));
        uint256 finalContractEZETHBalance = IERC20(EZETH).balanceOf(address(liquidMode));
        uint256 finalTotalAssets = liquidMode.totalAssets();
        uint256 finalUserShares = liquidMode.balanceOf(user);

        console.log("finalContractWRSETHBalance", finalContractWRSETHBalance);
        console.log("finalContractEZETHBalance", finalContractEZETHBalance);
        // Assertions
        assertEq(
            initialUserWETHBalance - finalUserWETHBalance,
            depositAmount,
            "User's WETH balance should decrease by deposit amount"
        );
        assertEq(finalTotalAssets - initialTotalAssets, depositAmount, "Total assets should increase by deposit amount");
        assertEq(finalUserShares - initialUserShares, sharesReceived, "User should receive correct amount of shares");
        assertGt(sharesReceived, 0, "User should receive more than 0 shares");

        vm.stopPrank();
    }

    function testMultipleDeposits() public {
        uint256[] memory depositAmounts = new uint256[](3);
        depositAmounts[0] = 1 ether;
        depositAmounts[1] = 2 ether;
        depositAmounts[2] = 0.5 ether;

        address[] memory users = new address[](3);
        users[0] = address(0x1);
        users[1] = address(0x2);
        users[2] = address(0x3);

        uint256 totalDepositAmount = 0;
        uint256[] memory sharesReceived = new uint256[](3);

        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(users[i]);

            // Mint WETH for the user
            deal(WETH, users[i], depositAmounts[i]);

            // Approve WETH spending
            IERC20(WETH).approve(address(liquidMode), depositAmounts[i]);

            // Get initial balances
            uint256 initialUserWETHBalance = IERC20(WETH).balanceOf(users[i]);
            uint256 initialTotalAssets = liquidMode.totalAssets();
            uint256 initialUserShares = liquidMode.balanceOf(users[i]);

            // Perform deposit
            sharesReceived[i] = liquidMode.deposit(depositAmounts[i], users[i]);

            // Get final balances
            uint256 finalUserWETHBalance = IERC20(WETH).balanceOf(users[i]);
            uint256 finalTotalAssets = liquidMode.totalAssets();
            uint256 finalUserShares = liquidMode.balanceOf(users[i]);

            // Assertions for each user
            assertEq(
                initialUserWETHBalance - finalUserWETHBalance,
                depositAmounts[i],
                "User's WETH balance should decrease by deposit amount"
            );
            assertEq(
                finalTotalAssets - initialTotalAssets,
                depositAmounts[i],
                "Total assets should increase by deposit amount"
            );
            assertEq(
                finalUserShares - initialUserShares, sharesReceived[i], "User should receive correct amount of shares"
            );
            assertGt(sharesReceived[i], 0, "User should receive more than 0 shares");

            totalDepositAmount += depositAmounts[i];

            vm.stopPrank();
        }

        // Final assertions after all deposits
        uint256 finalActualTotalAssets = liquidMode.totalAssets();
        assertEq(finalActualTotalAssets, totalDepositAmount, "Total assets should equal sum of all deposits");

        uint256 finalContractWRSETHBalance = IERC20(WRSETH).balanceOf(address(liquidMode));
        uint256 finalContractEZETHBalance = IERC20(EZETH).balanceOf(address(liquidMode));
        console.log("Final Contract WRSETH Balance", finalContractWRSETHBalance);
        console.log("Final Contract EZETH Balance", finalContractEZETHBalance);

        // Check that the sum of all users' shares equals the total supply
        uint256 totalShares = 0;
        for (uint256 i = 0; i < 3; i++) {
            totalShares += liquidMode.balanceOf(users[i]);
        }
        assertEq(totalShares, liquidMode.totalSupply(), "Sum of user shares should equal total supply");
    }

    function testDoubleDeposit() public {
        uint256 firstDepositAmount = 1 ether;
        uint256 secondDepositAmount = 2 ether;

        vm.startPrank(user);

        // Approve WETH spending for both deposits
        IERC20(WETH).approve(address(liquidMode), firstDepositAmount + secondDepositAmount);

        // Get initial KIMPosition
        (uint256 initialTokenId, uint128 initialLiquidity, uint256 initialAmount0, uint256 initialAmount1) =
            liquidMode.getKimPosition();

        // First deposit
        uint256 initialUserWETHBalance = IERC20(WETH).balanceOf(user);
        uint256 initialTotalAssets = liquidMode.totalAssets();
        uint256 initialUserShares = liquidMode.balanceOf(user);

        uint256 firstSharesReceived = liquidMode.deposit(firstDepositAmount, user);

        // Get KIMPosition after first deposit
        (uint256 midTokenId, uint128 midLiquidity, uint256 midAmount0, uint256 midAmount1) = liquidMode.getKimPosition();

        // Assert that a new position was created after first deposit
        assertEq(initialTokenId, 0, "Initial TokenId should be 0");
        assertGt(midTokenId, 0, "TokenId should be created after first deposit");
        assertGt(midLiquidity, initialLiquidity, "Liquidity should increase after first deposit");

        uint256 midUserWETHBalance = IERC20(WETH).balanceOf(user);
        uint256 midTotalAssets = liquidMode.totalAssets();
        uint256 midUserShares = liquidMode.balanceOf(user);

        // Assertions for first deposit
        assertEq(
            initialUserWETHBalance - midUserWETHBalance,
            firstDepositAmount,
            "User's WETH balance should decrease by first deposit amount"
        );
        assertEq(
            midTotalAssets - initialTotalAssets,
            firstDepositAmount,
            "Total assets should increase by first deposit amount"
        );
        assertEq(
            midUserShares - initialUserShares,
            firstSharesReceived,
            "User should receive correct amount of shares for first deposit"
        );
        assertGt(firstSharesReceived, 0, "User should receive more than 0 shares for first deposit");

        // Second deposit
        uint256 secondSharesReceived = liquidMode.deposit(secondDepositAmount, user);

        // Get KIMPosition after second deposit
        (uint256 finalTokenId, uint128 finalLiquidity, uint256 finalAmount0, uint256 finalAmount1) =
            liquidMode.getKimPosition();

        // Assert that liquidity increased after second deposit
        assertEq(finalTokenId, midTokenId, "TokenId should remain the same after second deposit");
        assertGt(finalLiquidity, midLiquidity, "Liquidity should increase after second deposit");

        uint256 finalUserWETHBalance = IERC20(WETH).balanceOf(user);
        uint256 finalTotalAssets = liquidMode.totalAssets();
        uint256 finalUserShares = liquidMode.balanceOf(user);

        // Assertions for second deposit
        assertEq(
            midUserWETHBalance - finalUserWETHBalance,
            secondDepositAmount,
            "User's WETH balance should decrease by second deposit amount"
        );
        assertEq(
            finalTotalAssets - midTotalAssets,
            secondDepositAmount,
            "Total assets should increase by second deposit amount"
        );
        assertEq(
            finalUserShares - midUserShares,
            secondSharesReceived,
            "User should receive correct amount of shares for second deposit"
        );
        assertGt(secondSharesReceived, 0, "User should receive more than 0 shares for second deposit");

        // Final assertions
        assertEq(
            initialUserWETHBalance - finalUserWETHBalance,
            firstDepositAmount + secondDepositAmount,
            "User's total WETH balance decrease should equal sum of both deposits"
        );
        assertEq(
            finalTotalAssets - initialTotalAssets,
            firstDepositAmount + secondDepositAmount,
            "Total assets increase should equal sum of both deposits"
        );
        assertEq(
            finalUserShares - initialUserShares,
            firstSharesReceived + secondSharesReceived,
            "Total shares received should equal sum of shares from both deposits"
        );

        console.log("Initial TokenId:", initialTokenId);
        console.log("Mid TokenId:", midTokenId);
        console.log("Final TokenId:", finalTokenId);
        console.log("Initial Liquidity:", initialLiquidity);
        console.log("Mid Liquidity:", midLiquidity);
        console.log("Final Liquidity:", finalLiquidity);

        uint256 finalContractWRSETHBalance = IERC20(WRSETH).balanceOf(address(liquidMode));
        uint256 finalContractEZETHBalance = IERC20(EZETH).balanceOf(address(liquidMode));
        console.log("Final Contract WRSETH Balance", finalContractWRSETHBalance);
        console.log("Final Contract EZETH Balance", finalContractEZETHBalance);

        vm.stopPrank();
    }

    function testMint() public {
        uint256 assetsToDeposit = 1 ether;

        vm.startPrank(user);

        // Calculate shares
        uint256 sharesToMint = liquidMode.previewDeposit(assetsToDeposit);

        // Approve WETH spending
        IERC20(WETH).approve(address(liquidMode), assetsToDeposit);

        // Get initial balances
        uint256 initialUserWETHBalance = IERC20(WETH).balanceOf(user);
        uint256 initialTotalAssets = liquidMode.totalAssets();
        uint256 initialUserShares = liquidMode.balanceOf(user);
        (uint256 initialTokenId, uint128 initialLiquidity,,) = liquidMode.getKimPosition();

        // Perform mint
        uint256 assetsMinted = liquidMode.mint(sharesToMint, user);

        // Get final balances
        uint256 finalUserWETHBalance = IERC20(WETH).balanceOf(user);
        uint256 finalTotalAssets = liquidMode.totalAssets();
        uint256 finalUserShares = liquidMode.balanceOf(user);
        (uint256 finalTokenId, uint128 finalLiquidity,,) = liquidMode.getKimPosition();

        // Assertions
        assertEq(
            initialUserWETHBalance - finalUserWETHBalance,
            assetsMinted,
            "User's WETH balance should decrease by minted amount"
        );
        assertEq(finalTotalAssets - initialTotalAssets, assetsMinted, "Total assets should increase by minted amount");
        assertEq(finalUserShares - initialUserShares, sharesToMint, "User should receive correct amount of shares");
        assertEq(assetsMinted, assetsToDeposit, "Minted assets should equal intended deposit amount");

        // Check KIMPosition
        if (initialTokenId == 0) {
            assertGt(finalTokenId, 0, "A new position should be created");
        } else {
            assertEq(finalTokenId, initialTokenId, "TokenId should remain the same");
        }
        assertGt(finalLiquidity, initialLiquidity, "Liquidity should increase");

        uint256 finalContractWRSETHBalance = IERC20(WRSETH).balanceOf(address(liquidMode));
        uint256 finalContractEZETHBalance = IERC20(EZETH).balanceOf(address(liquidMode));
        console.log("Final Contract WRSETH Balance", finalContractWRSETHBalance);
        console.log("Final Contract EZETH Balance", finalContractEZETHBalance);

        vm.stopPrank();
    }

    function testDepositWhenPaused() public {
        uint256 depositAmount = 1 ether;

        // Pause the contract
        vm.prank(liquidMode.owner());
        liquidMode.pause();

        // Ensure the contract is paused
        assertTrue(liquidMode.paused(), "Contract should be paused");

        vm.startPrank(user);

        // Approve WETH spending
        IERC20(WETH).approve(address(liquidMode), depositAmount);

        // Attempt to deposit while the contract is paused
        vm.expectRevert(Pausable.EnforcedPause.selector);
        liquidMode.deposit(depositAmount, user);

        vm.stopPrank();

        // Unpause the contract
        vm.prank(liquidMode.owner());
        liquidMode.unpause();

        // Ensure the contract is unpaused
        assertFalse(liquidMode.paused(), "Contract should be unpaused");

        // Now the deposit should succeed
        vm.prank(user);
        uint256 sharesReceived = liquidMode.deposit(depositAmount, user);

        assertGt(sharesReceived, 0, "Deposit should succeed after unpausing");
    }

    function testZeroAmountDeposit() public {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSignature("zeroAmountRequired()"));
        liquidMode.deposit(0, user);
        vm.stopPrank();
    }

    function testFuzzDeposit(uint256 depositAmount) public {
        vm.assume(depositAmount > 0 && depositAmount <= 1000 ether);

        vm.startPrank(user);
        deal(WETH, user, depositAmount);
        IERC20(WETH).approve(address(liquidMode), depositAmount);

        uint256 sharesBefore = liquidMode.balanceOf(user);

        try liquidMode.deposit(depositAmount, user) returns (uint256 sharesReceived) {
            uint256 sharesAfter = liquidMode.balanceOf(user);

            assertGt(sharesReceived, 0, "Should receive some shares for deposit");
            assertEq(sharesAfter, sharesBefore + sharesReceived, "Shares should increase by the amount received");

            console.log("Successful deposit amount:", depositAmount);
            console.log("Shares received:", sharesReceived);
        } catch Error(string memory reason) {
            console.log("Deposit failed with reason:", reason);
        } catch (bytes memory lowLevelData) {
            console.log("Deposit failed with low-level error");
        }

        vm.stopPrank();
    }

    function testDepositUnauthorizedToken() public {
        // Use ezETH as the unauthorized token
        address unauthorizedToken = 0xDfc7C877a950e49D2610114102175A06C2e3167a; //mode token

        // Mint some ezETH to the user
        uint256 depositAmount = 1 ether;
        deal(unauthorizedToken, user, depositAmount);

        vm.startPrank(user);

        // Approve the unauthorized token
        IERC20(unauthorizedToken).approve(address(liquidMode), depositAmount);

        // Try to deposit the unauthorized token
        vm.expectRevert();
        liquidMode.deposit(depositAmount, user);

        vm.stopPrank();

        // Verify that no deposit was made
        assertEq(liquidMode.balanceOf(user), 0, "User should have no shares");
        assertEq(liquidMode.totalAssets(), 0, "Total assets should remain unchanged");
    }

    function testWithdraw() public {
        uint256 depositAmount = 10 ether;
        uint256 withdrawAmount = 5 ether;

        // Setup: Deposit funds
        vm.startPrank(user);
        IERC20(WETH).approve(address(liquidMode), depositAmount);
        uint256 sharesReceived = liquidMode.deposit(depositAmount, user);
        vm.stopPrank(); // Stop prank after deposit

        // Skip 100 blocks to simulate time passing
        vm.roll(block.number + 100);

        // Get initial balances
        uint256 initialUserWETHBalance = IERC20(WETH).balanceOf(user);
        uint256 initialTotalAssets = liquidMode.totalAssets();
        uint256 initialUserShares = liquidMode.balanceOf(user);

        // Perform withdrawal
        vm.startPrank(user);
        uint256 sharesRedeemed = liquidMode.withdraw(withdrawAmount, user, user);
        vm.stopPrank();

        // Get final balances
        uint256 finalUserWETHBalance = IERC20(WETH).balanceOf(user);
        uint256 finalTotalAssets = liquidMode.totalAssets();
        uint256 finalUserShares = liquidMode.balanceOf(user);

        // Calculate the actual withdrawn amount
        uint256 actualWithdrawnAmount = finalUserWETHBalance - initialUserWETHBalance;

        // Define acceptable variance (e.g., 4%)
        uint256 acceptableVariance = withdrawAmount * 4 / 100;

        // Assertions with acceptable variance
        assertApproxEqAbs(
            actualWithdrawnAmount,
            withdrawAmount,
            acceptableVariance,
            "User should receive approximately the correct amount of WETH"
        );

        assertApproxEqAbs(
            initialTotalAssets - finalTotalAssets,
            withdrawAmount,
            acceptableVariance,
            "Total assets should decrease by approximately the withdrawn amount"
        );

        assertEq(
            initialUserShares - finalUserShares, sharesRedeemed, "User's shares should decrease by the correct amount"
        );
        assertGt(sharesRedeemed, 0, "Shares redeemed should be greater than 0");

        // Optional: Log the actual variance for informational purposes
        uint256 variancePercentage = (withdrawAmount > actualWithdrawnAmount)
            ? ((withdrawAmount - actualWithdrawnAmount) * 100) / withdrawAmount
            : ((actualWithdrawnAmount - withdrawAmount) * 100) / withdrawAmount;
        console.log("Withdrawal variance: ", variancePercentage, "%");

        // Check remaining balances in the contract
        uint256 finalContractWRSETHBalance = IERC20(WRSETH).balanceOf(address(liquidMode));
        uint256 finalContractEZETHBalance = IERC20(EZETH).balanceOf(address(liquidMode));
        console.log("Final Contract WRSETH Balance", finalContractWRSETHBalance);
        console.log("Final Contract EZETH Balance", finalContractEZETHBalance);
    }

    function testFullWithdrawOnly() public {
        uint256 depositAmount = 1 ether;

        // Setup: Deposit funds
        vm.startPrank(user);
        IERC20(WETH).approve(address(liquidMode), depositAmount);
        uint256 sharesReceived = liquidMode.deposit(depositAmount, user);
        vm.stopPrank();

        console.log("Initial shares received:", sharesReceived);
        console.log("Initial total assets:", liquidMode.totalAssets());
        console.log("Initial contract WETH balance", IERC20(WETH).balanceOf(address(liquidMode)));
        console.log("Initial contract WRSETH balance", IERC20(WRSETH).balanceOf(address(liquidMode)));
        console.log("Initial contract EZETH balance", IERC20(EZETH).balanceOf(address(liquidMode)));

        // Skip 100 blocks to simulate time passing
        vm.roll(block.number + 100);

        // Get initial balances
        uint256 initialUserWETHBalance = IERC20(WETH).balanceOf(user);
        uint256 initialTotalAssets = liquidMode.totalAssets();
        uint256 initialUserShares = liquidMode.balanceOf(user);

        console.log("Initial user WETH balance:", initialUserWETHBalance);
        console.log("Initial total assets:", initialTotalAssets);
        console.log("Initial user shares:", initialUserShares);

        // Perform full withdrawal
        vm.startPrank(user);
        uint256 assetsRedeemed = liquidMode.redeem(initialUserShares, user, user);
        vm.stopPrank();

        // Get final balances
        uint256 finalUserWETHBalance = IERC20(WETH).balanceOf(user);
        uint256 finalTotalAssets = liquidMode.totalAssets();
        uint256 finalUserShares = liquidMode.balanceOf(user);

        // Calculate the actual withdrawn amount
        uint256 actualWithdrawnAmount = finalUserWETHBalance - initialUserWETHBalance;

        console.log("Assets redeemed:", assetsRedeemed);
        console.log("Actual withdrawn amount:", actualWithdrawnAmount);
        console.log("Final total assets:", finalTotalAssets);
        console.log("Final user shares:", finalUserShares);

        // Define acceptable variance (1.5% of deposit amount to account for slippage and fees)
        uint256 acceptableVariance = depositAmount * 15 / 1000;
        uint256 acceptableVarianceForWithdraw = depositAmount * 170 / 10000;

        uint256 balWrsETH = IERC20(WRSETH).balanceOf(address(liquidMode));
        console.log("WRSETH balance", balWrsETH);
        uint256 balEZETH = IERC20(EZETH).balanceOf(address(liquidMode));
        console.log("EZETH balance", balEZETH);

        // Assertions with acceptable variance
        assertApproxEqAbs(
            actualWithdrawnAmount,
            depositAmount,
            acceptableVarianceForWithdraw,
            "User should receive approximately the full deposited amount of WETH (within 1.7%)"
        );

        assertApproxEqAbs(
            finalTotalAssets,
            0,
            acceptableVariance,
            "Total assets should be very close to zero after full withdrawal (within 1.5%)"
        );

        assertEq(finalUserShares, 0, "User should have no shares left after full withdrawal");

        assertApproxEqAbs(
            assetsRedeemed,
            actualWithdrawnAmount,
            acceptableVariance,
            "Assets redeemed should be close to actual withdrawn amount (within 1.5%)"
        );

        // Calculate and log the actual variance percentage
        uint256 variancePercentage = (depositAmount > actualWithdrawnAmount)
            ? ((depositAmount - actualWithdrawnAmount) * 10000) / depositAmount
            : ((actualWithdrawnAmount - depositAmount) * 10000) / depositAmount;
        console.log("Full withdrawal variance: ", variancePercentage, "basis points");

        // Check remaining balances in the contract
        uint256 finalContractWRSETHBalance = IERC20(WRSETH).balanceOf(address(liquidMode));
        uint256 finalContractEZETHBalance = IERC20(EZETH).balanceOf(address(liquidMode));
        console.log("Final Contract WRSETH Balance", finalContractWRSETHBalance);
        console.log("Final Contract EZETH Balance", finalContractEZETHBalance);

        // Assert that the contract balances are within acceptable limits (1.5% of deposit)
        assertLe(
            finalContractWRSETHBalance,
            acceptableVariance,
            "Contract should have less than 1.5% of deposit remaining as WRSETH"
        );
        assertLe(
            finalContractEZETHBalance,
            acceptableVariance,
            "Contract should have less than 1.5% of deposit remaining as EZETH"
        );
    }

    function testWithdrawMoreThanDeposited() public {
        uint256 depositAmount = 10 ether;
        uint256 withdrawAmount = 11 ether; // Trying to withdraw more than deposited

        // Setup: Deposit funds
        vm.startPrank(user);
        IERC20(WETH).approve(address(liquidMode), depositAmount);
        uint256 sharesReceived = liquidMode.deposit(depositAmount, user);
        vm.stopPrank();

        // Skip 100 blocks to simulate time passing
        vm.roll(block.number + 100);

        // Get initial balances
        uint256 initialUserWETHBalance = IERC20(WETH).balanceOf(user);
        uint256 initialTotalAssets = liquidMode.totalAssets();
        uint256 initialUserShares = liquidMode.balanceOf(user);

        // Attempt to withdraw more than deposited
        vm.startPrank(user);
        vm.expectRevert(); // We expect this call to revert
        liquidMode.withdraw(withdrawAmount, user, user);
        vm.stopPrank();

        // Get final balances
        uint256 finalUserWETHBalance = IERC20(WETH).balanceOf(user);
        uint256 finalTotalAssets = liquidMode.totalAssets();
        uint256 finalUserShares = liquidMode.balanceOf(user);

        // Assert that balances haven't changed
        assertEq(finalUserWETHBalance, initialUserWETHBalance, "User WETH balance should not change");
        assertEq(finalTotalAssets, initialTotalAssets, "Total assets should not change");
        assertEq(finalUserShares, initialUserShares, "User shares should not change");

        // Optional: Try to withdraw the exact amount deposited to ensure it's still possible
        vm.startPrank(user);
        uint256 withdrawnAmount = liquidMode.withdraw(depositAmount, user, user);
        vm.stopPrank();

        assertEq(withdrawnAmount, depositAmount, "User should be able to withdraw the exact amount deposited");
    }

    function testDepositWithdrawFullyThenWithdrawAgain() public {
        uint256 depositAmount = 10 ether;

        // Step 1: Deposit funds
        vm.startPrank(user);
        IERC20(WETH).approve(address(liquidMode), depositAmount);
        uint256 sharesReceived = liquidMode.deposit(depositAmount, user);
        vm.stopPrank();

        // Skip 100 blocks to simulate time passing
        vm.roll(block.number + 100);

        // Step 2: Withdraw fully
        vm.startPrank(user);
        uint256 withdrawnAmount = liquidMode.redeem(sharesReceived, user, user);
        vm.stopPrank();

        // Assert that the full amount was withdrawn (within acceptable variance)
        uint256 acceptableVariance = depositAmount * 2 / 100; // 2% variance
        assertApproxEqAbs(
            withdrawnAmount,
            depositAmount,
            acceptableVariance,
            "User should receive approximately the full deposited amount"
        );

        // Assert that user has no shares left
        assertEq(liquidMode.balanceOf(user), 0, "User should have no shares left after full withdrawal");

        // Step 3: Attempt to withdraw again
        vm.startPrank(user);
        uint256 attemptedWithdrawAmount = 1 ether; // Try to withdraw any amount

        // Expect this withdrawal to fail
        vm.expectRevert();
        liquidMode.withdraw(attemptedWithdrawAmount, user, user);
        vm.stopPrank();

        // Final checks
        assertEq(liquidMode.balanceOf(user), 0, "User should still have no shares");
        uint256 finalUserWETHBalance = IERC20(WETH).balanceOf(user);

        // Log final balances for debugging
        console.log("Final User WETH Balance:", finalUserWETHBalance);
        console.log("Final Contract Total Assets:", liquidMode.totalAssets());

        // Optional: Check that the contract's total assets are very close to zero
        assertApproxEqAbs(
            liquidMode.totalAssets(),
            0,
            acceptableVariance,
            "Contract should have negligible assets after full withdrawal"
        );
    }

    function testMultiplePartialWithdrawals() public {
        uint256 depositAmount = 4 ether;
        uint256[] memory withdrawAmounts = new uint256[](3);
        withdrawAmounts[0] = 1 ether;
        withdrawAmounts[1] = 0.2 ether;
        withdrawAmounts[2] = 0.9 ether;

        // Step 1: Deposit funds
        vm.startPrank(user);
        IERC20(WETH).approve(address(liquidMode), depositAmount);
        uint256 initialShares = liquidMode.deposit(depositAmount, user);
        vm.stopPrank();

        // Skip 100 blocks to simulate time passing
        vm.roll(block.number + 100);

        uint256 totalWithdrawn = 0;
        uint256 remainingShares = initialShares;

        // Step 2: Perform multiple withdrawals
        for (uint256 i = 0; i < withdrawAmounts.length; i++) {
            uint256 withdrawAmount = withdrawAmounts[i];

            uint256 initialUserWETHBalance = IERC20(WETH).balanceOf(user);
            uint256 initialTotalAssets = liquidMode.totalAssets();

            vm.startPrank(user);
            uint256 sharesRedeemed = liquidMode.withdraw(withdrawAmount, user, user);
            vm.stopPrank();

            totalWithdrawn += withdrawAmount;
            remainingShares -= sharesRedeemed;

            // Assert that the withdrawn amount is correct (within 2% variance)
            uint256 actualWithdrawnAmount = IERC20(WETH).balanceOf(user) - initialUserWETHBalance;
            assertApproxEqAbs(
                actualWithdrawnAmount,
                withdrawAmount,
                withdrawAmount * 2 / 100,
                string(abi.encodePacked("Withdrawal ", i + 1, " should be approximately correct"))
            );

            // Assert that total assets decreased by approximately the withdrawn amount
            uint256 newTotalAssets = liquidMode.totalAssets();
            assertApproxEqAbs(
                initialTotalAssets - newTotalAssets,
                withdrawAmount,
                withdrawAmount * 2 / 100,
                string(
                    abi.encodePacked(
                        "Total assets should decrease by approximately the withdrawn amount for withdrawal ", i + 1
                    )
                )
            );

            console.log("Withdrawal", i + 1, "amount:", withdrawAmount);
            console.log("Actual withdrawn:", actualWithdrawnAmount);
            console.log("Shares redeemed:", sharesRedeemed);
            console.log("Remaining shares:", remainingShares);
            console.log("Total assets after withdrawal:", newTotalAssets);
            console.log("---");
        }

        // Final checks
        uint256 finalUserShares = liquidMode.balanceOf(user);
        assertEq(finalUserShares, remainingShares, "Final user shares should match calculated remaining shares");

        uint256 finalTotalAssets = liquidMode.totalAssets();
        uint256 expectedRemainingAssets = depositAmount - totalWithdrawn;
        assertApproxEqAbs(
            finalTotalAssets,
            expectedRemainingAssets,
            expectedRemainingAssets * 2 / 100,
            "Final total assets should be approximately equal to expected remaining assets"
        );

        console.log("Total deposited:", depositAmount);
        console.log("Total withdrawn:", totalWithdrawn);
        console.log("Final total assets:", finalTotalAssets);
        console.log("Final user shares:", finalUserShares);
    }

    function testWithdrawWithoutDeposit() public {
        address depositor = address(1);
        address withdrawer = makeAddr("withdrawer");
        uint256 depositAmount = 5 ether;
        uint256 withdrawAmount = 1 ether;

        // Setup: Depositor deposits funds
        deal(WETH, depositor, depositAmount);
        vm.startPrank(depositor);
        IERC20(WETH).approve(address(liquidMode), depositAmount);
        liquidMode.deposit(depositAmount, depositor);
        vm.stopPrank();

        // Skip 100 blocks to simulate time passing
        vm.roll(block.number + 100);

        // Attempt withdrawal by a different user who hasn't deposited
        vm.startPrank(withdrawer);

        // Expect this withdrawal to fail
        vm.expectRevert();
        liquidMode.withdraw(withdrawAmount, withdrawer, withdrawer);

        vm.stopPrank();

        // Verify balances
        assertEq(liquidMode.balanceOf(withdrawer), 0, "Withdrawer should have no shares");
        assertEq(IERC20(WETH).balanceOf(withdrawer), 0, "Withdrawer should have no WETH");

        // Verify depositor's balance remains unchanged
        assertEq(liquidMode.balanceOf(depositor), depositAmount, "Depositor's shares should remain unchanged");

        // Verify contract's total assets
        assertEq(liquidMode.totalAssets(), depositAmount, "Contract's total assets should remain unchanged");

        console.log("Depositor shares:", liquidMode.balanceOf(depositor));
        console.log("Withdrawer shares:", liquidMode.balanceOf(withdrawer));
        console.log("Contract total assets:", liquidMode.totalAssets());
    }

    function testWithdrawOnBehalf() public {
        address depositor = makeAddr("depositor");
        address withdrawer = makeAddr("withdrawer");
        uint256 depositAmount = 5 ether;
        uint256 withdrawAmount = 1 ether;

        // Setup: Depositor deposits funds
        deal(WETH, depositor, depositAmount);
        vm.startPrank(depositor);
        IERC20(WETH).approve(address(liquidMode), depositAmount);
        liquidMode.deposit(depositAmount, depositor);

        // Depositor approves withdrawer to spend their shares
        liquidMode.approve(withdrawer, depositAmount);
        vm.stopPrank();

        // Skip 100 blocks to simulate time passing
        vm.roll(block.number + 100);

        // Initial balances
        uint256 initialDepositorBalance = IERC20(WETH).balanceOf(depositor);
        uint256 initialWithdrawerBalance = IERC20(WETH).balanceOf(withdrawer);

        // Withdrawer withdraws on behalf of depositor
        vm.startPrank(withdrawer);
        uint256 withdrawnAmount = liquidMode.withdraw(withdrawAmount, withdrawer, depositor);
        vm.stopPrank();

        // Calculate the minimum expected amount (98% of withdrawAmount due to 2% slippage tolerance)
        uint256 minExpectedAmount = withdrawAmount * 98 / 100;

        // Verify balances
        uint256 actualWithdrawnAmount = IERC20(WETH).balanceOf(withdrawer) - initialWithdrawerBalance;
        assertGe(
            actualWithdrawnAmount, minExpectedAmount, "Withdrawn amount should be at least 98% of requested amount"
        );
        assertLe(actualWithdrawnAmount, withdrawAmount, "Withdrawn amount should not exceed requested amount");

        assertApproxEqAbs(
            liquidMode.balanceOf(depositor),
            depositAmount - withdrawnAmount,
            withdrawAmount * 2 / 100,
            "Depositor's shares should decrease by approximately the withdrawn amount"
        );
        assertEq(liquidMode.balanceOf(withdrawer), 0, "Withdrawer should have no shares");

        // Verify contract's total assets
        assertApproxEqAbs(
            liquidMode.totalAssets(),
            depositAmount - withdrawnAmount,
            withdrawAmount * 2 / 100,
            "Contract's total assets should decrease by approximately the withdrawn amount"
        );

        console.log("Depositor shares:", liquidMode.balanceOf(depositor));
        console.log("Withdrawer WETH balance:", IERC20(WETH).balanceOf(withdrawer));
        console.log("Contract total assets:", liquidMode.totalAssets());
    }

    function testWithdrawMoreThanApproved() public {
        address depositor = makeAddr("depositor");
        address withdrawer = makeAddr("withdrawer");
        uint256 depositAmount = 5 ether;
        uint256 approvedAmount = 2 ether;
        uint256 withdrawAmount = 3 ether; // More than approved

        // Setup: Depositor deposits funds
        deal(WETH, depositor, depositAmount);
        vm.startPrank(depositor);
        IERC20(WETH).approve(address(liquidMode), depositAmount);
        liquidMode.deposit(depositAmount, depositor);

        // Depositor approves withdrawer to spend a limited amount of their shares
        liquidMode.approve(withdrawer, approvedAmount);
        vm.stopPrank();

        // Skip 100 blocks to simulate time passing
        vm.roll(block.number + 100);

        // Initial balances and state
        uint256 initialDepositorShares = liquidMode.balanceOf(depositor);
        uint256 initialWithdrawerBalance = IERC20(WETH).balanceOf(withdrawer);
        uint256 initialTotalAssets = liquidMode.totalAssets();

        // Attempt to withdraw more than approved
        vm.startPrank(withdrawer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, withdrawer, approvedAmount, withdrawAmount
            )
        );
        liquidMode.withdraw(withdrawAmount, withdrawer, depositor);
        vm.stopPrank();

        // Verify that balances and state remain unchanged
        assertEq(liquidMode.balanceOf(depositor), initialDepositorShares, "Depositor's shares should remain unchanged");
        assertEq(
            IERC20(WETH).balanceOf(withdrawer), initialWithdrawerBalance, "Withdrawer's balance should remain unchanged"
        );
        assertEq(liquidMode.totalAssets(), initialTotalAssets, "Contract's total assets should remain unchanged");

        // Verify that the approved amount can still be withdrawn
        vm.startPrank(withdrawer);
        uint256 withdrawnAmount = liquidMode.withdraw(approvedAmount, withdrawer, depositor);
        vm.stopPrank();

        // Calculate the minimum expected amount (98% of approvedAmount due to 2% slippage tolerance)
        uint256 minExpectedAmount = approvedAmount * 98 / 100;

        // Verify the successful withdrawal of the approved amount
        uint256 actualWithdrawnAmount = IERC20(WETH).balanceOf(withdrawer) - initialWithdrawerBalance;
        assertGe(actualWithdrawnAmount, minExpectedAmount, "Withdrawn amount should be at least 98% of approved amount");
        assertLe(actualWithdrawnAmount, approvedAmount, "Withdrawn amount should not exceed approved amount");

        console.log("Depositor shares after failed withdrawal:", liquidMode.balanceOf(depositor));
        console.log("Withdrawer WETH balance after failed withdrawal:", IERC20(WETH).balanceOf(withdrawer));
        console.log("Contract total assets after failed withdrawal:", liquidMode.totalAssets());
        console.log("Actual withdrawn amount (successful withdrawal):", actualWithdrawnAmount);
    }

    function testWithdrawWhenPaused() public {
        uint256 depositAmount = 1 ether;

        // Setup: Deposit funds
        vm.startPrank(user);
        IERC20(WETH).approve(address(liquidMode), depositAmount);
        liquidMode.deposit(depositAmount, user);
        vm.stopPrank();

        // Pause the contract
        vm.prank(liquidMode.owner());
        liquidMode.pause();

        // Attempt to withdraw when paused
        vm.startPrank(user);
        uint256 withdrawAmount = 0.5 ether;

        // Update the expected error message
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        liquidMode.withdraw(withdrawAmount, user, user);

        vm.stopPrank();

        // Verify that balances remain unchanged
        assertEq(liquidMode.balanceOf(user), depositAmount, "User balance should remain unchanged");
        assertEq(liquidMode.totalAssets(), depositAmount, "Total assets should remain unchanged");

        // Unpause the contract
        vm.prank(liquidMode.owner());
        liquidMode.unpause();

        // Verify that withdrawal succeeds after unpausing
        vm.startPrank(user);
        uint256 sharesRedeemed = liquidMode.withdraw(withdrawAmount, user, user);
        vm.stopPrank();

        assertGt(sharesRedeemed, 0, "Shares should be redeemed after unpausing");
        assertEq(
            liquidMode.balanceOf(user), depositAmount - sharesRedeemed, "User balance should decrease after withdrawal"
        );
        assertLt(liquidMode.totalAssets(), depositAmount, "Total assets should decrease after withdrawal");

        console.log("Initial deposit:", depositAmount);
        console.log("Withdrawal amount:", withdrawAmount);
        console.log("Shares redeemed:", sharesRedeemed);
        console.log("Remaining user balance:", liquidMode.balanceOf(user));
        console.log("Remaining total assets:", liquidMode.totalAssets());
    }

    function testWithdrawZeroAmount() public {
        uint256 depositAmount = 1 ether;

        // Setup: Deposit funds
        vm.startPrank(user);
        IERC20(WETH).approve(address(liquidMode), depositAmount);
        liquidMode.deposit(depositAmount, user);
        vm.stopPrank();

        // Get initial balances
        uint256 initialUserWETHBalance = IERC20(WETH).balanceOf(user);
        uint256 initialUserShares = liquidMode.balanceOf(user);
        uint256 initialTotalAssets = liquidMode.totalAssets();

        console.log("Initial user WETH balance:", initialUserWETHBalance);
        console.log("Initial user shares:", initialUserShares);
        console.log("Initial total assets:", initialTotalAssets);

        // Attempt to withdraw zero amount
        vm.startPrank(user);
        vm.expectRevert(); // Assuming the contract reverts with this message for zero withdrawals
        liquidMode.withdraw(0, user, user);
        vm.stopPrank();

        // Verify that balances remain unchanged
        assertEq(IERC20(WETH).balanceOf(user), initialUserWETHBalance, "User WETH balance should remain unchanged");
        assertEq(liquidMode.balanceOf(user), initialUserShares, "User shares should remain unchanged");
        assertEq(liquidMode.totalAssets(), initialTotalAssets, "Total assets should remain unchanged");

        console.log("Final user WETH balance:", IERC20(WETH).balanceOf(user));
        console.log("Final user shares:", liquidMode.balanceOf(user));
        console.log("Final total assets:", liquidMode.totalAssets());
    }

    function testFuzzWithdraw(uint256 withdrawAmount) public {
        uint256 depositAmount = 10 ether;

        // Limit the withdraw amount between 1 wei and the deposit amount
        withdrawAmount = bound(withdrawAmount, 1 gwei, depositAmount);

        // Setup: Deposit funds
        vm.startPrank(user);
        IERC20(WETH).approve(address(liquidMode), depositAmount);
        liquidMode.deposit(depositAmount, user);
        vm.stopPrank();

        // Skip some blocks to simulate time passing
        vm.roll(block.number + 100);

        // Get initial balances
        uint256 initialUserWETHBalance = IERC20(WETH).balanceOf(user);
        uint256 initialUserShares = liquidMode.balanceOf(user);
        uint256 initialTotalAssets = liquidMode.totalAssets();

        console.log("Initial user WETH balance:", initialUserWETHBalance);
        console.log("Initial user shares:", initialUserShares);
        console.log("Initial total assets:", initialTotalAssets);
        console.log("Attempting to withdraw:", withdrawAmount);
        console.log("Initial contract WETH balance:", IERC20(WETH).balanceOf(address(liquidMode)));

        // Attempt to withdraw
        vm.startPrank(user);
        uint256 sharesBurned = liquidMode.withdraw(withdrawAmount, user, user);

        // Verify withdrawal
        uint256 finalUserWETHBalance = IERC20(WETH).balanceOf(user);
        uint256 finalUserShares = liquidMode.balanceOf(user);
        uint256 finalTotalAssets = liquidMode.totalAssets();

        console.log("Shares burned:", sharesBurned);
        console.log("Final user WETH balance:", finalUserWETHBalance);
        console.log("Final user shares:", finalUserShares);
        console.log("Final total assets:", finalTotalAssets);

        // Assert that the user received WETH
        assertGt(finalUserWETHBalance, initialUserWETHBalance, "User should have received WETH");

        // Assert that shares were burned
        assertLt(finalUserShares, initialUserShares, "User shares should have decreased");

        // Assert that total assets decreased
        assertLt(finalTotalAssets, initialTotalAssets, "Total assets should have decreased");

        // Check for reasonable bounds (allowing for some slippage)
        uint256 expectedMinimumReceived = withdrawAmount * 98 / 100; // 2% slippage tolerance
        assertGe(finalUserWETHBalance - initialUserWETHBalance, expectedMinimumReceived, "Received amount too low");

        // Ensure we didn't withdraw more than requested
        assertLe(finalUserWETHBalance - initialUserWETHBalance, withdrawAmount, "Received more than requested");

        vm.stopPrank();
    }

    function testWithdrawWithYield() public {
        uint256 initialBalanceWETH = IERC20(WETH).balanceOf(user);
        uint256 depositAmount = 10 ether;
        uint256 yieldAmount = 1 ether; // 10% yield

        // Setup: Deposit funds
        vm.startPrank(user);
        IERC20(WETH).approve(address(liquidMode), depositAmount);
        uint256 sharesReceived = liquidMode.deposit(depositAmount, user);
        vm.stopPrank();

        console.log("Initial shares received:", sharesReceived);
        console.log("Initial total assets:", liquidMode.totalAssets());
        console.log("Initial user WETH balance:", IERC20(WETH).balanceOf(user));
        console.log("initial contract WETH balance", IERC20(WETH).balanceOf(address(liquidMode)));
        console.log("Initial ezETH Balance of contract:", IERC20(liquidMode.token0()).balanceOf(address(liquidMode)));
        console.log("Initial wrsETH Balance of contract:", IERC20(liquidMode.token1()).balanceOf(address(liquidMode)));
        (, uint128 initialLiquidity, uint256 initialAmount0, uint256 initialAmount1) = liquidMode.getKimPosition();
        console.log("Initial liquidity of contract:", initialLiquidity);
        console.log("Initial amount0 of contract:", initialAmount0);
        console.log("Initial amount1 of contract:", initialAmount1);

        // Record initial state
        uint256 initialTotalAssets = liquidMode.totalAssets();

        // Simulate yield accrual
        vm.roll(block.number + 1000); // Simulate time passing

        // Get price feeds
        (int224 _ezETHPrice,) = liquidMode.readDataFeed(EZETH_ETH_PROXY);
        uint256 ezETHPrice = uint256(uint224(_ezETHPrice));
        (int224 _wrsETHPrice,) = liquidMode.readDataFeed(WRSETH_ETH_PROXY);
        uint256 wrsETHPrice = uint256(uint224(_wrsETHPrice));

        // Convert yield to ETH equivalent
        uint256 yieldAmountInETH = ((yieldAmount / 2) * ezETHPrice) / 1e18 + ((yieldAmount / 2) * wrsETHPrice) / 1e18;

        // Mock the collect function to simulate yield
        vm.mockCall(
            address(liquidMode.poolAddress()),
            abi.encodeWithSelector(IAlgebraPoolActions.collect.selector),
            abi.encode(yieldAmount / 2, yieldAmount / 2) // Split yield between ezETH and wrsETH
        );

        // Transfer the mocked yield amounts to the LiquidMode contract
        deal(liquidMode.token0(), address(liquidMode), yieldAmount / 2);
        deal(liquidMode.token1(), address(liquidMode), yieldAmount / 2);

        // Call harvestReinvestAndReport to process the yield
        vm.prank(liquidMode.owner());
        liquidMode.harvestReinvestAndReport();

        console.log("After harvest total assets:", liquidMode.totalAssets());
        uint256 balEzETH = IERC20(liquidMode.token0()).balanceOf(address(liquidMode));
        uint256 balWrsETH = IERC20(liquidMode.token1()).balanceOf(address(liquidMode));
        console.log("After harvest EZETH balance:", balEzETH);
        console.log("After harvest WRSETH balance:", balWrsETH);
        (, uint128 liquidityAfterHarvest, uint256 amount0AfterHarvest, uint256 amount1AfterHarvest) =
            liquidMode.getKimPosition();
        console.log("Liquidity after harvest:", liquidityAfterHarvest);
        console.log("Amount0 after harvest:", amount0AfterHarvest);
        console.log("Amount1 after harvest:", amount1AfterHarvest);

        // Verify total assets increased
        uint256 newTotalAssets = liquidMode.totalAssets();
        uint256 actualIncrease = newTotalAssets - initialTotalAssets;

        // Calculate the expected increase, accounting for strategist fee
        uint256 expectedIncrease = (yieldAmountInETH * 95) / 100; // 95% of yield (5% goes to strategist)
        assertApproxEqRel(
            actualIncrease, expectedIncrease, 0.02e18, "Actual increase should be close to expected increase"
        );

        uint256 balStrategistToken0 = IERC20(liquidMode.token0()).balanceOf(address(liquidMode.strategist()));
        uint256 balStrategistToken1 = IERC20(liquidMode.token1()).balanceOf(address(liquidMode.strategist()));
        console.log("Strategist token0 balance:", balStrategistToken0);
        console.log("Strategist token1 balance:", balStrategistToken1);

        vm.roll(block.number + 10);
        vm.clearMockedCalls();

        // Attempt full redemption
        vm.startPrank(user);
        uint256 withdrawnAmount = liquidMode.redeem(liquidMode.balanceOf(user), user, user);
        vm.stopPrank();

        uint256 expectedFinalBalance = initialBalanceWETH - depositAmount + withdrawnAmount;

        // Verify user's balance
        assertApproxEqRel(
            IERC20(WETH).balanceOf(user), expectedFinalBalance, 0.02e18, "User balance should be close to total assets"
        );

        // Verify withdrawn amount
        assertApproxEqRel(withdrawnAmount, newTotalAssets, 0.02e18, "Withdrawn amount should be close to total assets");

        // Verify contract state after withdrawal
        assertEq(liquidMode.balanceOf(user), 0, "User should have no shares after full withdrawal");

        console.log("Initial deposit:", depositAmount);
        console.log("Yield amount in ETH:", yieldAmountInETH);
        console.log("New total assets:", newTotalAssets);
        console.log("Withdrawn amount:", withdrawnAmount);
        console.log("Final user balance:", IERC20(WETH).balanceOf(user));
        console.log("Remaining total assets:", liquidMode.totalAssets());
    }

    function testSlotValues() public {
        uint256 depositAmount = 10 ether;

        // Setup: Deposit funds
        vm.startPrank(user);
        IERC20(WETH).approve(address(liquidMode), depositAmount);
        liquidMode.deposit(depositAmount, user);
        vm.stopPrank();

        // Check values in slots 0 to 15
        for (uint256 i = 0; i < 20; i++) {
            bytes32 slotValue = vm.load(address(liquidMode), bytes32(i));
            console.log("Slot", i, ":", uint256(slotValue));
        }

        // Check the current totalAssets value
        uint256 totalAssets = liquidMode.totalAssets();
        console.log("Total Assets reported by contract:", totalAssets);

        // Try to identify which slot matches totalAssets
        for (uint256 i = 0; i < 16; i++) {
            bytes32 slotValue = vm.load(address(liquidMode), bytes32(i));
            if (uint256(slotValue) == totalAssets) {
                console.log("Slot matching totalAssets:", i);
                break;
            }
        }
    }

    function testHarvestReinvestAndReports() public {
        uint256 depositAmount = 10 ether;
        uint256 feeAmount0 = 1 ether; // 1 ezETH in fees
        uint256 feeAmount1 = 1.5 ether; // 1.5 wrsETH in fees

        (int224 _ezETHPrice,) = liquidMode.readDataFeed(EZETH_ETH_PROXY);
        uint256 ezETHPrice = uint256(uint224(_ezETHPrice));
        (int224 _wrsETHPrice,) = liquidMode.readDataFeed(WRSETH_ETH_PROXY);
        uint256 wrsETHPrice = uint256(uint224(_wrsETHPrice));

        //convert to ETH
        uint256 feeAmount0InETH = (1.25 ether * ezETHPrice) / 10 ** 18;
        uint256 feeAmount1InETH = (1.25 ether * wrsETHPrice) / 10 ** 18;

        // Setup initial deposit
        vm.startPrank(user);
        IERC20(WETH).approve(address(liquidMode), depositAmount);
        liquidMode.deposit(depositAmount, user);
        vm.stopPrank();

        assertEq(liquidMode.totalAssets(), depositAmount, "Initial deposit should match total assets");

        console.log("bal of WETH of Contract after deposit", IERC20(WETH).balanceOf(address(liquidMode)));
        console.log(
            "bal of ezETH of Contract after deposit", IERC20(liquidMode.token0()).balanceOf(address(liquidMode))
        );
        console.log(
            "bal of wrsETH of Contract after deposit", IERC20(liquidMode.token1()).balanceOf(address(liquidMode))
        );
        (, uint128 liquidity, uint256 amount0, uint256 amount1) = liquidMode.getKimPosition();
        console.log("Liquidity of contract after deposit:", liquidity);
        console.log("amount0 of contract after deposit:", amount0);
        console.log("amount1 of contract after deposit:", amount1);

        // Mock the collect function
        vm.mockCall(
            address(liquidMode.poolAddress()),
            abi.encodeWithSelector(IAlgebraPoolActions.collect.selector),
            abi.encode(feeAmount0, feeAmount1)
        );

        // Transfer the mocked fee amounts to the LiquidMode contract
        deal(liquidMode.token0(), address(liquidMode), feeAmount0);
        deal(liquidMode.token1(), address(liquidMode), feeAmount1);

        // Call harvestReinvestAndReport
        vm.prank(liquidMode.owner());
        liquidMode.harvestReinvestAndReport();

        console.log("feeAmount0InETH", feeAmount0InETH);
        console.log("feeAmount1InETH", feeAmount1InETH);
        // Assertions
        uint256 expectedMinIncrease = feeAmount0InETH + feeAmount1InETH; // 2% slippage tolerance
        console.log("expectedMinIncrease", expectedMinIncrease);
        uint256 strategistFee = expectedMinIncrease * 5 / 100;
        console.log("strategistFee", strategistFee);
        uint256 netIncrease = expectedMinIncrease - strategistFee;
        console.log("netIncrease", netIncrease);
        uint256 balEzETH = IERC20(liquidMode.token0()).balanceOf(address(liquidMode));
        uint256 balWrsETH = IERC20(liquidMode.token1()).balanceOf(address(liquidMode));
        console.log("balEzETH", balEzETH);
        console.log("balWrsETH", balWrsETH);
        uint256 actualIncrease = liquidMode.totalAssets() - depositAmount;
        assertApproxEqRel(
            actualIncrease, netIncrease, 0.02e18, "Total assets should have increased by at least 98% of collected fees"
        );

        // uint256 accumulatedFee = liquidMode.accumulatedStrategistFee();
        // assertGt(accumulatedFee, 0, "Accumulated strategist fee should be non-zero");
        // assertApproxEqRel(
        //     accumulatedFee, strategistFee, 0.02e18, "Accumulated strategist fee should not exceed 2% of collected fees"
        // );
    }

    function testHarvestReinvestAndReportOnlyEzETHFees() public {
        uint256 depositAmount = 10 ether;
        uint256 feeAmount0 = 1 ether; // 1 ezETH in fees
        uint256 feeAmount1 = 0; // No wrsETH fees

        (int224 _ezETHPrice,) = liquidMode.readDataFeed(EZETH_ETH_PROXY);
        uint256 ezETHPrice = uint256(uint224(_ezETHPrice));

        // Convert to ETH
        uint256 feeAmount0InETH = (feeAmount0 * ezETHPrice) / 10 ** 18;

        // Setup initial deposit
        vm.startPrank(user);
        IERC20(WETH).approve(address(liquidMode), depositAmount);
        liquidMode.deposit(depositAmount, user);
        vm.stopPrank();

        assertEq(liquidMode.totalAssets(), depositAmount, "Initial deposit should match total assets");

        // Mock the collect function
        vm.mockCall(
            address(liquidMode.poolAddress()),
            abi.encodeWithSelector(IAlgebraPoolActions.collect.selector),
            abi.encode(feeAmount0, feeAmount1)
        );

        // Transfer the mocked fee amount to the LiquidMode contract
        deal(liquidMode.token0(), address(liquidMode), feeAmount0);

        // Call harvestReinvestAndReport
        vm.prank(liquidMode.owner());
        liquidMode.harvestReinvestAndReport();

        console.log("feeAmount0InETH", feeAmount0InETH);

        // Assertions
        uint256 expectedMinIncrease = feeAmount0InETH;
        console.log("expectedMinIncrease", expectedMinIncrease);
        uint256 strategistFee = expectedMinIncrease * 5 / 100;
        console.log("strategistFee", strategistFee);
        uint256 netIncrease = expectedMinIncrease - strategistFee;
        console.log("netIncrease", netIncrease);
        uint256 actualIncrease = liquidMode.totalAssets() - depositAmount;
        assertApproxEqRel(
            actualIncrease, netIncrease, 0.02e18, "Total assets should have increased by at least 98% of collected fees"
        );

        // uint256 accumulatedFee = liquidMode.accumulatedStrategistFee();
        // assertGt(accumulatedFee, 0, "Accumulated strategist fee should be non-zero");
        // assertApproxEqRel(
        //     accumulatedFee,
        //     strategistFee,
        //     0.02e18,
        //     "Accumulated strategist fee should be close to 20% of collected fees"
        // );
    }

    function testHarvestReinvestAndReportNoFees() public {
        uint256 depositAmount = 10 ether;
        uint256 feeAmount0 = 0; // No ezETH fees
        uint256 feeAmount1 = 0; // No wrsETH fees

        // Setup initial deposit
        vm.startPrank(user);
        IERC20(WETH).approve(address(liquidMode), depositAmount);
        liquidMode.deposit(depositAmount, user);
        vm.stopPrank();

        assertEq(liquidMode.totalAssets(), depositAmount, "Initial deposit should match total assets");

        // Mock the collect function
        vm.mockCall(
            address(liquidMode.poolAddress()),
            abi.encodeWithSelector(IAlgebraPoolActions.collect.selector),
            abi.encode(feeAmount0, feeAmount1)
        );

        // Call harvestReinvestAndReport
        vm.prank(liquidMode.owner());
        liquidMode.harvestReinvestAndReport();

        // Assertions
        uint256 actualIncrease = liquidMode.totalAssets() - depositAmount;
        assertEq(actualIncrease, 0, "Total assets should not have increased");

        // uint256 accumulatedFee = liquidMode.accumulatedStrategistFee();
        // assertEq(accumulatedFee, 0, "Accumulated strategist fee should be zero");
    }

    // function testPerformMaintenance() public {
    //     // Setup: Deposit some funds
    //     uint256 depositAmount = 10 ether;

    //     // Deposit funds
    //     vm.startPrank(user);
    //     IERC20(WETH).approve(address(liquidMode), depositAmount);
    //     liquidMode.deposit(depositAmount, user);
    //     vm.stopPrank();

    //     // Simulate some time passing and operations occurring
    //     vm.roll(block.number + 1000);

    //     // Record initial balances
    //     uint256 initialWETHBalance = IERC20(WETH).balanceOf(address(liquidMode));
    //     uint256 initialEzETHBalance = IERC20(liquidMode.EZETH()).balanceOf(address(liquidMode));
    //     uint256 initialWrsETHBalance = IERC20(liquidMode.WRSETH()).balanceOf(address(liquidMode));
    //     (, uint128 initialLiquidity,,) = liquidMode.getKimPosition();

    //     console.log("Initial WETH balance:", initialWETHBalance);
    //     console.log("Initial ezETH balance:", initialEzETHBalance);
    //     console.log("Initial wrsETH balance:", initialWrsETHBalance);
    //     console.log("Initial liquidity:", initialLiquidity);
    //     // Record initial total assets
    //     uint256 initialTotalAssets = liquidMode.totalAssets();

    //     // Perform maintenance
    //     vm.prank(liquidMode.owner());
    //     liquidMode.performMaintenance();

    //     // Check final balances and total assets
    //     uint256 finalWETHBalance = IERC20(WETH).balanceOf(address(liquidMode));
    //     uint256 finalEzETHBalance = IERC20(liquidMode.EZETH()).balanceOf(address(liquidMode));
    //     uint256 finalWrsETHBalance = IERC20(liquidMode.WRSETH()).balanceOf(address(liquidMode));
    //     uint256 finalTotalAssets = liquidMode.totalAssets();
    //     (, uint128 finalLiquidity,,) = liquidMode.getKimPosition();

    //     // Assert WETH was fully converted if there was any
    //     assertEq(finalWETHBalance, 0, "All WETH should be converted");

    //     // Check if assets are balanced
    //     (int224 _ezETHPrice,) = liquidMode.readDataFeed(EZETH_ETH_PROXY);
    //     uint256 ezETHPrice = uint256(uint224(_ezETHPrice));
    //     (int224 _wrsETHPrice,) = liquidMode.readDataFeed(WRSETH_ETH_PROXY);
    //     uint256 wrsETHPrice = uint256(uint224(_wrsETHPrice));

    //     uint256 ezETHValueInETH = (finalEzETHBalance * ezETHPrice) / 1e18;
    //     uint256 wrsETHValueInETH = (finalWrsETHBalance * wrsETHPrice) / 1e18;

    //     // assertApproxEqRel(ezETHValueInETH, wrsETHValueInETH, 0.01e18, "ezETH and wrsETH values should be balanced");

    //     // Check if liquidity was added to KIM position
    //     (uint256 tokenId,,,) = liquidMode.getKimPosition();
    //     assertGt(tokenId, 0, "KIM position should be created or updated");
    //     assertGt(finalLiquidity, initialLiquidity, "Liquidity should be added to KIM position");

    //     // Log results
    //     console.log("Initial total assets:", initialTotalAssets);
    //     console.log("Final WETH balance:", finalWETHBalance);
    //     console.log("Final ezETH balance:", finalEzETHBalance);
    //     console.log("Final wrsETH balance:", finalWrsETHBalance);
    //     console.log("Final total assets:", finalTotalAssets);

    //     // Assert that the total assets have not decreased
    //     assertGe(finalTotalAssets, initialTotalAssets, "Total assets should not decrease after maintenance");
    // }

    // function testPerformMaintenanceWithWETH() public {
    //     // Setup: Deposit some funds and add extra WETH
    //     uint256 depositAmount = 10 ether;
    //     uint256 extraWETH = 0.5 ether;

    //     // Deposit funds
    //     vm.startPrank(user);
    //     IERC20(WETH).approve(address(liquidMode), depositAmount);
    //     liquidMode.deposit(depositAmount, user);
    //     vm.stopPrank();

    //     // Deal extra WETH directly to the contract
    //     deal(address(WETH), address(liquidMode), extraWETH);

    //     // Record initial state
    //     uint256 initialWETHBalance = IERC20(WETH).balanceOf(address(liquidMode));
    //     uint256 initialEzETHBalance = IERC20(liquidMode.EZETH()).balanceOf(address(liquidMode));
    //     uint256 initialWrsETHBalance = IERC20(liquidMode.WRSETH()).balanceOf(address(liquidMode));
    //     (, uint128 initialLiquidity,,) = liquidMode.getKimPosition();
    //     uint256 initialTotalAssets = liquidMode.totalAssets();

    //     console.log("Initial WETH balance:", initialWETHBalantestDepositUnauthorizedTokence);
    //     console.log("Initial ezETH balance:", initialEzETHBalance);
    //     console.log("Initial wrsETH balance:", initialWrsETHBalance);
    //     console.log("Initial liquidity:", initialLiquidity);
    //     console.log("Initial total assets:", initialTotalAssets);

    //     // Perform maintenance
    //     vm.prank(liquidMode.owner());
    //     liquidMode.performMaintenance();

    //     // Check final state
    //     uint256 finalWETHBalance = IERC20(WETH).balanceOf(address(liquidMode));
    //     (, uint128 finalLiquidity,,) = liquidMode.getKimPosition();
    //     uint256 finalTotalAssets = liquidMode.totalAssets();

    //     // Assertions
    //     assertEq(finalWETHBalance, 0, "All WETH should be converted");
    //     assertGt(finalLiquidity, initialLiquidity, "Liquidity should increase");
    //     assertGe(finalTotalAssets, initialTotalAssets, "Total assets should not decrease");

    //     // Log final state
    //     console.log("Final WETH balance:", finalWETHBalance);
    //     console.log("Final total assets:", finalTotalAssets);
    // }

    // function testPerformMaintenanceWithExtraEzETH() public {
    //     // Setup: Deposit some funds and add extra ezETH
    //     uint256 depositAmount = 10 ether;
    //     uint256 extraEzETH = 0.5 ether;

    //     // Deposit funds
    //     vm.startPrank(user);
    //     IERC20(WETH).approve(address(liquidMode), depositAmount);
    //     liquidMode.deposit(depositAmount, user);
    //     vm.stopPrank();

    //     // Deal extra ezETH directly to the contract
    //     deal(liquidMode.EZETH(), address(liquidMode), extraEzETH);

    //     // Record initial state
    //     uint256 initialWETHBalance = IERC20(WETH).balanceOf(address(liquidMode));
    //     uint256 initialEzETHBalance = IERC20(liquidMode.EZETH()).balanceOf(address(liquidMode));
    //     uint256 initialWrsETHBalance = IERC20(liquidMode.WRSETH()).balanceOf(address(liquidMode));
    //     (, uint128 initialLiquidity,,) = liquidMode.getKimPosition();
    //     uint256 initialTotalAssets = liquidMode.totalAssets();

    //     console.log("Initial WETH balance:", initialWETHBalance);
    //     console.log("Initial ezETH balance:", initialEzETHBalance);
    //     console.log("Initial wrsETH balance:", initialWrsETHBalance);
    //     console.log("Initial liquidity:", initialLiquidity);
    //     console.log("Initial total assets:", initialTotalAssets);

    //     // Perform maintenance
    //     vm.prank(liquidMode.owner());
    //     liquidMode.performMaintenance();

    //     // Check final state
    //     uint256 finalWETHBalance = IERC20(WETH).balanceOf(address(liquidMode));
    //     uint256 finalEzETHBalance = IERC20(liquidMode.EZETH()).balanceOf(address(liquidMode));
    //     uint256 finalWrsETHBalance = IERC20(liquidMode.WRSETH()).balanceOf(address(liquidMode));
    //     (, uint128 finalLiquidity,,) = liquidMode.getKimPosition();
    //     uint256 finalTotalAssets = liquidMode.totalAssets();

    //     // Assertions
    //     assertEq(finalWETHBalance, 0, "All WETH should be converted");
    //     assertLt(finalEzETHBalance, initialEzETHBalance, "ezETH balance should decrease");
    //     assertLt(finalWrsETHBalance, initialWrsETHBalance, "wrsETH balance should decrease");
    //     assertGt(finalLiquidity, initialLiquidity, "Liquidity should increase");
    //     assertGe(finalTotalAssets, initialTotalAssets, "Total assets should not decrease");

    //     // Log final state
    //     console.log("Final WETH balance:", finalWETHBalance);
    //     console.log("Final ezETH balance:", finalEzETHBalance);
    //     console.log("Final wrsETH balance:", finalWrsETHBalance);
    //     console.log("Final liquidity:", finalLiquidity);
    //     console.log("Final total assets:", finalTotalAssets);
    // }

    // function testClaimStrategistFees() public {
    //     // Setup: Deposit funds and generate some fees
    //     uint256 depositAmount = 100 ether;
    //     uint256 yieldAmount = 10 ether; // 10% yield

    //     // Deposit funds
    //     vm.startPrank(user);
    //     IERC20(WETH).approve(address(liquidMode), depositAmount);
    //     liquidMode.deposit(depositAmount, user);
    //     vm.stopPrank();

    //     // Simulate yield generation
    //     deal(liquidMode.EZETH(), address(liquidMode), yieldAmount / 2);
    //     deal(liquidMode.WRSETH(), address(liquidMode), yieldAmount / 2);

    //     vm.mockCall(
    //         address(liquidMode.poolAddress()),
    //         abi.encodeWithSelector(IAlgebraPoolActions.collect.selector),
    //         abi.encode(yieldAmount / 2, yieldAmount / 2)
    //     );

    //     // Harvest and reinvest to generate strategist fees
    //     vm.prank(liquidMode.owner());
    //     liquidMode.harvestReinvestAndReport();

    //     // Record initial state
    //     uint256 initialStrategistBalance = IERC20(WETH).balanceOf(liquidMode.strategist());
    //     uint256 initialAccumulatedFees = liquidMode.accumulatedStrategistFee();

    //     console.log("Initial strategist balance:", initialStrategistBalance);
    //     console.log("Initial accumulated fees:", initialAccumulatedFees);

    //     vm.clearMockedCalls();

    //     // Attempt to claim half of the accumulated fees
    //     uint256 claimAmount = initialAccumulatedFees / 2;
    //     vm.prank(liquidMode.strategist());
    //     liquidMode.claimStrategistFees(claimAmount);

    //     // Check final state
    //     uint256 finalStrategistBalance = IERC20(WETH).balanceOf(liquidMode.strategist());
    //     uint256 finalAccumulatedFees = liquidMode.accumulatedStrategistFee();

    //     // Assertions
    //     assertApproxEqRel(
    //         finalStrategistBalance,
    //         initialStrategistBalance + claimAmount,
    //         0.02e18,
    //         "Strategist balance should increase by claimed amount"
    //     );
    //     assertEq(
    //         finalAccumulatedFees,
    //         initialAccumulatedFees - claimAmount,
    //         "Accumulated fees should decrease by claimed amount"
    //     );

    //     // Log final state
    //     console.log("Final strategist balance:", finalStrategistBalance);
    //     console.log("Final accumulated fees:", finalAccumulatedFees);
    // }

    // function testClaimStrategistFeesMoreThanAvailable() public {
    //     // Setup: Deposit some funds and generate fees
    //     uint256 depositAmount = 100 ether;
    //     uint256 yieldAmount = 10 ether; // 10% yield

    //     // Deposit funds
    //     vm.startPrank(user);
    //     IERC20(WETH).approve(address(liquidMode), depositAmount);
    //     liquidMode.deposit(depositAmount, user);
    //     vm.stopPrank();

    //     // Simulate yield generation
    //     deal(liquidMode.EZETH(), address(liquidMode), yieldAmount / 2);
    //     deal(liquidMode.WRSETH(), address(liquidMode), yieldAmount / 2);

    //     vm.mockCall(
    //         address(liquidMode.poolAddress()),
    //         abi.encodeWithSelector(IAlgebraPoolActions.collect.selector),
    //         abi.encode(yieldAmount / 2, yieldAmount / 2)
    //     );

    //     // Harvest and reinvest to generate strategist fees
    //     vm.prank(liquidMode.owner());
    //     liquidMode.harvestReinvestAndReport();

    //     // Record initial state
    //     uint256 initialStrategistBalance = IERC20(WETH).balanceOf(liquidMode.strategist());
    //     uint256 initialAccumulatedFees = liquidMode.accumulatedStrategistFee();

    //     console.log("Initial strategist balance:", initialStrategistBalance);
    //     console.log("Initial accumulated fees:", initialAccumulatedFees);

    //     vm.clearMockedCalls();
    //     // Attempt to claim more than the accumulated fees
    //     uint256 excessiveClaimAmount = initialAccumulatedFees + 1 ether;
    //     console.log("excessiveClaimAmount", excessiveClaimAmount);
    //     console.log("currentAccumulatedFee", liquidMode.accumulatedStrategistFee());

    //     vm.prank(liquidMode.strategist());
    //     vm.expectRevert("Insufficient fees to claim");
    //     liquidMode.claimStrategistFees(excessiveClaimAmount);

    //     // Verify that the state hasn't changed
    //     uint256 finalStrategistBalance = IERC20(WETH).balanceOf(liquidMode.strategist());
    //     uint256 finalAccumulatedFees = liquidMode.accumulatedStrategistFee();

    //     assertEq(finalStrategistBalance, initialStrategistBalance, "Strategist balance should not change");
    //     assertEq(finalAccumulatedFees, initialAccumulatedFees, "Accumulated fees should not change");

    //     console.log("Final strategist balance:", finalStrategistBalance);
    //     console.log("Final accumulated fees:", finalAccumulatedFees);
    // }

    // function testNonStrategistCannotClaimFees() public {
    //     // Setup: Deposit some funds and generate fees
    //     uint256 depositAmount = 100 ether;
    //     uint256 yieldAmount = 10 ether; // 10% yield

    //     // Deposit funds
    //     vm.startPrank(user);
    //     IERC20(WETH).approve(address(liquidMode), depositAmount);
    //     liquidMode.deposit(depositAmount, user);
    //     vm.stopPrank();

    //     // Simulate yield generation
    //     deal(liquidMode.EZETH(), address(liquidMode), yieldAmount / 2);
    //     deal(liquidMode.WRSETH(), address(liquidMode), yieldAmount / 2);

    //     vm.mockCall(
    //         address(liquidMode.poolAddress()),
    //         abi.encodeWithSelector(IAlgebraPoolActions.collect.selector),
    //         abi.encode(yieldAmount / 2, yieldAmount / 2)
    //     );

    //     // Harvest and reinvest to generate strategist fees
    //     vm.prank(liquidMode.owner());
    //     liquidMode.harvestReinvestAndReport();

    //     // Record initial state
    //     uint256 initialAccumulatedFees = liquidMode.accumulatedStrategistFee();
    //     console.log("Initial accumulated fees:", initialAccumulatedFees);

    //     vm.clearMockedCalls();

    //     // Create a non-strategist address
    //     address nonStrategist = address(0x1234);
    //     bytes32 STRATEGIST_ROLE = liquidMode.STRATEGIST_ROLE();
    //     // Attempt to claim fees as non-strategist
    //     uint256 claimAmount = initialAccumulatedFees / 2;
    //     vm.prank(nonStrategist);
    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             IAccessControl.AccessControlUnauthorizedAccount.selector, nonStrategist, STRATEGIST_ROLE
    //         )
    //     );
    //     liquidMode.claimStrategistFees(claimAmount);

    //     // Verify that the state hasn't changed
    //     uint256 finalAccumulatedFees = liquidMode.accumulatedStrategistFee();
    //     assertEq(finalAccumulatedFees, initialAccumulatedFees, "Accumulated fees should not change");

    //     console.log("Final accumulated fees:", finalAccumulatedFees);
    // }

    function testNonHarvesterCannotHarvest() public {
        uint256 depositAmount = 10 ether;
        uint256 feeAmount0 = 1 ether; // 1 ezETH in fees
        uint256 feeAmount1 = 1.5 ether; // 1.5 wrsETH in fees

        (int224 _ezETHPrice,) = liquidMode.readDataFeed(EZETH_ETH_PROXY);
        uint256 ezETHPrice = uint256(uint224(_ezETHPrice));
        (int224 _wrsETHPrice,) = liquidMode.readDataFeed(WRSETH_ETH_PROXY);
        uint256 wrsETHPrice = uint256(uint224(_wrsETHPrice));

        //convert to ETH
        uint256 feeAmount0InETH = (1.25 ether * ezETHPrice) / 10 ** 18;
        uint256 feeAmount1InETH = (1.25 ether * wrsETHPrice) / 10 ** 18;

        // Setup initial deposit
        vm.startPrank(user);
        IERC20(WETH).approve(address(liquidMode), depositAmount);
        liquidMode.deposit(depositAmount, user);
        vm.stopPrank();

        assertEq(liquidMode.totalAssets(), depositAmount, "Initial deposit should match total assets");

        // Mock the collect function
        vm.mockCall(
            address(liquidMode.poolAddress()),
            abi.encodeWithSelector(IAlgebraPoolActions.collect.selector),
            abi.encode(feeAmount0, feeAmount1)
        );

        // Transfer the mocked fee amounts to the LiquidMode contract
        deal(liquidMode.token0(), address(liquidMode), feeAmount0);
        deal(liquidMode.token1(), address(liquidMode), feeAmount1);

        // Create a non-harvester address
        address nonHarvester = address(0x1234);
        vm.startPrank(nonHarvester);

        // Attempt to call harvestReinvestAndReport as non-harvester
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, nonHarvester, liquidMode.HARVESTER_ROLE()
            )
        );
        liquidMode.harvestReinvestAndReport();

        // Stop pranking
        vm.stopPrank();

        // Verify that the state hasn't changed
        assertEq(liquidMode.totalAssets(), depositAmount, "Total assets should not change");
        // assertEq(liquidMode.accumulatedStrategistFee(), 0, "Accumulated strategist fee should remain zero");

        console.log("Total assets after failed harvest:", liquidMode.totalAssets());
        // console.log("Accumulated strategist fee after failed harvest:", liquidMode.accumulatedStrategistFee());
    }

    // function testNonHarvesterCannotPerformMaintenance() public {
    //     // Setup: Deposit some funds
    //     uint256 depositAmount = 10 ether;

    //     // Deposit funds
    //     vm.startPrank(user);
    //     IERC20(WETH).approve(address(liquidMode), depositAmount);
    //     liquidMode.deposit(depositAmount, user);
    //     vm.stopPrank();

    //     // Simulate some time passing and operations occurring
    //     vm.roll(block.number + 1000);

    //     // Record initial balances
    //     uint256 initialWETHBalance = IERC20(WETH).balanceOf(address(liquidMode));
    //     uint256 initialEzETHBalance = IERC20(liquidMode.EZETH()).balanceOf(address(liquidMode));
    //     uint256 initialWrsETHBalance = IERC20(liquidMode.WRSETH()).balanceOf(address(liquidMode));
    //     (, uint128 initialLiquidity,,) = liquidMode.getKimPosition();

    //     console.log("Initial WETH balance:", initialWETHBalance);
    //     console.log("Initial ezETH balance:", initialEzETHBalance);
    //     console.log("Initial wrsETH balance:", initialWrsETHBalance);
    //     console.log("Initial liquidity:", initialLiquidity);

    //     // Record initial total assets
    //     uint256 initialTotalAssets = liquidMode.totalAssets();

    //     // Create a non-harvester address
    //     address nonHarvester = address(0x1234);

    //     // Attempt to perform maintenance as non-harvester
    //     vm.startPrank(nonHarvester);
    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             IAccessControl.AccessControlUnauthorizedAccount.selector, nonHarvester, liquidMode.HARVESTER_ROLE()
    //         )
    //     );
    //     liquidMode.performMaintenance();
    //     vm.stopPrank();

    //     // Check final balances and total assets
    //     uint256 finalWETHBalance = IERC20(WETH).balanceOf(address(liquidMode));
    //     uint256 finalEzETHBalance = IERC20(liquidMode.EZETH()).balanceOf(address(liquidMode));
    //     uint256 finalWrsETHBalance = IERC20(liquidMode.WRSETH()).balanceOf(address(liquidMode));
    //     uint256 finalTotalAssets = liquidMode.totalAssets();
    //     (, uint128 finalLiquidity,,) = liquidMode.getKimPosition();

    //     // Assert that nothing has changed
    //     assertEq(finalWETHBalance, initialWETHBalance, "WETH balance should not change");
    //     assertEq(finalEzETHBalance, initialEzETHBalance, "ezETH balance should not change");
    //     assertEq(finalWrsETHBalance, initialWrsETHBalance, "wrsETH balance should not change");
    //     assertEq(finalTotalAssets, initialTotalAssets, "Total assets should not change");
    //     assertEq(finalLiquidity, initialLiquidity, "Liquidity should not change");

    //     // Log results
    //     console.log("Final WETH balance:", finalWETHBalance);
    //     console.log("Final ezETH balance:", finalEzETHBalance);
    //     console.log("Final wrsETH balance:", finalWrsETHBalance);
    //     console.log("Final total assets:", finalTotalAssets);
    //     console.log("Final liquidity:", finalLiquidity);
    // }

    function testInvestWithdrawReinvest() public {
        uint256 initialDepositAmount = 0.00411 ether;

        // Step 1: Initial Investment
        vm.startPrank(user);
        IERC20(WETH).approve(address(liquidMode), initialDepositAmount);
        uint256 initialSharesReceived = liquidMode.deposit(initialDepositAmount, user);
        vm.stopPrank();

        console.log("Initial deposit amount:", initialDepositAmount);
        console.log("Initial shares received:", initialSharesReceived);
        console.log("Initial total assets:", liquidMode.totalAssets());

        // Skip 100 blocks to simulate time passing
        vm.roll(block.number + 100);

        // Step 2: Full Withdrawal
        uint256 userSharesBeforeWithdrawal = liquidMode.balanceOf(user);
        uint256 userWETHBalanceBeforeWithdrawal = IERC20(WETH).balanceOf(user);

        vm.startPrank(user);
        uint256 assetsRedeemed = liquidMode.redeem(userSharesBeforeWithdrawal, user, user);
        vm.stopPrank();

        uint256 userWETHBalanceAfterWithdrawal = IERC20(WETH).balanceOf(user);
        uint256 actualWithdrawnAmount = userWETHBalanceAfterWithdrawal - userWETHBalanceBeforeWithdrawal;

        console.log("Assets redeemed:", assetsRedeemed);
        console.log("Actual withdrawn amount:", actualWithdrawnAmount);
        console.log("Total assets after withdrawal:", liquidMode.totalAssets());

        // Define acceptable variance (1.5% of deposit amount to account for slippage and fees)
        uint256 acceptableVariance = initialDepositAmount * 15 / 1000;

        // Assertions for withdrawal
        assertApproxEqAbs(
            actualWithdrawnAmount,
            initialDepositAmount,
            0.02e18,
            "User should receive approximately the full deposited amount of WETH (within 1.5%)"
        );
        assertEq(liquidMode.balanceOf(user), 0, "User should have no shares left after full withdrawal");

        // Step 3: Reinvest the withdrawn amount
        uint256 reinvestAmount = actualWithdrawnAmount;

        vm.startPrank(user);
        IERC20(WETH).approve(address(liquidMode), reinvestAmount);
        uint256 reinvestedShares = liquidMode.deposit(reinvestAmount, user);
        vm.stopPrank();

        console.log("Reinvested amount:", reinvestAmount);
        console.log("Reinvested shares received:", reinvestedShares);
        console.log("Total assets after reinvestment:", liquidMode.totalAssets());

        // Assertions for reinvestment
        assertGt(reinvestedShares, 0, "User should receive shares for reinvestment");
        assertApproxEqAbs(
            liquidMode.totalAssets(),
            reinvestAmount,
            acceptableVariance,
            "Total assets should be close to reinvested amount (within 1.5%)"
        );

        // Check final balances
        uint256 finalContractWRSETHBalance = IERC20(WRSETH).balanceOf(address(liquidMode));
        uint256 finalContractEZETHBalance = IERC20(EZETH).balanceOf(address(liquidMode));
        console.log("Final Contract WRSETH Balance", finalContractWRSETHBalance);
        console.log("Final Contract EZETH Balance", finalContractEZETHBalance);
    }

    function testFullWithdrawAfterHarvest() public {
        uint256 depositAmount = 10 ether;
        uint256 feeAmount0 = 0; // No fees
        uint256 feeAmount1 = 0; // No fees

        // Setup: Deposit funds
        vm.startPrank(user);
        IERC20(WETH).approve(address(liquidMode), depositAmount);
        uint256 sharesReceived = liquidMode.deposit(depositAmount, user);
        vm.stopPrank();

        console.log("Initial shares received:", sharesReceived);
        console.log("Initial total assets:", liquidMode.totalAssets());
        console.log("Initial user WETH balance:", IERC20(WETH).balanceOf(user));
        console.log("initial contract WETH balance", IERC20(WETH).balanceOf(address(liquidMode)));
        console.log("Initial ezETH Balance of contract:", IERC20(liquidMode.token0()).balanceOf(address(liquidMode)));
        console.log("Initial wrsETH Balance of contract:", IERC20(liquidMode.token1()).balanceOf(address(liquidMode)));
        (, uint128 initialLiquidity, uint256 initialAmount0, uint256 initialAmount1) = liquidMode.getKimPosition();
        console.log("Initial liquidity of contract:", initialLiquidity);
        console.log("Initial amount0 of contract:", initialAmount0);
        console.log("Initial amount1 of contract:", initialAmount1);

        // Mock the collect function with zero fees
        vm.mockCall(
            address(liquidMode.poolAddress()),
            abi.encodeWithSelector(IAlgebraPoolActions.collect.selector),
            abi.encode(feeAmount0, feeAmount1)
        );

        // Call harvestReinvestAndReport (this should just rebalance positions)
        vm.prank(liquidMode.owner());
        liquidMode.harvestReinvestAndReport();

        // Log intermediate state
        console.log("After harvest total assets:", liquidMode.totalAssets());
        uint256 balEzETH = IERC20(liquidMode.token0()).balanceOf(address(liquidMode));
        uint256 balWrsETH = IERC20(liquidMode.token1()).balanceOf(address(liquidMode));
        console.log("After harvest EZETH balance:", balEzETH);
        console.log("After harvest WRSETH balance:", balWrsETH);
        (, uint128 liquidityAfterHarvest, uint256 amount0AfterHarvest, uint256 amount1AfterHarvest) =
            liquidMode.getKimPosition();
        console.log("Liquidity after harvest:", liquidityAfterHarvest);
        console.log("Amount0 after harvest:", amount0AfterHarvest);
        console.log("Amount1 after harvest:", amount1AfterHarvest);

        vm.clearMockedCalls();

        // Attempt full withdrawal
        vm.startPrank(user);
        uint256 withdrawnAmount = liquidMode.redeem(sharesReceived, user, user);
        vm.stopPrank();

        uint256 finalUserWETHBalance = IERC20(WETH).balanceOf(user);
        uint256 actualWithdrawnAmount = finalUserWETHBalance - (1000 ether - depositAmount);

        console.log("Assets redeemed:", sharesReceived);
        console.log("Actual withdrawn amount:", actualWithdrawnAmount);
        console.log("Final total assets:", liquidMode.totalAssets());
        console.log("Final user shares:", liquidMode.balanceOf(user));

        // Check remaining balances in the contract
        uint256 finalContractWRSETHBalance = IERC20(WRSETH).balanceOf(address(liquidMode));
        uint256 finalContractEZETHBalance = IERC20(EZETH).balanceOf(address(liquidMode));
        console.log("Final Contract WRSETH Balance:", finalContractWRSETHBalance);
        console.log("Final Contract EZETH Balance:", finalContractEZETHBalance);

        // Calculate variance
        uint256 variancePercentage = actualWithdrawnAmount >= depositAmount
            ? ((actualWithdrawnAmount - depositAmount) * 10000) / depositAmount
            : ((depositAmount - actualWithdrawnAmount) * 10000) / depositAmount;
        console.log("Full withdrawal variance:", variancePercentage, "basis points");

        // Assert that the withdrawal amount is within 1.7% of deposit
        assertApproxEqAbs(
            actualWithdrawnAmount,
            depositAmount,
            (depositAmount * 17) / 1000, // 1.7% tolerance
            "User should receive approximately the full deposited amount of WETH (within 1.7%)"
        );

        // Assert that the contract balances are within acceptable limits (0.1% of deposit)
        uint256 acceptableVariance = depositAmount / 1000; // 0.1% of deposit
        assertLe(
            finalContractWRSETHBalance,
            acceptableVariance,
            "Contract should have less than 0.1% of deposit remaining as WRSETH"
        );
        assertLe(
            finalContractEZETHBalance,
            acceptableVariance,
            "Contract should have less than 0.1% of deposit remaining as EZETH"
        );
    }
}
// check if token0 matches with either of the two tokens
// check if token
// check if token1 matches with either of the two tokens
