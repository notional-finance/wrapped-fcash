// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "./wfCashLogic.sol";
import "../interfaces/IERC4626.sol";

contract wfCashERC4626 is IERC4626, wfCashLogic {
    constructor(INotionalV2 _notional, WETH9 _weth) wfCashLogic(_notional, _weth) {}

    /** @dev See {IERC4626-asset} */
    function asset() public view override returns (address) {
        (IERC20 underlyingToken, bool isETH) = getToken(true);
        return isETH ? address(WETH) : address(underlyingToken);
    }

    /** 
     * @notice Although not explicitly required by ERC4626 standards, this totalAssets method
     * is expected to be manipulation resistant because it queries an internal Notional V2 TWAP
     * of the fCash interest rate. This means that the value here along with `convertToAssets`
     * and `convertToShares` can be used as an on-chain price oracle.
     *
     * If the wrapper is holding a cash balance prior to maturity, the total value of assets held
     * by the contract will exceed what is returned by this function. The value of the excess value
     * should never be accessible by Wrapped fCash holders due to the redemption mechanism, therefore
     * the lower reported value is correct.
     *
     * @dev See {IERC4626-totalAssets}
     */
    function totalAssets() public view override returns (uint256) {
        if (hasMatured()) {
            // We calculate the matured cash value of the total supply of fCash. This is
            // not always equal to the cash balance held by the wrapper contract.
            uint256 primeCashValue = _getMaturedCashValue(totalSupply());
            require(primeCashValue < uint256(type(int256).max));
            int256 externalValue = NotionalV2.convertCashBalanceToExternal(
                getCurrencyId(), int256(primeCashValue), true
            );
            return externalValue >= 0 ? uint256(externalValue) : 0;
        } else {
            (/* */, uint256 pvExternal) = _getPresentCashValue(totalSupply());
            return pvExternal;
        }
    }

    /** @dev See {IERC4626-convertToShares} */
    function convertToShares(uint256 assets) public view override returns (uint256 shares) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            // Scales assets by the value of a single unit of fCash
            (/* */, uint256 unitfCashValue) = _getPresentCashValue(uint256(Constants.INTERNAL_TOKEN_PRECISION));
            return (assets * uint256(Constants.INTERNAL_TOKEN_PRECISION)) / unitfCashValue;
        }

        return (assets * supply) / totalAssets();
    }

    /** @dev See {IERC4626-convertToAssets} */
    function convertToAssets(uint256 shares) public view override returns (uint256 assets) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            // Catch the edge case where totalSupply causes a divide by zero error
            (/* */, assets) = _getPresentCashValue(shares);
        } else {
            assets = (shares * totalAssets()) / supply;
        }
    }

    /** @dev See {IERC4626-maxDeposit} */
    function maxDeposit(address) external view override returns (uint256) {
        return hasMatured() ? 0 : type(uint256).max;
    }

    /** @dev See {IERC4626-maxMint} */
    function maxMint(address) external view override returns (uint256) {
        return hasMatured() ? 0 : type(uint88).max;
    }

    /** @dev See {IERC4626-maxWithdraw} */
    function maxWithdraw(address owner) external view override returns (uint256) {
        return previewRedeem(balanceOf(owner));
    }

    /** @dev See {IERC4626-maxRedeem} */
    function maxRedeem(address owner) external view override returns (uint256) {
        return balanceOf(owner);
    }

    /** @dev See {IERC4626-previewDeposit} */
    function _previewDeposit(uint256 assets) internal view returns (uint256 shares, uint256 maxFCash) {
        if (hasMatured()) return (0, 0);
        // This is how much fCash received from depositing assets
        (uint16 currencyId, uint40 maturity) = getDecodedID();
        (/* */, maxFCash) = getTotalFCashAvailable();

        try NotionalV2.getfCashLendFromDeposit(
            currencyId,
            assets,
            maturity,
            0,
            block.timestamp,
            true
        ) returns (uint88 s, uint8, bytes32) {
            shares = s;
        } catch {
            shares = maxFCash;
        }
    }

    function previewDeposit(uint256 assets) public view override returns (uint256 shares) {
        (shares, /* */) = _previewDeposit(assets);
    }

    /** @dev See {IERC4626-previewMint} */
    function _previewMint(uint256 shares) internal view returns (uint256 assets, uint256 maxFCash) {
        if (hasMatured()) return (0, 0);

        // This is how much fCash received from depositing assets
        (uint16 currencyId, uint40 maturity) = getDecodedID();
        (/* */, maxFCash) = getTotalFCashAvailable();
        if (maxFCash < shares) {
            (/* */, int256 precision) = getUnderlyingToken();
            require(precision > 0);
            // Lending at zero interest means that 1 fCash unit is equivalent to 1 asset unit
            assets = shares * uint256(precision) / uint256(Constants.INTERNAL_TOKEN_PRECISION);
        } else {
            // This method will round up when calculating the depositAmountUnderlying (happens inside
            // CalculationViews._convertToAmountExternal).
            (assets, /* */, /* */, /* */) = NotionalV2.getDepositFromfCashLend(
                currencyId,
                shares,
                maturity,
                0,
                block.timestamp
            );
        }
    }

    function previewMint(uint256 shares) public view override returns (uint256 assets) {
        (assets, /* */) = _previewMint(shares);
    }

    /** @dev See {IERC4626-previewWithdraw} */
    function previewWithdraw(uint256 assets) public view override returns (uint256 shares) {
        if (assets == 0) return 0;

        // Although the ERC4626 standard suggests that shares is rounded up in this calculation,
        // it would not have much of an effect for wrapped fCash in practice. The actual amount
        // of assets returned to the user is not dictated by the `assets` parameter supplied here
        // but is actually calculated inside _burnInternal (rounding against the user) when fCash
        // has matured or inside the NotionalV2 AMM when withdrawing fCash early. In either case,
        // the number of shares returned here will be burned exactly and the user will receive close
        // to the assets input, but not exactly.
        if (hasMatured()) {
            shares = convertToShares(assets);
        } else {
            // If withdrawing non-matured assets, we sell them on the market (i.e. borrow)
            (uint16 currencyId, uint40 maturity) = getDecodedID();
            (shares, /* */, /* */) = NotionalV2.getfCashBorrowFromPrincipal(
                currencyId,
                assets,
                maturity,
                0,
                block.timestamp,
                true
            );
        }
    }

    /** @dev See {IERC4626-previewRedeem} */
    function previewRedeem(uint256 shares) public view override returns (uint256 assets) {
        if (shares == 0) return 0;

        if (hasMatured()) {
            assets = convertToAssets(shares);
        } else {
            // If withdrawing non-matured assets, we sell them on the market (i.e. borrow)
            (uint16 currencyId, uint40 maturity) = getDecodedID();
            (assets, /* */, /* */, /* */) = NotionalV2.getPrincipalFromfCashBorrow(
                currencyId,
                shares,
                maturity,
                0,
                block.timestamp
            );
        }
    }

    /** @dev See {IERC4626-deposit} */
    function deposit(uint256 assets, address receiver) external override returns (uint256) {
        (uint256 shares, uint256 maxFCash) = _previewDeposit(assets);
        // Will revert if matured
        _mintInternal(assets, _safeUint88(shares), receiver, 0, maxFCash);
        emit Deposit(msg.sender, receiver, assets, shares);
        return shares;
    }

    /** @dev See {IERC4626-mint} */
    function mint(uint256 shares, address receiver) external override returns (uint256) {
        (uint256 assets, uint256 maxFCash) = _previewMint(shares);
        // Will revert if matured
        _mintInternal(assets, _safeUint88(shares), receiver, 0, maxFCash);
        emit Deposit(msg.sender, receiver, assets, shares);
        return assets;
    }

    /** @dev See {IERC4626-withdraw} */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external override returns (uint256) {
        // This is a noop if the account has already been settled, cheaper to call this than cache
        // it locally in storage.
        NotionalV2.settleAccount(address(this));

        uint256 shares = previewWithdraw(assets);

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _redeemInternal(shares, receiver, owner);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        return shares;
    }

    /** @dev See {IERC4626-redeem} */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external override returns (uint256) {
        // It is more accurate and gas efficient to check the balance of the
        // receiver here than rely on the previewRedeem method.
        IERC20 token = IERC20(asset());
        uint256 balanceBefore = token.balanceOf(receiver);

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _redeemInternal(shares, receiver, owner);

        uint256 balanceAfter = token.balanceOf(receiver);
        uint256 assets = balanceAfter - balanceBefore;
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return assets;
    }

    function _redeemInternal(
        uint256 shares,
        address receiver,
        address owner
    ) private {
        _burnInternal(
            owner,
            shares,
            RedeemOpts({
                redeemToUnderlying: true,
                transferfCash: false,
                receiver: receiver,
                maxImpliedRate: 0
            })
        );
    }
}