// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {VaultStrategy} from "../src/Vault_Strategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

contract Vault_StrategyScript is Script {
    VaultStrategy public vaultStrategyImplementation;
    TransparentUpgradeableProxy public proxy;
    ProxyAdmin public proxyAdmin;

    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        vm.startBroadcast(deployerPrivateKey);

        // Deploy the implementation contract
        vaultStrategyImplementation = new VaultStrategy();

        // Deploy the ProxyAdmin contract with the deployer as the initial owner
        proxyAdmin = new ProxyAdmin(deployer);

        // Prepare initialization data
        address asset = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        uint256 initialDeposit = 100;
        address initialOwner = 0x07a721260416e764618B059811eaf099a940Af14;
        string memory name = "YieldHive Prime USDC";
        string memory symbol = "ypUSDC";
        address pythContract = 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a;
        address aavePoolContract = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
        address aaveProtocolDataProviderContract = 0x793177a6Cf520C7fE5B2E45660EBB48132184BBC;
        address aerodromePoolContract = 0x6cDcb1C4A4D1C3C6d054b27AC5B77e89eAFb971d; // mainnet
        address pythPriceUpdaterContract = 0x4896bB51d19A7c7a69e48732580FB628903086eF;
        address aaveOracleContract = 0x2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156;
        address strategist = 0x07a721260416e764618B059811eaf099a940Af14;

        bytes memory initData = abi.encodeWithSelector(
            VaultStrategy.initialize.selector,
            IERC20(asset),
            initialDeposit,
            initialOwner,
            name,
            symbol,
            pythContract,
            aavePoolContract,
            aaveProtocolDataProviderContract,
            aerodromePoolContract,
            pythPriceUpdaterContract,
            aaveOracleContract,
            strategist
        );

        // Deploy the TransparentUpgradeableProxy
        proxy = new TransparentUpgradeableProxy(
            address(vaultStrategyImplementation),
            address(proxyAdmin),
            initData
        );

        // The proxy address is now the address of your upgradeable VaultStrategy
        console.log("Upgradeable VaultStrategy deployed at:", address(proxy));
        console.log(
            "Implementation address:",
            address(vaultStrategyImplementation)
        );
        console.log("ProxyAdmin address:", address(proxyAdmin));

        vm.stopBroadcast();
    }
}
