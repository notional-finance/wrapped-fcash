import pytest
import brownie
import eth_abi
import json
from tests.helpers import get_balance_trade_action, get_lend_action
from brownie import Contract, wfCashERC4626, network, nUpgradeableBeacon, MockAggregator
from brownie.project import WrappedFcashProject
from brownie.convert.datatypes import Wei, HexString
from brownie.convert import to_bytes
from brownie.network import Chain
from scripts.EnvironmentConfig import getEnvironment

chain = Chain()

@pytest.fixture(autouse=True)
def run_around_tests():
    chain.snapshot()
    yield
    chain.revert()

@pytest.fixture()
def env(accounts):
    name = network.show_active()
    if name == 'mainnet-fork':
        environment = getEnvironment('mainnet')
        environment.notional.upgradeTo('0x2C67B0C0493e358cF368073bc0B5fA6F01E981e0', {'from': environment.owner})
        environment.notional.updateAssetRate(1, "0x8E3D447eBE244db6D28E2303bCa86Ef3033CFAd6", {"from": environment.owner})
        environment.notional.updateAssetRate(2, "0x719993E82974f5b5eA0c5ebA25c260CD5AF78E00", {"from": environment.owner})
        environment.notional.updateAssetRate(3, "0x612741825ACedC6F88D8709319fe65bCB015C693", {"from": environment.owner})
        environment.notional.updateAssetRate(4, "0x39D9590721331B13C8e9A42941a2B961B513E69d", {"from": environment.owner})

        # Borrow a significant amount of USDC to get the interest rates up
        environment.notional.batchBalanceAndTradeAction(
            accounts[5],
            [ 
                get_balance_trade_action(
                    1,
                    "DepositUnderlying",
                    [],
                    depositActionAmount=900e18
                ),
                get_balance_trade_action(
                    2,
                    "None",
                    [{
                        "tradeActionType": "Borrow",
                        "marketIndex": 1,
                        "notional": 5_000_000e8,
                        "maxSlippage": 0
                    }],
                ),
                get_balance_trade_action(
                    3,
                    "None",
                    [{
                        "tradeActionType": "Borrow",
                        "marketIndex": 1,
                        "notional": 5_000_000e8,
                        "maxSlippage": 0
                    }],
                )
            ], { "from": accounts[5], "value": 900e18 }
        )

        return environment
    elif name == 'kovan-fork':
        return getEnvironment('kovan')

@pytest.fixture() 
def beacon(wfCashERC4626, nUpgradeableBeacon, env):
    impl = wfCashERC4626.deploy(env.notional.address, env.tokens['WETH'], {"from": env.deployer})
    return nUpgradeableBeacon.deploy(impl.address, {"from": env.deployer})

@pytest.fixture() 
def factory(WrappedfCashFactory, beacon, env):
    return WrappedfCashFactory.deploy(beacon.address, {"from": env.deployer})

@pytest.fixture() 
def wrapper(factory, env):
    markets = env.notional.getActiveMarkets(2)
    txn = factory.deployWrapper(2, markets[0][1])
    return Contract.from_abi("Wrapper", txn.events['WrapperDeployed']['wrapper'], wfCashERC4626.abi)

@pytest.fixture() 
def lender(env, accounts):
    acct = accounts[4]
    env.tokens["DAI"].transfer(acct, 1_000_000e18, {'from': env.whales["DAI_EOA"]})
    
    env.tokens["DAI"].approve(env.notional.address, 2**255-1, {'from': acct})
    env.notional.batchBalanceAndTradeAction(
        acct,
        [ 
            get_balance_trade_action(
                2,
                "DepositUnderlying",
                [{
                    "tradeActionType": "Lend",
                    "marketIndex": 1,
                    "notional": 100_000e8,
                    "minSlippage": 0
                },
                {
                    "tradeActionType": "Lend",
                    "marketIndex": 2,
                    "notional": 100_000e8,
                    "minSlippage": 0
                }],
                depositActionAmount=200_000e18,
                withdrawEntireCashBalance=True,
                redeemToUnderlying=True,
            )
        ], { "from": acct }
    )

    return acct

@pytest.fixture() 
def lender_contract(env):
    env.tokens["DAI"].approve(env.notional.address, 2**255-1, {'from': env.whales["DAI_CONTRACT"]})
    env.notional.batchBalanceAndTradeAction(
        env.whales["DAI_CONTRACT"],
        [ 
            get_balance_trade_action(
                2,
                "DepositUnderlying",
                [{
                    "tradeActionType": "Lend",
                    "marketIndex": 1,
                    "notional": 100_000e8,
                    "minSlippage": 0
                }],
                depositActionAmount=100_000e18,
                withdrawEntireCashBalance=True,
                redeemToUnderlying=True,
            )
        ], { "from": env.whales["DAI_CONTRACT"] }
    )

    return env.whales["DAI_CONTRACT"]

# Deploy and Upgrade
def test_deploy_wrapped_fcash(factory, env):
    markets = env.notional.getActiveMarkets(2)
    computedAddress = factory.computeAddress(2, markets[0][1])
    txn = factory.deployWrapper(2, markets[0][1], {"from": env.deployer})
    assert txn.events['WrapperDeployed']['wrapper'] == computedAddress

    wrapper = Contract.from_abi("Wrapper", computedAddress, wfCashERC4626.abi)
    assert wrapper.getCurrencyId() == 2
    assert wrapper.getMaturity() == markets[0][1]
    assert wrapper.name() == "Wrapped fDAI @ {}".format(markets[0][1])
    assert wrapper.symbol() == "wfDAI:{}".format(markets[0][1])

def test_upgrade_wrapped_fcash(factory, beacon, wrapper, env):
    assert wrapper.getCurrencyId() == 2

    beacon.upgradeTo(factory.address, {"from": beacon.owner()})

    with brownie.reverts():
        wrapper.getCurrencyId()


def test_cannot_deploy_wrapper_twice(factory, env):
    markets = env.notional.getActiveMarkets(2)
    txn = factory.deployWrapper(2, markets[0][1])
    assert txn.events['WrapperDeployed'] is not None

    txn = factory.deployWrapper(2, markets[0][1])
    assert 'WrapperDeployed' not in txn.events

def test_cannot_deploy_invalid_currency(factory, env):
    markets = env.notional.getActiveMarkets(2)
    with brownie.reverts():
        factory.deployWrapper(99, markets[0][1])

def test_cannot_deploy_invalid_maturity(factory, env):
    markets = env.notional.getActiveMarkets(2)
    with brownie.reverts():
        factory.deployWrapper(2, markets[0][1] + 86400 * 720)
    
    with brownie.reverts("Create2: Failed on deploy"):
        factory.deployWrapper(2, markets[0][1] - 86400 * 90)

# Test Minting fCash
def test_only_accepts_notional_v2(wrapper, beacon, lender, env):
    impl = wfCashERC4626.deploy(env.deployer.address, env.tokens["WETH"].address, {"from": env.deployer})

    # Change the address of notional on the beacon
    beacon.upgradeTo(impl.address)

    with brownie.reverts("Invalid"):
        env.notional.safeTransferFrom(
            lender.address,
            wrapper.address,
            wrapper.getfCashId(),
            100_000e8,
            "",
            {"from": lender}
        )


def test_cannot_transfer_invalid_fcash(lender, factory, env):
    markets = env.notional.getActiveMarkets(2)
    txn = factory.deployWrapper(2, markets[1][1])
    wrapper = Contract.from_abi("Wrapper", txn.events['WrapperDeployed']['wrapper'], wfCashERC4626.abi)
    fCashId = env.notional.encodeToId(2, markets[0][1], 1)

    with brownie.reverts():
        env.notional.safeTransferFrom(
            lender.address,
            wrapper.address,
            fCashId,
            100_000e8,
            "",
            {"from": lender}
        )

def test_cannot_transfer_batch_fcash(wrapper, lender, env):
    with brownie.reverts():
        env.notional.safeBatchTransferFrom(
            lender.address,
            wrapper.address,
            [wrapper.getfCashId()],
            [100_000e8],
            "",
            {"from": lender}
        )

def test_transfer_fcash(wrapper, lender, env):
    env.notional.safeTransferFrom(
        lender.address,
        wrapper.address,
        wrapper.getfCashId(),
        100_000e8,
        "",
        {"from": lender}
    )

    assert wrapper.balanceOf(lender) == 100_000e8

def test_transfer_fcash_to_contract(wrapper, lender_contract, env):
    env.notional.safeTransferFrom(
        lender_contract.address,
        wrapper.address,
        wrapper.getfCashId(),
        100_000e8,
        "",
        {"from": lender_contract}
    )

    assert wrapper.balanceOf(lender_contract) == 100_000e8

# Test Redeem fCash

def test_fail_redeem_above_balance(wrapper, lender, env):
    env.notional.safeTransferFrom(
        lender.address,
        wrapper.address,
        wrapper.getfCashId(),
        100_000e8,
        "",
        {"from": lender}
    )

    with brownie.reverts():
        wrapper.redeem(105_000e8, (False, False, lender.address, 0), {"from": lender})
        wrapper.redeemToAsset(105_000e8, lender.address, 0, {"from": lender})
        wrapper.redeemToUnderlying(105_000e8, lender.address, 0, {"from": lender})

def test_transfer_fcash(wrapper, lender, env):
    env.notional.safeTransferFrom(
        lender.address,
        wrapper.address,
        wrapper.getfCashId(),
        100_000e8,
        "",
        {"from": lender}
    )
    wrapper.redeem(50_000e8, (False, True, lender, 0), {"from": lender})

    assert wrapper.balanceOf(lender.address) == 50_000e8
    assert env.notional.balanceOf(lender.address, wrapper.getfCashId()) == 50_000e8

def test_transfer_fcash_contract(wrapper, lender_contract, env):
    env.notional.safeTransferFrom(
        lender_contract.address,
        wrapper.address,
        wrapper.getfCashId(),
        100_000e8,
        "",
        {"from": lender_contract}
    )

    # This does not work on kovan right now...
    with brownie.reverts():
        wrapper.redeem(
            50_000e8,
            (False, True, lender_contract, 0),
            {"from": lender_contract}
        )

    wrapper.transfer(env.deployer, 50_000e8, {"from": lender_contract})

    assert wrapper.balanceOf(lender_contract.address) == 50_000e8
    assert wrapper.balanceOf(env.deployer) == 50_000e8

def test_redeem_post_maturity_asset(wrapper, lender, env):
    env.notional.safeTransferFrom(
        lender.address,
        wrapper.address,
        wrapper.getfCashId(),
        100_000e8,
        "",
        {"from": lender}
    )

    chain.mine(1, timestamp=wrapper.getMaturity())
    wrapper.redeemToAsset(50_000e8, lender.address, 0, {"from": lender})

    assert wrapper.balanceOf(lender.address) == 50_000e8
    expectedAssetTokens = Wei(50_000e8 * 1e10 * 1e18) / env.tokens['cDAI'].exchangeRateStored()
    assert pytest.approx(env.tokens["cDAI"].balanceOf(lender.address), abs=100) == expectedAssetTokens

def test_redeem_post_maturity_underlying(wrapper, lender, env):
    env.notional.safeTransferFrom(
        lender.address,
        wrapper.address,
        wrapper.getfCashId(),
        100_000e8,
        "",
        {"from": lender}
    )

    balanceBefore = env.tokens["DAI"].balanceOf(lender.address)
    # For underlying tokens we need to settle the account and mine a few blocks to ensure
    # that the balance check works. Since Compound uses blocks instead of timestamps to accrue
    # interest we need to actually mine a few blocks to get the interest accrued to increase
    chain.mine(1, timestamp=wrapper.getMaturity())
    env.notional.settleAccount(wrapper.address, {"from": lender.address})
    chain.mine(50)
    wrapper.redeemToUnderlying(50_000e8, lender.address, 0, {"from": lender})

    assert wrapper.balanceOf(lender.address) == 50_000e8
    assert env.tokens["DAI"].balanceOf(lender.address) - balanceBefore >= 50_000e18

def test_redeem_failure_slippage(wrapper, lender, env):
    env.notional.safeTransferFrom(
        lender.address,
        wrapper.address,
        wrapper.getfCashId(),
        100_000e8,
        "",
        {"from": lender}
    )

    with brownie.reverts('Trade failed, slippage'):
        wrapper.redeemToUnderlying(50_000e8, lender.address, 0.01e9, {"from": lender})

    wrapper.redeemToUnderlying(50_000e8, lender.address, 0.2e9, {"from": lender})
    assert wrapper.balanceOf(lender.address) == 50_000e8

# Test Direct fCash Trading
def test_mint_failure_slippage(wrapper, lender, env):
    env.tokens["DAI"].approve(wrapper.address, 2 ** 255 - 1, {'from': lender})
    with brownie.reverts():
        wrapper.mintViaUnderlying(
            10_000e18,
            10_000e8,
            lender.address,
            0.2e9,
            {'from': lender}
        )

    wrapper.mintViaUnderlying(
        10_000e18,
        10_000e8,
        lender.address,
        0.01e9,
        {'from': lender}
    )

    assert wrapper.balanceOf(lender.address) == 10_000e8


def test_mint_and_redeem_fcash_via_underlying(wrapper, lender, env):
    env.tokens["DAI"].approve(wrapper.address, 2 ** 255 - 1, {'from': lender.address})
    wrapper.mintViaUnderlying(
        10_000e18,
        10_000e8,
        lender.address,
        0,
        {'from': lender.address}
    )
    assert env.tokens["cDAI"].balanceOf(wrapper.address) == 0
    assert env.tokens["DAI"].balanceOf(wrapper.address) == 0

    assert wrapper.balanceOf(lender.address) == 10_000e8
    portfolio = env.notional.getAccount(wrapper.address)[2]
    assert portfolio[0][0] == wrapper.getCurrencyId()
    assert portfolio[0][1] == wrapper.getMaturity()
    assert portfolio[0][3] == 10_000e8
    assert len(portfolio) == 1

    # Now redeem the fCash
    balanceBefore = env.tokens["DAI"].balanceOf(lender.address)
    wrapper.redeemToUnderlying(
        10_000e8,
        lender.address,
        0,
        {"from": lender.address}
    )
    balanceAfter = env.tokens["DAI"].balanceOf(lender.address)
    balanceChange = balanceAfter - balanceBefore 

    assert 9700e18 <= balanceChange and balanceChange <= 9998e18
    portfolio = env.notional.getAccount(wrapper.address)[2]
    assert len(portfolio) == 0
    assert wrapper.balanceOf(lender.address) == 0

    assert env.tokens["cDAI"].balanceOf(wrapper.address) == 0
    assert env.tokens["DAI"].balanceOf(wrapper.address) == 0

def test_mint_and_redeem_fusdc_via_underlying(factory, env):
    markets = env.notional.getActiveMarkets(2)
    txn = factory.deployWrapper(3, markets[0][1])
    wrapper = Contract.from_abi("Wrapper", txn.events['WrapperDeployed']['wrapper'], wfCashERC4626.abi)

    env.tokens["USDC"].approve(wrapper.address, 2 ** 255 - 1, {'from': env.whales["USDC"].address})
    wrapper.mintViaUnderlying(
        10_000e6,
        10_000e8,
        env.whales["USDC"].address,
        0,
        {'from': env.whales["USDC"].address}
    )
    assert env.tokens["cUSDC"].balanceOf(wrapper.address) == 0
    assert env.tokens["USDC"].balanceOf(wrapper.address) == 0

    assert wrapper.balanceOf(env.whales["USDC"].address) == 10_000e8
    portfolio = env.notional.getAccount(wrapper.address)[2]
    assert portfolio[0][0] == wrapper.getCurrencyId()
    assert portfolio[0][1] == wrapper.getMaturity()
    assert portfolio[0][3] == 10_000e8
    assert len(portfolio) == 1

    # Now redeem the fCash
    balanceBefore = env.tokens["USDC"].balanceOf(env.whales["USDC"].address)
    wrapper.redeemToUnderlying(
        10_000e8,
        env.whales["USDC"].address,
        0,
        {"from": env.whales["USDC"].address}
    )
    balanceAfter = env.tokens["USDC"].balanceOf(env.whales["USDC"].address)
    balanceChange = balanceAfter - balanceBefore 

    assert 9700e6 <= balanceChange and balanceChange <= 9997e6
    portfolio = env.notional.getAccount(wrapper.address)[2]
    assert len(portfolio) == 0
    assert wrapper.balanceOf(env.whales["USDC"].address) == 0
    assert env.tokens["cUSDC"].balanceOf(wrapper.address) == 0
    assert env.tokens["USDC"].balanceOf(wrapper.address) == 0

def test_mint_and_redeem_fcash_via_asset(wrapper, env, accounts):
    acct = accounts[0]
    env.tokens["DAI"].transfer(acct, 100_000e18, {'from': env.whales["DAI_EOA"]})
    env.tokens["DAI"].approve(env.tokens["cDAI"].address, 2 ** 255 - 1, {'from': acct})
    env.tokens["cDAI"].mint(100_000e18, {'from': acct})
    env.tokens["cDAI"].approve(wrapper.address, 2**255-1, {'from': acct})

    wrapper.mintViaAsset(
        500_000e8,
        10_000e8,
        acct.address,
        0,
        {'from': acct}
    )
    assert env.tokens["cDAI"].balanceOf(wrapper.address) == 0
    assert env.tokens["DAI"].balanceOf(wrapper.address) == 0

    assert wrapper.balanceOf(acct.address) == 10_000e8
    portfolio = env.notional.getAccount(wrapper.address)[2]
    assert portfolio[0][0] == wrapper.getCurrencyId()
    assert portfolio[0][1] == wrapper.getMaturity()
    assert portfolio[0][3] == 10_000e8
    assert len(portfolio) == 1

    # Now redeem the fCash
    balanceBefore = env.tokens["cDAI"].balanceOf(acct.address)
    wrapper.redeemToAsset(10_000e8, acct.address, 0, {"from": acct.address})
    balanceAfter = env.tokens["cDAI"].balanceOf(acct.address)
    balanceChange = balanceAfter - balanceBefore 

    assert 440_000e8 <= balanceChange and balanceChange <= 499_000e8
    portfolio = env.notional.getAccount(wrapper.address)[2]
    assert len(portfolio) == 0
    assert wrapper.balanceOf(acct.address) == 0
    assert env.tokens["cDAI"].balanceOf(wrapper.address) == 0
    assert env.tokens["DAI"].balanceOf(wrapper.address) == 0

def test_lend_via_erc1155_action_asset_token(wrapper, env, accounts):
    acct = accounts[0]
    env.tokens["DAI"].transfer(acct, 100_000e18, {'from': env.whales["DAI_EOA"]})
    env.tokens["DAI"].approve(env.tokens["cDAI"].address, 2 ** 255 - 1, {'from': acct})
    env.tokens["cDAI"].mint(100_000e18, {'from': acct})
    env.tokens["cDAI"].approve(env.notional.address, 2**255-1, {'from': acct})

    # Requires approval on the Notional side...
    action = get_lend_action(
        2,
        [{"tradeActionType": "Lend", "marketIndex": wrapper.getMarketIndex(),
            "notional": 100_000e8, "minSlippage": 0}],
        False,
    )
    lendCallData = env.notional.batchLend.encode_input(acct.address, [action])

    # will msg.sender will lend directly on notional, via erc1155 transfer
    env.notional.safeTransferFrom(
        acct.address, # msg.sender
        wrapper.address, # wrapper will receive fCash
        wrapper.getfCashId(),
        100_000e8,
        lendCallData,
        {"from": acct}
    )

    assert env.tokens["cDAI"].balanceOf(wrapper.address) == 0
    assert env.tokens["DAI"].balanceOf(wrapper.address) == 0

    # test balance on wrapper and in notional fCash
    assert wrapper.balanceOf(acct.address) == 100_000e8
    # assert that the account has no Notional position
    portfolio = env.notional.getAccount(acct.address)[2]
    assert len(portfolio) == 0

def test_lend_via_erc1155_action_underlying_token(wrapper, env, accounts):
    acct = accounts[0]
    env.tokens["DAI"].transfer(acct, 100_000e18, {'from': env.whales["DAI_EOA"]})
    env.tokens["DAI"].approve(env.notional.address, 2 ** 255 - 1, {'from': acct})

    # Requires approval on the Notional side...
    action = get_lend_action(
        2,
        [{"tradeActionType": "Lend", "marketIndex": wrapper.getMarketIndex(),
            "notional": 100_000e8, "minSlippage": 0}],
        True,
    )
    lendCallData = env.notional.batchLend.encode_input(acct.address, [action])

    # will msg.sender will lend directly on notional, via erc1155 transfer
    env.notional.safeTransferFrom(
        acct.address, # msg.sender
        wrapper.address, # wrapper will receive fCash
        wrapper.getfCashId(),
        100_000e8,
        lendCallData,
        {"from": acct}
    )

    assert env.tokens["cDAI"].balanceOf(wrapper.address) == 0
    assert env.tokens["DAI"].balanceOf(wrapper.address) == 0

    # test balance on wrapper and in notional fCash
    assert wrapper.balanceOf(acct.address) == 100_000e8
    # assert that the account has no Notional position
    portfolio = env.notional.getAccount(acct.address)[2]
    assert len(portfolio) == 0

# ERC4626 tests
def test_deposit_4626(wrapper, env, lender):
    env.tokens["DAI"].approve(wrapper.address, 2 ** 255 - 1, {'from': lender})

    # There is a little drift between these two calls
    preview = wrapper.previewDeposit(Wei(100e18))
    balanceBefore = env.tokens["DAI"].balanceOf(lender.address)
    txn = wrapper.deposit(Wei(100e18), lender.address, {"from": lender})
    balanceAfter = env.tokens["DAI"].balanceOf(lender.address)

    assert pytest.approx(wrapper.balanceOf(lender.address), abs=100) == preview
    assert txn.events['Deposit']['shares'] == wrapper.balanceOf(lender.address)
    assert pytest.approx(balanceBefore - balanceAfter, abs=1e11) == 100e18

def test_deposit_receiver_4626(wrapper, env, lender, accounts):
    env.tokens["DAI"].approve(wrapper.address, 2 ** 255 - 1, {'from': lender})

    preview = wrapper.previewDeposit(100e18)
    txn = wrapper.deposit(100e18, accounts[0].address, {"from": lender})

    assert pytest.approx(wrapper.balanceOf(accounts[0].address), abs=100) == preview
    assert txn.events['Deposit']['shares'] == wrapper.balanceOf(accounts[0].address)
    assert wrapper.balanceOf(lender.address) == 0

def test_deposit_matured_4626(wrapper, env, lender):
    chain.mine(1, timestamp=wrapper.getMaturity())

    env.tokens["DAI"].approve(wrapper.address, 2 ** 255 - 1, {'from': lender})

    assert wrapper.previewDeposit(100e18) == 0

    with brownie.reverts("fCash matured"):
        wrapper.deposit(100e18, lender.address, {"from": lender})

def test_mint_4626(wrapper, env, lender):
    env.tokens["DAI"].approve(wrapper.address, 2 ** 255 - 1, {'from': lender})
    daiBalanceBefore = env.tokens["DAI"].balanceOf(lender.address)

    assets = wrapper.previewMint(100e8)
    wrapper.mint(100e8, lender.address, {"from": lender})
    daiBalanceAfter = env.tokens["DAI"].balanceOf(lender.address)

    assert pytest.approx(daiBalanceBefore - daiBalanceAfter, abs=1e11) == assets
    assert wrapper.balanceOf(lender.address) == 100e8

def test_mint_receiver_4626(wrapper, env, lender, accounts):
    env.tokens["DAI"].approve(wrapper.address, 2 ** 255 - 1, {'from': lender})
    daiBalanceBefore = env.tokens["DAI"].balanceOf(lender.address)

    assets = wrapper.previewMint(100e8)
    wrapper.mint(100e8, accounts[0].address, {"from": lender})
    daiBalanceAfter = env.tokens["DAI"].balanceOf(lender.address)

    assert pytest.approx(daiBalanceBefore - daiBalanceAfter, abs=1e11) == assets
    assert wrapper.balanceOf(lender.address) == 0
    assert wrapper.balanceOf(accounts[0].address) == 100e8

def test_mint_deposit_matured_4626(wrapper, env, lender):
    chain.mine(1, timestamp=wrapper.getMaturity())

    with brownie.reverts("fCash matured"):
        wrapper.mint(100e8, lender.address, {"from": lender})
        wrapper.deposit(100e18, lender.address, {"from": lender})

def test_withdraw_4626(wrapper, env, lender, accounts):
    env.tokens["DAI"].approve(wrapper.address, 2 ** 255 - 1, {'from': lender})
    wrapper.mint(100e8, lender.address, {"from": lender})
    balanceBefore = wrapper.balanceOf(lender.address)
    daiBalanceBefore = env.tokens["DAI"].balanceOf(lender.address)

    shares = wrapper.previewWithdraw(50e18)
    wrapper.withdraw(50e18, lender.address, lender.address, {'from': lender.address})
    balanceAfter = wrapper.balanceOf(lender.address)
    daiBalanceAfter = env.tokens["DAI"].balanceOf(lender.address)
    assert pytest.approx(balanceBefore - balanceAfter, rel=1e-6) == shares
    assert pytest.approx(daiBalanceAfter - daiBalanceBefore, abs=1e11) == 50e18

def test_withdraw_receiver_4626(wrapper, env, lender, accounts):
    env.tokens["DAI"].approve(wrapper.address, 2 ** 255 - 1, {'from': lender})
    wrapper.mint(100e8, lender.address, {"from": lender})
    balanceBefore = wrapper.balanceOf(lender.address)

    shares = wrapper.previewWithdraw(50e18)
    wrapper.withdraw(50e18, accounts[0].address, lender.address, {'from': lender.address})
    assert pytest.approx(balanceBefore - shares, rel=1e-6) == wrapper.balanceOf(lender.address)
    assert pytest.approx(env.tokens['DAI'].balanceOf(accounts[0].address), abs=1e11) == 50e18

def test_withdraw_allowance_4626(wrapper, env, lender, accounts):
    env.tokens["DAI"].approve(wrapper.address, 2 ** 255 - 1, {'from': lender})
    wrapper.mint(100e8, lender.address, {"from": lender})
    balanceBefore = wrapper.balanceOf(lender.address)

    with brownie.reverts("ERC20: insufficient allowance"):
        # No allowance set
        wrapper.withdraw(50e18, accounts[0].address, lender.address, {'from': accounts[0].address})
    wrapper.approve(accounts[0].address, 10e8, {'from': lender})

    with brownie.reverts("ERC20: insufficient allowance"):
        # Insufficient allowance
        wrapper.withdraw(50e18, accounts[0].address, lender.address, {'from': accounts[0].address})
    wrapper.approve(accounts[0].address, 100e8, {'from': lender})

    shares = wrapper.previewWithdraw(50e18)
    txn = wrapper.withdraw(50e18, accounts[0].address, lender.address, {'from': accounts[0].address})
    assert pytest.approx(shares, abs=100) == txn.events["Withdraw"]["shares"]
    assert wrapper.balanceOf(lender.address) == balanceBefore - txn.events["Withdraw"]["shares"]
    assert pytest.approx(env.tokens['DAI'].balanceOf(accounts[0].address), abs=1e11) == 50e18

def test_withdraw_matured_4626(wrapper, env, lender, accounts):
    env.tokens["DAI"].approve(wrapper.address, 2 ** 255 - 1, {'from': lender})
    wrapper.mint(100e8, lender.address, {"from": lender})

    chain.mine(1, timestamp=wrapper.getMaturity() + 86400)
    balanceBefore = wrapper.balanceOf(lender.address)

    txn = wrapper.withdraw(50.000000010e18, accounts[0].address, lender.address, {'from': lender})
    assert wrapper.balanceOf(lender.address) == balanceBefore - txn.events["Withdraw"]["shares"]
    assert env.tokens['DAI'].balanceOf(accounts[0].address) > 50e18
    assert env.tokens['DAI'].balanceOf(accounts[0].address) < 50.1e18

def test_redeem_4626(wrapper, env, lender, accounts):
    env.tokens["DAI"].approve(wrapper.address, 2 ** 255 - 1, {'from': lender})
    wrapper.mint(100e8, lender.address, {"from": lender})
    balanceBefore = wrapper.balanceOf(lender.address)
    daiBalanceBefore = env.tokens["DAI"].balanceOf(lender.address)

    assets = wrapper.previewRedeem(50e8)
    wrapper.redeem(50e8, lender.address, lender.address, {'from': lender.address})
    balanceAfter = wrapper.balanceOf(lender.address)
    daiBalanceAfter = env.tokens["DAI"].balanceOf(lender.address)
    assert balanceBefore - balanceAfter == 50e8
    assert pytest.approx(daiBalanceAfter - daiBalanceBefore, abs=1e11) == assets

def test_redeem_receiver_4626(wrapper, env, accounts, lender):
    env.tokens["DAI"].approve(wrapper.address, 2 ** 255 - 1, {'from': lender})
    wrapper.mint(100e8, lender.address, {"from": lender})
    balanceBefore = wrapper.balanceOf(lender.address)

    assets = wrapper.previewRedeem(100e8)
    wrapper.redeem(100e8, accounts[0].address, lender.address, {'from': lender.address})
    assert wrapper.balanceOf(lender.address) == 0
    assert pytest.approx(env.tokens['DAI'].balanceOf(accounts[0].address), abs=5e11) == assets

def test_redeem_allowance_4626(wrapper, env, accounts, lender):
    env.tokens["DAI"].approve(wrapper.address, 2 ** 255 - 1, {'from': lender})
    wrapper.mint(100e8, lender.address, {"from": lender})
    balanceBefore = wrapper.balanceOf(lender.address)

    with brownie.reverts("ERC20: insufficient allowance"):
        # No allowance set
        wrapper.redeem(50e8, accounts[0].address, lender.address, {'from': accounts[0].address})
    wrapper.approve(accounts[0].address, 10e8, {'from': lender})

    with brownie.reverts("ERC20: insufficient allowance"):
        # Insufficient allowance
        wrapper.redeem(50e8, accounts[0].address, lender.address, {'from': accounts[0].address})
    wrapper.approve(accounts[0].address, 100e8, {'from': lender})

    assets = wrapper.previewRedeem(50e8)
    wrapper.redeem(50e8, accounts[0].address, lender.address, {'from': accounts[0].address})
    assert wrapper.balanceOf(lender.address) == balanceBefore - 50e8
    assert pytest.approx(env.tokens['DAI'].balanceOf(accounts[0].address), abs=1.1e11) == assets

def test_redeem_matured_4626(wrapper, env, accounts, lender):
    env.tokens["DAI"].approve(wrapper.address, 2 ** 255 - 1, {'from': lender})
    wrapper.mint(100e8, lender.address, {"from": lender})

    chain.mine(1, timestamp=wrapper.getMaturity())
    env.notional.settleAccount(lender.address, {"from": lender})
    chain.mine(50)
    balanceBefore = wrapper.balanceOf(lender.address)

    txn = wrapper.redeem(100e8, accounts[0].address, lender.address, {'from': lender})
    assert wrapper.balanceOf(lender.address) == 0
    assert env.tokens['DAI'].balanceOf(accounts[0].address) > 100e18
    assert env.tokens['DAI'].balanceOf(accounts[0].address) < 100.1e18

def test_mint_and_redeem_via_weth(factory, env, accounts, lender):
    markets = env.notional.getActiveMarkets(1)
    txn = factory.deployWrapper(1, markets[0][1])
    wrapper = Contract.from_abi("Wrapper", txn.events['WrapperDeployed']['wrapper'], wfCashERC4626.abi)
    wethABI = WrappedFcashProject._build.get("WETH9")["abi"]
    weth = Contract.from_abi("WETH", env.tokens["WETH"], wethABI)
    
    account = accounts[1]
    weth.deposit({'from': account, 'value': 1e18})

    env.tokens['WETH'].approve(wrapper.address, 2**255-1, {"from": account})
    balanceBefore = env.tokens["WETH"].balanceOf(account)
    wrapper.mintViaUnderlying(1e18, 1e8, account.address, 0, {"from": account})
    balanceAfter = env.tokens["WETH"].balanceOf(account)

    assert wrapper.balanceOf(account) == 1e8
    # There is some residual WETH left
    assert 0.98e18 <= balanceBefore - balanceAfter and balanceBefore - balanceAfter <= 1e18

    # Redeem to underlying mints WETH
    wrapper.redeemToUnderlying(1e8, accounts[2].address, 0, {'from': account})
    assert wrapper.balanceOf(account.address) == 0
    assert env.tokens['WETH'].balanceOf(accounts[2].address) > 0.98e18
    assert env.tokens['WETH'].balanceOf(accounts[2].address) < 1e18

def test_mint_redeem_eth_4626(factory, env, lender, accounts):
    markets = env.notional.getActiveMarkets(1)
    txn = factory.deployWrapper(1, markets[0][1])
    wrapper = Contract.from_abi("Wrapper", txn.events['WrapperDeployed']['wrapper'], wfCashERC4626.abi)
    wethABI = WrappedFcashProject._build.get("WETH9")["abi"]
    weth = Contract.from_abi("WETH", env.tokens["WETH"], wethABI)
    
    account = accounts[1]
    weth.deposit({'from': account, 'value': 1e18})
    
    env.tokens['WETH'].approve(wrapper.address, 2**255-1, {"from": account})
    wrapper.mint(1e8, account.address, {"from": account})
    assert wrapper.balanceOf(account.address) == 1e8
    assert env.tokens["WETH"].balanceOf(account) < 0.1e18

    wrapper.redeem(1e8, account.address, account.address, {"from": account})
    assert env.tokens["WETH"].balanceOf(account) > 0.95e18
    assert wrapper.balanceOf(account.address) == 0

    wrapper.deposit(0.95e18, account.address, {"from": account})
    assert wrapper.balanceOf(account.address) > 0.95e8
    assert env.tokens["WETH"].balanceOf(account) < 0.05e18

    chain.mine(1, timestamp=wrapper.getMaturity())
    env.notional.settleAccount(wrapper.address, {"from": account})
    wrapper.redeem(wrapper.balanceOf(account), account.address, account.address, {"from": account})
    assert env.tokens["WETH"].balanceOf(account) > 0.95e18

def test_convert_to_and_from_shares_zero_supply(env, wrapper):
    assert wrapper.totalAssets() == 0
    assert 100e8 < wrapper.convertToShares(100e18) and wrapper.convertToShares(100e18) < 105e8
    assert 95e18 < wrapper.convertToAssets(100e8) and wrapper.convertToAssets(100e8) < 100e18


def test_convert_to_and_from_shares(env, wrapper, lender):
    env.tokens["DAI"].approve(wrapper.address, 2 ** 255 - 1, {'from': lender})
    wrapper.mint(100e8, lender.address, {"from": lender})
    assert 95e18 < wrapper.totalAssets() and wrapper.totalAssets() < 100e18
    assert 100e8 < wrapper.convertToShares(100e18) and wrapper.convertToShares(100e18) < 105e8
    assert 95e18 < wrapper.convertToAssets(100e8) and wrapper.convertToAssets(100e8) < 100e18

def test_transfer_fcash_off_maturity(env, factory, lender, accounts):
    markets = env.notional.getActiveMarkets(2)
    threeMonthWrapperAddress = factory.computeAddress(2, markets[0][1])

    txn = factory.deployWrapper(2, markets[1][1])
    sixMonthWrapper = Contract.from_abi("Wrapper", txn.events['WrapperDeployed']['wrapper'], wfCashERC4626.abi)
    sixMonthfCashId = sixMonthWrapper.getfCashId()
    env.notional.safeTransferFrom(
        lender.address,
        threeMonthWrapperAddress,
        sixMonthfCashId,
        10_000e8,
        "",
        {"from": lender}
    )

    txn = factory.deployWrapper(2, markets[0][1])
    threeMonthWrapper = Contract.from_abi("Wrapper", txn.events['WrapperDeployed']['wrapper'], wfCashERC4626.abi)

    # Expected that the contract would revert here due to length
    with brownie.reverts():
        env.notional.safeTransferFrom(
            lender.address,
            threeMonthWrapper.address,
            threeMonthWrapper.getfCashId(),
            10_000e8,
            "",
            {"from": lender}
        )
    
    assert env.notional.balanceOf(accounts[3], sixMonthfCashId) == 0

    with brownie.reverts():
        # This call is not authorized
        threeMonthWrapper.recoverInvalidfCash(sixMonthfCashId, accounts[3], {"from": accounts[3]})

    # This will transfer the fCash
    threeMonthWrapper.recoverInvalidfCash(sixMonthfCashId, accounts[3], {"from": env.notional.owner()})
    assert env.notional.balanceOf(accounts[3], sixMonthfCashId) == 10_000e8

    # Now this method will succeed
    env.notional.safeTransferFrom(
        lender.address,
        threeMonthWrapper.address,
        threeMonthWrapper.getfCashId(),
        10_000e8,
        "",
        {"from": lender}
    )
    assert threeMonthWrapper.balanceOf(lender) == 10_000e8

    # This method should fail due to unauthorized fCash
    with brownie.reverts():
        threeMonthWrapper.recoverInvalidfCash(threeMonthWrapper.getfCashId(), accounts[3], {"from": env.notional.owner()})

def token_with_fees(env, factory, accounts, MockERC20, MockAggregator, feeAmount):
    zeroAddress = HexString(0, type_str="bytes20")
    token = MockERC20.deploy("Transfer Fee", "TEST", 18, feeAmount, {"from": accounts[0]})
    aggregator = MockAggregator.deploy(18, {"from": accounts[0]})
    aggregator.setAnswer(1e18)
    txn = env.notional.listCurrency(
        (token.address, feeAmount > 0, 4, 18, 0),
        (zeroAddress, False, 0, 0, 0),
        aggregator.address,
        False,
        110,
        75,
        108,
        {"from": env.notional.owner()}
    )
    currencyId = txn.events["ListCurrency"]["newCurrencyId"]
    env.notional.enableCashGroup(
        currencyId,
        zeroAddress,
        (2, 20, 30, 50, 150, 150, 40, 50, 50, (95, 90), (21, 21)),
        "Test Token",
        "TEST",
        {"from": env.notional.owner()}
    )

    env.notional.updateDepositParameters(
        currencyId,
        [int(0.5e8), int(0.5e8)],
        [int(0.8e9), int(0.8e9)],
        {"from": env.notional.owner()}
    )
    env.notional.updateInitializationParameters(
        currencyId,
        # Annualized Anchor Rates
        [int(0.02e9), int(0.02e9)],
        # Target proportion
        [int(0.5e9), int(0.5e9)],
        {"from": env.notional.owner()}
    )

    token.approve(env.notional.address, 2 ** 255, {"from": accounts[0]})
    env.notional.batchBalanceAction(
        accounts[0], [(3, currencyId, 10_000_000e18, 0, False, False)], {"from": accounts[0]}
    )

    env.notional.initializeMarkets(currencyId, True, {"from": accounts[0]})

    return (token, currencyId)

def test_mint_and_redeem_tokens_with_transfer_fees(env, factory, accounts, MockERC20, MockAggregator):
    (token, currencyId) = token_with_fees(env, factory, accounts, MockERC20, MockAggregator, 0.01e18)
    markets = env.notional.getActiveMarkets(currencyId)
    txn = factory.deployWrapper(currencyId, markets[0][1])
    wrapper = Contract.from_abi("Wrapper", txn.events['WrapperDeployed']['wrapper'], wfCashERC4626.abi)

    token.transfer(accounts[1], 250e18, {"from": accounts[0]})
    token.approve(wrapper.address, 250e18, {"from": accounts[1]})
    txn = wrapper.mintViaUnderlying(105e18, 100e8, accounts[1], 0, {"from": accounts[1]})
    assert wrapper.balanceOf(accounts[1]) == 100e8
    assert token.balanceOf(wrapper.address) == 0

    wrapper.mintViaAsset(105e18, 100e8, accounts[1], 0, {"from": accounts[1]})
    assert wrapper.balanceOf(accounts[1]) == 200e8
    assert token.balanceOf(wrapper.address) == 0

    wrapper.redeemToUnderlying(100e8, accounts[1], 0, {"from": accounts[1]})
    assert wrapper.balanceOf(accounts[1]) == 100e8
    assert token.balanceOf(wrapper.address) == 0

    wrapper.redeemToAsset(100e8, accounts[1], 0, {"from": accounts[1]})
    assert wrapper.balanceOf(accounts[1]) == 0
    assert token.balanceOf(wrapper.address) == 0

def test_mint_and_redeem_non_mintable_tokens(env, factory, lender, accounts, MockERC20, MockAggregator):
    (token, currencyId) = token_with_fees(env, factory, accounts, MockERC20, MockAggregator, 0)
    markets = env.notional.getActiveMarkets(currencyId)
    txn = factory.deployWrapper(currencyId, markets[0][1])
    wrapper = Contract.from_abi("Wrapper", txn.events['WrapperDeployed']['wrapper'], wfCashERC4626.abi)

    token.transfer(accounts[1], 200e18, {"from": accounts[0]})
    token.approve(wrapper.address, 200e18, {"from": accounts[1]})
    wrapper.mintViaUnderlying(100e18, 100e8, accounts[1], 0, {"from": accounts[1]})

    assert wrapper.balanceOf(accounts[1]) == 100e8
    assert token.balanceOf(accounts[1]) <= 102e18

    wrapper.mintViaAsset(100e18, 100e8, accounts[1], 0, {"from": accounts[1]})
    assert wrapper.balanceOf(accounts[1]) == 200e8
    assert token.balanceOf(accounts[1]) <= 1e18

    wrapper.redeemToUnderlying(100e8, accounts[1], 0, {"from": accounts[1]})
    assert wrapper.balanceOf(accounts[1]) == 100e8
    assert 98e18 < token.balanceOf(accounts[1]) and token.balanceOf(accounts[1]) <= 102e18

    wrapper.redeemToAsset(100e8, accounts[1], 0, {"from": accounts[1]})
    assert wrapper.balanceOf(accounts[1]) == 0
    assert 198e18 < token.balanceOf(accounts[1]) and token.balanceOf(accounts[1]) <= 200e18

def test_redeem_usdc_post_maturity(factory, env):
    markets = env.notional.getActiveMarkets(2)
    txn = factory.deployWrapper(3, markets[0][1])
    wrapper = Contract.from_abi("Wrapper", txn.events['WrapperDeployed']['wrapper'], wfCashERC4626.abi)

    env.tokens["USDC"].approve(wrapper.address, 2 ** 255 - 1, {'from': env.whales["USDC"].address})
    wrapper.mintViaUnderlying(
        10_000e6,
        10_000e8,
        env.whales["USDC"].address,
        0,
        {'from': env.whales["USDC"].address}
    )

    balanceBefore = env.tokens["USDC"].balanceOf(env.whales['USDC'].address)
    chain.mine(1, timestamp=wrapper.getMaturity())
    wrapper.redeemToUnderlying(10_000e8, env.whales['USDC'].address, 0, {"from": env.whales['USDC']})

    assert wrapper.balanceOf(env.whales['USDC'].address) == 0
    assert env.tokens["USDC"].balanceOf(env.whales['USDC'].address) - balanceBefore >= 10_000e6

def deploy_atoken_aggregator(lendingPool, aToken, deployer):
    with open("./tests/aTokenAggregator.json", "r") as a:
        artifact = json.load(a)

    createdContract = network.web3.eth.contract(abi=artifact["abi"], bytecode=artifact["bytecode"])
    txn = createdContract.constructor(lendingPool, aToken).buildTransaction(
        {"from": deployer.address, "nonce": deployer.nonce}
    )
    # This does a manual deployment of a contract
    tx_receipt = deployer.transfer(data=txn["data"])

    return Contract.from_abi("aTokenAggregator", tx_receipt.contract_address, abi=artifact["abi"], owner=deployer)

def test_mint_and_redeem_atoken(factory, env, accounts):
    aToken = env.tokens["aDAI"]
    underlying = env.tokens["DAI"]
    env.notional.setLendingPool("0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9", {"from": env.notional.owner()})

    aggregator = deploy_atoken_aggregator(
        "0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9",
        aToken.address,
        accounts[0]
    )
    rateOracle = MockAggregator.deploy(18, {"from": accounts[0]})
    rateOracle.setAnswer(0.01e18, {"from": accounts[0]})

    txn = env.notional.listCurrency(
        (aToken.address, False, 5, aToken.decimals(), 0),
        (underlying.address, False, 0, underlying.decimals(), 0),
        rateOracle.address,
        False,
        130,
        75,
        108,
        {"from": env.notional.owner()},
    )

    currencyId = txn.events["ListCurrency"]["newCurrencyId"]
    env.notional.updateAssetRate(currencyId, aggregator.address, {"from": env.notional.owner()})

    env.notional.enableCashGroup(
        currencyId,
        aggregator.address,
        (2, 10, 30, 50, 30, 30, 40, 20, 20, (99, 98), (21, 21)),
        "DAI",
        "DAI",
        {"from": env.notional.owner()},
    )
    env.tokens['aDAI'].approve(
        env.notional.address, 2 ** 255 - 1, {"from": env.whales['aDAI']}
    )

    env.notional.updateDepositParameters(
        currencyId,
        # Deposit shares
        [int(0.5e8), int(0.5e8)],
        # Leverage thresholds
        [int(0.8e9), int(0.8e9)],
        {"from": env.notional.owner()}
    )
    env.notional.updateInitializationParameters(
        currencyId,
        # Annualized Anchor Rates
        [int(0.02e9), int(0.02e9)],
        # Target proportion
        [int(0.5e9), int(0.5e9)],
        {"from": env.notional.owner()}
    )
    env.notional.updateTokenCollateralParameters(
        currencyId,
        20,  # residual purchase incentive bps
        85,  # pv haircut
        24,  # time buffer hours
        80,  # cash withholding
        92,  # liquidation haircut percentage
        {"from": env.notional.owner()}
    )

    env.notional.batchBalanceAction(
        env.whales['aDAI'].address,
        [(3, currencyId, 9_000_000e18, 0, False, False)],
        {"from": env.whales['aDAI']}
    )
    env.notional.initializeMarkets(currencyId, True, {"from": env.notional.owner()})

    markets = env.notional.getActiveMarkets(currencyId)
    txn = factory.deployWrapper(currencyId, markets[0][1])
    wrapper = Contract.from_abi("Wrapper", txn.events['WrapperDeployed']['wrapper'], wfCashERC4626.abi)
    
    # mintViaAsset
    aToken.approve(wrapper.address, 2 ** 255 - 1, {'from': env.whales['aDAI']})
    wrapper.mintViaAsset(10_000e18, 10_000e8, env.whales['aDAI'], 0, {"from": env.whales['aDAI']})
    assert wrapper.balanceOf(env.whales['aDAI']) == 10_000e8

    # mintViaUnderlying, mint, deposit (all using DAI)
    underlying.approve(wrapper.address, 2 ** 255 - 1, {'from': env.whales['DAI_EOA']})
    txn = wrapper.mintViaUnderlying(10_000e18, 10_000e8, env.whales['DAI_EOA'], 0, {"from": env.whales['DAI_EOA']})
    wrapper.mint(10_000e8, env.whales['DAI_EOA'], {"from": env.whales['DAI_EOA']})
    # wrapper.deposit(10_000e18, env.whales['DAI_EOA'], {"from": env.whales['DAI_EOA']})
    assert wrapper.balanceOf(env.whales['DAI_EOA']) == 20_000e8

    # redeemToAsset
    wrapper.redeemToAsset(5_000e8, accounts[1], 0, {"from": env.whales['aDAI']})
    assert wrapper.balanceOf(env.whales['aDAI']) == 5_000e8
    assert 4_950e18 < aToken.balanceOf(accounts[1]) and aToken.balanceOf(accounts[1]) < 5_000e18

    # redeemToUnderlying, redeem, withdraw (all using DAI)
    wrapper.redeemToUnderlying(5_000e8, accounts[1], 0, {"from": env.whales['DAI_EOA']})
    wrapper.redeem(5_000e8, accounts[1], env.whales['DAI_EOA'], {"from": env.whales['DAI_EOA']})
    #wrapper.withdraw(5_000e18, accounts[1], env.whales['DAI_EOA'], {"from": env.whales['DAI_EOA']})
    assert wrapper.balanceOf(env.whales['DAI_EOA']) == 10_000e8
    assert 9_900e18 < underlying.balanceOf(accounts[1]) and underlying.balanceOf(accounts[1]) < 10_000e18