// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./interfaces/IPythPriceUpdater.sol";

contract PythPriceUpdater is IPythPriceUpdater {
    bytes[] private priceUpdate;

    function getPricePyth() external view override returns (bytes[] memory) {
        return priceUpdate;
    }

    function setPricePyth(bytes[] calldata newPriceUpdate) external override {
        priceUpdate = newPriceUpdate;
    }
}
