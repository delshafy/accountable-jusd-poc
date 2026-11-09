// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IStrategy {
    function borrower() external view returns (address);
    function investmentManager() external view returns (address);
    function loanState() external view returns (uint8);
    function defaultLoan() external;
    function acceptDefault() external;
    function coverDefault(uint256 assets) external;
    function sharePrice(address share) external view returns (uint256);
    function processAvailableWithdrawals() external returns (uint256);
    function borrow(uint256 assets) external;
}

interface IVault {
    function deposit(uint256 assets, address receiver, address controller) external returns (uint256);
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256);
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256);
    function maxRedeem(address controller) external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function totalQueuedShares() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function redeem(uint256 shares, address receiver, address controller) external returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @notice A request queued BEFORE the default is filled at the post-cover cash price, while a request arriving after
///         the default but before the cover is paid at par. Queuing earlier buys nothing.
contract QueuedThroughDefault is Test {
    address constant VAULT = 0x2B5895b716311A1eaC8f93fB88C56aF9eC8C1A69;
    address constant STRATEGY = 0x4c376DF2f5182F5373502ccAB12700c479d8A128;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    IStrategy strategy = IStrategy(STRATEGY);
    IVault vault = IVault(VAULT);

    address queuedUser = address(0xC0FFEE);
    address lateUser = address(0xBEEF);

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
    }

    function test_queued_before_default_is_filled_at_cash_price() public {
        address manager = strategy.investmentManager();
        address borrower = strategy.borrower();

        // Two equal depositors, then drain idle cash so any redeem has to queue.
        deal(USDC, queuedUser, 100_000e6);
        deal(USDC, lateUser, 100_000e6);
        vm.startPrank(queuedUser);
        IERC20(USDC).approve(VAULT, type(uint256).max);
        vault.deposit(1_000e6, queuedUser, queuedUser);
        vm.stopPrank();
        vm.startPrank(lateUser);
        IERC20(USDC).approve(VAULT, type(uint256).max);
        vault.deposit(1_000e6, lateUser, lateUser);
        vm.stopPrank();

        vm.startPrank(borrower);
        IERC20(USDC).approve(STRATEGY, type(uint256).max);
        uint256 drain = vault.totalAssets();
        try strategy.borrow(drain) {} catch { strategy.borrow(drain * 99 / 100); }
        vm.stopPrank();

        // 1. Queued BEFORE any default.
        uint256 sharesQueued = vault.balanceOf(queuedUser);
        vm.startPrank(queuedUser);
        vault.requestRedeem(sharesQueued, queuedUser, queuedUser);
        vm.stopPrank();
        assertGt(vault.pendingRedeemRequest(0, queuedUser), 0, "should be queued");
        uint256 stateAtQueue = strategy.loanState();
        emit log_named_uint("state when queued", stateAtQueue);

        uint256 par = strategy.sharePrice(VAULT);
        emit log_named_uint("par price", par);

        // 2. Default is accepted, then covered, while the request still sits in the queue.
        vm.startPrank(manager);
        strategy.defaultLoan();
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days + 1);
        strategy.acceptDefault();

        deal(USDC, manager, 200_000e6);
        vm.startPrank(manager);
        IERC20(USDC).approve(VAULT, type(uint256).max);
        strategy.coverDefault(50_000e6);
        vm.stopPrank();

        // 3. Now the earlier request finally gets processed, at the post-cover price.
        emit log_named_uint("state after cover", strategy.loanState());
        emit log_named_uint("price after cover", strategy.sharePrice(VAULT));
        emit log_named_uint("vault cash", vault.totalAssets());
        emit log_named_uint("supply", vault.totalSupply());
        strategy.processAvailableWithdrawals();
        uint256 queuedClaim = vault.maxRedeem(queuedUser);
        emit log_named_uint("queued claimable after cover", queuedClaim);

        uint256 priceAfter = strategy.sharePrice(VAULT);
        uint256 parValue = sharesQueued * par / 1e36;
        uint256 actualValue = queuedClaim * priceAfter / 1e36;
        emit log_named_uint("shares fulfilled", queuedClaim);
        emit log_named_uint("par would have paid", parValue);
        emit log_named_uint("actual value after cover", actualValue);

        assertLt(actualValue * 10, parValue, "queue should be an order of magnitude worse than par");
    }
}
