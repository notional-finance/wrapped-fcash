// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.15;

import "forge-std/Script.sol";
import "forge-std/Test.sol";
import "../contracts/proxy/nBeaconProxy.sol";
import "../contracts/proxy/nUpgradeableBeacon.sol";
import "../contracts/proxy/WrappedfCashFactory.sol";
import "../contracts/wfCashERC4626.sol";

import "../interfaces/notional/IWrappedfCashFactory.sol";
import "../interfaces/notional/INotionalV2.sol";
import "../interfaces/WETH9.sol";

contract Upgrade is Script, Test {
    WETH9 constant WETH = WETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    INotionalV2 constant NOTIONAL = INotionalV2(0x6e7058c91F85E0F6db4fc9da2CA41241f5e4263f);
    nUpgradeableBeacon constant beacon = nUpgradeableBeacon(0xEBe1BF1653d55d31F6ED38B1A4CcFE2A92338f66);

    function run() public {
        assertEq(WETH.symbol(), "WETH");

        wfCashERC4626 impl = wfCashERC4626(0x44919c298CC2dd295FD2b2dE10E944491cDB8c48);
        WrappedfCashFactory factory = WrappedfCashFactory(0x56408a51b96609c10B005a2fc599ee36b534d01b);
        beacon.upgradeTo(address(impl));

        vm.startBroadcast();
        beacon.transferOwnership(NOTIONAL.owner());
        vm.stopBroadcast();

        console.log("FACTORY ADDRESS", address(factory));
        assertEq(NOTIONAL.owner(), beacon.owner());
        console.log("Beacon Owner", beacon.owner());

        address wrapper1 = factory.deployWrapper(1, 1734048000);
        console.log("WRAPPER", wrapper1);

        vm.expectRevert();
        factory.deployWrapper(4, 1734048000);
    }
}
