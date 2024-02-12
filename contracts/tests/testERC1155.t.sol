// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "./BaseTest.sol";

contract TestWrapperERC1155 is BaseTest {
    address LENDER = makeAddr("Lender");
    wfCashERC4626 w;
    uint256 fCashId;
    IERC20 asset;
    uint256 precision;

    function setUp() public override {
        super.setUp();
        vm.startPrank(LENDER);
        vm.deal(LENDER, 10e18);
        (/* */, /* */, /* */, bytes32 encodedTrade) = NOTIONAL.getDepositFromfCashLend(
            ETH,
            0.05e8,
            maturity_3mo,
            0,
            block.timestamp
        );

        BalanceActionWithTrades[] memory t = new BalanceActionWithTrades[](1);
        bytes32[] memory trades = new bytes32[](1);
        trades[0] = encodedTrade;
        t[0] = BalanceActionWithTrades({
            actionType: DepositActionType.DepositUnderlying,
            currencyId: ETH,
            depositActionAmount: 0.05e18,
            withdrawAmountInternalPrecision: 0,
            withdrawEntireCashBalance: true,
            redeemToUnderlying: true,
            trades: trades
        });
        NOTIONAL.batchBalanceAndTradeAction{value: 0.05e18}(LENDER, t);

        w = wfCashERC4626(factory.deployWrapper(ETH, maturity_3mo));
        asset = IERC20(w.asset());
        precision = 1e18;
        fCashId = w.getfCashId();
    }

    function test_RevertIfSenderIsNotNotional() public {
        address fakeNotional = makeAddr("FAKE_NOTIONAL");
        address newImpl = address(new wfCashERC4626(INotionalV2(fakeNotional), WETH));

        vm.stopPrank();
        vm.prank(beacon.owner());
        beacon.upgradeTo(newImpl);

        vm.prank(LENDER);
        vm.expectRevert("Invalid");
        NOTIONAL.safeTransferFrom(LENDER, address(w), fCashId, 0.05e8, "");
    }

    function test_RevertIfInvalidCurrency() public {
        wfCashERC4626 w2 = wfCashERC4626(factory.deployWrapper(DAI, maturity_3mo));

        vm.expectRevert("Invalid");
        NOTIONAL.safeTransferFrom(LENDER, address(w2), fCashId, 0.05e8, "");
    }

    function test_RevertIfInvalidMaturity() public {
        wfCashERC4626 w2 = wfCashERC4626(factory.deployWrapper(ETH, maturity_6mo));

        vm.expectRevert("Invalid");
        NOTIONAL.safeTransferFrom(LENDER, address(w2), fCashId, 0.05e8, "");
    }

    function test_RevertIfBatchTransfer() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = fCashId;
        uint256[] memory values = new uint256[](1);
        values[0] = 0.05e8;

        vm.expectRevert();
        NOTIONAL.safeBatchTransferFrom(LENDER, address(w), ids, values, "");
    }

    function test_RecoverInvalidFCash() public {
        address w2address = factory.computeAddress(ETH, maturity_6mo);
        // NOTE: transfers incorrect fCash id to the w2 address (3mo vs 6mo)
        NOTIONAL.safeTransferFrom(LENDER, w2address, fCashId, 0.05e8, "");

        wfCashERC4626 w2 = wfCashERC4626(factory.deployWrapper(ETH, maturity_6mo));
        address RECEIVER = makeAddr("RECEIVER");

        vm.expectRevert();
        w2.recoverInvalidfCash(fCashId, RECEIVER);

        assertEq(NOTIONAL.balanceOf(w2address, fCashId), 0.05e8);

        vm.stopPrank();
        vm.prank(NOTIONAL.owner());
        w2.recoverInvalidfCash(fCashId, RECEIVER);

        assertEq(NOTIONAL.balanceOf(RECEIVER, fCashId), 0.05e8);
        assertEq(NOTIONAL.balanceOf(w2address, fCashId), 0);
    }


    function test_RevertIfRedeemAfterMaturityViafCashTransfer() public {
        NOTIONAL.safeTransferFrom(LENDER, address(w), fCashId, 0.05e8, "");
        uint256 balance = w.balanceOf(LENDER);
        assertEq(balance, 0.05e8);

        vm.warp(maturity_3mo);
        NOTIONAL.initializeMarkets(ETH, false);
        assertEq(w.hasMatured(), true);

        vm.expectRevert();
        w.redeem(balance, IWrappedfCash.RedeemOpts({
            redeemToUnderlying: false,
            transferfCash: true,
            receiver: LENDER,
            maxImpliedRate: 0
        }));
    }

    function test_LendAtZero_ETHRefunds() public {
        (/* */, uint256 maxFCash) = w.getTotalFCashAvailable();

        asset.approve(address(w), type(uint256).max);

        {
            uint256 shares = maxFCash * 2;
            uint256 previewAssets = w.previewMint(shares);
            // Deposit excess to test refunds
            deal(address(asset), LENDER, previewAssets * 2, true);

            uint256 assetsBefore = asset.balanceOf(LENDER);
            w.mintViaUnderlying(previewAssets * 2, uint88(shares), LENDER, 0);
            uint256 assetsAfter = asset.balanceOf(LENDER);

            // The method should only take sufficient assets to mint the required shares.
            int256 diff = int256(previewAssets) - int256(assetsBefore - assetsAfter);
            assertLe(diff < 0 ? -diff : diff, 1e10, "Deposit Amount");
        }

        {
            uint256 shares = maxFCash / 10;
            uint256 previewAssets = w.previewMint(shares);

            deal(address(asset), LENDER, previewAssets * 2, true);
            uint256 assetsBefore = asset.balanceOf(LENDER);
            w.mintViaUnderlying(previewAssets * 2, uint88(shares), LENDER, 0);
            uint256 assetsAfter = asset.balanceOf(LENDER);

            // The method should only take sufficient assets to mint the required shares.
            int256 diff = int256(previewAssets) - int256(assetsBefore - assetsAfter);
            assertLe(diff < 0 ? -diff : diff, 1e10, "Deposit Amount");
        }

        {
            // Assert that reverts occur if attempting to use the existing cash balance
            uint256 shares = maxFCash / 10;
            uint256 previewAssets = w.previewMint(shares);

            deal(address(asset), LENDER, previewAssets / 2, true);

            // Expect a revert here on underflow because we have insufficient cash
            // balance to lend
            vm.expectRevert();
            w.mintViaUnderlying(previewAssets / 2, uint88(shares), LENDER, 0);
        }
    }
}
