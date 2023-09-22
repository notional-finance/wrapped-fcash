
// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "./BaseTest.sol";
import "./Handlers.sol";

abstract contract BaseInvariant is BaseTest {
    BaseHandler handler;
    wfCashERC4626 wrapper;

    /// forge-config: default.invariant.runs = 10
    /// forge-config: default.invariant.depth = 4
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_totalSupply() external {
        assertEq(handler.totalShares(), wrapper.totalSupply(), "Total Supply");
    }

}

abstract contract InvariantActive is BaseInvariant {
    /// forge-config: default.invariant.runs = 10
    /// forge-config: default.invariant.depth = 4
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_fCashSupply() external {
        uint256 fCashId = wrapper.getfCashId();
        assertEq(NOTIONAL.balanceOf(address(wrapper), fCashId), wrapper.totalSupply(), "Wrapper Balance");
    }

    /// forge-config: default.invariant.runs = 10
    /// forge-config: default.invariant.depth = 4
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_totalAssets() external {
        int256 presentValue = NOTIONAL.getPresentfCashValue(
            wrapper.getCurrencyId(),
            wrapper.getMaturity(),
            int256(handler.totalShares()),
            block.timestamp,
            false
        ) * int256(handler.precision()) / 1e8;
        assertGe(presentValue, 0);
        assertEq(uint256(presentValue), wrapper.totalAssets(), "Present Value");
    }
}

contract InvariantActiveDepositMint is InvariantActive {
    function setUp() public override {
        super.setUp();
        wrapper = wfCashERC4626(factory.deployWrapper(ETH, maturity_3mo));
        handler = new DepositMintHandler(wrapper);
        targetContract(address(handler));
    }
}

contract InvariantActiveRedeemWithdraw is InvariantActive {
    function setUp() public override {
        super.setUp();
        wrapper = wfCashERC4626(factory.deployWrapper(ETH, maturity_3mo));
        handler = new RedeemWithdrawHandler(wrapper);
        targetContract(address(handler));
    }
}

contract InvariantMatured is BaseInvariant {
    function setUp() public override {
        super.setUp();
        wrapper = wfCashERC4626(factory.deployWrapper(ETH, maturity_3mo));
        handler = new RedeemWithdrawHandler(wrapper);

        vm.warp(maturity_3mo);
        NOTIONAL.initializeMarkets(ETH, false);
        targetContract(address(handler));
    }
}