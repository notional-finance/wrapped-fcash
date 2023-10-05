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
    WETH9 constant WETH = WETH9(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    INotionalV2 constant NOTIONAL = INotionalV2(0x1344A36A1B56144C3Bc62E7757377D288fDE0369);
    nUpgradeableBeacon constant beacon = nUpgradeableBeacon(0xD676d720E4e8B14F545F9116F0CAD47aF32329DD);
    WrappedfCashFactory constant factory = WrappedfCashFactory(0x5D051DeB5db151C2172dCdCCD42e6A2953E27261);

    function run() public {
        assertEq(WETH.symbol(), "WETH");

        vm.startBroadcast();
        wfCashERC4626 impl = new wfCashERC4626(NOTIONAL, WETH);
        vm.stopBroadcast();

        vm.prank(NOTIONAL.owner());
        beacon.upgradeTo(address(impl));
        console.log("Upgrade CallData: ");
        console.log("Target: %s", address(beacon));
        console.log("From: %s", NOTIONAL.owner());
        console.log("CallData:");
        console.logBytes(abi.encodeWithSignature("upgradeTo(address)", address(impl)));
    }
}
