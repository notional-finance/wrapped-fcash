// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "./BaseTest.sol";

contract TestFactory is BaseTest {
    wfCashERC4626 wrapper;

    function setUp() public override {
        super.setUp();
        wrapper = wfCashERC4626(factory.deployWrapper(DAI, maturity_3mo));
    }

    function test_computeAddressMatchesMainnet() public {
        // Ensure that we get the same address as mainnet
        assertEq(factory.computeAddress(1, 1702944000),  0x61bc08051000971aCfDE13041Bd701D8F547C645);
        assertEq(factory.computeAddress(2, 1702944000),  0x5b0aE20561Fcc9e7Eb254cA297869027B75DDd55);
    }

    function test_computeAddress() public {
        address computed = factory.computeAddress(ETH, maturity_3mo);
        vm.expectEmit(true, true, true, true);
        emit WrapperDeployed(ETH, maturity_3mo, computed);
        address deployed = factory.deployWrapper(ETH, maturity_3mo);

        assertEq(computed, deployed);

        // Assert that a second deployment does not occur
        address deployed2 = factory.deployWrapper(ETH, maturity_3mo);
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
        factory.deployWrapper(20, maturity_3mo);
    }

    function test_RevertIfDeployInvalidmaturity_3mo() public {
        vm.expectRevert("Create2: Failed on deploy");
        factory.deployWrapper(ETH, maturity_3mo + 360 * 86400);
    }

}
