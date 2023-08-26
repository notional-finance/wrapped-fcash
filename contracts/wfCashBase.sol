// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "./lib/Constants.sol";
import "./lib/DateTime.sol";
import "./lib/EncodeDecode.sol";
import "../interfaces/notional/INotionalV2.sol";
import "../interfaces/notional/IWrappedfCash.sol";
import "../interfaces/WETH9.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";

abstract contract wfCashBase is ERC20Upgradeable, IWrappedfCash {
    using SafeERC20 for IERC20;

    /// @notice address to the NotionalV2 system
    INotionalV2 public immutable NotionalV2;
    WETH9 public immutable WETH;

    /// @dev Storage slot for fCash id. Read only and set on initialization
    uint64 private _fCashId;

    /// @notice Constructor is called only on deployment to set the Notional address, rest of state
    /// is initialized on the proxy.
    /// @dev Ensure initializer modifier is on the constructor to prevent an attack on UUPSUpgradeable contracts
    constructor(INotionalV2 _notional, WETH9 _weth) initializer {
        NotionalV2 = _notional;
        WETH = _weth;
    }

    /// @notice Initializes a proxy for a specific fCash asset
    function initialize(uint16 currencyId, uint40 maturity) external override initializer {
        CashGroupSettings memory cashGroup = NotionalV2.getCashGroup(currencyId);
        require(cashGroup.maxMarketIndex > 0, "Invalid currency");
        require(maturity > block.timestamp, "Invalid maturity");
        // Ensure that the maturity is not past the max market index, also ensure that the maturity
        // is not in the past. This statement will allow idiosyncratic (non-tradable) fCash assets.
        require(
            DateTime.isValidMaturity(cashGroup.maxMarketIndex, maturity, block.timestamp),
            "Invalid maturity"
        );

        // Get the corresponding fCash ID
        uint256 fCashId = EncodeDecode.encodeERC1155Id(currencyId, maturity, Constants.FCASH_ASSET_TYPE);
        require(fCashId <= uint256(type(uint64).max));
        _fCashId = uint64(fCashId);

        (IERC20 underlyingToken, /* */) = getUnderlyingToken();
        (IERC20 assetToken, /* */, /* */) = getAssetToken();

        string memory _symbol = address(underlyingToken) == Constants.ETH_ADDRESS
            ? "ETH"
            : IERC20Metadata(address(underlyingToken)).symbol();

        string memory _maturity = Strings.toString(maturity);

        __ERC20_init(
            // name
            string(abi.encodePacked("Wrapped f", _symbol, " @ ", _maturity)),
            // symbol
            string(abi.encodePacked("wf", _symbol, ":", _maturity))
        );

        // Set approvals for Notional. It is possible for an asset token address to equal the underlying
        // token address when there is no money market involved.
        assetToken.safeApprove(address(NotionalV2), type(uint256).max);
        if (
            address(assetToken) != address(underlyingToken) &&
            address(underlyingToken) != Constants.ETH_ADDRESS
        ) {
            underlyingToken.safeApprove(address(NotionalV2), type(uint256).max);
        }
    }

    /// @notice Returns the underlying fCash ID of the token
    function getfCashId() public view override returns (uint256) {
        return _fCashId;
    }

    /// @notice Returns the underlying fCash maturity of the token
    function getMaturity() public view override returns (uint40 maturity) {
        (/* */, maturity, /* */) = EncodeDecode.decodeERC1155Id(_fCashId);
    }

    /// @notice True if the fCash has matured, assets mature exactly on the block time
    function hasMatured() public view override returns (bool) {
        return getMaturity() <= block.timestamp;
    }

    /// @notice Returns the underlying fCash currency
    function getCurrencyId() public view override returns (uint16 currencyId) {
        (currencyId, /* */, /* */) = EncodeDecode.decodeERC1155Id(_fCashId);
    }

    /// @notice Returns the components of the fCash idd
    function getDecodedID() public view override returns (uint16 currencyId, uint40 maturity) {
        (currencyId, maturity, /* */) = EncodeDecode.decodeERC1155Id(_fCashId);
    }

    /// @notice fCash is always denominated in 8 decimal places
    function decimals() public pure override returns (uint8) {
        return Constants.INTERNAL_TOKEN_DECIMALS;
    }

    /// @notice Returns the current market index for this fCash asset. If this returns
    /// zero that means it is idiosyncratic and cannot be traded.
    function getMarketIndex() public view override returns (uint8) {
        (uint256 marketIndex, bool isIdiosyncratic) = DateTime.getMarketIndex(
            Constants.MAX_TRADED_MARKET_INDEX,
            getMaturity(),
            block.timestamp
        );

        if (isIdiosyncratic) return 0;
        // Market index as defined does not overflow this conversion
        return uint8(marketIndex);
    }

    /// @notice Returns the token and precision of the token that this token settles
    /// to. For example, fUSDC will return the USDC token address and 1e6. The zero
    /// address will represent ETH.
    function getUnderlyingToken() public view override returns (IERC20 underlyingToken, int256 underlyingPrecision) {
        (Token memory asset, Token memory underlying) = NotionalV2.getCurrency(getCurrencyId());

        if (asset.tokenType == TokenType.NonMintable) {
            // In this case the asset token is the underlying
            return (IERC20(asset.tokenAddress), asset.decimals);
        } else {
            return (IERC20(underlying.tokenAddress), underlying.decimals);
        }
    }

    /// @notice Returns the asset token which the fCash settles to. This will be an interest
    /// bearing token like a cToken or aToken.
    function getAssetToken() public view override returns (IERC20 assetToken, int256 underlyingPrecision, TokenType tokenType) {
        (Token memory asset, /* Token memory underlying */) = NotionalV2.getCurrency(getCurrencyId());
        return (IERC20(asset.tokenAddress), asset.decimals, asset.tokenType);
    }

    function getToken(bool useUnderlying) public view returns (IERC20 token, bool isETH) {
        if (useUnderlying) {
            (token, /* */) = getUnderlyingToken();
        } else {
            (token, /* */, /* */) = getAssetToken();
        }
        isETH = address(token) == Constants.ETH_ADDRESS;
    }

    function getTotalFCashAvailable() public view returns (uint256) {
        uint8 marketIndex = getMarketIndex();
        if (marketIndex == 0) return 0;
        MarketParameters[] memory markets = NotionalV2.getActiveMarkets(getCurrencyId());
        require(markets.length <= marketIndex);

        int256 totalfCash = markets[marketIndex - 1].totalfCash;
        require(totalfCash > 0);

        return uint256(totalfCash);
    }

    function getBalances() public view returns (int256 cashBalance, uint256 fCashBalance) {
        (cashBalance, /* */, /* */) = NotionalV2.getAccountBalance(getCurrencyId(), address(this));
        fCashBalance = NotionalV2.balanceOf(address(this), _fCashId);
    }

    function getPresentCashValue(uint256 fCashAmount) internal view returns (
        uint256 primeCashValue,
        uint256 pvExternalUnderlying
    ) {
        if (hasMatured()) return (0, 0);
        (/* */, int256 precision) = getUnderlyingToken();

        // Get the present value of the fCash held by the contract, this is returned in 8 decimal precision
        (uint16 currencyId, uint40 maturity) = getDecodedID();
        int256 pvInternal = NotionalV2.getPresentfCashValue(
            currencyId,
            maturity,
            int256(fCashAmount),
            block.timestamp,
            false
        );
        int256 pvExternal = pvInternal * precision / Constants.INTERNAL_TOKEN_PRECISION;
        require(pvExternal >= 0);
        int256 cashValue = NotionalV2.convertUnderlyingToPrimeCash(currencyId, pvExternal);
        require(cashValue >= 0);

        primeCashValue = uint256(cashValue);
        pvExternalUnderlying = uint256(pvExternal);
    }

    function getMaturedCashValue(uint256 fCashAmount) internal view returns (uint256) {
        if (!hasMatured()) return 0;
        // If the fCash has matured we use the cash balance instead.
        (uint16 currencyId, uint40 maturity) = getDecodedID();
        PrimeRate memory pr = NotionalV2.getSettlementRate(currencyId, maturity);

        // fCash has not yet been settled
        if (pr.supplyFactor == 0) return 0;
        require(pr.supplyFactor > 0);

        return fCashAmount * uint256(pr.supplyFactor) / Constants.DOUBLE_SCALAR_PRECISION;
    }

    /// @dev Internal method with more flags required for use inside mint internal
    function _getTokenForMintInternal() internal view returns (
        IERC20 token, bool isETH, bool hasTransferFee, uint256 precision
    ) {
        (/* */, Token memory underlying) = NotionalV2.getCurrency(getCurrencyId());
        token = IERC20(underlying.tokenAddress);
        hasTransferFee = underlying.hasTransferFee;
        isETH = address(token) == Constants.ETH_ADDRESS;

        require(underlying.decimals > 0);
        precision = uint256(underlying.decimals);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[45] private __gap;
}