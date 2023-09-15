
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

contract InvariantActive is BaseInvariant {
    function setUp() public override {
        super.setUp();
        wrapper = wfCashERC4626(factory.deployWrapper(ETH, maturity_3mo));
        handler = new ActiveHandler(wrapper);
        targetContract(address(handler));
    }

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

contract InvariantMatured is BaseInvariant {
    function setUp() public override {
        super.setUp();
        wrapper = wfCashERC4626(factory.deployWrapper(ETH, maturity_3mo));
        handler = new MaturedHandler(wrapper);
        targetContract(address(handler));
    }
}