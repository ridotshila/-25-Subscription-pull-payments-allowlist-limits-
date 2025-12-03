# 📘 **Subscription / Pull-Payment Smart Contract – Full Tutorial**

This tutorial explains how your **subscription billing**, **pull-payment**, and **allowance-based debit** Plutus V2 validator works.

It is written for developers, auditors, and anyone integrating the script into a backend or DApp.

---

# 📚 **Table of Contents**

1. [🎯 Purpose of the Contract](#purpose)
2. [📄 Datum & Redeemer](#datum)
3. [🛠️ Helper Functions](#helpers)
4. [🧠 Core Validator Logic](#core)

   * Charge
   * Cancel
   * TopUp
   * Update
5. [⏱️ Allowance Logic & Reset Windows](#allowance)
6. [🔐 Signature Requirements](#sigs)
7. [🏗️ Off-chain Workflow](#offchain)
8. [🧪 Testing Cases](#tests)
9. [📘 Glossary](#glossary)

---

<a name="purpose"></a>

# 1. 🎯 **Purpose of the Contract**

This validator implements a **subscription billing model** where:

✔️ A merchant is allowed to *pull* funds
✔️ The subscriber has a **spending limit per period**
✔️ Billing resets automatically based on a **POSIX timestamp**
✔️ Subscriber may **cancel**, **top up**, or **update** their subscription
✔️ All logic is enforced on-chain with clear signatures

This contract is ideal for:

* SaaS subscriptions
* Streaming services (monthly billing)
* API usage billing
* Pay-as-you-go models
* Decentralized debit orders

---

<a name="datum"></a>

# 2. 📄 **Datum & Redeemer**

The contract uses:

## 📌 **SubDatum**

Holds subscription state:

| Field             | Description                       |
| ----------------- | --------------------------------- |
| `sdSubscriber`    | The subscriber who owns the funds |
| `sdMerchant`      | The merchant billing them         |
| `sdPeriod`        | Length of a billing period        |
| `sdLimit`         | Maximum spend allowed in a period |
| `sdSpentInPeriod` | Total spent in current period     |
| `sdResetAt`       | When the allowance resets         |

This allows the contract to track periodic spending limits safely.

---

## 🔄 **SubAction**

Redeemer used per action:

* **Charge amount**
* **Cancel**
* **TopUp amount**
* **Update newLimit newPeriod newResetAt**

Each action activates a different validation path.

---

<a name="helpers"></a>

# 3. 🛠️ **Helper Functions**

### **`valuePaidTo`**

Reads how much ADA was paid to a specific PKH in the Tx outputs.

Used to enforce:

✔️ Merchant must receive at least `amt` ADA
✔️ Prevents merchants from billing without actual payment

---

### **`nowInRange`**

Checks whether the transaction’s valid range includes a given timestamp.

Used for allowance reset logic.

---

### **`remainingAllowance`**

If reset time passed during this transaction → allowance resets.

Otherwise:

`remaining = limit - spentInPeriod`

This creates an automatic, trustless billing period.

---

<a name="core"></a>

# 4. 🧠 **Core Validator Logic**

The validator is implemented in:

```haskell
mkSubscriptionValidator
```

We break down each action:

---

## 🟦 A) **Charge amt**

Merchant attempts to pull money.

### Must-pass conditions:

### ✔️ Amount must be > 0

Prevents invalid or attack scenarios.

### ✔️ Merchant must sign the transaction

```haskell
txSignedBy info (sdMerchant datum)
```

No other actor may trigger a debit.

### ✔️ Amount must not exceed remaining allowance

After applying reset logic.

### ✔️ Merchant must be paid at least `amt` lovelace

```haskell
valuePaidTo info merchant >= amt
```

Validates real economic activity.

---

## 🟥 B) **Cancel**

Only subscriber may cancel.

Rules:

✔️ Subscriber signature required
✔️ Merchant cannot force cancellation

Upon cancellation the UTxO is removed or updated off-chain.

---

## 🟧 C) **TopUp amt**

Allows subscriber to add more ADA to the script output.

Rules:

✔️ Subscriber signature required
✔️ Amount > 0

Note: On-chain cannot verify the top-up amount *matches actual added lovelace*, so off-chain must ensure correctness.

---

## 🟨 D) **Update newLimit newPeriod newResetAt**

Subscriber updates subscription settings.

Rules:

✔️ Only subscriber signs
✔️ All new fields must be ≥ 0

This allows subscriber to adjust:

* Billing cycle
* Spending limits
* Next reset timestamp

---

<a name="allowance"></a>

# 5. ⏱️ **Allowance Logic & Reset Window**

Your contract includes advanced time-window logic.

### Reset occurs when:

`txInfoValidRange` **contains** `from resetAt`

Meaning:
If transaction *passes through or beyond the reset timestamp*, the allowance resets inside the same transaction.

This ensures:

✔️ Accurate period starts
✔️ No leftover spending between periods
✔️ Merchants cannot sneak early charges

---

<a name="sigs"></a>

# 6. 🔐 **Signature Requirements**

| Action | Required Signature |
| ------ | ------------------ |
| Charge | Merchant           |
| Cancel | Subscriber         |
| TopUp  | Subscriber         |
| Update | Subscriber         |

This prevents unauthorized billing and ensures the subscriber fully controls their subscription.

---

<a name="offchain"></a>

# 7. 🏗️ **Off-chain Workflow**

Here’s the real-world flow:

### **1. Subscriber creates subscription UTxO**

Includes full SubDatum.

### **2. Merchant attempts a charge**

* Merchant signs
* Must include ADA payment
* Checks allowance
* Automatically handles period reset

### **3. Subscriber may:**

✔️ Cancel
✔️ Top up
✔️ Update parameters

Everything is permission-controlled.

---

<a name="tests"></a>

# 8. 🧪 **Testing Cases**

### Charge

* [ ] Amount > remaining → must fail
* [ ] Wrong signature → fail
* [ ] Merchant not actually paid → fail
* [ ] Reset window passed → allow fresh limit

### Cancel

* [ ] Subscriber signature required

### TopUp

* [ ] Subscriber signature required
* [ ] Ensure lovelace added off-chain

### Update

* [ ] Subscriber only
* [ ] All fields ≥ 0

---

<a name="glossary"></a>

# 9. 📘 **Glossary**

| Term             | Meaning                         |
| ---------------- | ------------------------------- |
| **Pull Payment** | Merchant initiates the charge   |
| **Allowance**    | Max spending per billing period |
| **ResetAt**      | Time when allowance resets      |
| **TopUp**        | Add funds to subscription UTxO  |
| **Update**       | Change subscription terms       |
| **TxValidRange** | Transaction time window         |

---

