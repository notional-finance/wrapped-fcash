// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "./BaseTest.sol";

contract TestFactory is BaseTest {
    function test_computeAddress() public {
        address computed = factory.computeAddress(ETH, maturity);
        vm.expectEmit(true, true, true, true);
        emit WrapperDeployed(ETH, maturity, computed);
        address deployed = factory.deployWrapper(ETH, maturity);

        assertEq(computed, deployed);

        // Assert that a second deployment does not occur
        address deployed2 = factory.deployWrapper(ETH, maturity);
        assertEq(deployed, deployed2);
    }

    function test_upgrade() public {
        assertEq(wrapper.getCurrencyId(), DAI);
        vm.prank(beacon.owner());
        beacon.upgradeTo(address(factory));

        vm.expectRevert();
        wrapper.getCurrencyId();
    }

    function test_RevertIfDeployInvalidCurrency() public {
        vm.expectRevert("Create2: Failed on deploy");
        factory.deployWrapper(20, maturity);
    }

    function test_RevertIfDeployInvalidMaturity() public {
        vm.expectRevert("Create2: Failed on deploy");
        factory.deployWrapper(ETH, maturity + 360 * 86400);
    }

}
