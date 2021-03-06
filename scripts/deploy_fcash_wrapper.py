import json
from brownie import wfCashERC4626, nUpgradeableBeacon, WrappedfCashFactory, network, accounts

notionalAddress = {
    "kovan": "0x0EAE7BAdEF8f95De91fDDb74a89A786cF891Eb0e",
    "kovan-fork": "0x0EAE7BAdEF8f95De91fDDb74a89A786cF891Eb0e",
    "goerli": "0xD8229B55bD73c61D840d339491219ec6Fa667B0a",
    "mainnet": "0x1344A36A1B56144C3Bc62E7757377D288fDE0369"
}

wethAddress = {
    "kovan": "0xd0a1e359811322d97991e03f863a0c30c2cf029c",
    "goerli": "0x04B9c40dF01bdc99dd2c31Ae4B232f20F4BBaC5B",
    "mainnet": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
}

def main():
    networkName = network.show_active()
    if networkName == "goerli-fork":
        networkName = "goerli"
    if networkName == "mainnet-fork":
        networkName = "mainnet"
    deployer = accounts.load("{}_DEPLOYER".format(networkName.upper()))

    impl = wfCashERC4626.deploy(notionalAddress[networkName], wethAddress[networkName],
        {"from": deployer}, publish_source=True)
    beacon = nUpgradeableBeacon.deploy(impl.address, {"from": deployer}, publish_source=True)
    factory = WrappedfCashFactory.deploy(beacon.address, {"from": deployer}, publish_source=True)

    with open("wrapper.{}.json".format(network.show_active()), "w") as f:
        json.dump({
            "implementation": impl.address,
            "beacon": beacon.address,
            "factory": factory.address
        }, f, indent=4, sort_keys=True)

    with open("abi/WrappedfCash.json", "w") as f:
        json.dump(wfCashERC4626.abi, f, indent=4, sort_keys=True)

    with open("abi/WrappedfCashFactory.json", "w") as f:
        json.dump(WrappedfCashFactory.abi, f, indent=4, sort_keys=True)