// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Looptimism} from "../src/Looptimism.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LooptimismScript is Script {
    Looptimism public looptimism;

    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address asset = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85; // USDC address
        uint256 initialDeposit = 100; // 100 USDC (assuming 6 decimals)
        address initialOwner = 0x07a721260416e764618B059811eaf099a940Af14; // Replace with your desired owner address
        string memory name = "Looptimism USDC Vault";
        string memory symbol = "lUSDC";
        address pythContract = 0xff1a0f4744e8582DF1aE09D5611b887B6a12925C;
        address aavePoolContract = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
        address aaveProtocolDataProviderContract = 0x69FA688f1Dc47d4B5d8029D5a35FB7a548310654;
        address pythPriceUpdaterContract = 0xE632D545cBd3A26733F5e90A367660883EbAa09D;

        looptimism = new Looptimism(
            IERC20(asset),
            initialDeposit,
            initialOwner,
            name,
            symbol,
            pythContract,
            aavePoolContract,
            aaveProtocolDataProviderContract,
            pythPriceUpdaterContract
        );

        vm.stopBroadcast();
    }
}
