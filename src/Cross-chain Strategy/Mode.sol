// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRouterClient} from "@chainlink/contracts-ccip@1.4.0/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip@1.4.0/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip@1.4.0/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip@1.4.0/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * THIS IS AN EXAMPLE CONTRACT THAT USES HARDCODED VALUES FOR CLARITY.
 * THIS IS AN EXAMPLE CONTRACT THAT USES UN-AUDITED CODE.
 * DO NOT USE THIS CODE IN PRODUCTION.
 */

/// @title - A simple contract for sending string data across chains.
contract BaseStrategy is ERC4626, Ownable {
    using Math for uint256;
    using SafeERC20 for IERC20;
    // Custom errors to provide more descriptive revert messages.
    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees); // Used to make sure contract has enough balance.

    // Event emitted when a message is sent to another chain.
    event MessageSent(
        bytes32 indexed messageId, // The unique ID of the CCIP message.
        uint64 indexed destinationChainSelector, // The chain selector of the destination chain.
        address receiver, // The address of the receiver on the destination chain.
        address asset,
        uint256 amount,
        address feeToken, // the token address used to pay CCIP fees.
        uint256 fees // The fees paid for sending the CCIP message.
    );

    IRouterClient private immutable i_router;
    IERC20 private immutable i_linkToken;

    // Mapping to keep track of the receiver contract per destination chain.
    mapping(uint64 => address) public s_receivers;
    // Mapping to store the gas limit per destination chain.
    mapping(uint64 => uint256) public s_gasLimits;

    // Mapping to keep track of the sender contract per source chain.
    mapping(uint64 => address) public s_senders;

    // The message contents of failed messages are stored here.
    mapping(bytes32 => Client.Any2EVMMessage) public s_messageContents;

    /// @notice Constructor initializes the contract with the router address.
    /// @param _router The address of the router contract.
    /// @param _link The address of the link contract.
    /// @param _initialDeposit The initial deposit of assets.
    /// @param _asset The address of the asset token.
    /// @param initialOwner The address of the initial owner.
    /// @param name_ The name of the token.
    /// @param symbol_ The symbol of the token.
    constructor(
        IERC20 asset_,
        address _router,
        address _link,
        uint256 _initialDeposit,
        address _asset,
        address initialOwner,
        string memory name_,
        string memory symbol_
    ) ERC4626(asset_) ERC20(name_, symbol_) Ownable(initialOwner) {
        asset_.safeTransferFrom(msg.sender, address(this), _initialDeposit);
        i_router = IRouterClient(_router);
        i_linkToken = IERC20(_link);
    }

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        address assetAddress = asset();
        // Transfer the assets from the caller to this contract
        SafeERC20.safeTransferFrom(
            IERC20(assetAddress),
            caller,
            address(this),
            assets
        );

        // Mint shares to the receiver
        _mint(receiver, shares);

        // Call the internal function to invest the funds
        _investFunds(assets, assetAddress);

        emit Deposit(caller, receiver, assets, shares);
    }

    function _investFunds(uint256 assets, address assetAddress) internal {
        uint64 destinationChainSelector = 111; // Replace with actual Optimism chain selector
        address receiver = s_receivers[destinationChainSelector];
        require(assets > 0, "Amount must be greater than 0");
        require(
            receiver != address(0),
            "Receiver not set for destination chain"
        );

        uint256 gasLimit = s_gasLimits[destinationChainSelector];
        require(gasLimit != 0, "Gas limit not set for destination chain");

        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: assetAddress,
            amount: assets
        });

        // Encode the function call for the receiving contract
        bytes memory encodedFunction = abi.encodeWithSignature(
            "_investFunds()"
        );

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
        IERC20(assetAddress).approve(address(i_router), assets);

        bytes32 messageId = i_router.ccipSend(
            destinationChainSelector,
            evm2AnyMessage
        );

        emit MessageSent(
            messageId,
            destinationChainSelector,
            receiver,
            assetAddress,
            assets,
            address(i_linkToken),
            fees
        );
    }

    // Add functions to set receiver and gas limit for destination chains
    function setReceiverForDestinationChain(
        uint64 _destinationChainSelector,
        address _receiver
    ) external onlyOwner {
        require(_receiver != address(0), "Invalid receiver address");
        s_receivers[_destinationChainSelector] = _receiver;
    }

    function setGasLimitForDestinationChain(
        uint64 _destinationChainSelector,
        uint256 _gasLimit
    ) external onlyOwner {
        require(_gasLimit > 0, "Invalid gas limit");
        s_gasLimits[_destinationChainSelector] = _gasLimit;
    }
}
