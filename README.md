# 🌱 Protocol Protection Layer V2

**Eternal Seed Variant 8: Yield-Funded Embedded Protection**

*Current Version: 2.0*

---

## The Idea

You came for yield. Protection is included.

Like train tickets with delay compensation. Like credit cards with purchase protection. You didn't pay extra. It's just there.

---

## What Is This?

A primitive that embeds protection into yield-generating protocols.

**The Old Way:**
- Deposit funds, earn yield
- Protocol gets hacked, you lose everything
- Maybe a governance vote about compensation months later
- Maybe nothing

**The PPL Way:**
- Deposit funds, earn yield
- Protection builds automatically from a slice of yield
- If something goes wrong, compensation is automatic
- No votes, no committees, no uncertainty

---

## How It Works

```
User deposits (e.g., 1000 USDC)
        │
        └──► ALL funds go to Aave (earning yield)
        
Yield generated over time
        │
        ├──► 80% → User (competitive return)
        ├──► 10% → Protection Seed (grows, compounds)
        └──► 10% → Treasury (operations)

User can withdraw principal ANYTIME.
Protection is funded by yield, not by locking deposits.
```

**Key difference from V1:** Principal stays liquid. Seed grows from yield only.

---

## The Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                         NORMAL OPERATION                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   User Deposit (100%)                                           │
│        │                                                        │
│        ▼                                                        │
│   ┌─────────┐                                                   │
│   │  Aave   │  ← All funds earn yield                          │
│   └────┬────┘                                                   │
│        │                                                        │
│        ▼                                                        │
│   Yield Generated                                               │
│        │                                                        │
│   ┌────┴────────────┬────────────┐                             │
│   │                 │            │                              │
│   ▼                 ▼            ▼                              │
│ ┌──────┐      ┌──────┐     ┌─────────┐                         │
│ │ User │      │ Seed │     │Treasury │                         │
│ │ 80%  │      │ 10%  │     │  10%    │                         │
│ └──────┘      └──────┘     └─────────┘                         │
│                  │                                              │
│                  ▼                                              │
│            Compounds in Aave                                    │
│            Protection grows                                     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                       WHEN TRIGGER FIRES                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   1. Oracle detects exploit/failure                             │
│   2. Proposes trigger to contract                               │
│   3. Multi-sig confirms (1-24hr window)                         │
│   4. Seed releases up to 50%                                    │
│   5. Users claim pro-rata shares                                │
│   6. Unclaimed returns to seed after 30 days                    │
│   7. Seed rebuilds from ongoing yield                           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Key Features

### 💧 Liquid Principal
Withdraw your deposit anytime. No lock-ups. Protection is funded by yield, not by trapping your money.

### 🛡️ Front-Run Protection
Attackers can't deposit after seeing an exploit and claim payouts. Block-anchored snapshots ensure only pre-exploit depositors are eligible.

### ⏱️ Trigger Governance
Two-phase commit: Oracle proposes, multi-sig confirms. Minimum 1-hour delay prevents compromised oracles from draining the seed.

### 💤 Dormancy Protection
If protocol goes inactive for 90 days, anyone can activate dormancy mode. Users can withdraw their pro-rata share. Funds are never trapped.

### 🔄 Cascade Prevention
7-day minimum cooldown between compensation events prevents attackers from bleeding the seed with rapid triggers.

### 📊 Full Transparency
All balances, yields, and payouts are on-chain and verifiable. No discretionary decisions.

---

## Configuration

| Parameter | Description | Default | Range |
|-----------|-------------|---------|-------|
| userYieldBps | User's share of yield | 8000 (80%) | 1-9999 |
| seedYieldBps | Seed's share of yield | 1000 (10%) | 1-9999 |
| treasuryYieldBps | Treasury's share | 1000 (10%) | 1-9999 |
| maxCompensationBps | Max % of seed per event | 5000 (50%) | 1-5000 |
| cooldownPeriod | Time between events | 7 days | ≥7 days |
| MIN_DEPOSIT | Minimum deposit | 1 token | Auto (from decimals) |
| DORMANCY_THRESHOLD | Inactivity trigger | 90 days | Fixed |
| MIN_COMPENSATION_WINDOW | Claim period | 30 days | Fixed |

*Yield split must total 100% (10000 bps).*

---

## Deployment

### Prerequisites

```bash
forge install
```

### Constructor Arguments

```solidity
constructor(
    address _depositToken,      // e.g., USDC
    address _aToken,            // e.g., aUSDC  
    address _aavePool,          // Aave V3 Pool
    address _triggerOracle,     // Chainlink Automation
    address _triggerMultisig    // Gnosis Safe
)
```

Default config: 80/10/10 split, 50% max compensation, 7-day cooldown.

---

## User Functions

| Function | What It Does |
|----------|--------------|
| `deposit(amount)` | Deposit tokens, all go to Aave |
| `withdraw(amount)` | Withdraw principal anytime |
| `claimYield()` | Claim accumulated yield (80% share) |
| `claimCompensation()` | Claim payout after trigger event |
| `dormancyWithdraw()` | Exit if protocol inactive 90 days |

---

## Admin Functions

| Function | What It Does | Notes |
|----------|--------------|-------|
| `addTrigger(id, desc)` | Register trigger type | e.g., "AAVE_EXPLOIT" |
| `removeTrigger(id)` | Deregister trigger | |
| `updateYieldSplit(...)` | Change 80/10/10 | Must sum to 100% |
| `withdrawTreasury(...)` | Withdraw treasury funds | Timelock recommended |
| `heartbeat()` | Reset dormancy timer | Call every ~60 days |
| `pause() / unpause()` | Emergency controls | |

*All admin functions should be behind a timelock in production.*

---

## Trigger Flow

```solidity
// 1. Oracle proposes (deposits halt immediately)
ppl.proposeTrigger(keccak256("AAVE_EXPLOIT"));

// 2. Wait 1-24 hours

// 3. Multi-sig confirms
ppl.confirmTrigger();

// 4. Users claim their share
ppl.claimCompensation();

// 5. After 30 days, owner ends period
ppl.endCompensationPeriod();
```

---

## Risk Factors

These are known limitations and trade-offs.

| Risk | Description |
|------|-------------|
| **Yield Timing** | Pro-rata model allows "yield sniping" by large depositors entering after harvest |
| **Aave Dependency** | If Aave restricts withdrawals, PPL is affected |
| **Compensation Freeze** | Deposits/withdrawals pause during 30-day compensation window |
| **Dormancy Queue** | 10% per-tx cap creates first-come-first-served during exit |
| **Trigger Centralisation** | Oracle + multisig compromise could drain seed |
| **Underfunding** | Seed (10% of yield) may be smaller than losses in major events |

This is embedded protection, not insurance. The seed improves outcomes. It does not guarantee them.

---

## Security Model

### Trust Assumptions

| Component | Trust Level | Notes |
|-----------|-------------|-------|
| Owner | High | Config changes. Should be timelocked. |
| Oracle | Medium | Can only propose, not execute. 1hr delay allows cancellation. |
| Multi-sig | Medium | Can only confirm valid proposals within window. |
| Aave | External | Yield source. If Aave fails, PPL is affected. |

### Pre-Audit Hardening (V2.0)

- ✅ Post-withdraw balance checks (reverts if Aave returns <95%)
- ✅ Contract balance checks before all transfers
- ✅ Anti-spam on `harvestYield()` (reverts if no yield)
- ✅ 10% per-tx cap on dormancy withdrawals
- ✅ Timelock comments on all admin functions

---

## Audit Status

| Item | Status |
|------|--------|
| Specification | ✅ Complete |
| Implementation | ✅ Complete (V2.0) |
| NatSpec | ✅ Complete |
| Pre-Audit Polish | ✅ Complete |
| Unit Tests | 🔄 In Progress |
| Audit | ⏳ Pending |

---

## License

**Business Source License 1.1 (BUSL-1.1)**

- **Licensor:** DYBL Foundation
- **Licensed Work:** Protocol Protection Layer
- **Change Date:** May 10, 2029
- **Change License:** MIT

After the Change Date, this code becomes MIT licensed.

For commercial licensing before 2029, contact: dybl7@proton.me

---

## Contact

📧 Email: dybl7@proton.me  
🐦 Twitter: [@DYBL77](https://x.com/DYBL77)  
💻 GitHub: [github.com/DYBL777](https://github.com/DYBL777)

---

## Part of The Eternal Seed Family

This is the production implementation of **Variant 8: Protection Layer** from The Eternal Seed specification (TES.sol_V1.1).

Other variants include lotteries, savings products, and more. See the full specification for details.

---

*You came for yield. Protection is included.*

🌱
