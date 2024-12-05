// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PrimeUSDC} from "../src/Vault_Strategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

contract PrimeUSDCScript is Script {
    PrimeUSDC public primeUSDCImplementation;
    TransparentUpgradeableProxy public proxy;
    ProxyAdmin public proxyAdmin;

    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        vm.startBroadcast(deployerPrivateKey);

        // Deploy the implementation contract
        primeUSDCImplementation = new PrimeUSDC();

        // Deploy the ProxyAdmin contract with the deployer as the initial owner
        proxyAdmin = new ProxyAdmin(deployer);

        // Prepare initialization data
        address asset = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // USDC on OP
        uint256 initialDeposit = 100;
        address initialOwner = 0x07a721260416e764618B059811eaf099a940Af14;
        string memory name = "YieldHive Prime USDC";
        string memory symbol = "ypUSDC";
        address aavePoolContract = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
        address aaveProtocolDataProviderContract = 0x793177a6Cf520C7fE5B2E45660EBB48132184BBC;
        address aaveOracleContract = 0x2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156;
        address strategist = 0x07a721260416e764618B059811eaf099a940Af14;
        address aerodromePoolContract = 0x6cDcb1C4A4D1C3C6d054b27AC5B77e89eAFb971d;
        uint256 targetHealthFactor = 10300;
        uint256 healthFactorBuffer = 300;
        uint256 strategistFeePercentage = 2000;

        bytes memory initData = abi.encodeWithSelector(
            PrimeUSDC.initialize.selector,
            IERC20(asset),
            initialDeposit,
            initialOwner,
            name,
            symbol,
            aavePoolContract,
            aaveProtocolDataProviderContract,
            aaveOracleContract,
            strategist,
            aerodromePoolContract,
            targetHealthFactor,
            healthFactorBuffer,
            strategistFeePercentage
        );

        // Deploy the TransparentUpgradeableProxy
        proxy = new TransparentUpgradeableProxy(address(primeUSDCImplementation), address(proxyAdmin), initData);

        // The proxy address is now the address of your upgradeable PrimeUSDC
        console.log("Upgradeable PrimeUSDC deployed at:", address(proxy));
        console.log("Implementation address:", address(primeUSDCImplementation));
        console.log("ProxyAdmin address:", address(proxyAdmin));

        vm.stopBroadcast();
    }
}
