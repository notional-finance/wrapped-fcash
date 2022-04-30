// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;

import "./Constants.sol";

library EncodeDecode {
    /// @notice Specifies the different trade action types in the system. Each trade action type is
    /// encoded in a tightly packed bytes32 object. Trade action type is the first big endian byte of the
    /// 32 byte trade action object. The schemas for each trade action type are defined below.
    enum TradeActionType {
        // (uint8 TradeActionType, uint8 MarketIndex, uint88 fCashAmount, uint32 minImpliedRate, uint120 unused)
        Lend,
        // (uint8 TradeActionType, uint8 MarketIndex, uint88 fCashAmount, uint32 maxImpliedRate, uint120 unused)
        Borrow

        // Below here are unused:
        // // (uint8 TradeActionType, uint8 MarketIndex, uint88 assetCashAmount, uint32 minImpliedRate, uint32 maxImpliedRate, uint88 unused)
        // AddLiquidity,
        // // (uint8 TradeActionType, uint8 MarketIndex, uint88 tokenAmount, uint32 minImpliedRate, uint32 maxImpliedRate, uint88 unused)
        // RemoveLiquidity,
        // // (uint8 TradeActionType, uint32 Maturity, int88 fCashResidualAmount, uint128 unused)
        // PurchaseNTokenResidual,
        // // (uint8 TradeActionType, address CounterpartyAddress, int88 fCashAmountToSettle)
        // SettleCashDebt
    }

    /// @notice Decodes asset ids
    function decodeERC1155Id(uint256 id)
        internal
        pure
        returns (
            uint16 currencyId,
            uint40 maturity,
            uint8 assetType
        )
    {
        assetType = uint8(id);
        maturity = uint40(id >> 8);
        currencyId = uint16(id >> 48);
    }

    /// @notice Encodes asset ids
    function encodeERC1155Id(
        uint256 currencyId,
        uint256 maturity,
        uint256 assetType
    ) internal pure returns (uint256) {
        require(currencyId <= Constants.MAX_CURRENCIES);
        require(maturity <= type(uint40).max);
        require(assetType <= Constants.MAX_LIQUIDITY_TOKEN_INDEX);

        return
            uint256(
                (bytes32(uint256(uint16(currencyId))) << 48) |
                (bytes32(uint256(uint40(maturity))) << 8) |
                bytes32(uint256(uint8(assetType)))
            );
    }

    function encodeLendTrade(
        uint8 marketIndex,
        uint88 fCashAmount,
        uint32 minImpliedRate
    ) internal pure returns (bytes32) {
        return
            bytes32(
                (uint256(uint8(TradeActionType.Lend)) << 248) |
                (uint256(marketIndex) << 240) |
                (uint256(fCashAmount) << 152) |
                (uint256(minImpliedRate) << 120)
            );
    }

    function encodeBorrowTrade(
        uint8 marketIndex,
        uint88 fCashAmount,
        uint32 maxImpliedRate
    ) internal pure returns (bytes32) {
        return
            bytes32(
                uint256(
                    (uint256(uint8(TradeActionType.Borrow)) << 248) |
                    (uint256(marketIndex) << 240) |
                    (uint256(fCashAmount) << 152) |
                    (uint256(maxImpliedRate) << 120)
                )
            );
    }
}