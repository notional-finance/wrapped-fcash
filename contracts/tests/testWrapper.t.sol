// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "./BaseTest.sol";

contract TestWrapperERC1155 is BaseTest {
    address LENDER = makeAddr("Lender");
    wfCashERC4626 w;
    uint256 fCashId;

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

    function test_MintViaEOAfCashTransfer() public {
        NOTIONAL.safeTransferFrom(LENDER, address(w), fCashId, 0.05e8, "");
        assertEq(w.balanceOf(LENDER), 0.05e8);
        assertEq(w.totalSupply(), 0.05e8);

        PortfolioAsset[] memory assets = NOTIONAL.getAccountPortfolio(LENDER);
        assertEq(assets.length, 0);
    }

    // function test_MintViaContractfCashTransfer() public {}
    // function test_RedeemViaEOAfCashTransfer() public {}
    // function test_RedeemViaContractfCashTransfer() public {}
    // function test_RevertIfRedeemAfterMaturityViafCashTransfer() public {}
    // function test_RecoverInvalidFCash() public {}
}

/*
contract TestWrapperERC4626 is BaseTest {
    function test_Mint() public {}
    function test_Deposit() public {}
    function test_Mint_ToReceiver() public {}
    function test_Deposit_ToReceiver() public {}
    function test_RevertIf_Mint_InsufficientBalance() public {}
    function test_RevertIf_Deposit_InsufficientBalance() public {}

    function test_Withdraw() public {}
    function test_Redeem() public {}
    function test_Withdraw_FromReceiver() public {}
    function test_Redeem_FromReceiver() public {}
    function test_RevertIf_Redeem_AboveBalance() public {}
    function test_RevertIf_Withdraw_AboveBalance() public {}
    function test_RevertIf_Redeem_WithoutApproval() public {}
    function test_RevertIf_Withdraw_WithoutApproval() public {}

    function test_RevertIf_Mint_PostMaturity() public {}
    function test_RevertIf_Deposit_PostMaturity() public {}
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
    function test_totalAssets_NotAffectedByPrimeCashDonation() public {}

    function test_totalAssets() public {}
    function test_convertToShares_NoChangeAfterTrade() public {}
    function test_convertToAssets_NoChangeAfterTrade() public {}

    function test_totalAssets_PostMaturity() public {}
    function test_convertToShares_PostMaturity() public {}
    function test_convertToAssets_PostMaturity() public {}
}
*/
