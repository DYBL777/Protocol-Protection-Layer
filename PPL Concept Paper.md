# Protocol Protection Layer

**DYBL Foundation**  
*January 2026*  
*Concept Paper*

---

## The Idea

What if protection was just... included?

Not insurance. Not an add-on. Not something you pay extra for.

Just part of the product.

You deposit to earn yield. Protection comes with it. If something goes wrong, compensation happens automatically. No claims. No committees. No waiting to find out if you qualify.

This is Protocol Protection Layer.

---

## How It Could Work

A user deposits funds to earn yield. Nothing unusual there.

The difference is what happens to that yield.

```
User deposits (e.g., 1000 USDC)
        │
        └──► Funds go to yield source (e.g., Aave)
        
Yield generated over time
        │
        ├──► ~80% → User (competitive return)
        ├──► ~10% → Protection Seed (grows, compounds)
        └──► ~10% → Treasury (operations)
```

*Percentages are illustrative. Could be configured differently.*

The user gets most of the yield. A small portion builds a protection fund. Another small portion covers costs.

The user's principal stays liquid. They can withdraw anytime.

Protection is funded by yield, not by locking their money.

---

## What The User Sees

From the user's perspective:

| Action | Experience |
|--------|------------|
| Deposit | Same as depositing anywhere else |
| Earn | Competitive yield |
| Withdraw | Anytime, no lock-up |
| If something goes wrong | Automatic compensation |

The trade-off is almost invisible. They give up a small slice of yield. In return, they get protection they didn't have to think about, pay for, or opt into.

---

## The Seed

The seed is where protection lives.

| Property | Behaviour |
|----------|-----------|
| Source | Portion of yield, not deposits |
| Growth | Compounds over time |
| Purpose | Pays out if something goes wrong |
| Direction | Only rises under normal conditions |

The seed grows naturally. More users, more yield, bigger seed. The protection fund strengthens the longer the protocol runs.

One way to bootstrap this: the protocol itself could contribute initial seed capital. This creates immediate credibility. Users see a protection fund from day one, not an empty promise.

---

## When Something Goes Wrong

If a qualifying event occurs, an exploit, a significant loss, an unexpected failure, the seed pays out.

| Aspect | Approach |
|--------|----------|
| Detection | Could be oracle-based, multi-sig confirmed |
| Calculation | Pro-rata based on user deposits |
| Payout | Automatic, no claims process |
| Eligibility | Deposited before the event |

Users who were there when it happened get their share. The seed doesn't drain completely. Sensible limits prevent that. The protocol can recover and rebuild.

---

## The Analogy

Think about train tickets with delay compensation.

You didn't buy "train ticket plus insurance." You bought a train ticket. Compensation for delays is just part of what you get.

Or credit cards with purchase protection. Or products with warranties. You bought the thing. Coverage came with it.

PPL works the same way. You came for yield. Protection is included.

---

## Why This Could Matter

**Traditional DeFi yield:**
- Deposit funds
- Earn yield
- If protocol gets exploited, you lose everything
- Maybe a governance vote about compensation, months later
- Maybe nothing

**With embedded protection:**
- Deposit funds
- Earn yield
- If protocol gets exploited, compensation is automatic
- No votes, no committees, no uncertainty

The difference isn't the yield. It's what happens when things go wrong.

---

## What This Is Not

PPL is not insurance.

Insurance requires premiums, underwriters, claims assessors, and discretionary decisions. Someone deciding if your claim is valid. Waiting. Uncertainty.

PPL has none of that. Protection is embedded. Funded by yield. Automatic when triggered.

Think of it as a feature, not a product. A property of the system, not a separate purchase.

---

## Risk Factors

This is a concept. These are known limitations and trade-offs.

### Yield Timing (Yield Sniping)

The current yield distribution uses a simple pro-rata model based on current principal. A large depositor entering immediately before harvest could claim a share of yield generated before they arrived. This is a known vulnerability. Production deployment should implement a yield-per-share accumulator pattern (similar to MasterChef/Synthetix) to ensure users only earn yield generated after their deposit. Documented for V3.

### Precision Loss

Because yield allocation uses totalPrincipal as denominator, if principal changes between harvest and claims, the allocated amounts may not balance perfectly. In extreme cases, last claimers could face shortfall. The yield-per-share pattern recommended above also resolves this issue.

### Aave Dependency

All funds are held in Aave. If Aave restricts withdrawals or the deposit token becomes illiquid, PPL withdrawals and compensation payouts could fail. This is an accepted dependency. Future versions could diversify across multiple yield sources.

### Compensation Freeze

During an active compensation event, deposits and withdrawals are paused. This could last up to 30 days. The trade-off is security, preventing users from gaming compensation eligibility. Users who need immediate access during a crisis may be blocked.

### Dormancy Queue

The 10% per-transaction cap during dormancy prevents whale griefing but creates a first-come-first-served dynamic. In a true protocol death scenario, later users may face delays.

### Trigger Centralisation

The compensation trigger relies on an oracle proposing and a multisig confirming. If both are compromised, the seed could be drained via a malicious trigger. Production deployments should use timelocks, multiple oracle sources, and well-distributed multisig signers.

### Underfunding Risk

The seed is funded by 10% of yield, not by deposits. In a major loss event, the seed may be significantly smaller than total losses. Users should not expect full recovery. This is embedded protection, not insurance. The seed improves outcomes, it does not guarantee them.

---

## Open Questions

This is a concept. Details remain open.

| Question | Possibilities |
|----------|---------------|
| Yield split | 80/10/10 is one option. Could vary. |
| Trigger mechanism | Oracle, multi-sig, combination |
| What qualifies as an event | Protocol-specific definitions |
| Seed floor | Minimum that can't be drained |
| Recovery period | Time between events |

These are design choices. Different implementations could make different decisions. The core idea stays the same: protection funded by yield, included by default.

---

## Relationship to The Eternal Seed

PPL is one application of The Eternal Seed primitive.

The Eternal Seed describes mechanisms where capital is retained and compounded rather than fully distributed. Different variants serve different purposes. Lotteries, savings products, protection layers.

PPL uses the primitive for embedded protection. Others use it differently. The specification (TES.sol_V1.1) documents the full range of possibilities.

---

## Where This Could Go

Near term:
- Working implementation
- Security review
- Integration with existing yield sources

Longer term:
- Protocol-native integrations
- Cross-chain protection pools
- Dynamic adjustment based on conditions
- Foundation-seeded initial funds for credibility

We're not trying to build everything at once. The concept comes first. Implementation follows. Iteration continues.

---

## Contact

**DYBL Foundation**

If embedded protection interests you, as a builder, integrator, or collaborator, we'd like to hear from you.

📧 dybl7@proton.me  
🐦 [@DYBL77](https://x.com/DYBL77)  
💻 [github.com/DYBL777](https://github.com/DYBL777)

---

*You came for yield. Protection is included.*

🌱
