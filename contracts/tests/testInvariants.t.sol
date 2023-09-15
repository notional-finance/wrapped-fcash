
// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "./BaseTest.sol";
import "./Handler.sol";

contract TestInvariants is BaseTest {
    Handler handler;
    wfCashERC4626 wrapper;

    function setUp() public override {
        super.setUp();
        wrapper = wfCashERC4626(factory.deployWrapper(ETH, maturity_3mo));
        handler = new Handler(wrapper);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_totalSupply() external {
        assertEq(handler.totalShares(), wrapper.totalSupply());

        uint256 fCashId = wrapper.getfCashId();
        assertEq(NOTIONAL.balanceOf(address(wrapper), fCashId), wrapper.totalSupply());
    }

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
        assertEq(uint256(presentValue), wrapper.totalAssets());
    }
}