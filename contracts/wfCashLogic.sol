// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;
pragma experimental ABIEncoderV2;

import "./wfCashBase.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";

/// @dev This implementation contract is deployed as an UpgradeableBeacon. Each BeaconProxy
/// that uses this contract as an implementation will call initialize to set its own fCash id.
/// That identifier will represent the fCash that this ERC20 wrapper can hold.
abstract contract wfCashLogic is wfCashBase, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    // bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"))
    bytes4 internal constant ERC1155_ACCEPTED = 0xf23a6e61;

    constructor(INotionalV2 _notional, WETH9 _weth) wfCashBase(_notional, _weth) {}

    /***** Mint Methods *****/

    /// @notice Lends deposit amount in return for fCashAmount using underlying tokens
    /// @param depositAmountExternal amount of cash to deposit into this method
    /// @param fCashAmount amount of fCash to purchase (lend)
    /// @param receiver address to receive the fCash shares
    /// @param minImpliedRate minimum annualized interest rate to lend at
    function mintViaUnderlying(
        uint256 depositAmountExternal,
        uint88 fCashAmount,
        address receiver,
        uint32 minImpliedRate
    ) external override {
        (/* */, uint256 maxFCash) = getTotalFCashAvailable();
        _mintInternal(depositAmountExternal, fCashAmount, receiver, minImpliedRate, maxFCash);
    }

    function _mintInternal(
        uint256 depositAmountExternal,
        uint88 fCashAmount,
        address receiver,
        uint32 minImpliedRate,
        uint256 maxFCash
    ) internal nonReentrant {
        require(!hasMatured(), "fCash matured");
        (IERC20 token, bool isETH, bool hasTransferFee, uint256 precision) = _getTokenForMintInternal();
        uint256 balanceBefore = isETH ? WETH.balanceOf(address(this)) : token.balanceOf(address(this));
        uint256 msgValue;
        uint16 currencyId = getCurrencyId();
        
        if (isETH) {
            // Use WETH if lending ETH. Although Notional natively supports ETH, we use WETH here for integration
            // contracts so they only have to support ERC20 token transfers.
            // NOTE: safeTransferFrom not required since WETH is known to be compatible
            IERC20((address(WETH))).transferFrom(msg.sender, address(this), depositAmountExternal);
            WETH.withdraw(depositAmountExternal);
            msgValue = depositAmountExternal;
        } else {
            token.safeTransferFrom(msg.sender, address(this), depositAmountExternal);
            depositAmountExternal = token.balanceOf(address(this)) - balanceBefore;
        }

        if (maxFCash < fCashAmount) {
            // NOTE: lending at zero
            uint256 fCashAmountExternal = fCashAmount * precision / uint256(Constants.INTERNAL_TOKEN_PRECISION);
            require(fCashAmountExternal <= depositAmountExternal);

            // NOTE: Residual (depositAmountExternal - fCashAmountExternal) will be transferred
            // back to the account
            NotionalV2.depositUnderlyingToken{value: msgValue}(address(this), currencyId, fCashAmountExternal);
        } else if (isETH || hasTransferFee || getCashBalance() > 0) {
            _lendLegacy(currencyId, depositAmountExternal, fCashAmount, minImpliedRate, msgValue, isETH);
        } else {
            // Executes a lending action on Notional. Since this lending action uses an existing cash balance
            // prior to pulling payment, we cannot use it if there is a cash balance on the wrapper contract,
            // it will cause existing cash balances to be minted into fCash and create a shortfall. In normal
            // conditions, this method is more gas efficient.
            BatchLend[] memory action = EncodeDecode.encodeLendTrade(
                currencyId,
                getMarketIndex(),
                fCashAmount,
                minImpliedRate
            );
            NotionalV2.batchLend(address(this), action);
        }

        // Mints ERC20 tokens for the receiver
        _mint(receiver, fCashAmount);

        // Residual tokens will be sent back to msg.sender, not the receiver. The msg.sender
        // was used to transfer tokens in and these are any residual tokens left that were not
        // lent out. Sending these tokens back to the receiver risks them getting locked on a
        // contract that does not have the capability to transfer them off
        _sendTokensToReceiver(token, msg.sender, isETH, balanceBefore);
    }

    function _lendLegacy(
        uint16 currencyId,
        uint256 depositAmountExternal,
        uint88 fCashAmount,
        uint32 minImpliedRate,
        uint256 msgValue,
        bool isETH
    ) internal {
        // If dealing in ETH, we use WETH in the wrapper instead of ETH. NotionalV2 uses
        // ETH natively but due to pull payment requirements for batchLend, it does not support
        // ETH. batchLend only supports ERC20 tokens. Since the wrapper is a compatibility
        // layer, it will support WETH so integrators can deal solely in ERC20 tokens. Instead of using
        // "batchLend" we will use "batchBalanceActionWithTrades". The difference is that "batchLend"
        // is more gas efficient.

        // If deposit amount external is in excess of the cost to purchase fCash amount (often the case),
        // then we need to return the difference between postTradeCash - preTradeCash. This is done because
        // the encoded trade does not automatically withdraw the entire cash balance in case the wrapper
        // is holding a cash balance.
        uint256 preTradeCash = getCashBalance();

        BalanceActionWithTrades[] memory action = EncodeDecode.encodeLegacyLendTrade(
            currencyId,
            getMarketIndex(),
            depositAmountExternal,
            fCashAmount,
            minImpliedRate
        );
        // Notional will return any residual ETH as the native token. When we _sendTokensToReceiver those
        // native ETH tokens will be wrapped back to WETH.
        NotionalV2.batchBalanceAndTradeAction{value: msgValue}(address(this), action);

        uint256 postTradeCash = getCashBalance();

        if (preTradeCash != postTradeCash) {
            // If ETH, then redeem to WETH (redeemToUnderlying == false)
            NotionalV2.withdraw(currencyId, _safeUint88(postTradeCash - preTradeCash), !isETH);
        }
    }

    /// @notice This hook will be called every time this contract receives fCash, will validate that
    /// this is the correct fCash and then mint the corresponding amount of wrapped fCash tokens
    /// back to the user.
    function onERC1155Received(
        address /* _operator */,
        address _from,
        uint256 _id,
        uint256 _value,
        bytes calldata /* _data */
    ) external nonReentrant returns (bytes4) {
        uint256 fCashID = getfCashId();
        // Only accept erc1155 transfers from NotionalV2
        require(msg.sender == address(NotionalV2), "Invalid");
        // Only accept the fcash id that corresponds to the listed currency and maturity
        require(_id == fCashID, "Invalid");
        // Protect against signed value underflows
        require(int256(_value) > 0, "Invalid");

        // Double check the account's position, these are not strictly necessary and add gas costs
        // but might be good safe guards
        AccountContext memory ac = NotionalV2.getAccountContext(address(this));
        PortfolioAsset[] memory assets = NotionalV2.getAccountPortfolio(address(this));
        require(ac.hasDebt == 0x00);
        require(assets.length == 1);
        require(EncodeDecode.encodeERC1155Id(
                assets[0].currencyId,
                assets[0].maturity,
                assets[0].assetType) == fCashID
        );

        // Mint ERC20 tokens for the sender
        _mint(_from, _value);

        // This will allow the fCash to be accepted
        return ERC1155_ACCEPTED;
    }

    /***** Redeem (Burn) Methods *****/

    /// @notice Redeems tokens using custom options
    /// @dev re-entrancy is protected on _burn
    function redeem(uint256 amount, RedeemOpts memory opts) external override {
        _burnInternal(msg.sender, amount, opts);
    }

    /// @notice Redeems tokens to underlying
    /// @dev re-entrancy is protected on _burn
    function redeemToUnderlying(
        uint256 amount,
        address receiver,
        uint32 maxImpliedRate
    ) external override {
        _burnInternal(
            msg.sender,
            amount,
            RedeemOpts({
                redeemToUnderlying: true,
                transferfCash: false,
                receiver: receiver,
                maxImpliedRate: maxImpliedRate
            })
        );
    }

    /// @notice This method is here only in the case where someone has transferred invalid fCash
    /// to the contract and would prevent ERC1155 transfer hooks from succeeding. In this case the
    /// owner can recover the invalid fCash to a designated receiver. This can only occur if the fCash
    /// is transferred prior to contract creation.
    function recoverInvalidfCash(uint256 fCashId, address receiver) external {
        // Only the Notional owner can call this method
        require(msg.sender == NotionalV2.owner());
        // Cannot transfer the native fCash id of this wrapper
        require(fCashId != getfCashId());
        uint256 balance = NotionalV2.balanceOf(address(this), fCashId);
        // There should be a positive balance before we try to transfer this
        require(balance > 0);
        NotionalV2.safeTransferFrom(address(this), receiver, fCashId, balance, "");
        
        // Double check that we don't incur debt
        AccountContext memory ac = NotionalV2.getAccountContext(address(this));
        require(ac.hasDebt == 0x00);
    }

    /// @notice Called before tokens are burned (redemption) and so we will handle
    /// the fCash properly before and after maturity.
    function _burnInternal(
        address from,
        uint256 fCashShares,
        RedeemOpts memory opts
    ) internal nonReentrant {
        require(opts.receiver != address(0), "Receiver is zero address");
        require(opts.redeemToUnderlying || opts.transferfCash);
        // This will validate that the account has sufficient tokens to burn and make
        // any relevant underlying stateful changes to balances.
        super._burn(from, fCashShares);

        if (hasMatured()) {
            require(opts.transferfCash == false);
            // If the fCash has matured, then we need to ensure that the account is settled
            // and then we will transfer back the account's share of asset tokens.

            // This is a noop if the account is already settled, it is cheaper to call this method than
            // cache it in storage locally
            NotionalV2.settleAccount(address(this));
            uint16 currencyId = getCurrencyId();
            uint256 primeCashClaim = _getMaturedCashValue(fCashShares);

            // Transfer withdrawn tokens to the `from` address
            _withdrawCashToAccount(currencyId, opts.receiver, _safeUint88(primeCashClaim));
        } else if (opts.transferfCash) {
            // If the fCash has not matured, then we can transfer it via ERC1155.
            // NOTE: this may fail if the destination is a contract and it does not implement 
            // the `onERC1155Received` hook. If that is the case it is possible to use a regular
            // ERC20 transfer on this contract instead.
            NotionalV2.safeTransferFrom(
                address(this), // Sending from this contract
                opts.receiver, // Where to send the fCash
                getfCashId(), // fCash identifier
                fCashShares, // Amount of fCash to send
                ""
            );
        } else {
            _sellfCash(opts.receiver, fCashShares, opts.maxImpliedRate);
        }
    }

    /// @notice After maturity, withdraw cash back to account
    function _withdrawCashToAccount(
        uint16 currencyId,
        address receiver,
        uint88 primeCashToWithdraw
    ) private returns (uint256 tokensTransferred) {
        (IERC20 token, bool isETH) = getToken(true);
        uint256 balanceBefore = isETH ? WETH.balanceOf(address(this)) : token.balanceOf(address(this));

        NotionalV2.withdraw(currencyId, primeCashToWithdraw, !isETH);

        tokensTransferred = _sendTokensToReceiver(token, receiver, isETH, balanceBefore);
    }

    /// @dev Sells an fCash share back on the Notional AMM
    function _sellfCash(
        address receiver,
        uint256 fCashToSell,
        uint32 maxImpliedRate
    ) private returns (uint256 tokensTransferred) {
        (IERC20 token, bool isETH) = getToken(true);
        uint256 balanceBefore = isETH ? WETH.balanceOf(address(this)) : token.balanceOf(address(this));
        uint16 currencyId = getCurrencyId();

        (uint256 initialCashBalance, uint256 fCashBalance) = getBalances();
        bool hasInsufficientfCash = fCashBalance < fCashToSell;

        uint256 primeCashToWithdraw;
        if (hasInsufficientfCash) {
            // If there is insufficient fCash, calculate how much prime cash would be purchased if the
            // given fCash amount would be sold and that will be how much the wrapper will withdraw and
            // send to the receiver. Since fCash always sells at a discount to underlying prior to maturity,
            // the wrapper is guaranteed to have sufficient cash to send to the account.
            (/* */, primeCashToWithdraw, /* */, /* */) = NotionalV2.getPrincipalFromfCashBorrow(
                currencyId,
                fCashToSell,
                getMaturity(),
                0,
                block.timestamp
            );
            // If this is zero then it signifies that the trade will fail.
            require(primeCashToWithdraw > 0, "Redeem Failed");

            // Re-write the fCash to sell to the entire fCash balance.
            fCashToSell = fCashBalance;
        }

        if (fCashToSell > 0) {
            // Sells fCash on Notional AMM (via borrowing)
            BalanceActionWithTrades[] memory action = EncodeDecode.encodeBorrowTrade(
                currencyId,
                getMarketIndex(),
                _safeUint88(fCashToSell),
                maxImpliedRate
            );
            NotionalV2.batchBalanceAndTradeAction(address(this), action);
        }

        uint256 postTradeCash = getCashBalance();

        // If the account did not have insufficient fCash, then the amount of cash change here is what
        // the receiver is owed. In the other case, we transfer to the receiver the total calculated amount
        // above without modification.
        if (!hasInsufficientfCash) primeCashToWithdraw = postTradeCash - initialCashBalance;
        require(primeCashToWithdraw <= postTradeCash);

        // Withdraw the total amount of cash and send it to the receiver
        NotionalV2.withdraw(currencyId, _safeUint88(primeCashToWithdraw), !isETH);
        tokensTransferred = _sendTokensToReceiver(token, receiver, isETH, balanceBefore);
    }

    function _sendTokensToReceiver(
        IERC20 token,
        address receiver,
        bool isETH,
        uint256 balanceBefore
    ) private returns (uint256 tokensTransferred) {
        uint256 balanceAfter = isETH ? WETH.balanceOf(address(this)) : token.balanceOf(address(this));
        tokensTransferred = balanceAfter - balanceBefore;

        if (isETH) {
            // No need to use safeTransfer for WETH since it is known to be compatible
            IERC20(address(WETH)).transfer(receiver, tokensTransferred);
        } else if (tokensTransferred > 0) {
            token.safeTransfer(receiver, tokensTransferred);
        }
    }

    function _safeUint88(uint256 x) internal pure returns (uint88) {
        require(x <= uint256(type(uint88).max));
        return uint88(x);
    }
}