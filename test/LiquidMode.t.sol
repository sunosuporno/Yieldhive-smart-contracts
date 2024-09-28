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

contract LiquidModeTest is Test {
    LiquidMode public liquidMode;

    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant INITIAL_OWNER = 0x07a721260416e764618B059811eaf099a940Af14;
    address constant STRATEGIST = 0x6A0a7c97c3B6e9fBdA3626ED15A244aDa74A54CF;
    address constant NONFUNGIBLE_POSITION_MANAGER = 0x2e8614625226D26180aDf6530C3b1677d3D7cf10;
    address constant FACTORY = 0xB5F00c2C5f8821155D8ed27E31932CFD9DB3C5D5;
    address constant POOL_DEPLOYER = 0x6414A461B19726410E52488d9D5ff33682701635;
    address constant EZETH = 0x2416092f143378750bb29b79eD961ab195CcEea5;
    address constant WRSETH = 0xe7903B1F75C534Dd8159b313d92cDCfbC62cB3Cd;
    address constant EZETH_WRSETH_POOL = 0xCC29E407a272F2CC817DB9fBfF7e6FdA6536Fc0e;
    address constant SWAP_ROUTER = 0xAc48FcF1049668B285f3dC72483DF5Ae2162f7e8;
    address constant TREASURY = 0x273dFa01f5605b8c41d6CE1146ed0911FDC5ad07;
    address constant EZETH_ETH_PROXY = 0x3621b06BfFE478eB481adf65bbF139A052Ed7321;
    address constant WRSETH_ETH_PROXY = 0xc30e51C9EDD92B9eeF45f281c712faaAf59912BA;
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
            EZETH,
            WRSETH,
            WETH,
            EZETH_WRSETH_POOL,
            ISwapRouter(SWAP_ROUTER),
            TREASURY,
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
        assertEq(liquidMode.EZETH(), EZETH, "EZETH should be set correctly");
        assertEq(liquidMode.WRSETH(), WRSETH, "WRSETH should be set correctly");
        assertEq(address(liquidMode.WETH()), WETH, "WETH should be set correctly");
        assertEq(liquidMode.ezETHwrsETHPool(), EZETH_WRSETH_POOL, "ezETHwrsETHPool should be set correctly");
        assertEq(address(liquidMode.swapRouter()), SWAP_ROUTER, "SwapRouter should be set correctly");
        assertEq(liquidMode.treasury(), TREASURY, "Treasury should be set correctly");
    }

    function testDeposit() public {
        uint256 depositAmount = 1 ether;

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
            liquidMode.kimPosition();

        // First deposit
        uint256 initialUserWETHBalance = IERC20(WETH).balanceOf(user);
        uint256 initialTotalAssets = liquidMode.totalAssets();
        uint256 initialUserShares = liquidMode.balanceOf(user);

        uint256 firstSharesReceived = liquidMode.deposit(firstDepositAmount, user);

        // Get KIMPosition after first deposit
        (uint256 midTokenId, uint128 midLiquidity, uint256 midAmount0, uint256 midAmount1) = liquidMode.kimPosition();

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
            liquidMode.kimPosition();

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
        (uint256 initialTokenId, uint128 initialLiquidity,,) = liquidMode.kimPosition();

        // Perform mint
        uint256 assetsMinted = liquidMode.mint(sharesToMint, user);

        // Get final balances
        uint256 finalUserWETHBalance = IERC20(WETH).balanceOf(user);
        uint256 finalTotalAssets = liquidMode.totalAssets();
        uint256 finalUserShares = liquidMode.balanceOf(user);
        (uint256 finalTokenId, uint128 finalLiquidity,,) = liquidMode.kimPosition();

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

    // function testInitialDeposit() public {
    //     vm.startPrank(user);
    //     IERC20(WETH).approve(address(newLiquidMode), initialDeposit);
    //     uint256 sharesReceived = newLiquidMode.deposit(initialDeposit, user);
    //     vm.stopPrank();
    //     assertEq(sharesReceived, initialDeposit, "First deposit should mint equal amount of shares");
    // }
}
