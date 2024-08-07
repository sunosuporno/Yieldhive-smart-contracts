// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {VaultStrategy} from "../src/Vault_Strategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Vault_StrategyScript is Script {
    VaultStrategy public vault_strategy;

    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address asset = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
        uint256 initialDeposit = 0; //
        address initialOwner = 0x07a721260416e764618B059811eaf099a940Af14;
        string memory name = "YieldHive Prime USDC";
        string memory symbol = "ypUSDC";
        address pythContract = 0xA2aa501b19aff244D90cc15a4Cf739D2725B5729;
        address aavePoolContract = 0x07eA79F68B2B3df564D0A34F8e19D9B1e339814b;
        address aaveProtocolDataProviderContract = 0x80437224dc5Dcb43C5fC87CBdE73152418055274;
        address aerodromePoolContract = 0x6cDcb1C4A4D1C3C6d054b27AC5B77e89eAFb971d; // mainnet

        // Approve the transfer of initial deposit
        IERC20(asset).approve(address(this), initialDeposit);

        vault_strategy = new VaultStrategy(
            IERC20(asset),
            initialDeposit,
            initialOwner,
            name,
            symbol,
            pythContract,
            aavePoolContract,
            aaveProtocolDataProviderContract,
            aerodromePoolContract
        );

        vm.stopBroadcast();
    }
}
