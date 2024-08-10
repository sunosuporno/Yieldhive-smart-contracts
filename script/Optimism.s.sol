// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {OptimismStrategy} from "../src/Cross-chain Strategy/Optimism.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract OptimismStrategyScript is Script {
    OptimismStrategy public optimismStrategy;

    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Replace these addresses with the correct ones for the Optimism network
        address router = 0x114A20A10b43D4115e5aeef7345a1A71d2a60C57; // Replace with the CCIP router address on Optimism
        address aavePool = 0xb50201558B00496A145fE76f7424749556E326D8; // Replace with Aave Pool address on Optimism
        address aaveProtocolDataProvider = 0x501B4c19dd9C2e06E94dA7b6D5Ed4ddA013EC741; // Replace with Aave Protocol Data Provider address on Optimism
        address usdc = 0x5fd84259d66Cd46123540766Be93DFE6D43130D7; // Replace with USDC token address on Optimism
        address weth = 0x4200000000000000000000000000000000000006; // Replace with WETH token address on Optimism
        address pythContract = 0x0708325268dF9F66270F1401206434524814508b; // Replace with Pyth contract address on Optimism

        optimismStrategy = new OptimismStrategy(
            router,
            aavePool,
            aaveProtocolDataProvider,
            usdc,
            weth,
            pythContract
        );

        vm.stopBroadcast();
    }
}
