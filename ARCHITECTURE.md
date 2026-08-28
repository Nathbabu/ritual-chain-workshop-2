# RitualPredict — Architecture

A self-resolving binary prediction market on Ritual Chain. No backend, no cron job, no trusted resolver.

---

## Overview

Users stake native RITUAL on YES or NO for a question like _"Will ETH/USD be ≥ $4,000?"_. When the betting window closes, the Ritual Scheduler wakes the contract at a pre-booked block. The contract reads a public oracle URL using the HTTP precompile, extracts one number using the jq precompile, compares it to the target, and settles the market. Winners pull their proportional share.

---

## System Architecture

```
                 createMarket()
   user  ──────────────────────────────────────▶  RitualPredict.sol
   user  ──────── bet(id, YES|NO) ─────────────▶
                                                      │
                                  IScheduler.schedule()
                                                      │
                                                      ▼
             ┌──────────────────────────────────────────────┐
             │  Scheduler  0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B │
             │  Fires at resolveBlock                                  │
             │  MAX_ATTEMPTS=3 times, RETRY_INTERVAL_BLOCKS=200 apart  │
             └────────────────────────┬─────────────────────────────────┘
                                      │  onScheduledResolve(executionIndex, marketId)
                                      ▼
                              RitualPredict.sol
                                      │
                     ┌────────────────┴───────────────────────┐
                     ▼                                        ▼
          TEEServiceRegistry                        HTTP precompile 0x0801
          pickServiceByCapability()                 GET oracleUrl (in TEE)
          → executor address                        → async envelope
                                                           │
                                                           ▼
                                                   jq precompile 0x0803
                                                   extract number from JSON
                                                           │
                                                           ▼
                                                observed ⋈ target
                                                    │           │
                                                   YES          NO
                                                    │           │
                                                    ▼
                                              Resolved (winners claim)
                                    3× failure → Invalid (everyone refunds)
```

---

## Key Design Decisions

### Block numbers, never timestamps

Every deadline is a block number. Ritual Chain blocks arrive roughly every 195ms and `block.timestamp` is Unix **milliseconds** (not seconds). A seconds-based deadline computed as `now + 1 day` would always be smaller than the chain's actual `block.timestamp`, making every deadline immediately expired. Using block numbers entirely sidesteps this.

### Retry scheduling via the Scheduler's `numCalls`/`frequency`

`createMarket` books `MAX_ATTEMPTS = 3` executions in a single `Scheduler.schedule()` call with `frequency = RETRY_INTERVAL_BLOCKS = 200`. The Scheduler delivers attempt 1 at `resolveBlock`, attempt 2 at `resolveBlock + 200`, and attempt 3 at `resolveBlock + 400`. When any attempt succeeds, `onScheduledResolve` calls `Scheduler.cancel(scheduleId)` to drop the remaining retries.

### Revert-free resolution callback

`onScheduledResolve` is deliberately revert-free (except for the `OnlyScheduler` auth guard). A revert would roll back the entire transaction, including the attempt counter increment. The market could then never reach `Invalid` because it would never accumulate three failed attempts. Every failure path returns normally and records the failure.

### oracle failure ≠ NO outcome

A failed HTTP call, non-200 status, malformed JSON, or jq extraction error is counted as a resolution failure, triggering a retry. Only a genuine `observed ⋈ target` evaluation produces YES or NO. After three failures the market becomes `Invalid` and all stakes are refundable.

### TEE executor selection per attempt

`_pickExecutor` seeds `TEEServiceRegistry.pickServiceByCapability` with `keccak256(block.number, marketId, executionIndex)`. This re-rolls the executor on every retry, so a single unhealthy TEE cannot block all three attempts.

### Pari-mutuel, pull-based payouts

There is no loop over participants. Each winner calls `claimWinnings` and receives `stake × totalPool / winningPool`. Integer division leaves sub-wei dust in the contract; this is deliberate and negligible. If nobody staked on the winning side, the market becomes `Invalid` and everyone refunds instead.

---

## Market State Machine

```
           createMarket()
                │
                ▼
              Open  ──── bet() ───▶ (accumulates stakes)
                │
           closeBlock reached (view-only, no transaction)
                │
                ▼
             Closed
                │
        Scheduler wakes up
                │
                ▼
           Resolving  ◀──── retry (up to 3 total)
                │                │
         oracle ok?            oracle failed attempt < 3
                │                │
                ▼                ▼
           Resolved           Resolving (attempt 2 or 3)
           (winners claim)         │
                            all 3 failed
                                  │
                                  ▼
                               Invalid
                               (everyone refunds)
```

---

## Contract Interactions

| Contract | Address | Role |
|---|---|---|
| Scheduler | `0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B` | Wakes `onScheduledResolve` at `resolveBlock`, 3 attempts |
| RitualWallet | `0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948` | Holds prepaid execution fees; `payer` for scheduled calls |
| TEEServiceRegistry | `0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F` | Selects a healthy HTTP-capable TEE executor |
| HTTP precompile | `0x0000…0801` | Performs the oracle GET inside a TEE enclave |
| jq precompile | `0x0000…0803` | Extracts a `uint256` from the JSON response body |

---

## Test Architecture

Tests run entirely against mocks — `vm.etch` places mock bytecode at canonical Ritual addresses so no network access or funded wallet is required.

- **`MockScheduler`** — records `schedule()` calls, exposes `triggerResolve()` for tests to simulate Scheduler callbacks.
- **`MockRitualWallet`** — accepts deposits, tracks balances.
- **`MockTEEServiceRegistry`** — returns a configurable executor address.
- **`MockHttpPrecompile`** — returns a configurable ABI-encoded short-running-async HTTP envelope, or a forced failure.
- **`MockJqPrecompile`** — returns a configurable `uint256`, or a forced failure.

The mock wrappers are bound to the canonical addresses (not the original deployment addresses) so all storage writes during tests land at the correct locations.
