# Accountable JUSD vault — PoCs

Four fork tests against the live contracts. Vault `0x2B5895b716311A1eaC8f93fB88C56aF9eC8C1A69`,
strategy `0x4c376DF2f5182F5373502ccAB12700c479d8A128`, Ethereum mainnet. No mocks, no state fabrication
except the demands of a simulated default.

    forge test --match-path test/ClaimsRecovery.t.sol -vv
    forge test --match-path test/QueuedThroughDefault.t.sol -vv
    forge test --match-path test/DefaultCliff.t.sol -vv
    forge test --match-path test/Starvation.t.sol -vv

## 1. coverDefault is one-shot (ClaimsRecovery.t.sol)

`coverDefault` sets `loanState = InDefaultClaims` while its guard `_requireLoanInDefault()` accepts only
`InDefault`. A second cover reverts `LoanNotInDefault()`. `repay` requires `Ongoing`, so the borrower cannot fund
the shortfall either. A partial cover freezes the vault: residual bad debt can never be covered and the price stays
at the cash ratio. The comment above the function says coverage should be possible at all times.

## 2. Queued requests are filled at the post-cover price (QueuedThroughDefault.t.sol)

Nothing fixes a request's price when it is queued. `_processUpToShares` prices at `sharePrice()` at processing time,
which after the cover is `assetShareRatio()`. Measured: 961.39 JUSD queued before the default is worth 3.16 USDC
after the cover, against 1000 USDC at par.

## 3. Share price holds bad debt at par until the cover (DefaultCliff.t.sol)

`_sharePrice` returns the debt-inclusive price for the whole `InDefault` state and switches to cash-only at
`InDefaultClaims`. `acceptDefault` is permissionless. Measured: 1.0404 USDC per share before the cover, 0.00297
after.

## 4. Deposits never advance the queue (Starvation.t.sol)

`repay` calls `_processAvailableWithdrawals`; `deposit` does not. Liquidity arriving through a deposit is handed to
the next requester while queued users wait for a keeper.

Verification of the deployed source: implementation `0x616eca2310eb1a0bd620afbf916314f3702dd3b6` is
Sourcify-verified (exact match), as is the vault.
