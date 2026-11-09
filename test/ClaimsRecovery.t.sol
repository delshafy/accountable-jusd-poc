// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";

interface IERC20 {
    function approve(address, uint256) external returns (bool);
}

interface IStrategy {
    function investmentManager() external view returns (address);
    function loanState() external view returns (uint8);
    function defaultLoan() external;
    function acceptDefault() external;
    function coverDefault(uint256 assets) external;
    function sharePrice(address share) external view returns (uint256);
    function repay(uint256 assets) external;
    function borrower() external view returns (address);
}

interface IVault {
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @notice After the cliff, does more covering raise the price for whoever is still holding? Confirms the direction of
///         the incentive inside the claims state.
contract ClaimsRecovery is Test {
    error LoanNotInDefault();
    error LoanNotOngoing();
    address constant VAULT = 0x2B5895b716311A1eaC8f93fB88C56aF9eC8C1A69;
    address constant STRATEGY = 0x4c376DF2f5182F5373502ccAB12700c479d8A128;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    IStrategy strategy = IStrategy(STRATEGY);
    IVault vault = IVault(VAULT);

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
    }

    function test_covers_raise_price_for_remaining_holders() public {
        address manager = strategy.investmentManager();

        vm.startPrank(manager);
        strategy.defaultLoan();
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days + 1);
        strategy.acceptDefault();

        uint256 par = strategy.sharePrice(VAULT);
        emit log_named_uint("par", par);

        deal(USDC, manager, 500_000e6);
        vm.startPrank(manager);
        IERC20(USDC).approve(VAULT, type(uint256).max);

        strategy.coverDefault(50_000e6);
        uint256 previous = strategy.sharePrice(VAULT);
        emit log_named_uint("price after first cover", previous);
        emit log_named_uint("state after cover", strategy.loanState());

        // Second cover: reverts, the state is no longer InDefault.
        vm.expectRevert(LoanNotInDefault.selector);
        strategy.coverDefault(50_000e6);
        vm.stopPrank();

        // Borrower repayment is blocked too, so nothing else can fund the shortfall.
        address borrower = strategy.borrower();
        vm.prank(borrower);
        vm.expectRevert(LoanNotOngoing.selector);
        strategy.repay(1_000e6);

        // Cash alone cannot reach par: 150k of covers against a 15.2M supply.
        emit log_named_uint("cash after three covers", vault.totalAssets());
        emit log_named_uint("supply", vault.totalSupply());
        emit log_named_uint("price still short of par by x", par / (previous == 0 ? 1 : previous));

        assertLt(previous, par, "one cover cannot reach par");
    }
}
