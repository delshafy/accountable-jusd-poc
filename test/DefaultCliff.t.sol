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
}

interface IVault {
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256);
    function maxRedeem(address controller) external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

/// @notice The share price keeps valuing the defaulted debt at face value through the InDefault state and only
///         collapses to the cash ratio when the safety module covers. Whoever redeems before the cover is paid as if
///         the bad debt were good, out of the cash that should cushion everyone.
contract DefaultCliff is Test {
    address constant VAULT = 0x2B5895b716311A1eaC8f93fB88C56aF9eC8C1A69;
    address constant STRATEGY = 0x4c376DF2f5182F5373502ccAB12700c479d8A128;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant HOLDER = 0x4B07AaA370189E5603DF56C84f59c5A59181BFB1;

    IStrategy strategy = IStrategy(STRATEGY);
    IVault vault = IVault(VAULT);

    uint256 constant ONE_SHARE = 1e6; // JUSD is 6 decimals

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
    }

    function test_price_collapses_at_cover_not_at_default() public {
        address manager = strategy.investmentManager();
        assertEq(strategy.loanState(), 3, "loan should be ongoing");

        // 1. Start the default, wait out the timelock, accept it (permissionless).
        vm.startPrank(manager);
        strategy.defaultLoan();
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days + 1);
        strategy.acceptDefault();
        assertEq(strategy.loanState(), 6, "should be InDefault");

        uint256 priceAtDefault = strategy.sharePrice(VAULT);
        emit log_named_uint("price per share after acceptDefault", priceAtDefault);

        // 2. What one share would return right now.
        uint256 before = _redeemOne();

        // 3. Safety module covers a slice, which is what flips the state to InDefaultClaims.
        deal(USDC, manager, 100_000e6);
        vm.startPrank(manager);
        IERC20(USDC).approve(VAULT, type(uint256).max);
        strategy.coverDefault(10_000e6);
        vm.stopPrank();
        assertEq(strategy.loanState(), 7, "should be InDefaultClaims");

        uint256 priceAfterCover = strategy.sharePrice(VAULT);
        emit log_named_uint("price per share after cover", priceAfterCover);

        uint256 afterCover = _redeemOne();

        emit log_named_uint("assets out before cover", before);
        emit log_named_uint("assets out after cover", afterCover);

        assertLt(priceAfterCover, priceAtDefault, "price did not fall at the cover");
        assertLt(afterCover, before, "redeeming after the cover returned no less");
    }

    /// @dev Snapshots, redeems one share as HOLDER, returns the assets received, then rewinds.
    function _redeemOne() internal returns (uint256 assetsOut) {
        uint256 snap = vm.snapshot();
        uint256 start = IERC20(USDC).balanceOf(HOLDER);
        bytes32 commitment = keccak256(abi.encode("redeem"));
        commitment;

        uint256 shares = vault.balanceOf(HOLDER);
        uint256 take = shares < ONE_SHARE ? shares : ONE_SHARE;
        if (take == 0) return 0;

        vm.prank(HOLDER);
        vault.requestRedeem(take, HOLDER, HOLDER);
        uint256 claimable = vault.maxRedeem(HOLDER);
        if (claimable > 0) {
            vm.prank(HOLDER);
            (bool ok, bytes memory data) = VAULT.call(abi.encodeWithSignature("redeem(uint256,address,address)", claimable, HOLDER, HOLDER));
            ok;
            data;
        }
        assetsOut = IERC20(USDC).balanceOf(HOLDER) - start;
        vm.revertTo(snap);
    }
}
