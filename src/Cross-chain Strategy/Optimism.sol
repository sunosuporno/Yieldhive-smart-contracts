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

    address public constant swapRouter =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address public constant aUSDC = 0x625E7708f30cA75bfd92586e17077590C60eb4cD;
    address public constant variableDebtWETH =
        0x0c84331e39d6658Cd6e6b9ba04736cC4c4734351;

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
        address _weth
    ) CCIPReceiver(_router) {
        aavePool = IPoolAave(_aavePool);
        aaveProtocolDataProvider = IPoolDataProvider(_aaveProtocolDataProvider);
        usdc = IERC20(_usdc);
        weth = IERC20(_weth);
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
        // 1. Supply USDC to Aave
        usdc.approve(address(aavePool), usdcAmount);
        aavePool.supply(address(usdc), usdcAmount, address(this), 0);

        if (shouldBorrow) {
            // 2. Calculate borrowing capacity
            (, uint256 ltv, , , , , , , , ) = aaveProtocolDataProvider
                .getReserveConfigurationData(address(usdc));
            uint256 borrowCapacityUSDC = (usdcAmount * ltv) / 1e4; // LTV is in basis points (1e4)

            // 3. Calculate WETH amount to borrow (95% of capacity)
            uint256 wethPrice = getWETHPrice();
            uint256 wethToBorrow = (borrowCapacityUSDC *
                95 *
                PRICE_DENOMINATOR) / (100 * wethPrice);

            // 4. Borrow WETH from Aave
            aavePool.borrow(address(weth), wethToBorrow, 2, 0, address(this));

            // 5. Swap WETH for USDC using Uniswap
            uint256 usdcReceived = _swapWETHToUSDC(wethToBorrow);

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
            uint24(3000), // 0.3% fee tier
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

    function getWETHPrice() public view returns (uint256) {
        // In a real-world scenario, you would use an oracle here.
        // For simplicity, we're using a hardcoded price.
        return 2000 * PRICE_DENOMINATOR; // Assuming 1 WETH = 2000 USDC
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
        uint256 borrowedWETHValueChangeInUSDC = (getWETHPrice() *
            borrowedWETHChange) / (10 ** 18);

        int256 aaveNetGain = int256(suppliedUSDCValueChange) -
            int256(borrowedWETHValueChangeInUSDC);

        // Update the previous balances
        previousAUSDCBalance = currentAUSDCBalance;
        previousVariableDebtBalance = currentVariableDebtBalance;

        // Send net gain value to Mode.sol
        sendMessageToMode(
            "_accountAssetsAfterHarvest()",
            0,
            uint256(aaveNetGain)
        );

        emit HarvestReport(aaveNetGain);
    }

    function withdrawAll() external onlyOwner {
        // Withdraw all USDC from Aave
        uint256 aUSDCBalance = IERC20(aUSDC).balanceOf(address(this));
        if (aUSDCBalance > 0) {
            aavePool.withdraw(address(usdc), type(uint256).max, address(this));
        }

        // Repay all WETH debt
        uint256 wethDebt = IERC20(variableDebtWETH).balanceOf(address(this));
        if (wethDebt > 0) {
            weth.approve(address(aavePool), wethDebt);
            aavePool.repay(address(weth), type(uint256).max, 2, address(this));
        }

        // Transfer all USDC to the owner
        uint256 usdcBalance = usdc.balanceOf(address(this));
        if (usdcBalance > 0) {
            usdc.safeTransfer(owner(), usdcBalance);
        }

        // Send withdrawal information to Mode.sol
        sendMessageToMode("withdrawAll", usdcBalance, 0);
    }

    function sendMessageToMode(
        string memory functionName,
        uint256 amount,
        uint256 value
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
        uint64 destinationChainSelector = 111; // Replace with actual Optimism chain selector
        address receiver = s_receivers[destinationChainSelector];
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
}
