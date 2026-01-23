# 🌱 Protocol Protection Layer

**Eternal Seed Variant 8 : Self-Funding Protocol Protection**

**Current Version: 3.1**

> (Un)popular opinion: protocols shouldn't buy insurance.. they should *be* insurance.
> No premiums leaving the system.. no external underwriters.. no committees deciding if you deserve a payout.
> Just open code that pays when it says. Eternally fair.

---

## What Is This?

A primitive that turns any protocol into its own protection layer.

**The Problem:**
- Most protocols have no answer for "what if we get hacked?"
- External coverage (Nexus Mutual) requires premiums that leave your ecosystem
- Token emissions to cover losses = slow rug via dilution
- Discretionary claim committees decide if you "deserve" a payout

**The Solution:**
- A seed that grows from normal transaction flow
- Compounds via Aave yield (rising floor)
- Opens on verified triggers (oracle proposes, multi-sig confirms)
- No premiums. No emissions. No claim committees.

**Protection as infrastructure, not expense.**

---

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                         NORMAL OPERATION                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   User Deposit                                                  │
│        │                                                        │
│        ▼                                                        │
│   ┌─────────┐                                                   │
│   │  Split  │                                                   │
│   └────┬────┘                                                   │
│        │                                                        │
│   ┌────┴────┐                                                   │
│   │         │                                                   │
│   ▼         ▼                                                   │
│ ┌─────┐  ┌──────────┐                                          │
│ │Seed │  │Yield Pool│                                          │
│ │(15%)│  │  (85%)   │                                          │
│ └──┬──┘  └────┬─────┘                                          │
│    │          │                                                 │
│    ▼          ▼                                                 │
│ ┌─────┐  ┌──────────┐                                          │
│ │Aave │  │Operations│                                          │
│ │Yield│  │ Rewards  │                                          │
│ └─────┘  └──────────┘                                          │
│                                                                 │
│   Seed compounds. Floor rises. Protection grows.                │
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
│   7. Seed rebuilds from ongoing deposits                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Key Features

### 🛡️ Front-Run Protection
Attackers can't deposit after seeing an exploit and claim payouts. Block-anchored snapshots ensure only pre-exploit depositors are eligible.

### ⏱️ Trigger Governance
Two-phase commit: Oracle proposes, multi-sig confirms. Minimum 1-hour delay prevents compromised oracles from draining the seed.

### 💤 Dormancy Protection
If protocol goes inactive for 90 days, anyone can activate dormancy mode. Users can withdraw their pro-rata share.

### 🔄 Cascade Prevention
7-day minimum cooldown between claim events prevents attackers from bleeding the seed with rapid small triggers.

### 💓 Heartbeat Function
Owner can call `heartbeat()` to reset dormancy timer if protocol is healthy but has low deposit activity. Prevents unintended dormancy.

### 🔢 Dynamic Token Support
MIN_DEPOSIT is automatically derived from token decimals. Works with USDC (6), DAI (18), WBTC (8), or any ERC20.

### 📊 Full Transparency
All balances, claims, and payouts are on-chain and verifiable. No discretionary decisions.

---

## Configuration

| Parameter | Description | Default | Range |
|-----------|-------------|---------|-------|
| `seedBps` | % of deposits to seed | 1500 (15%) | 1-5000 |
| `maxClaimBps` | Max % claimable per event | 5000 (50%) | 1-5000 |
| `cooldownPeriod` | Time between claims | 7 days | ≥7 days |
| `MIN_DEPOSIT` | Minimum deposit amount | 1 token | Auto (from decimals) |
| `DORMANCY_THRESHOLD` | Inactivity before dormancy | 90 days | Fixed |
| `MIN_CLAIM_WINDOW` | Minimum claim period | 30 days | Fixed |
| `TRIGGER_MIN_DELAY` | Delay before confirm | 1 hour | Fixed |
| `TRIGGER_CONFIRMATION_WINDOW` | Max confirm window | 24 hours | Fixed |

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
    uint256 _seedBps,           // e.g., 1500 (15%)
    uint256 _maxClaimBps,       // e.g., 5000 (50%)
    uint256 _cooldownPeriod,    // e.g., 7 days
    address _triggerOracle,     // Chainlink Automation
    address _triggerMultisig    // Gnosis Safe
)
```

---

## Integration

### For Protocols

```solidity
// In your deposit/payment function:
function userDeposit(uint256 amount) external {
    token.transferFrom(msg.sender, address(this), amount);
    
    // Route through protection layer
    token.approve(address(protectionLayer), amount);
    protectionLayer.deposit(amount);
}
```

### Setting Up Triggers

```solidity
// Register trigger types
ppl.addTrigger(
    keccak256("AAVE_EXPLOIT"),
    "Aave protocol exploit detected"
);

ppl.addTrigger(
    keccak256("ORACLE_MANIPULATION"),
    "Price oracle manipulation detected"
);

ppl.addTrigger(
    keccak256("GOVERNANCE_EMERGENCY"),
    "Emergency declared by governance"
);
```

---

## Security Model

### Trust Assumptions

| Component | Trust Level | Notes |
|-----------|-------------|-------|
| Owner | High | Can add/remove triggers, update config. Should be timelocked. |
| Oracle | Medium | Can only propose, not execute. 1hr delay allows cancellation. |
| Multi-sig | Medium | Can only confirm valid proposals within window. |
| Aave | External | Yield source. Failure redirects to yield pool. |

### Invariants

1. **Rising Floor**: Under normal operation, seed principal only exits via approved claims or dormancy
2. **No Front-Running**: Deposits after trigger block are ineligible
3. **No Cascade Drain**: Minimum 7-day cooldown between claims
4. **Dormancy Exit**: 90-day inactivity enables fund recovery

### Known Limitations

- `emergencyTrigger()` allows owner bypass. Disable or timelock in production
- Yield source (Aave) failure doesn't trigger protection, redirects to yield pool
- Pro-rata claims favor larger depositors proportionally

---

## Audit Status

| Item | Status |
|------|--------|
| Specification | ✅ Complete |
| Implementation | ✅ Complete |
| Natspec | ✅ Complete |
| Unit Tests | 🔄 In Progress |
| Audit | ⏳ Pending |

---

## License

**Business Source License 1.1 (BUSL-1.1)**

- **Licensor:** DYBL Foundation
- **Licensed Work:** Protocol Protection Layer & Eternal Seed Mechanism
- **Change Date:** May 10, 2029
- **Change License:** MIT

After the Change Date, this code becomes MIT licensed.

For commercial licensing before 2029, contact: dybl7@proton.me

---

## Contact

- 📧 Email: dybl7@proton.me
- 🐦 Twitter: [@DYBL77](https://twitter.com/DYBL77)
- 💬 Discord: dybl777
- 🔗 GitHub: [github.com/DYBL777](https://github.com/DYBL777)

---

## Part of the Eternal Seed Family

This is the production implementation of **Variant 8: Protection Layer Seed** from the [SeedEngine specification](https://github.com/DYBL777/SeedEngine-Permanent-Capital-Retention-Primitive).

---

🌱 *A seed that grows from within. A floor that rises. Eternally fair.*
