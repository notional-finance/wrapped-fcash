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

abstract contract BaseTest is Test {
    WETH9 constant WETH = WETH9(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    INotionalV2 constant NOTIONAL = INotionalV2(0x1344A36A1B56144C3Bc62E7757377D288fDE0369);
    wfCashERC4626 impl;
    nUpgradeableBeacon beacon;
    IWrappedfCashFactory factory;

    string ARBITRUM_RPC_URL = vm.envString("ARBITRUM_RPC_URL");
    uint256 ARBITRUM_FORK_BLOCK = vm.envUint("ARBITRUM_FORK_BLOCK");

    event WrapperDeployed(uint16 currencyId, uint40 maturity, address wrapper);

    uint16 constant ETH = 1;
    uint16 constant DAI = 2;
    uint16 constant USDC = 3;
    uint40 maturity_3mo;
    uint40 maturity_6mo;

    function setUp() public virtual {
        vm.createSelectFork(ARBITRUM_RPC_URL, ARBITRUM_FORK_BLOCK);
        impl = new wfCashERC4626(NOTIONAL, WETH);
        beacon = new nUpgradeableBeacon(address(impl));
        factory = new WrappedfCashFactory(address(beacon));
        maturity_3mo = uint40(NOTIONAL.getActiveMarkets(ETH)[0].maturity);
        maturity_6mo = uint40(NOTIONAL.getActiveMarkets(ETH)[1].maturity);
    }
}
