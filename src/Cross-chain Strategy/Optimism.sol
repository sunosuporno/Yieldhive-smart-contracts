// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OwnerIsCreator} from "@chainlink/contracts-ccip@1.4.0/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip@1.4.0/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip@1.4.0/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IRouterClient} from "@chainlink/contracts-ccip@1.4.0/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {IPool as IPoolAave} from "../interfaces/IPool.sol";
import {IPoolDataProvider} from "../interfaces/IPoolDataProvider.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {TransferHelper} from "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

contract OptimismStrategy is CCIPReceiver, OwnerIsCreator {
    using SafeERC20 for IERC20;
    using EnumerableMap for EnumerableMap.Bytes32ToUintMap;

    IPoolAave public immutable aavePool;
    IPoolDataProvider public immutable aaveProtocolDataProvider;
    IERC20 public immutable usdc;
    IERC20 public immutable weth;
    IERC20 private immutable i_linkToken;
    IRouterClient private immutable i_router;
    IPyth pyth;

    address public constant swapRouter =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address public constant aUSDC = 0x625E7708f30cA75bfd92586e17077590C60eb4cD;
    address public constant variableDebtWETH =
        0x0c84331e39d6658Cd6e6b9ba04736cC4c4734351;
    bytes32 public constant usdcUsdPriceFeedId =
        0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 public constant wethUsdPriceFeedId =
        0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    uint256 private constant PRICE_DENOMINATOR = 1e8;
    uint256 private constant USDC_DECIMALS = 6;
    uint256 private constant WETH_DECIMALS = 18;
    uint256 public previousAUSDCBalance;
    uint256 public previousVariableDebtBalance;

    // Mapping to keep track of the sender contract per source chain.
    mapping(uint64 => address) public s_senders;

    // The message contents of failed messages are stored here.
    mapping(bytes32 => Client.Any2EVMMessage) public s_messageContents;

    // Mapping to keep track of the receiver contract per destination chain.
    mapping(uint64 => address) public s_receivers;
    // Mapping to store the gas limit per destination chain.
    mapping(uint64 => uint256) public s_gasLimits;

    // Contains failed messages and their state.
    EnumerableMap.Bytes32ToUintMap internal s_failedMessages;

    event MessageReceived(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address indexed sender,
        address token,
        uint256 tokenAmount
    );

    event MessageFailed(bytes32 indexed messageId, bytes reason);
    event MessageRecovered(bytes32 indexed messageId);
    event MessageSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address indexed receiver,
        address token,
        uint256 tokenAmount,
        address feeToken,
        uint256 fees
    );
    event HarvestReport(int256 aaveNetGain);

    enum ErrorCode {
        RESOLVED,
        FAILED
    }

    struct FailedMessage {
        bytes32 messageId;
        ErrorCode errorCode;
    }

    constructor(
        address _router,
        address _aavePool,
        address _aaveProtocolDataProvider,
        address _usdc,
        address _weth,
        address pythContract
    ) CCIPReceiver(_router) {
        aavePool = IPoolAave(_aavePool);
        aaveProtocolDataProvider = IPoolDataProvider(_aaveProtocolDataProvider);
        usdc = IERC20(_usdc);
        weth = IERC20(_weth);
        pyth = IPyth(pythContract);
    }

    function setSenderForSourceChain(
        uint64 _sourceChainSelector,
        address _sender
    ) external onlyOwner {
        require(_sender != address(0), "Invalid sender address");
        s_senders[_sourceChainSelector] = _sender;
    }

    function ccipReceive(
        Client.Any2EVMMessage calldata any2EvmMessage
    ) external override onlyRouter {
        require(
            abi.decode(any2EvmMessage.sender, (address)) ==
                s_senders[any2EvmMessage.sourceChainSelector],
            "Wrong sender for source chain"
        );

        try this.processMessage(any2EvmMessage) {
            // Message processed successfully
        } catch (bytes memory err) {
            s_failedMessages.set(
                any2EvmMessage.messageId,
                uint256(ErrorCode.FAILED)
            );
            s_messageContents[any2EvmMessage.messageId] = any2EvmMessage;
            emit MessageFailed(any2EvmMessage.messageId, err);
            return;
        }
    }

    function processMessage(
        Client.Any2EVMMessage calldata any2EvmMessage
    ) external {
        require(msg.sender == address(this), "Only self");
        _ccipReceive(any2EvmMessage);
    }

    function _ccipReceive(
        Client.Any2EVMMessage memory any2EvmMessage
    ) internal override {
        require(
            any2EvmMessage.destTokenAmounts[0].token == address(usdc),
            "Wrong received token"
        );

        (bool success, bytes memory returnData) = address(this).call(
            any2EvmMessage.data
        );
        require(success, "Call to contract failed");

        emit MessageReceived(
            any2EvmMessage.messageId,
            any2EvmMessage.sourceChainSelector,
            abi.decode(any2EvmMessage.sender, (address)),
            any2EvmMessage.destTokenAmounts[0].token,
            any2EvmMessage.destTokenAmounts[0].amount
        );
    }

    function _investFunds() internal {
        uint256 usdcBalance = usdc.balanceOf(address(this));
        require(usdcBalance > 0, "Insufficient USDC balance");

        for (uint256 i = 0; i < 3; i++) {
            bool shouldBorrow = (i != 2);
            usdcBalance = _investLoop(usdcBalance, shouldBorrow);
        }
    }

    function _investLoop(
        uint256 usdcAmount,
        bool shouldBorrow
    ) internal returns (uint256) {
        uint256 usdcPriceInUSD = getPricePyth(usdcUsdPriceFeedId);
        uint256 wethPriceInUSD = getPricePyth(wethUsdPriceFeedId);
        // 1. Supply USDC to Aave
        usdc.approve(address(aavePool), usdcAmount);
        aavePool.supply(address(usdc), usdcAmount, address(this), 0);

        if (shouldBorrow) {
            uint256 usdcAmountIn18Decimals = usdcAmount * 10 ** 12;
            // Finding total price of the asset supplied in USD
            uint256 usdcAmountIn18DecimalsInUSD = (usdcAmountIn18Decimals *
                (usdcPriceInUSD)) / 10 ** 8;
            // Fetching LTV of USDC from Aave
            (, uint256 ltv, , , , , , , , ) = aaveProtocolDataProvider
                .getReserveConfigurationData(address(usdc));
            // Calculating the maximum loan amount in USD
            uint256 maxLoanAmountIn18DecimalsInUSD = (usdcAmountIn18DecimalsInUSD *
                    ltv) / 10 ** 5;
            // Calculating the maximum amount of cbETH that can be borrowed
            uint256 wethAbleToBorrow = (maxLoanAmountIn18DecimalsInUSD *
                10 ** 8) / wethPriceInUSD;
            // Borrowing cbETH after calculating a safe amount
            uint256 safeAmount = (wethAbleToBorrow * 95) / 100;
            aavePool.borrow(address(weth), safeAmount, 2, 0, address(this));

            // 5. Swap WETH for USDC using Uniswap
            uint256 usdcReceived = _swapWETHToUSDC(safeAmount);

            return usdcReceived;
        }

        return usdcAmount;
    }

    function _swapWETHToUSDC(
        uint256 amountIn
    ) internal returns (uint256 amountOut) {
        TransferHelper.safeApprove(address(weth), swapRouter, amountIn);

        bytes memory path = abi.encodePacked(
            address(weth),
            uint24(500), // 0.05% fee tier in Optimism Sepolia
            address(usdc)
        );

        bytes memory data = abi.encodeWithSignature(
            "exactInput((bytes,address,uint256,uint256))",
            abi.encode(path, address(this), amountIn, 0)
        );

        (bool success, bytes memory result) = swapRouter.call(data);
        require(success, "Swap failed");
        amountOut = abi.decode(result, (uint256));
    }

    function retryFailedMessage(
        bytes32 messageId,
        address beneficiary
    ) external onlyOwner {
        require(
            s_failedMessages.get(messageId) == uint256(ErrorCode.FAILED),
            "Message not failed"
        );

        s_failedMessages.set(messageId, uint256(ErrorCode.RESOLVED));

        Client.Any2EVMMessage memory message = s_messageContents[messageId];

        IERC20(message.destTokenAmounts[0].token).safeTransfer(
            beneficiary,
            message.destTokenAmounts[0].amount
        );

        emit MessageRecovered(messageId);
    }

    function getFailedMessages(
        uint256 offset,
        uint256 limit
    ) external view returns (FailedMessage[] memory) {
        uint256 length = s_failedMessages.length();
        uint256 returnLength = (offset + limit > length)
            ? length - offset
            : limit;
        FailedMessage[] memory failedMessages = new FailedMessage[](
            returnLength
        );

        for (uint256 i = 0; i < returnLength; i++) {
            (bytes32 messageId, uint256 errorCode) = s_failedMessages.at(
                offset + i
            );
            failedMessages[i] = FailedMessage(messageId, ErrorCode(errorCode));
        }
        return failedMessages;
    }

    function harvest() external onlyOwner {
        // Get current balances
        uint256 currentAUSDCBalance = IERC20(aUSDC).balanceOf(address(this));
        uint256 currentVariableDebtBalance = IERC20(variableDebtWETH).balanceOf(
            address(this)
        );

        // Calculate the change in balances
        uint256 borrowedWETHChange = currentVariableDebtBalance -
            previousVariableDebtBalance;

        // Calculate the net gain in Aave
        uint256 suppliedUSDCValueChange = currentAUSDCBalance -
            previousAUSDCBalance;
        uint256 borrowedWETHValueChangeInUSDC = (getPricePyth(
            wethUsdPriceFeedId
        ) * borrowedWETHChange) / (getPricePyth(usdcUsdPriceFeedId) * 10 ** 12);

        int256 aaveNetGain = int256(suppliedUSDCValueChange) -
            int256(borrowedWETHValueChangeInUSDC);

        // Update the previous balances
        previousAUSDCBalance = currentAUSDCBalance;
        previousVariableDebtBalance = currentVariableDebtBalance;

        // Send net gain value to Mode.sol
        sendMessageToMode("_accountAssetsAfterHarvest()", 0, aaveNetGain);

        emit HarvestReport(aaveNetGain);
    }

    function withdrawFunds(uint256 amountToWithdraw) external onlyOwner {
        require(amountToWithdraw > 0, "Amount must be greater than 0");

        uint256 currentUSDCBalance = usdc.balanceOf(address(this));
        uint256 aUSDCBalance = IERC20(aUSDC).balanceOf(address(this));
        uint256 wethDebt = IERC20(variableDebtWETH).balanceOf(address(this));
        uint256 usdcPriceInUSD = getPricePyth(usdcUsdPriceFeedId);
        uint256 wethPriceInUSD = getPricePyth(wethUsdPriceFeedId);

        // Calculate how much USDC we need to withdraw from Aave

        (, uint256 ltv, , , , , , , , ) = aaveProtocolDataProvider
            .getReserveConfigurationData(address(usdc));
        uint usdcAmountToWithdrawInUSD = (amountToWithdraw *
            usdcPriceInUSD *
            10 ** 12) / PRICE_DENOMINATOR;

        //amount of WETH(in $) we can get for amountToWithdraw of USDC(in $)
        uint wethAmountToRepayInUSD = (usdcAmountToWithdrawInUSD * ltv) / 10000;
        uint wethAmountToRepay = (wethAmountToRepayInUSD * 10 ** 8) /
            wethPriceInUSD;
        // Calculate how much WETH we need to repay

        // Repay WETH debt
        weth.approve(address(aavePool), wethAmountToRepay);
        aavePool.repay(address(weth), wethAmountToRepay, 2, address(this));

        // Withdraw USDC from Aave

        aavePool.withdraw(address(usdc), amountToWithdraw, address(this));

        // Transfer USDC to the owner
        uint256 finalUSDCBalance = usdc.balanceOf(address(this));
        uint256 amountToTransfer = amountToWithdraw < finalUSDCBalance
            ? amountToWithdraw
            : finalUSDCBalance;
        if (amountToTransfer > 0) {
            usdc.safeTransfer(owner(), amountToTransfer);
        }

        // Send withdrawal information to Mode.sol
        sendMessageToMode("withdrawAll", amountToTransfer, 0);
    }

    function sendMessageToMode(
        string memory functionName,
        uint256 amount,
        int256 value
    ) internal {
        uint64 destinationChainSelector = 111; // Replace with actual Mode chain selector
        address receiver = s_receivers[destinationChainSelector];
        require(
            receiver != address(0),
            "Receiver not set for destination chain"
        );

        uint256 gasLimit = s_gasLimits[destinationChainSelector];
        require(gasLimit != 0, "Gas limit not set for destination chain");

        Client.EVMTokenAmount[] memory tokenAmounts;
        if (amount > 0) {
            tokenAmounts = new Client.EVMTokenAmount[](1);
            tokenAmounts[0] = Client.EVMTokenAmount({
                token: address(usdc),
                amount: amount
            });
            IERC20(address(usdc)).approve(address(i_router), amount);
        } else {
            tokenAmounts = new Client.EVMTokenAmount[](0);
        }

        // Encode the function call for the receiving contract
        bytes memory encodedFunction = abi.encodeWithSignature(
            functionName,
            value
        );

        sendMessage(receiver, encodedFunction, tokenAmounts, gasLimit);
    }

    function sendMessage(
        address receiver,
        bytes memory encodedFunction,
        Client.EVMTokenAmount[] memory tokenAmounts,
        uint256 gasLimit
    ) internal {
        uint64 destinationChainSelector = 111;
        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: encodedFunction,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: gasLimit})
            ),
            feeToken: address(i_linkToken)
        });

        uint256 fees = i_router.getFee(
            destinationChainSelector,
            evm2AnyMessage
        );
        require(
            i_linkToken.balanceOf(address(this)) >= fees,
            "Not enough LINK for fees"
        );

        i_linkToken.approve(address(i_router), fees);
        if (tokenAmounts.length > 0) {
            usdc.approve(address(i_router), tokenAmounts[0].amount);
        }

        bytes32 messageId = i_router.ccipSend(
            destinationChainSelector,
            evm2AnyMessage
        );

        emit MessageSent(
            messageId,
            destinationChainSelector,
            receiver,
            tokenAmounts.length > 0 ? address(usdc) : address(0),
            tokenAmounts.length > 0 ? tokenAmounts[0].amount : 0,
            address(i_linkToken),
            fees
        );
    }

    function getPricePyth(bytes32 priceFeedId) public view returns (uint) {
        PythStructs.Price memory price = pyth.getPrice(priceFeedId);
        return uint256(uint64(price.price));
    }
}
