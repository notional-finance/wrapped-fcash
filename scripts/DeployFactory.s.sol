// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.15;

import "forge-std/Test.sol";
import "forge-std/Script.sol";
import "../contracts/proxy/nBeaconProxy.sol";
import "../contracts/proxy/nUpgradeableBeacon.sol";
import "../contracts/proxy/WrappedfCashFactory.sol";
import "../contracts/wfCashERC4626.sol";

import "../interfaces/notional/IWrappedfCashFactory.sol";
import "../interfaces/notional/INotionalV2.sol";
import "../interfaces/WETH9.sol";

contract DeployFactory is Script, Test {
    WETH9 constant WETH = WETH9(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    INotionalV2 constant NOTIONAL = INotionalV2(0x1344A36A1B56144C3Bc62E7757377D288fDE0369);

    function incrementToNonce(uint256 targetNonce) internal {
        for (;true;) {
            uint256 currentNonce = vm.getNonce(msg.sender);
            if (currentNonce == targetNonce) return;
            payable(msg.sender).transfer(0);
        }
    }

    function run() public {
        assertEq(WETH.symbol(), "WETH");
        require(msg.sender == 0x8B64fA5Fd129df9c755eB82dB1e16D6D0Bdf5Bc3, "Sender");

        vm.startBroadcast();
        incrementToNonce(102);
        // Nonce: 102
        wfCashERC4626 impl = new wfCashERC4626(NOTIONAL, WETH);
        nUpgradeableBeacon beacon = new nUpgradeableBeacon(address(impl));
        IWrappedfCashFactory factory = new WrappedfCashFactory(address(beacon));
        beacon.transferOwnership(NOTIONAL.owner());

        console.log("Beacon: %s", address(beacon));
        console.log("Factory: %s", address(factory));
        require(
            address(beacon) == 0xD676d720E4e8B14F545F9116F0CAD47aF32329DD,
            "Beacon Mismatch"
        );
        require(
            address(factory) == 0x5D051DeB5db151C2172dCdCCD42e6A2953E27261,
            "Factory Mismatch"
        );
    }

}