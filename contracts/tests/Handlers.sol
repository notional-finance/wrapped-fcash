// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "forge-std/Test.sol";

import "../wfCashERC4626.sol";
import "../../interfaces/notional/IWrappedfCashFactory.sol";

contract BaseHandler is Test {
    uint16 constant ETH = 1;
    WETH9 constant WETH = WETH9(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    INotionalV2 constant NOTIONAL = INotionalV2(0x1344A36A1B56144C3Bc62E7757377D288fDE0369);
    uint256 constant BASIS_POINT = 1e5;

    wfCashERC4626 wrapper;
    address[5] public actors;
    address internal currentActor;
    uint256 public totalShares;
    uint256 public precision;
    uint256 public roundingPrecision;
    uint256 public fCashId;
    IERC20Metadata public asset;

    constructor(wfCashERC4626 _wrapper) {
        wrapper = _wrapper;

        actors[0] = makeAddr("ACTOR_1");
        actors[1] = makeAddr("ACTOR_2");
        actors[2] = makeAddr("ACTOR_3");
        actors[3] = makeAddr("ACTOR_4");
        actors[4] = makeAddr("ACTOR_5");
    }

    modifier useActor(uint256 actorIndexSeed, bool approveToken) {
        currentActor = actors[bound(actorIndexSeed, 0, actors.length - 1)];

        // NOTE: wrappers always use WETH
        asset = IERC20Metadata(wrapper.asset());
        uint8 decimals = asset.decimals();
        precision = 10 ** decimals;
        roundingPrecision = decimals > 8 ? 10 ** (decimals - 8) : 10 ** (8 - decimals);

        fCashId = wrapper.getfCashId();
        deal(address(asset), currentActor, 100 * precision, true);

        vm.startPrank(currentActor);
        if (approveToken) asset.approve(address(wrapper), type(uint256).max);
        _;
        vm.stopPrank();
    }

    function assertAbsDiff(uint256 a, uint256 b, uint256 diff, string memory m) internal {
        uint256 d = a > b ? a - b : b - a;
        assertLe(d, diff, m);
    }

    function assertRelDiff(uint256 a, uint256 b, uint256 rel, string memory m) internal {
        uint256 d = a > b ? a - b : b - a;
        uint256 r = d * 1e9 / precision;
        assertLe(r, rel, m);
    }
}

contract DepositMintHandler is BaseHandler {

    constructor(wfCashERC4626 _wrapper) BaseHandler(_wrapper) {}

    function _mintViaERC1155(uint256 fCashAmount) internal {
        uint16 currencyId = wrapper.getCurrencyId();
        uint40 maturity = wrapper.getMaturity();
        // Normally WETH is dealt to the actor
        if (currencyId == ETH) vm.deal(currentActor, 100e18);
        else asset.approve(address(NOTIONAL), type(uint256).max);

        (
            uint256 depositAmountUnderlying,
            /* */,
            /* */,
            bytes32 encodedTrade
        ) = NOTIONAL.getDepositFromfCashLend(
            currencyId,
            fCashAmount,
            maturity,
            0,
            block.timestamp
        );

        BalanceActionWithTrades[] memory t = new BalanceActionWithTrades[](1);
        bytes32[] memory trades = new bytes32[](1);
        trades[0] = encodedTrade;
        t[0] = BalanceActionWithTrades({
            actionType: DepositActionType.DepositUnderlying,
            currencyId: currencyId,
            depositActionAmount: depositAmountUnderlying,
            withdrawAmountInternalPrecision: 0,
            withdrawEntireCashBalance: true,
            redeemToUnderlying: true,
            trades: trades
        });
        uint256 msgValue = currencyId == ETH ? depositAmountUnderlying : 0;
        NOTIONAL.batchBalanceAndTradeAction{value: msgValue}(currentActor, t);

        // This will mint via ERC1155 transfer
        uint256 balanceBefore = wrapper.balanceOf(currentActor);
        uint256 notionalBefore = NOTIONAL.balanceOf(currentActor, fCashId);
        NOTIONAL.safeTransferFrom(currentActor, address(wrapper), fCashId, fCashAmount, "");

        assertEq(wrapper.balanceOf(currentActor) - balanceBefore, fCashAmount);
        assertEq(NOTIONAL.balanceOf(currentActor, fCashId), notionalBefore - fCashAmount, "Notional Balance");

        totalShares += fCashAmount;
    }

    function mintViaERC1155(uint256 actorIndexSeed) useActor(actorIndexSeed, false) public {
        _mintViaERC1155(0.05e8);
    }

    function mintViaUnderlying(uint256 actorIndexSeed, uint256 receiverIndex) useActor(actorIndexSeed, true) public {
        receiverIndex = bound(receiverIndex, 0, actors.length - 1);
        address receiver = actors[receiverIndex];
        uint256 assets = 0.05e8 * precision / 1e8;

        uint256 assetsBefore = asset.balanceOf(currentActor);
        uint256 sharesBefore = wrapper.balanceOf(receiver);
        uint256 previewValue = wrapper.previewDeposit(assets);

        wrapper.mintViaUnderlying(assets, uint88(previewValue), receiver, 0);

        uint256 assetsAfter = asset.balanceOf(currentActor);
        uint256 sharesAfter = wrapper.balanceOf(receiver);
        uint256 shares = sharesAfter - sharesBefore;

        assertEq(previewValue, shares, "Deposit Shares");
        assertLe(assets - (assetsBefore - assetsAfter), roundingPrecision, "Deposit Amount");

        totalShares += shares;
    }

    function deposit(uint256 actorIndexSeed, uint256 receiverIndex) useActor(actorIndexSeed, true) public {
        receiverIndex = bound(receiverIndex, 0, actors.length - 1);
        address receiver = actors[receiverIndex];
        uint256 assets = 0.05e8 * precision / 1e8;

        uint256 assetsBefore = asset.balanceOf(currentActor);
        uint256 sharesBefore = wrapper.balanceOf(receiver);
        uint256 previewValue = wrapper.previewDeposit(assets);

        uint256 shares = wrapper.deposit(assets, receiver);

        uint256 assetsAfter = asset.balanceOf(currentActor);
        uint256 sharesAfter = wrapper.balanceOf(receiver);

        assertEq(previewValue, shares, "Deposit Shares");
        assertEq(sharesAfter - sharesBefore, shares, "Deposit Shares");
        assertLe(assets - (assetsBefore - assetsAfter), roundingPrecision, "Deposit Amount");

        totalShares += shares;
    }

    function mint(uint256 actorIndexSeed, uint256 receiverIndex) useActor(actorIndexSeed, true) public {
        receiverIndex = bound(receiverIndex, 0, actors.length - 1);
        address receiver = actors[receiverIndex];
        uint256 shares = 0.05e8;

        uint256 assetsBefore = asset.balanceOf(currentActor);
        uint256 sharesBefore = wrapper.balanceOf(receiver);
        uint256 previewValue = wrapper.previewMint(shares);

        uint256 assets = wrapper.mint(shares, receiver);

        uint256 assetsAfter = asset.balanceOf(currentActor);
        uint256 sharesAfter = wrapper.balanceOf(receiver);

        assertEq(previewValue, assets, "Mint Assets");
        assertEq(sharesAfter - sharesBefore, shares, "Mint Shares");
        assertLe(assets - (assetsBefore - assetsAfter), roundingPrecision, "Mint Amount");

        totalShares += shares;
    }
}

contract RedeemWithdrawHandler is BaseHandler {
    constructor(wfCashERC4626 _wrapper) BaseHandler(_wrapper) {
        // NOTE: wrappers always use WETH
        asset = IERC20Metadata(wrapper.asset());
        precision = 10 ** asset.decimals();
        fCashId = wrapper.getfCashId();
        (/* */, uint256 maxFCash) = wrapper.getTotalFCashAvailable();
        uint256 mintAmount = maxFCash / (actors.length - 1);

        // All actors mint some shares prior to maturity
        for (uint256 i; i < actors.length; i++) {
            deal(address(asset), actors[i], 100_000_000 * precision, true);
            vm.startPrank(actors[i]);
            asset.approve(address(wrapper), type(uint256).max);
            wrapper.mint(mintAmount, actors[i]);
            vm.stopPrank();
        }

        vm.warp(block.timestamp + 3600);

        // Ensure that there is a bit of cash and fcash
        (uint256 cashBalance, uint256 fCash) = wrapper.getBalances();
        assertGt(cashBalance, 0);
        assertGt(fCash, 0);

        totalShares = wrapper.totalSupply();
    }

    function redeem(
        uint256 actorIndexSeed,
        uint256 receiverIndex,
        uint256 redeemShare
    ) useActor(actorIndexSeed, false) public {
        receiverIndex = bound(receiverIndex, 0, actors.length - 1);
        redeemShare = bound(redeemShare, 1, 100);
        address receiver = actors[receiverIndex];

        uint256 maxRedeem = wrapper.maxRedeem(currentActor);
        uint256 shares = maxRedeem * redeemShare / 100;

        uint256 assetsBefore = asset.balanceOf(receiver);
        uint256 sharesBefore = wrapper.balanceOf(currentActor);
        // Withdrawing dust balances causes reverts
        if (shares < 1_000) return;

        uint256 previewValue = wrapper.previewRedeem(shares);
        uint256 assets = wrapper.redeem(shares, receiver, currentActor);

        uint256 assetsAfter = asset.balanceOf(receiver);
        uint256 sharesAfter = wrapper.balanceOf(currentActor);

        assertEq(sharesBefore - sharesAfter, shares, " Redeem Shares");
        assertAbsDiff(previewValue, assets, 5 * roundingPrecision, "Redeem Preview");

        assertAbsDiff(assets, (assetsAfter - assetsBefore), roundingPrecision, " Redeem Amount");

        totalShares -= shares;
    }

    function withdraw(
        uint256 actorIndexSeed,
        uint256 receiverIndex,
        uint256 redeemShare
    ) useActor(actorIndexSeed, false) public {
        receiverIndex = bound(receiverIndex, 0, actors.length - 1);
        redeemShare = bound(redeemShare, 1, 100);
        address receiver = actors[receiverIndex];

        uint256 maxWithdraw = wrapper.maxWithdraw(currentActor);
        uint256 assets = maxWithdraw * redeemShare / 100;

        uint256 assetsBefore = asset.balanceOf(receiver);
        uint256 sharesBefore = wrapper.balanceOf(currentActor);
        // Withdrawing dust balances causes reverts
        if (assets < 10 * roundingPrecision) return;

        uint256 previewValue = wrapper.previewWithdraw(assets);
        uint256 shares = wrapper.withdraw(assets, receiver, currentActor);

        uint256 assetsAfter = asset.balanceOf(receiver);
        uint256 sharesAfter = wrapper.balanceOf(currentActor);

        assertEq(previewValue, shares, "Withdraw Preview");
        assertEq(sharesBefore - sharesAfter, shares, "Withdraw Shares");
        assertAbsDiff(assets, (assetsAfter - assetsBefore), 5 * roundingPrecision, "Withdraw Amount");

        totalShares -= shares;
    }

    function redeemViaERC1155(uint256 actorIndexSeed, uint256 redeemShare) useActor(actorIndexSeed, false) public {
        if (wrapper.hasMatured()) return;

        redeemShare = bound(redeemShare, 1, 100);
        uint256 balance = wrapper.balanceOf(currentActor);
        uint256 notionalBefore = NOTIONAL.balanceOf(currentActor, fCashId);
        uint256 redeemAmount = balance * redeemShare / 100;

        wrapper.redeem(redeemAmount, IWrappedfCash.RedeemOpts({
            redeemToUnderlying: false,
            transferfCash: true,
            receiver: currentActor,
            maxImpliedRate: 0
        }));

        assertEq(wrapper.balanceOf(currentActor), balance - redeemAmount, "Wrapper Balance");
        assertEq(NOTIONAL.balanceOf(currentActor, fCashId), notionalBefore + redeemAmount, "Notional Balance");
        totalShares -= redeemAmount;
    }

}