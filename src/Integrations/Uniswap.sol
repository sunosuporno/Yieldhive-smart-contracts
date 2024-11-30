// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TransferHelper} from "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import {ISwapRouter02, IV3SwapRouter} from "../interfaces/ISwapRouter.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {console} from "forge-std/Test.sol";

library Uniswap {
    struct SwapParams {
        ISwapRouter02 router;
        address tokenIn;
        address tokenOut;
        address WETH9;
        uint24 fee1;
        uint24 fee2;
        uint256 amountIn;
        address priceFeedIn;
        address priceFeedOut;
    }

    struct TokenSwapResult {
        uint256 amountOut;
        uint256 amountOutUSDC;
        uint256 amountOutAERO;
    }

    // function swap(SwapParams memory params) internal returns (uint256 amountOut) {
    //     TransferHelper.safeApprove(params.tokenIn, address(params.router), params.amountIn);

    //     // Get prices from Chainlink
    //     uint256 inPrice = getChainlinkPrice(params.priceFeedIn);
    //     uint256 outPrice = getChainlinkPrice(params.priceFeedOut);

    //     // Calculate the expected amount out
    //     uint256 expectedAmountOut = (params.amountIn * inPrice) / outPrice;

    //     // Adjust for decimal differences if necessary
    //     uint256 inDecimals = IERC20Metadata(params.tokenIn).decimals();
    //     uint256 outDecimals = IERC20Metadata(params.tokenOut).decimals();
    //     if (inDecimals != outDecimals) {
    //         expectedAmountOut = (expectedAmountOut * (10 ** outDecimals)) / (10 ** inDecimals);
    //     }

    //     // Calculate minimum amount out with 2% slippage tolerance
    //     uint256 amountOutMinimum = (expectedAmountOut * 98) / 100;

    //     bytes memory path = abi.encodePacked(params.tokenIn, params.fee1, params.WETH9, params.fee2, params.tokenOut);

    //     IV3SwapRouter.ExactInputParams memory swapParams = IV3SwapRouter.ExactInputParams({
    //         path: path,
    //         recipient: msg.sender,
    //         amountIn: params.amountIn,
    //         amountOutMinimum: amountOutMinimum
    //     });

    //     amountOut = params.router.exactInput(swapParams);
    //     return amountOut;
    // }

    ISwapRouter02 public constant swapRouter = ISwapRouter02(0x2626664c2603336E57B271c5C0b26F421741e481);

    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant CBETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant WETH9 = 0x4200000000000000000000000000000000000006;
    address constant A_USDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address constant DEBT_CBETH = 0x1DabC36f19909425f654777249815c073E8Fd79F;
    address constant usdcUsdDataFeedAddress = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address constant cbEthUsdDataFeedAddress = 0xd7818272B9e248357d13057AAb0B417aF31E817d;
    address constant aeroUsdDataFeedAddress = 0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0;
    address constant swapRouterAddress = 0x2626664c2603336E57B271c5C0b26F421741e481;

    function _swap(
        address tokenIn,
        address tokenOut,
        uint256 fee1,
        uint256 fee2,
        uint256 amountIn,
        uint256 inPrice,
        uint256 outPrice
    ) internal returns (uint256 amountOut) {
        TransferHelper.safeApprove(tokenIn, address(swapRouter), amountIn);

        // // Get price feed IDs for both input and output tokens
        // address inPriceFeedId = getDataFeedAddress(tokenIn);
        // address outPriceFeedId = getDataFeedAddress(tokenOut);

        // address[] memory dataFeedAddresses = new address[](2);
        // dataFeedAddresses[0] = inPriceFeedId;
        // dataFeedAddresses[1] = outPriceFeedId;
        // uint256[] memory prices = getChainlinkDataFeedLatestAnswer(dataFeedAddresses);
        // uint256 inPrice = prices[0];
        // uint256 outPrice = prices[1];
        console.log("Price calculated for swap");

        // Calculate the expected amount out
        uint256 expectedAmountOut = (amountIn * inPrice) / outPrice;

        // Adjust for decimal differences if necessary
        uint256 inDecimals = IERC20Metadata(tokenIn).decimals();
        uint256 outDecimals = IERC20Metadata(tokenOut).decimals();
        if (inDecimals != outDecimals) {
            expectedAmountOut = (expectedAmountOut * (10 ** outDecimals)) / (10 ** inDecimals);
        }

        // Calculate the minimum amount out with 2% slippage tolerance
        uint256 amountOutMinimum = (expectedAmountOut * 98) / 100;
        console.log("Amount out minimum calculated");

        bytes memory path = abi.encodePacked(tokenIn, uint24(fee1), WETH9, uint24(fee2), tokenOut);

        IV3SwapRouter.ExactInputParams memory params = IV3SwapRouter.ExactInputParams({
            path: path,
            recipient: address(this),
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum
        });
        console.log("Params set for swap");

        amountOut = swapRouter.exactInput(params);
        console.log("Swap executed");
    }

    // function getDataFeedAddress(address token) external view returns (address) {
    //     if (token == address(asset())) {
    //         return usdcUsdDataFeedAddress;
    //     } else if (token == cbETH) {
    //         return cbEthUsdDataFeedAddress;
    //     } else if (token == AERO) {
    //         return aeroUsdDataFeedAddress;
    //     } else {
    //         revert("Unsupported token");
    //     }
    // }

    function swapcbETHToUSDCAndAERO(uint256 amountIn, uint256 usdcPrice, uint256 cbETHPrice, uint256 aeroPrice)
        external
        returns (uint256 amountOutUSDC, uint256 amountOutAERO)
    {
        address assetAddress = USDC;
        console.log("swapping cbETH to USDC and AERO");
        // Swap half of cbETH to AERO
        amountOutAERO = _swap(CBETH, AERO, 500, 3000, amountIn / 2, cbETHPrice, aeroPrice);
        console.log("swapped cbETH to AERO");
        // Swap the other half of cbETH to USDC
        amountOutUSDC = _swap(CBETH, assetAddress, 500, 500, amountIn / 2, cbETHPrice, usdcPrice);
        console.log("swapped cbETH to USDC");
        return (amountOutUSDC, amountOutAERO);
    }

    function swapUSDCAndAEROToCbETH(
        uint256 amountInUSDC,
        uint256 amountInAERO,
        uint256 cbEthPrice,
        uint256 usdcPrice,
        uint256 aeroPrice
    ) external returns (uint256) {
        address assetAddress = USDC;
        // Swap USDC to cbETH
        uint256 amountOutcbETH1 = _swap(assetAddress, CBETH, 500, 500, amountInUSDC, usdcPrice, cbEthPrice);
        uint256 amountOutcbETH2 = _swap(AERO, CBETH, 3000, 500, amountInAERO, aeroPrice, cbEthPrice);
        return amountOutcbETH1 + amountOutcbETH2;
    }

    function swapAEROToUSDC(uint256 amountIn, uint256 usdcPrice, uint256 aeroPrice)
        external
        returns (uint256 amountOut)
    {
        amountOut = _swap(AERO, USDC, 3000, 500, amountIn, aeroPrice, usdcPrice);
    }

    // function swapUSDCToAERO(uint256 amountIn) external returns (uint256 amountOut) {
    //     amountOut = swap(asset(), AERO, 500, 3000, amountIn);
    // }
}
