// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "./BaseTest.sol";

contract TestWrapperERC4626 is BaseTest {
    address LENDER = makeAddr("Lender");
    wfCashERC4626 w;
    uint256 public precision;
    uint256 public fCashId;
    IERC20Metadata public asset;

    function setUp() public override {
        super.setUp();
        w = wfCashERC4626(factory.deployWrapper(DAI, maturity_3mo));

        // NOTE: wrappers always use WETH
        asset = IERC20Metadata(w.asset());
        precision = 10 ** asset.decimals();
        fCashId = w.getfCashId();
        deal(address(asset), LENDER, 1000 * precision, true);

        vm.startPrank(LENDER);
    }

    function test_RevertIf_SlippageLimit() public {
        asset.approve(address(w), type(uint256).max);
        vm.expectRevert("Trade failed, slippage");
        w.mintViaUnderlying(100e18, 100e8, LENDER, 0.15e9);
    }

    function test_RevertIf_Mint_WithoutApproval() public {
        vm.expectRevert("Dai/insufficient-allowance");
        w.mint(1e8, LENDER);
    }

    function test_RevertIf_Deposit_WithoutApproval() public {
        vm.expectRevert("Dai/insufficient-allowance");
        w.deposit(1e18, LENDER);
    }

    function test_RevertIf_Mint_InsufficientBalance() public {
        asset.approve(address(w), type(uint256).max);
        vm.expectRevert("Dai/insufficient-balance");
        w.mint(1100e8, LENDER);
    }

    function test_RevertIf_Deposit_InsufficientBalance() public {
        asset.approve(address(w), type(uint256).max);
        vm.expectRevert("Dai/insufficient-balance");
        w.deposit(1100e18, LENDER);
    }

    function test_RevertIf_Redeem_AboveBalance() public {
        asset.approve(address(w), 5e18);
        w.mint(1e8, LENDER);

        vm.expectRevert("ERC20: burn amount exceeds balance");
        w.redeem(5e8, LENDER, LENDER);
    }

    function test_RevertIf_Withdraw_AboveBalance() public {
        asset.approve(address(w), 5e18);
        w.mint(1e8, LENDER);

        vm.expectRevert("ERC20: burn amount exceeds balance");
        w.withdraw(5e18, LENDER, LENDER);
    }

    function test_RevertIf_Redeem_WithoutApproval() public {
        asset.approve(address(w), 5e18);
        w.mint(1e8, LENDER);
        address operator = makeAddr("Operator");
        vm.stopPrank();
        vm.prank(operator);

        vm.expectRevert("ERC20: insufficient allowance");
        w.redeem(1e8, LENDER, LENDER);

        vm.prank(LENDER);
        w.approve(operator, 5e8);

        vm.prank(operator);
        w.redeem(1e8, LENDER, LENDER);

        assertEq(w.allowance(LENDER, operator), 4e8);
    }

    function test_RevertIf_Withdraw_WithoutApproval() public {
        asset.approve(address(w), 5e18);
        w.mint(1e8, LENDER);
        address operator = makeAddr("Operator");
        vm.stopPrank();
        vm.prank(operator);

        vm.expectRevert("ERC20: insufficient allowance");
        w.withdraw(0.1e18, LENDER, LENDER);

        vm.prank(LENDER);
        w.approve(operator, 5e8);

        vm.prank(operator);
        w.withdraw(0.1e18, LENDER, LENDER);

        assertLt(w.allowance(LENDER, operator), 5e8);
    }

    function test_RevertIf_Mint_PostMaturity() public {
        vm.warp(maturity_3mo);
        NOTIONAL.initializeMarkets(DAI, false);
        asset.approve(address(w), 5e18);

        vm.expectRevert("fCash matured");
        w.mint(1e8, LENDER);
    }

    function test_RevertIf_Deposit_PostMaturity() public {
        vm.warp(maturity_3mo);
        NOTIONAL.initializeMarkets(DAI, false);
        asset.approve(address(w), 5e18);

        vm.expectRevert("fCash matured");
        w.deposit(1e8, LENDER);
    }

    // Ensures that prime cash donations cannot manipulate the oracle value
    function test_totalAssets_NotAffectedByPrimeCashDonation() public {
        asset.approve(address(w), 5e18);
        asset.approve(address(NOTIONAL), 5e18);

        w.mint(1e8, LENDER);

        uint256 totalAssetsBefore = w.totalAssets();
        uint256 shareValueBefore = w.convertToShares(1e18);
        uint256 assetValueBefore = w.convertToAssets(1e8);

        // Donates prime cash to the wrapper contract
        NOTIONAL.depositUnderlyingToken(LENDER, w.getCurrencyId(), 1e18);
        IERC20 pCash = IERC20(NOTIONAL.pCashAddress(w.getCurrencyId()));
        pCash.transfer(address(w), 0.1e8);

        uint256 totalAssetsAfter = w.totalAssets();
        uint256 shareValueAfter = w.convertToShares(1e18);
        uint256 assetValueAfter = w.convertToAssets(1e8);

        assertEq(totalAssetsBefore, totalAssetsAfter);
        assertEq(shareValueBefore, shareValueAfter);
        assertEq(assetValueBefore, assetValueAfter);
    }

    // Ensures that trading does not manipulate the immediate oracle value
    function test_convertTo_NoChangeAfterMint() public {
        asset.approve(address(w), type(uint256).max);

        uint256 shareValueBefore = w.convertToShares(1e18);
        uint256 assetValueBefore = w.convertToAssets(1e8);

        w.mint(1000e8, LENDER);

        uint256 shareValueAfter = w.convertToShares(1e18);
        uint256 assetValueAfter = w.convertToAssets(1e8);

        assertEq(shareValueBefore, shareValueAfter, "Share Value Change");
        assertAbsDiff(assetValueAfter, assetValueBefore, 1e10, "Asset Value Change");
    }

    function test_convertTo_NoChangeAfterRedeem() public {
        asset.approve(address(w), type(uint256).max);
        w.mint(1000e8, LENDER);
        
        uint256 shareValueBefore = w.convertToShares(1e18);
        uint256 assetValueBefore = w.convertToAssets(1e8);

        w.redeem(100e8, LENDER, LENDER);

        uint256 shareValueAfter = w.convertToShares(1e18);
        uint256 assetValueAfter = w.convertToAssets(1e8);

        assertEq(shareValueBefore, shareValueAfter, "Share Value Change");
        assertAbsDiff(assetValueAfter, assetValueBefore, 1e10, "Asset Value Change");
    }

    function test_convertTo_NoChangeAfterRedeem_PostMaturity() public {
        asset.approve(address(w), type(uint256).max);
        w.mint(1000e8, LENDER);

        vm.warp(maturity_3mo);
        NOTIONAL.initializeMarkets(DAI, false);
        
        uint256 shareValueBefore = w.convertToShares(1e18);
        uint256 assetValueBefore = w.convertToAssets(1e8);

        w.redeem(100e8, LENDER, LENDER);

        uint256 shareValueAfter = w.convertToShares(1e18);
        uint256 assetValueAfter = w.convertToAssets(1e8);

        assertEq(shareValueBefore, shareValueAfter, "Share Value Change");
        assertAbsDiff(assetValueAfter, assetValueBefore, 1e10, "Asset Value Change");
    }

    function test_lendToMaxFCash() public {
        (uint256 totalfCash, uint256 maxFCash) = w.getTotalFCashAvailable();
        deal(address(asset), LENDER, totalfCash * precision / 1e8, true);

        asset.approve(address(w), type(uint256).max);
        w.mint(maxFCash, LENDER);

        (/* */, uint256 maxFCashAfter) = w.getTotalFCashAvailable();
        assertEq(maxFCashAfter, 0);

        IERC20 pCash = IERC20(NOTIONAL.pCashAddress(w.getCurrencyId()));
        PortfolioAsset[] memory assets = NOTIONAL.getAccountPortfolio(address(w));

        assertEq(uint256(assets[0].notional), maxFCash, "fCash Balance");
        assertEq(pCash.balanceOf(address(w)), 0, "pCash Balance");
    }

    function test_lendAboveMaxFCash() public {
        (uint256 totalfCash, uint256 maxFCash) = w.getTotalFCashAvailable();
        deal(address(asset), LENDER, totalfCash * 5 * precision / 1e8, true);

        asset.approve(address(w), type(uint256).max);
        uint256 shares = maxFCash * 2;
        w.mint(shares, LENDER);

        (/* */, uint256 maxFCashAfter) = w.getTotalFCashAvailable();
        assertEq(maxFCashAfter, maxFCash);

        (uint256 cashBalance, uint256 fCash) = w.getBalances();
        int256 cashBalanceInUnderlying = NOTIONAL.convertCashBalanceToExternal(
            w.getCurrencyId(),
            int256(cashBalance),
            true
        );

        assertEq(shares, w.totalSupply());
        assertEq(shares, w.balanceOf(LENDER));
        assertEq(fCash, 0, "fCash Balance");
        assertAbsDiff(uint256(cashBalanceInUnderlying), shares * 1e10, 1e10, "pCash Balance");
    }

    function test_lendWhenWrapperHasCash() public {
        (uint256 totalfCash, uint256 maxFCash) = w.getTotalFCashAvailable();
        deal(address(asset), LENDER, totalfCash * 5 * precision / 1e8, true);

        asset.approve(address(w), type(uint256).max);
        uint256 shares = maxFCash * 2;
        w.mint(shares, LENDER);

        (uint256 cashBalanceBefore, /* */) = w.getBalances();
        assertGt(cashBalanceBefore, 0);

        uint256 assetsBefore = asset.balanceOf(LENDER);
        uint256 sharesBefore = w.balanceOf(LENDER);

        uint256 assets = w.mint(maxFCash / 2, LENDER);

        (uint256 cashBalanceAfter, /* */) = w.getBalances();
        uint256 assetsAfter = asset.balanceOf(LENDER);
        uint256 sharesAfter = w.balanceOf(LENDER);

        // Ensure that the contract does not lend excess cash when it is holding it.
        assertEq(sharesBefore + maxFCash / 2, sharesAfter, "fCash Shares");
        assertEq(cashBalanceBefore, cashBalanceAfter, "Cash Balance Changed");
        assertLe(assets - (assetsBefore - assetsAfter), 1e10, "Mint Amount");
    }

    function test_withdrawWhenMarketIsMaxed() public {
        (uint256 totalfCash, uint256 maxFCash) = w.getTotalFCashAvailable();
        deal(address(asset), LENDER, totalfCash * 500_000 * precision / 1e8, true);

        asset.approve(address(w), type(uint256).max);
        uint256 shares = maxFCash * 2;
        w.mint(shares, LENDER);

        (uint256 cashBalanceBefore, /* */) = w.getBalances();
        assertGt(cashBalanceBefore, 0);

        // Borrow all the cash to max out the rate...
        MarketParameters[] memory markets = NOTIONAL.getActiveMarkets(w.getCurrencyId());
        int256 totalPrimeCash = markets[0].totalPrimeCash * 92 / 100;

        (/* */, /* */, bytes32 encodedTrade) = NOTIONAL.getfCashBorrowFromPrincipal(
            w.getCurrencyId(),
            uint256(totalPrimeCash),
            w.getMaturity(),
            0,
            block.timestamp,
            false
        );

        asset.approve(address(NOTIONAL), type(uint256).max);
        BalanceActionWithTrades[] memory t = new BalanceActionWithTrades[](1);
        bytes32[] memory trades = new bytes32[](1);
        trades[0] = encodedTrade;
        t[0] = BalanceActionWithTrades({
            actionType: DepositActionType.DepositUnderlying,
            currencyId: w.getCurrencyId(),
            depositActionAmount: 10_000e18,
            withdrawAmountInternalPrecision: 0,
            withdrawEntireCashBalance: false,
            redeemToUnderlying: true,
            trades: trades
        });
        NOTIONAL.batchBalanceAndTradeAction(LENDER, t);

        // The interest rate is now maxed out and the fCash market has insufficient
        // cash so that the lender cannot redeem.
        uint256 balance = w.balanceOf(LENDER);
        vm.expectRevert("Redeem Failed");
        w.redeem(balance, LENDER, LENDER);
    }

    function test_redeemFullMatured() public {
        asset.approve(address(w), type(uint256).max);
        w.mint(1000e8, LENDER);

        vm.warp(maturity_3mo);
        NOTIONAL.initializeMarkets(DAI, false);
        
        uint256 assets = w.redeem(w.balanceOf(LENDER), LENDER, LENDER);
        assertAbsDiff(assets, 1000e18, 1e10, "Asset Value Change");
    }
}