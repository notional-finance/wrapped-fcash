// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.15;

import "forge-std/Script.sol";
import "../contracts/proxy/nBeaconProxy.sol";
import "../contracts/proxy/nUpgradeableBeacon.sol";
import "../contracts/proxy/WrappedfCashFactory.sol";
import "../contracts/wfCashERC4626.sol";

import "../interfaces/notional/IWrappedfCashFactory.sol";
import "../interfaces/notional/INotionalV2.sol";
import "../interfaces/WETH9.sol";

contract VerifyFactory is Script {
    INotionalV2 constant NOTIONAL = INotionalV2(0x1344A36A1B56144C3Bc62E7757377D288fDE0369);
    nUpgradeableBeacon constant beacon = nUpgradeableBeacon(0xD676d720E4e8B14F545F9116F0CAD47aF32329DD);
    WrappedfCashFactory constant factory = WrappedfCashFactory(0x5D051DeB5db151C2172dCdCCD42e6A2953E27261);

    function run() public {
        require(msg.sender == 0x8B64fA5Fd129df9c755eB82dB1e16D6D0Bdf5Bc3, "Sender");

        require(factory.computeAddress(1, 1702944000) == 0x61bc08051000971aCfDE13041Bd701D8F547C645, "Compute Address Failed");
        require(factory.computeAddress(2, 1702944000) == 0x5b0aE20561Fcc9e7Eb254cA297869027B75DDd55, "Compute Address Failed");

        vm.startBroadcast();
        // Verify compute address
        beacon.transferOwnership(NOTIONAL.owner());
        require(beacon.owner() == 0xbf778Fc19d0B55575711B6339A3680d07352B221);
    }

}
