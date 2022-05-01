// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./wfCashLogic.sol";
import "../interfaces/IERC4626.sol";

contract wfCashERC4626 is IERC4626, wfCashLogic {
    constructor(INotionalV2 _notional) wfCashLogic(_notional) {}

    /** @dev See {IERC4262-asset} */
    function asset() public view override returns (address) {
        (IERC20 underlyingToken, /* */) = getUnderlyingToken();
        return address(underlyingToken);
    }

    /** @dev See {IERC4262-totalAssets} */
    function totalAssets() public view override returns (uint256) {
        // TODO: if has matured convert cash balance share...

        int256 pv = NotionalV2.getPresentfCashValue(
            getCurrencyId(),
            getMaturity(),
            int256(totalSupply()), // total supply cannot overflow as fCash overflows at uint88
            block.timestamp,
            false
        );

        // PV should always be >= 0
        require(pv >= 0);
        return uint256(pv);
    }

    /** @dev See {IERC4262-convertToShares} */
    function convertToShares(uint256 assets) public view override returns (uint256 shares) {
        (/* */, int256 precision) = getUnderlyingToken();
        uint256 underlyingCashInternal = (assets * uint256(Constants.INTERNAL_TOKEN_PRECISION)) / uint256(precision);

        // TODO: if has matured convert cash balance share...

        int256 fCashAmount = NotionalV2.getfCashAmountGivenCashAmount(
            getCurrencyId(),
            _safeNegInt88(underlyingCashInternal),
            getMarketIndex(),
            block.timestamp
        );
        require(fCashAmount > 0);

        // Overflow checked above.
        return uint256(fCashAmount);
    }

    /** @dev See {IERC4262-convertToAssets} */
    function convertToAssets(uint256 shares) public view override returns (uint256 assets) {
        // TODO: if has matured convert cash balance share...

        (/*  */, int256 underlyingCashInternal) = NotionalV2.getCashAmountGivenfCashAmount(
            getCurrencyId(),
            _safeNegInt88(shares),
            getMarketIndex(),
            block.timestamp
        );

        (/* */, int256 precision) = getUnderlyingToken();
        int256 underlyingCashExternal = (underlyingCashInternal * precision) / Constants.INTERNAL_TOKEN_PRECISION;
        require(underlyingCashExternal > 0);

        return uint256(underlyingCashExternal);
    }

    /** @dev See {IERC4262-maxDeposit} */
    function maxDeposit(address) public view override returns (uint256) {
        return hasMatured() ? 0 : type(uint256).max;
    }

    /** @dev See {IERC4262-maxMint} */
    function maxMint(address) public view override returns (uint256) {
        return hasMatured() ? 0 : type(uint88).max;
    }

    /** @dev See {IERC4262-maxWithdraw} */
    function maxWithdraw(address owner) public view override returns (uint256) {
        return convertToAssets(balanceOf(owner));
    }

    /** @dev See {IERC4262-maxRedeem} */
    function maxRedeem(address owner) public view override returns (uint256) {
        return balanceOf(owner);
    }

    /** @dev See {IERC4262-previewDeposit} */
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        require(!hasMatured(), "Matured");
        return convertToShares(assets);
    }

    /** @dev See {IERC4262-previewMint} */
    function previewMint(uint256 shares) public view override returns (uint256) {
        require(!hasMatured(), "Matured");
        uint256 assets = convertToAssets(shares);
        return assets + (convertToShares(assets) < shares ? 1 : 0);
    }

    /** @dev See {IERC4262-previewWithdraw} */
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 shares = convertToShares(assets);
        return shares + (convertToAssets(shares) < assets ? 1 : 0);
    }

    /** @dev See {IERC4262-previewRedeem} */
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return convertToAssets(shares);
    }

    /** @dev See {IERC4262-deposit} */
    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        require(assets <= maxDeposit(receiver), "Max Deposit");
        uint256 shares = previewDeposit(assets);

        _mintInternal(assets, _safeUint88(shares), receiver, 0, true);
        emit Deposit(msg.sender, receiver, assets, shares);
        return shares;
    }

    /** @dev See {IERC4262-mint} */
    function mint(uint256 shares, address receiver) public override returns (uint256) {
        uint256 assets = previewMint(shares);

        _mintInternal(assets, _safeUint88(shares), receiver, 0, true);
        emit Deposit(msg.sender, receiver, assets, shares);
        return assets;
    }

    /** @dev See {IERC4262-withdraw} */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override returns (uint256) {
        uint256 shares = previewWithdraw(assets);

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _redeemInternal(shares, receiver, owner);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        return shares;
    }

    /** @dev See {IERC4262-redeem} */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override returns (uint256) {
        uint256 assets = previewRedeem(shares);

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _redeemInternal(shares, receiver, owner);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return assets;
    }

    function _redeemInternal(
        uint256 shares,
        address receiver,
        address owner
    ) private {
        redeem(
            shares,
            RedeemOpts({
                redeemToUnderlying: true,
                transferfCash: false,
                receiver: receiver,
                maxImpliedRate: 0
            })
        );
    }

    function _safeNegInt88(uint256 x) private pure returns (int88) {
        int256 y = -int256(x);
        require(int256(type(int88).min) <= y);
        return int88(y);
    }
}