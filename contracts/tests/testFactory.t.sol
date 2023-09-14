// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "forge-std/Test.sol";

import "../proxy/nBeaconProxy.sol";
import "../proxy/nUpgradeableBeacon.sol";
import "../proxy/WrappedfCashFactory.sol";
import "../wfCashERC4626.sol";

import "../../interfaces/notional/IWrappedfCashFactory.sol";
import "../../interfaces/notional/INotionalV2.sol";
import "../../interfaces/WETH9.sol";


contract TestFactory is Test {
    WETH9 constant WETH = WETH9(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    INotionalV2 constant NOTIONAL = INotionalV2(0x1344A36A1B56144C3Bc62E7757377D288fDE0369);
    wfCashERC4626 impl;
    nUpgradeableBeacon beacon;
    IWrappedfCashFactory factory;

    wfCashERC4626 wrapper;
    string ARBITRUM_RPC_URL = vm.envString("ARBITRUM_RPC_URL");
    uint256 ARBITRUM_FORK_BLOCK = vm.envUint("ARBITRUM_FORK_BLOCK");

    event WrapperDeployed(uint16 currencyId, uint40 maturity, address wrapper);

    uint16 constant ETH = 1;
    uint16 constant DAI = 2;
    uint16 constant USDC = 3;
    uint40 maturity;

    function setUp() public {
        vm.createSelectFork(ARBITRUM_RPC_URL, ARBITRUM_FORK_BLOCK);
        impl = new wfCashERC4626(NOTIONAL, WETH);
        beacon = new nUpgradeableBeacon(address(impl));
        factory = new WrappedfCashFactory(address(beacon));
        maturity = uint40(NOTIONAL.getActiveMarkets(ETH)[0].maturity);

        wrapper = wfCashERC4626(factory.deployWrapper(DAI, maturity));
    }
    
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
