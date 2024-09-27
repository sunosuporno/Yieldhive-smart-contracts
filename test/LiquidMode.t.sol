// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {LiquidMode} from "../src/LiquidMode.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from
    "@cryptoalgebra/integral-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {ISwapRouter} from "@cryptoalgebra/integral-periphery/contracts/interfaces/ISwapRouter.sol";

contract LiquidModeTest is Test {
    LiquidMode public liquidMode;

    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant INITIAL_OWNER = 0x07a721260416e764618B059811eaf099a940Af14;
    address constant STRATEGIST = 0x6A0a7c97c3B6e9fBdA3626ED15A244aDa74A54CF;
    address constant X_RENZO_DEPOSIT = 0x4D7572040B84b41a6AA2efE4A93eFFF182388F88;
    address constant RSETH_POOL_V2 = 0xbDf612E616432AA8e8D7d8cC1A9c934025371c5C;
    address constant NONFUNGIBLE_POSITION_MANAGER = 0x2e8614625226D26180aDf6530C3b1677d3D7cf10;
    address constant FACTORY = 0xB5F00c2C5f8821155D8ed27E31932CFD9DB3C5D5;
    address constant POOL_DEPLOYER = 0x6414A461B19726410E52488d9D5ff33682701635;
    address constant EZETH = 0x2416092f143378750bb29b79eD961ab195CcEea5;
    address constant WRSETH = 0xe7903B1F75C534Dd8159b313d92cDCfbC62cB3Cd;
    address constant EZETH_WRSETH_POOL = 0xCC29E407a272F2CC817DB9fBfF7e6FdA6536Fc0e;
    address constant SWAP_ROUTER = 0xAc48FcF1049668B285f3dC72483DF5Ae2162f7e8;
    address constant TREASURY = 0x273dFa01f5605b8c41d6CE1146ed0911FDC5ad07;

    function setUp() public {
        // Deploy the LiquidMode contract
        liquidMode = new LiquidMode(
            IERC20(WETH),
            "LiquidMode Token",
            "LMT",
            INITIAL_OWNER,
            STRATEGIST,
            X_RENZO_DEPOSIT,
            RSETH_POOL_V2,
            INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER),
            FACTORY,
            POOL_DEPLOYER,
            EZETH,
            WRSETH,
            WETH,
            EZETH_WRSETH_POOL,
            ISwapRouter(SWAP_ROUTER),
            TREASURY
        );
    }

    function testInitialSetup() public {
        assertEq(address(liquidMode.asset()), WETH, "Asset should be WETH");
        assertEq(liquidMode.name(), "LiquidMode Token", "Name should be set correctly");
        assertEq(liquidMode.symbol(), "LMT", "Symbol should be set correctly");
        assertEq(liquidMode.owner(), INITIAL_OWNER, "Owner should be set correctly");
        assertEq(liquidMode.strategist(), STRATEGIST, "Strategist should be set correctly");
        assertEq(address(liquidMode.xRenzoDeposit()), X_RENZO_DEPOSIT, "xRenzoDeposit should be set correctly");
        assertEq(address(liquidMode.rSETHPoolV2()), RSETH_POOL_V2, "rSETHPoolV2 should be set correctly");
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

    // Add more tests here...
}
