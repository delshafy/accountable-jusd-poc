// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IVault {
    function deposit(uint256 assets, address receiver, address controller) external returns (uint256);
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256);
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256);
    function maxRedeem(address controller) external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function totalQueuedShares() external view returns (uint256);
    function redeem(uint256 shares, address receiver, address controller) external returns (uint256);
}

interface IStrategy {
    function borrower() external view returns (address);
    function borrow(uint256 assets) external;
    function repay(uint256 assets) external;
    function processAvailableWithdrawals() external returns (uint256);
    function sharePrice(address share) external view returns (uint256);
}

/// @notice A redeemer who arrives later is served instantly while an earlier request waits, because the instant
///         path in onRequestRedeem never tries to advance the queue first.
contract QueueStarvation is Test {
    address constant VAULT = 0x2B5895b716311A1eaC8f93fB88C56aF9eC8C1A69;
    address constant STRATEGY = 0x4c376DF2f5182F5373502ccAB12700c479d8A128;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address holderSmall = 0x28Fd7f987A9D66d61d7FCB1292B6CeB8615371a5; // 12,019 JUSD, real holder
    address holderBig = 0x4B07AaA370189E5603DF56C84f59c5A59181BFB1; // 12,019 JUSD, real holder

    IVault vault = IVault(VAULT);
    IStrategy strategy = IStrategy(STRATEGY);

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
    }

    function test_late_redeemer_jumps_the_queue() public {
        address borrower = strategy.borrower();
        address whale1 = makeAddr("whale1");
        address whale2 = makeAddr("whale2");

        // 1. Fund the vault, then drain idle liquidity through the borrower so a queue can form.
        deal(USDC, whale1, 500_000e6);
        vm.startPrank(whale1);
        IERC20(USDC).approve(VAULT, type(uint256).max);
        vault.deposit(200_000e6, whale1, whale1);
        vm.stopPrank();

        vm.startPrank(borrower);
        IERC20(USDC).approve(STRATEGY, type(uint256).max);
        uint256 borrowable = vault.totalAssets();
        try strategy.borrow(borrowable) {} catch { strategy.borrow(borrowable * 99 / 100); }
        vm.stopPrank();
        emit log_named_uint("idle liquidity after borrow", vault.totalAssets());

        // 2. Small holder queues behind a drained vault.
        uint256 earlyShares = IERC20(VAULT).balanceOf(holderSmall);
        vm.startPrank(holderSmall);
        vault.requestRedeem(earlyShares, holderSmall, holderSmall);
        vm.stopPrank();

        uint256 earlyPending = vault.pendingRedeemRequest(0, holderSmall);
        emit log_named_uint("early pending", earlyPending);
        assertGt(earlyPending, 0, "early request should be queued");

        // 3. Liquidity returns via a DEPOSIT, which does not run the keeper.
        deal(USDC, whale2, 500_000e6);
        vm.startPrank(whale2);
        IERC20(USDC).approve(VAULT, type(uint256).max);
        vault.deposit(200_000e6, whale2, whale2);
        vm.stopPrank();
        emit log_named_uint("idle liquidity after deposit", vault.totalAssets());
        assertEq(vault.pendingRedeemRequest(0, holderSmall), earlyPending, "deposit must not process the queue");

        // 4. A large redeemer arriving later is served instantly out of that idle liquidity.
        uint256 lateShares = IERC20(VAULT).balanceOf(holderBig);
        vm.startPrank(holderBig);
        vault.requestRedeem(lateShares, holderBig, holderBig);
        vm.stopPrank();

        uint256 lateClaimable = vault.maxRedeem(holderBig);
        emit log_named_uint("late claimable at once", lateClaimable);
        emit log_named_uint("early still pending", vault.pendingRedeemRequest(0, holderSmall));
        assertGt(lateClaimable, 0, "late redeemer was not served instantly");
        assertEq(vault.pendingRedeemRequest(0, holderSmall), earlyPending, "early request untouched");

        // 5. The early one only moves when a keeper is called.
        strategy.processAvailableWithdrawals();
        uint256 earlyAfter = vault.pendingRedeemRequest(0, holderSmall);
        emit log_named_uint("early pending after keeper", earlyAfter);
        assertLt(earlyAfter, earlyPending, "keeper should advance the early request");
    }
}
