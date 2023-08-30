import "forge-std/Test.sol";

import "../proxy/nBeaconProxy.sol";
import "../proxy/nUpgradeableBeacon.sol";
import "../proxy/WrappedfCashFactory.sol";
import "../wfCashERC4626.sol";

import "../../interfaces/notional/IWrappedfCashFactory.sol";
import "../../interfaces/notional/INotionalV2.sol";
import "../../interfaces/WETH9.sol";


contract TestFactory is Test {
    WETH9 constant WETH = WETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    INotionalV2 constant NOTIONAL = INotionalV2(0x1344A36A1B56144C3Bc62E7757377D288fDE0369);
    wfCashERC4626 impl;
    nUpgradeableBeacon beacon;
    IWrappedfCashFactory factory;

    function setUp() public {
        impl = new wfCashERC4626(NOTIONAL, WETH);
        beacon = new nUpgradeableBeacon(address(impl));
        factory = new WrappedfCashFactory(address(beacon));
    }

    function test_computeAddress() public {
        assertEq(true, true);
    }

}
