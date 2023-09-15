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
        deal(address(asset), LENDER, 1 * precision, true);

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
        asset.approve(address(w), 5e18);
        vm.expectRevert("Dai/insufficient-balance");
        w.mint(5e8, LENDER);
    }

    function test_RevertIf_Deposit_InsufficientBalance() public {
        asset.approve(address(w), 5e18);
        vm.expectRevert("Dai/insufficient-balance");
        w.deposit(5e18, LENDER);
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

    // function test_totalAssets_NotAffectedByPrimeCashDonation() public {}
    // function test_convertToShares_NoChangeAfterTrade() public {}
    // function test_convertToAssets_NoChangeAfterTrade() public {}
}

/*
contract TestWrapperERC4626 is BaseTest {
    function test_Withdraw_PostMaturity() public {}
    function test_Redeem_PostMaturity() public {}
}

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

contract TestWrapperValuation is BaseTest {
    function test_convertToShares_NoChangeAfterTrade() public {}
    function test_convertToAssets_NoChangeAfterTrade() public {}
    function test_convertToShares_PostMaturity() public {}
    function test_convertToAssets_PostMaturity() public {}
}
*/