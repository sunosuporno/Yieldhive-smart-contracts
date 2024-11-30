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

    function swap(SwapParams memory params) internal returns (uint256 amountOut) {
        TransferHelper.safeApprove(params.tokenIn, address(params.router), params.amountIn);

        // Get prices from Chainlink
        uint256 inPrice = getChainlinkPrice(params.priceFeedIn);
        uint256 outPrice = getChainlinkPrice(params.priceFeedOut);

        // Calculate the expected amount out
        uint256 expectedAmountOut = (params.amountIn * inPrice) / outPrice;

        // Adjust for decimal differences if necessary
        uint256 inDecimals = IERC20Metadata(params.tokenIn).decimals();
        uint256 outDecimals = IERC20Metadata(params.tokenOut).decimals();
        if (inDecimals != outDecimals) {
            expectedAmountOut = (expectedAmountOut * (10 ** outDecimals)) / (10 ** inDecimals);
        }

        // Calculate minimum amount out with 2% slippage tolerance
        uint256 amountOutMinimum = (expectedAmountOut * 98) / 100;

        bytes memory path = abi.encodePacked(params.tokenIn, params.fee1, params.WETH9, params.fee2, params.tokenOut);

        IV3SwapRouter.ExactInputParams memory swapParams = IV3SwapRouter.ExactInputParams({
            path: path,
            recipient: msg.sender,
            amountIn: params.amountIn,
            amountOutMinimum: amountOutMinimum
        });

        amountOut = params.router.exactInput(swapParams);
        return amountOut;
    }

    function getChainlinkPrice(address priceFeed) internal view returns (uint256) {
        (, int256 answer,,,) = AggregatorV3Interface(priceFeed).latestRoundData();
        return uint256(answer);
    }

    function swapCbETHToUSDCAndAERO(SwapParams memory baseParams, address USDC, address AERO)
        external
        returns (TokenSwapResult memory result)
    {
        // Split amount for both swaps
        uint256 halfAmount = baseParams.amountIn / 2;
        console.log("halfAmount: %s", halfAmount);

        // Swap half to AERO
        SwapParams memory aeroParams = baseParams;
        aeroParams.tokenOut = AERO;
        aeroParams.amountIn = halfAmount;
        result.amountOutAERO = swap(aeroParams);

        // Swap half to USDC
        SwapParams memory usdcParams = baseParams;
        usdcParams.tokenOut = USDC;
        usdcParams.amountIn = halfAmount;
        result.amountOutUSDC = swap(usdcParams);

        return result;
    }

    function swapUSDCAndAEROToCbETH(SwapParams memory baseParams, uint256 amountInUSDC, uint256 amountInAERO)
        external
        returns (uint256)
    {
        // Swap USDC to cbETH
        SwapParams memory usdcParams = baseParams;
        usdcParams.amountIn = amountInUSDC;
        uint256 amountOutcbETH1 = swap(usdcParams);

        // Swap AERO to cbETH
        SwapParams memory aeroParams = baseParams;
        aeroParams.tokenIn = baseParams.tokenOut; // AERO
        aeroParams.amountIn = amountInAERO;
        uint256 amountOutcbETH2 = swap(aeroParams);

        return amountOutcbETH1 + amountOutcbETH2;
    }
}
