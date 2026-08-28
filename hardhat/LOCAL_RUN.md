# Local Run Evidence — RitualPredict Bootcamp #2

Testnet is currently paused, so deployment and live chain interaction are not possible.
All work below was done locally against a Hardhat node and Foundry-style Solidity tests.

---

## Environment

- **OS:** Windows 11
- **Node.js:** v20+
- **Hardhat:** v3.13.0
- **Solidity:** 0.8.28 (evm target: cancun)
- **forge-std:** v1.9.4

---

## 1. Compile

```
cd hardhat
npm install
npx hardhat build
```

**Output:**

```
Downloading solc 0.8.28
Downloading solc 0.8.28 (WASM build)

Compiled 4 Solidity files with solc 0.8.28 (evm target: cancun)
```

Files compiled:
- `contracts/RitualPredict.sol` — main market contract
- `contracts/ritual/RitualChain.sol` — canonical Ritual addresses and interfaces
- `contracts/mocks/RitualMocks.sol` — test-only mocks for all Ritual system contracts and precompiles
- `contracts/RitualPredict.t.sol` — 51-test Foundry-style Solidity test suite

Zero warnings, zero errors.

---

## 2. Solidity Tests

```
npx hardhat test solidity
```

**Output:**

```
Running Solidity tests

  contracts/RitualPredict.t.sol:RitualPredictTest
    ✔ test_WinnerReceivesFullPool()
    ✔ test_ThreeFailuresInvalidateMarket()
    ✔ test_SuccessAfterOneFailureResolves()
    ✔ test_StakesOfShowsClaimableAfterResolve()
    ✔ test_StakesOfReturnsCorrectValues()
    ✔ test_RevertConstructorZeroBlockTime()
    ✔ test_ResolveYesWin()
    ✔ test_ResolveRevertNotScheduler()
    ✔ test_ResolveNoWin()
    ✔ test_ResolveIgnoresUnknownMarket()
    ✔ test_RefundRevertNotInvalid()
    ✔ test_RefundOnInvalidMarket()
    ✔ test_RefundCoveresBothSideBets()
    ✔ test_RefundCannotClaimTwice()
    ✔ test_ProportionalPayoutMultipleWinners()
    ✔ test_OracleFailureDoesNotSettle()
    ✔ test_LoserCannotClaimWinnings()
    ✔ test_LeftoverCallbackAfterResolutionIsIdempotent()
    ✔ test_JqFailureDoesNotSettle()
    ✔ test_Http404InvalidatesAfterMaxAttempts()
    ✔ test_GetMarketsReturnsMostRecentFirst()
    ✔ test_GetMarketUnknownReverts()
    ✔ test_GetMarketShowsOpenInitially()
    ✔ test_GetMarketShowsClosedAfterCloseBlock()
    ✔ test_FundExecutionRevertZeroValue()
    ✔ test_FundExecutionDepositsToWallet()
    ✔ test_EmptyWinningSideInvalidates()
    ✔ test_DecodeHttpResponseRevertsOnEmptyOutput()
    ✔ test_DecodeHttpResponseParsesCorrectly()
    ✔ test_CreateMarketSchedulesResolution()
    ✔ test_CreateMarketRevertResolveDelayTooShort()
    ✔ test_CreateMarketRevertEmptyQuestion()
    ✔ test_CreateMarketRevertEmptyOracleUrl()
    ✔ test_CreateMarketRevertEmptyJsonPath()
    ✔ test_CreateMarketRevertBettingTooShort()
    ✔ test_CreateMarketRevertBettingTooLong()
    ✔ test_CreateMarketReturnsId()
    ✔ test_CreateMarketIncrementsCount()
    ✔ test_CreateMarketEmitsEvents()
    ✔ test_ComparatorLT_Win()
    ✔ test_ComparatorLTE_Win()
    ✔ test_ComparatorGT_Win()
    ✔ test_ComparatorGT_Loss()
    ✔ test_ClaimWinningsRevertNotResolved()
    ✔ test_CannotClaimTwice()
    ✔ test_BlockTimeMsStored()
    ✔ test_BetYesAccountedCorrectly()
    ✔ test_BetRevertZeroStake()
    ✔ test_BetRevertUnknownMarket()
    ✔ test_BetRevertAfterCloseBlock()
    ✔ test_BetNoAccountedCorrectly()


  51 passing
```

---

## 3. What Was Extended

The starter repo ships `RitualPredict.sol` with five functions left as `// we'll fill this up` stubs:

| Function | What it does |
|---|---|
| `createMarket` | Validates params, converts seconds → blocks, books resolution via Scheduler, initialises market storage, emits `MarketCreated` + `ResolutionRuleSet` |
| `_scheduleResolution` | Calls `IScheduler.schedule` with `MAX_ATTEMPTS=3`, `RETRY_INTERVAL_BLOCKS=200`, correct callback selector, `address(this)` as payer |
| `_pickExecutor` | Queries `TEEServiceRegistry.pickServiceByCapability` with a per-attempt entropy seed (`keccak256(block.number, marketId, executionIndex)`) |
| `_readOracle` | HTTP precompile GET → `decodeHttpResponse` (via external `try`) → jq `uint256` extraction; every failure path returns `(false, 0, reason)` without reverting |
| `onScheduledResolve` | Auth guard, attempt counter, oracle call, comparator evaluation, retry cancellation on success, empty-winning-side invalidation |

Files added beyond what the starter ships:

- `contracts/mocks/RitualMocks.sol` — 5 configurable mocks (`MockScheduler`, `MockRitualWallet`, `MockTEEServiceRegistry`, `MockHttpPrecompile`, `MockJqPrecompile`) etched at canonical Ritual addresses in tests
- `contracts/RitualPredict.t.sol` — 51 Foundry-style Solidity unit tests
- `test/RitualPredict.e2e.ts` — 2 TypeScript end-to-end lifecycle tests (happy path + retry exhaustion → Invalid → refund)
- `ARCHITECTURE.md` — state machine diagram, design decision notes, contract address reference
