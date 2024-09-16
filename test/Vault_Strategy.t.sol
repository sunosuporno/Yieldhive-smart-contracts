pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {VaultStrategy} from "../src/Vault_Strategy.sol";
import {PythPriceUpdater} from "../src/PythPriceUpdater.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract Vault_StrategyTest is Test {
    VaultStrategy public vaultStrategy;
    PythPriceUpdater public pythPriceUpdater;
    IERC20 public usdc;
    address public user;
    address public owner;

    // Constants from the deployment script
    address constant ASSET = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // USDC
    uint256 constant INITIAL_DEPOSIT = 100;
    string constant NAME = "YieldHive Prime USDC";
    string constant SYMBOL = "ypUSDC";
    address constant PYTH_CONTRACT = 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a;
    address constant AAVE_POOL_CONTRACT = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant AAVE_PROTOCOL_DATA_PROVIDER_CONTRACT = 0x793177a6Cf520C7fE5B2E45660EBB48132184BBC;
    address constant AERODROME_POOL_CONTRACT = 0x6cDcb1C4A4D1C3C6d054b27AC5B77e89eAFb971d;
    address constant AAVE_ORACLE_CONTRACT = 0x2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156;

    function setUp() public {
        // Remove the line: vm.createSelectFork("optimism");

        // Set up accounts
        owner = makeAddr("owner");
        user = makeAddr("user");

        // Deploy PythPriceUpdater
        pythPriceUpdater = new PythPriceUpdater();

        // Deploy VaultStrategy implementation
        VaultStrategy vaultStrategyImplementation = new VaultStrategy();

        // Deploy ProxyAdmin
        ProxyAdmin proxyAdmin = new ProxyAdmin(owner);

        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            VaultStrategy.initialize.selector,
            IERC20(ASSET),
            INITIAL_DEPOSIT,
            owner,
            NAME,
            SYMBOL,
            PYTH_CONTRACT,
            AAVE_POOL_CONTRACT,
            AAVE_PROTOCOL_DATA_PROVIDER_CONTRACT,
            AERODROME_POOL_CONTRACT,
            address(pythPriceUpdater),
            AAVE_ORACLE_CONTRACT,
            owner // strategist
        );

        // Deploy TransparentUpgradeableProxy
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(vaultStrategyImplementation), address(proxyAdmin), initData);

        // Assign the proxy address to vaultStrategy
        vaultStrategy = VaultStrategy(address(proxy));

        // Assign 20 ETH to the Vault_Strategy contract
        vm.deal(address(vaultStrategy), 20 ether);

        // Set up USDC for the user
        usdc = IERC20(ASSET);
        deal(address(usdc), user, 1000 * 10 ** 6); // 1000 USDC (6 decimals)

        // Approve VaultStrategy to spend user's USDC
        vm.prank(user);
        usdc.approve(address(vaultStrategy), type(uint256).max);
    }

    // Add your test functions here
    function testInitialSetup() public {
        assertEq(vaultStrategy.name(), NAME);
        assertEq(vaultStrategy.symbol(), SYMBOL);
        assertEq(address(vaultStrategy.asset()), ASSET);
        assertEq(vaultStrategy.owner(), owner);
        assertEq(address(vaultStrategy.pythPriceUpdater()), address(pythPriceUpdater));
        assertEq(usdc.balanceOf(user), 1000 * 10 ** 6);
        assertEq(usdc.allowance(user, address(vaultStrategy)), type(uint256).max);
        assertEq(address(vaultStrategy).balance, 20 ether);
    }

    // Add more test functions as needed
    function testDeposit() public {
        vm.startPrank(user);
        uint256 initalBalance = usdc.balanceOf(user);
        vaultStrategy.deposit(100_000_000, user);
        uint256 finalBalance = usdc.balanceOf(user);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(vaultStrategy)), 100_000_000);
        assertEq(vaultStrategy.balanceOf(user), 100_000_000);
        assertEq(finalBalance, initalBalance - 100_000_000);
        assertEq(vaultStrategy.accumulatedDeposits(), 100_000_000);
    }

    function testMultipleDeposits() public {
        address user2 = makeAddr("user2");
        address user3 = makeAddr("user3");

        // Give USDC to user2 and user3
        deal(address(usdc), user2, 1000 * 10 ** 6);
        deal(address(usdc), user3, 1000 * 10 ** 6);

        // Approve VaultStrategy for user2 and user3
        vm.prank(user2);
        usdc.approve(address(vaultStrategy), type(uint256).max);
        vm.prank(user3);
        usdc.approve(address(vaultStrategy), type(uint256).max);

        // User deposits
        vm.prank(user);
        vaultStrategy.deposit(50_000_000, user);

        // User2 deposits
        vm.prank(user2);
        vaultStrategy.deposit(75_000_000, user2);

        // User3 deposits
        vm.prank(user3);
        vaultStrategy.deposit(100_000_000, user3);

        // Check individual balances
        assertEq(vaultStrategy.balanceOf(user), 50_000_000);
        assertEq(vaultStrategy.balanceOf(user2), 75_000_000);
        assertEq(vaultStrategy.balanceOf(user3), 100_000_000);

        // Check total accumulated deposits
        assertEq(vaultStrategy.accumulatedDeposits(), 225_000_000);

        // Check USDC balance of the vault
        assertEq(usdc.balanceOf(address(vaultStrategy)), 225_000_000);
    }

    function testDepositWhenPaused() public {
        // Setup: Give user some USDC and approve the vault
        deal(address(usdc), user, 1000 * 10 ** 6);
        vm.startPrank(user);
        usdc.approve(address(vaultStrategy), type(uint256).max);
        vm.stopPrank();

        // Pause the contract (assuming onlyOwner can pause)
        vm.prank(owner);
        vaultStrategy.pause();

        // Attempt to deposit while paused
        vm.prank(user);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vaultStrategy.deposit(100 * 10 ** 6, user);

        // Verify no deposit occurred
        assertEq(vaultStrategy.balanceOf(user), 0);
        assertEq(usdc.balanceOf(address(vaultStrategy)), 0);

        // Unpause the contract
        vm.prank(owner);
        vaultStrategy.unpause();

        // Verify deposit works after unpausing
        vm.prank(user);
        vaultStrategy.deposit(100 * 10 ** 6, user);
        assertEq(vaultStrategy.balanceOf(user), 100 * 10 ** 6);
        assertEq(usdc.balanceOf(address(vaultStrategy)), 100 * 10 ** 6);
    }

    function testInvestAccumulatedFunds() public {
        address user2 = makeAddr("user2");
        // Setup: Give users some USDC and approve the vault
        deal(address(usdc), user, 1000 * 10 ** 6);
        deal(address(usdc), user2, 1000 * 10 ** 6);

        vm.startPrank(user);
        usdc.approve(address(vaultStrategy), type(uint256).max);
        vaultStrategy.deposit(500 * 10 ** 6, user);
        vm.stopPrank();

        vm.startPrank(user2);
        usdc.approve(address(vaultStrategy), type(uint256).max);
        vaultStrategy.deposit(300 * 10 ** 6, user2);
        vm.stopPrank();

        // Verify accumulated deposits
        assertEq(vaultStrategy.accumulatedDeposits(), 800 * 10 ** 6);

        // Update Pyth price feed (replace with actual bytes array)
        bytes[] memory priceUpdateData = new bytes[](1);
        priceUpdateData[0] = bytes(
            "0x504e41550100000003b801000000040d00462a0784cfbd18f873affe08094b696049ff9f980509c083c5cb67330845ad1b2d90a509c10279b29283277a2f7f01562771369b641714a26de6b6abd02bb9e20102ee0dd3b581fbf38baaa6fac8020b05a31a1b5f7028401b3f8368994c17d1ce0277dd7a23bcfdf867734bea7a90d603df7baec303bb7710e39357f46e7b7d57440103f61a90c72470a4c9a2aea410c722a405a93e1ddf80e21e4e1ab37043f714b9f477f8292b33c8fd0a29bf060678d9ad16505e12f25c357b79e59546195a617cc300041f5f3723de37fb42020abfc1ac48a8c500e5bf68571db8a70dbf537724d12f614b17ccb7fe5be19e63cfea974f9c584b623c919ae1b013345ecc066805d23e9300061b9a11eb125febed4e321bd2d3e93e7df46d05c78270da8146728ac3d155ccd66a41ec948fb8eb2aab58d5a0789b5704a58bb9b29ecd8f4122d0216e0d7e99870008a9973a4c91f0c6dd29299f3f15c9507b5612e4bdd028170f78efbdddfdc3bd234bf55b5285e2cd1625b605c661fee2c1b6c7c542732c60ea027bccd461e751fd000aa5eb16adf1aad021208eb923b2723a1f2b266049176685bd3ecbb2aec3df339042d71dd9e18a8167316334d314ce8b61b733060f28b0cd1037f2ac42ff0ebb69000b355150350e7e0de0b02cfc11cbaf590daffe8efcdb98b4150d2e37c9a6459bd242ece9c644f4b5dfcc44a0e9d8bb60e72026db5e1d5ad7f0f9f69d42ecca95dc000c7571e478ca24b409df2d7853f2ce9460597531669fed16a2e82fe7bc160242e12fa7759559dd7aba0d7ff6ae0a4056e6d46206382d69c026889318d2f0f944ea000ddd469b7c3ab60c67109532d4689ec16000b70690bc9015bb57f3c01556a2cc97148b24e96b7abe31144832ed8a814749f2b3dd43d2fde5bf03d45b0de1e51d84010eee96c4ee8700a2d7e93923825b46dc98d96c095c651e2a5749ec1a84f0e5fcaf78fdae50ba423c8240a601ae5a00aa2aa94ccba6eabeaf415738266a3eaf7d15000f1aab3feede5a7147f477201ef6b084c06eba4e54d88c07831faecdd93b5881296cf806016f2aee4fac384992bf4c94dcdd0707b6cf35abea5a4d0f7d805734c10110cf69172ee36c4d82afcd4f1998ae9ccd2e14211353b40a25ffa10cdc9d242f5542981ab145a3b10905641d8413f138321d0ee89b2fbcf1c35a3f7165782df0920066e8a13700000000001ae101faedac5851e32b9b23b5f9411a8c2bac4aae3ed4dd7b811dd1a72ea4aa710000000004d1b42f0141555756000000000009dd38c300002710eddd80249be2fa4eec3040851d59cf8e816f8c5303005500eaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a0000000005f5e1030000000000018eaafffffff80000000066e8a1370000000066e8a1360000000005f5e0d300000000000191a30a2c442930a78600a8b79aca0f77c2ab23596992139cf145874193782f3449358ff5fe852c5946407ad093e4ad7434bb0873f0ab90deb56e50eae0b396bd5084025593911bdbcb5c22bfd95ef30e7b4b0b4be0b8138f96a28f80831328262f89b7e938a022d8c22d51de5a6a5dbc1ebfc775cb4698b299378fde4f991a2abbef2be17078f409cfdad9da62e10ca8ebfd8932b7ba3d20fe61c6b423aee6ad8bf80c0bbae40a0df7aaa63c9397efeeae281a21e5c4722e31c247acb08a997f29c62b366f64311dbe090800550015ecddd26d49e1a8f1de9376ebebc03916ede873447c1255d2d5891b92ce5717000000395980c72c000000002d698990fffffff80000000066e8a1370000000066e8a136000000394870ec8000000000285d90620a5c70dfc58e66c6a63294b3dfdf2053aa9b445a724ba2c179e3123679d6fd33e84533f0dc1ea9f5195bdf07c72ac55c9923b80807a862590dcfa6021e763f0485eef1ae85a2778a6888ddfbc5cfd782573f941de5a0895d70276053e9b0cfe01f9332267e30266a1f52f93cb0f5177475543d997b981926e1a9b8992b355aa996a119d21c88e31c8eacb29d4f9ee4f14f6b3c21c74abc580d4875fea3518b37fe2428b753d83b657affb9543f355ffd991bd64c092e31c247acb08a997f29c62b366f64311dbe09080055009db37f4d5654aad3e37e2e14ffd8d53265fb3026d1d8f91146539eebaa2ef45f0000000003eaf6a9000000000002d565fffffff80000000066e8a1370000000066e8a1360000000003eb14040000000000030c560aff2346aa0ba36803644ded412c2792e011cd798339b7d6f1eb71e68655e657834dd99161af8f40392fc371781b5fde1c23ba9f30a50305f51c4d1689c231dfca0046d2cd7bf43adeea69e301c0a08d247fff35ed65cbe3c6b3751de07e3c91c55a998618f4b18965cf7de34c691c50658c82045c88cc1b9dc632b488ff9bb1bd2436569cafa3582350544cd86fd2e9469fb5283bd3d6d9e21da74d09d661118d0bbae40a0df7aaa63c9397efeeae281a21e5c4722e31c247acb08a997f29c62b366f64311dbe0908"
        ); // Replace with actual price update data

        vm.prank(owner);
        pythPriceUpdater.setPricePyth(priceUpdateData);

        // Get initial balances
        uint256 initialVaultBalance = usdc.balanceOf(address(vaultStrategy));
        uint256 initialAUSDCBalance = IERC20(vaultStrategy.aUSDC()).balanceOf(address(vaultStrategy));

        // Invest accumulated funds
        vm.prank(owner);
        vaultStrategy.investAccumulatedFunds();

        // Verify accumulated deposits are reset
        assertEq(vaultStrategy.accumulatedDeposits(), 0);

        // Verify USDC balance of vault has decreased
        assertLt(usdc.balanceOf(address(vaultStrategy)), initialVaultBalance);

        // Verify aUSDC balance has increased
        assertGt(IERC20(vaultStrategy.aUSDC()).balanceOf(address(vaultStrategy)), initialAUSDCBalance);

        // Verify total assets haven't changed significantly (allowing for small differences due to rounding)
        uint256 totalAssetsAfterInvest = vaultStrategy.totalAssets();
        assertApproxEqRel(totalAssetsAfterInvest, 800 * 10 ** 6, 1e16); // 1% tolerance
    }
}
