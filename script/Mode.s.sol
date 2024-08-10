// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {BaseStrategy} from "../src/Cross-chain Strategy/Mode.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ModeScript is Script {
    BaseStrategy public baseStrategy;

    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Replace these addresses with the correct ones for the Mode network
        address asset = 0x22198B46C84Cf43831E65D32a9403A194D617a61; // Replace with the asset token address on Mode
        address router = 0xc49ec0eB4beb48B8Da4cceC51AA9A5bD0D0A4c43; // Replace with the CCIP router address on Mode
        address link = 0x925a4bfE64AE2bFAC8a02b35F78e60C29743755d; // Replace with the LINK token address on Mode
        uint256 initialDeposit = 0; // Adjust as needed
        address initialOwner = 0x07a721260416e764618B059811eaf099a940Af14; // Replace if needed
        string memory name = "Looptimism";
        string memory symbol = "lUSDC";

        baseStrategy = new BaseStrategy(
            IERC20(asset),
            router,
            link,
            initialDeposit,
            initialOwner,
            name,
            symbol
        );

        vm.stopBroadcast();
    }
}
