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
}

/*
contract TestMintAndRedeemAtZeroInterest is BaseTest {
    function test_Mint() public {}
    function test_Deposit() public {}

    function test_Withdraw_WhenSufficientFCash() public {}
    function test_Redeem_WhenSufficientFCash() public {}
    function test_Withdraw_InsufficientFCash() public {}
    function test_Redeem_InsufficientFCash() public {}
    function test_Withdraw_PostMaturity() public {}
    function test_Redeem_PostMaturity() public {}
}
*/