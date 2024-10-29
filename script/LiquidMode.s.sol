// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {LiquidMode} from "../src/LiquidMode.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from
    "@cryptoalgebra/integral-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {ISwapRouter} from "@cryptoalgebra/integral-periphery/contracts/interfaces/ISwapRouter.sol";

contract LiquidModeScript is Script {
    LiquidMode public liquidMode;

    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Deploy the LiquidMode contract
        liquidMode = new LiquidMode(
            IERC20(address(0x4200000000000000000000000000000000000006)), // asset_
            "LiquidMode Token", // name_
            "LMT", // symbol_
            address(0x07a721260416e764618B059811eaf099a940Af14), // initialOwner
            address(0x6A0a7c97c3B6e9fBdA3626ED15A244aDa74A54CF), // _strategist
            INonfungiblePositionManager(address(0x2e8614625226D26180aDf6530C3b1677d3D7cf10)), // _nonfungiblePositionManager
            address(0xB5F00c2C5f8821155D8ed27E31932CFD9DB3C5D5), // _factory
            address(0x6414A461B19726410E52488d9D5ff33682701635), // _poolDeployer
            address(0x4200000000000000000000000000000000000006), // _WETH
            address(0xCC29E407a272F2CC817DB9fBfF7e6FdA6536Fc0e), // _ezETHwrsETHPool
            ISwapRouter(address(0xAc48FcF1049668B285f3dC72483DF5Ae2162f7e8)), // _swapRouter
            address(0x273dFa01f5605b8c41d6CE1146ed0911FDC5ad07), // _treasury
            address(0x2416092f143378750bb29b79eD961ab195CcEea5), // _token0
            address(0xe7903B1F75C534Dd8159b313d92cDCfbC62cB3Cd), // _token1
            address(0x3621b06BfFE478eB481adf65bbF139A052Ed7321), // _token0EthProxy
            address(0xc30e51C9EDD92B9eeF45f281c712faaAf59912BA) // _token1thProxy
        );

        console.log("LiquidMode deployed at:", address(liquidMode));

        vm.stopBroadcast();
    }
}
