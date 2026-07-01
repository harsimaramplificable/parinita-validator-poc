# smart-contracts

Hardhat project for deploying and interacting with `ChrysalisLedger` on the local Besu QBFT network. Integrates **ML-DSA (FIPS 204 / CRYSTALS-Dilithium)** — a post-quantum digital signature scheme — for off-chain data authentication with an on-chain tamper-evident commitment.

---

## Table of Contents

1. [Project Structure](#1-project-structure)
2. [Network Configuration](#2-network-configuration)
3. [Contracts Overview](#3-contracts-overview)
4. [ML-DSA — Deep Dive](#4-ml-dsa--deep-dive)
5. [How ML-DSA Integrates with the Ledger](#5-how-ml-dsa-integrates-with-the-ledger)
6. [Commands](#6-commands)
7. [Step-by-Step Walkthrough](#7-step-by-step-walkthrough)
8. [Environment Variables](#8-environment-variables)

---

## 1. Project Structure

```
smart-contracts/
├── contracts/
│   ├── ValidatorRegistry.sol   # Manages which addresses can submit records
│   └── ChrysalisLedger.sol     # Core ledger — stores record anchors on-chain
├── scripts/
│   ├── deploy.js               # Deploys both contracts, registers the validator
│   └── interact.js             # Signs data with ML-DSA, indexes records, audits
├── hardhat.config.js           # Besu network config (chainId 1337, gasPrice 0)
├── package.json
├── .env                        # RPC URL, private keys, deployed addresses
└── .gitignore
```

---

## 2. Network Configuration

The Besu network runs locally via Docker Compose with four QBFT validator nodes.

| Parameter    | Value                    |
|--------------|--------------------------|
| Chain ID     | `1337`                   |
| Consensus    | QBFT (Istanbul BFT)      |
| Hardfork     | Berlin (no EIP-1559)     |
| RPC endpoint | `http://localhost:8545`  |
| Gas price    | `0` (dev network)        |

**Why `gasPrice: 0`?** The genesis uses the Berlin hardfork which predates EIP-1559 (introduced in London). Hardhat defaults to EIP-1559 fee fields; setting `gasPrice: 0` forces legacy transactions which Besu accepts on dev chains with no miner fee requirement.

Pre-funded dev accounts (publicly known Besu keys — lab use only):

| Role      | Address                                      |
|-----------|----------------------------------------------|
| Deployer  | `0xfe3b557e8fb62b89f4916b721be55ceb828dbd73` |
| Validator | `0x627306090abaB3A6e1400e9345bC60c78a8BEf57` |

---

## 3. Contracts Overview

### ValidatorRegistry.sol

An owner-controlled whitelist of addresses that are permitted to submit records to the ledger.

| Function               | Description                                |
|------------------------|--------------------------------------------|
| `addValidator(address)`    | Owner adds an address to the whitelist |
| `removeValidator(address)` | Owner removes an address               |
| `isValidator(address) → bool` | Read-only check (called by the ledger) |

### ChrysalisLedger.sol

The core contract. Stores `RecordAnchor` structs keyed by a `bytes32` record ID.

```solidity
struct RecordAnchor {
    bytes32 checkpointId;   // block or batch identifier
    string  popId;          // proof-of-provenance identifier
    uint8   region;         // geographic/logical region code
    uint8   recordType;     // record classification
    uint64  timestamp;      // Unix timestamp (seconds)
    bytes32 hashData;       // keccak256 of the ML-DSA-signed payload
    bool    exists;         // presence sentinel (enables idempotency)
}
```

| Function | Description |
|---|---|
| `indexBatch(recordIds, checkpointId, popId, region, recordType, timestamp, hashData)` | Batch-write anchors; skips already-indexed IDs (idempotent) |
| `getAnchor(recordId) → RecordAnchor` | Read back any anchor by record ID |

**Access control:** `indexBatch` is guarded by `onlyValidator` — the caller must be registered in `ValidatorRegistry`. Any other address will receive `NOT_VALIDATOR`.

**Event emitted per new record:**
```solidity
event RecordIndexed(
    bytes32 indexed recordId,
    string  popId,
    uint8   indexed region,
    bytes32 checkpointBlock,
    bytes32 hashData
);
```

---

## 4. ML-DSA — Deep Dive

### What is ML-DSA?

**ML-DSA** (Module-Lattice-Based Digital Signature Algorithm) is the name standardized in **NIST FIPS 204** (August 2024) for the algorithm formerly known as **CRYSTALS-Dilithium**. It is a post-quantum digital signature scheme — meaning it is designed to remain secure against attacks from quantum computers, unlike RSA or ECDSA which are vulnerable to Shor's algorithm.

ML-DSA is built on the hardness of the **Module Learning With Errors (MLWE)** and **Module Short Integer Solution (MSIS)** problems over structured lattices.

### Security Levels

FIPS 204 defines three parameter sets:

| Variant    | NIST Security Level | Public Key | Secret Key | Signature |
|------------|---------------------|------------|------------|-----------|
| ML-DSA-44  | Level 2 (≥ AES-128) | 1,312 B    | 2,528 B    | 2,420 B   |
| ML-DSA-65  | Level 3 (≥ AES-192) | 1,952 B    | 4,000 B    | 3,309 B   |
| ML-DSA-87  | Level 5 (≥ AES-256) | 2,592 B    | 4,864 B    | 4,595 B   |

This project uses **ML-DSA-65** — the mid-tier providing 192-bit equivalent post-quantum security, a common choice for enterprise applications.

### How ML-DSA Signing Works (simplified)

```
Key Generation:
  seed (32 bytes) ──► expand with SHAKE-128/256 ──► matrix A, vectors s1, s2
  public key  = (A, t = A·s1 + s2)
  secret key  = (ρ, K, tr, s1, s2, t0)

Signing (message M):
  μ  = SHAKE-256(tr ‖ M)          # message hash bound to the public key
  κ  = SHAKE-256(K ‖ rnd ‖ μ)    # randomised nonce
  y  ← sample from Rq^ℓ           # random masking vector
  w1 = HighBits(A·y)
  c̃  = SHAKE-256(μ ‖ w1)         # challenge hash
  c  = SampleInBall(c̃)            # sparse polynomial challenge
  z  = y + c·s1                   # response
  output: σ = (c̃, z, h)

Verification:
  recompute w'1 from (A, t, z, c̃, h)
  accept if SHAKE-256(μ ‖ w'1) == c̃  AND  ‖z‖∞ < bound
```

The key property: a quantum adversary cannot forge a valid `(c̃, z, h)` without knowing `s1, s2` because finding a short vector in a module lattice is believed to be hard even for quantum computers.

### Why ML-DSA Signatures Cannot Be Stored On-Chain

An ML-DSA-65 signature is **3,309 bytes**. Storing it in a Solidity `bytes` field would cost approximately:

```
3309 bytes × 32 gas/byte (cold SSTORE) ≈ 105,888 gas ≈ $0.02–$2 per record
```

More importantly, `bytes32` (the standard fixed-size hash slot) can only hold **32 bytes** — it is physically impossible to store a raw ML-DSA signature in it.

---

## 5. How ML-DSA Integrates with the Ledger

The integration follows the standard **PQC + blockchain commitment pattern**:

```
                 ┌─────────────────────────────────────────┐
                 │            OFF-CHAIN                    │
                 │                                         │
  Record Data ──►│  JSON payload (record IDs, metadata)   │
                 │         │                               │
                 │         ▼                               │
                 │  ml_dsa65.sign(secretKey, payload)      │
                 │         │                               │
                 │         ├──► signature (3309 B)         │
                 │         │    stored in audit DB / IPFS  │
                 │         │                               │
                 │         ▼                               │
                 │  keccak256(payload) ──► hashData (32 B) │
                 └──────────────┬──────────────────────────┘
                                │
                                ▼  on-chain
                 ┌─────────────────────────────────────────┐
                 │        ChrysalisLedger.indexBatch()     │
                 │                                         │
                 │  RecordAnchor {                         │
                 │    checkpointId,                        │
                 │    popId, region, recordType,           │
                 │    timestamp,                           │
                 │    hashData  ◄── 32-byte commitment     │
                 │    exists                               │
                 │  }                                      │
                 └─────────────────────────────────────────┘
```

### Audit / Verification Flow

To later prove a record is authentic:

1. Retrieve `anchor.hashData` from the contract via `getAnchor(recordId)`.
2. Retrieve the original payload and ML-DSA signature from the off-chain store.
3. Check `keccak256(payload) == anchor.hashData` — confirms the payload was not tampered with after indexing.
4. Check `ml_dsa65.verify(publicKey, payload, signature) == true` — confirms the payload was signed by the holder of the corresponding private key.

Both checks together provide a post-quantum-resistant tamper-evidence chain: breaking it requires either forging a lattice-based signature or finding a keccak256 preimage, both of which are computationally infeasible.

---

## 6. Commands

### Install dependencies

```bash
npm install
```

### Compile contracts

```bash
npm run compile
# or
npx hardhat compile
```

### Deploy to Besu network

Deploys `ValidatorRegistry` and `ChrysalisLedger`, registers the validator, and writes contract addresses back to `.env`.

```bash
npm run deploy
# or
npx hardhat run scripts/deploy.js --network besu
```

Expected output:

```
Deployer   : 0xfe3b557e8fb62b89f4916b721be55ceb828dbd73
Validator  : 0x627306090abaB3A6e1400e9345bC60c78a8BEf57
Balance    : 200.0 ETH
Chain ID   : 1337

Deploying ValidatorRegistry...
ValidatorRegistry deployed to: 0x...

Registering validator: 0x627306090abaB3A6e1400e9345bC60c78a8BEf57
Validator registered. tx: 0x...

Deploying ChrysalisLedger...
ChrysalisLedger deployed to: 0x...

─── Deployment summary ──────────────────────────────
ValidatorRegistry : 0x...
ChrysalisLedger   : 0x...
Validator account : 0x627306090abaB3A6e1400e9345bC60c78a8BEf57
─────────────────────────────────────────────────────
```

### Interact with deployed contracts

Signs a batch payload with ML-DSA-65, indexes three records on-chain, reads them back, verifies the ML-DSA proof, and tests idempotency.

```bash
npm run interact
# or
npx hardhat run scripts/interact.js --network besu
```

Expected output:

```
Deployer  : 0xfe3b557e8fb62b89f4916b721be55ceb828dbd73
Validator : 0x627306090abaB3A6e1400e9345bC60c78a8BEf57

isValidator(0x627306090abaB3A6e1400e9345bC60c78a8BEf57) = true

─── ML-DSA (FIPS 204 / Dilithium) ───────────────────────────────
Signing payload with ML-DSA-65...
Algorithm  : ML-DSA-65 (CRYSTALS-Dilithium, security level 3)
Public key : 6f8a3c...
Sig size   : 3309 bytes (stored off-chain)
Payload    : 312 bytes
hashData   : 0xabc123... (keccak256 of ML-DSA-signed payload → on-chain)
Sig valid  : true

─── indexBatch ───────────────────────────────────────────────────
tx hash    : 0x...
gas used   : 187432
events     : 3 (RecordIndexed × 3)

─── getAnchor(record-001) ────────────────────────────────────────
checkpointId : 0x...
popId        : POP-REGION-A-2025
region       : 1
recordType   : 2
timestamp    : 1751380000
hashData     : 0xabc123... ← ML-DSA payload commitment
exists       : true

─── Off-chain audit verification ─────────────────────────────────
on-chain hash matches recomputed : true
ML-DSA signature still valid     : true

─── Idempotency (re-index same IDs) ─────────────────────────────
tx hash  : 0x...
events   : 0 (should be 0 — all already indexed)
```

### Run tests

```bash
npm test
# or
npx hardhat test
```

### Compile only (no deploy)

```bash
npx hardhat compile
```

---

## 7. Step-by-Step Walkthrough

### Step 1 — Start the Besu network

```bash
# From the repo root
cd docker
docker compose up -d

# Wait for nodes to be healthy (~60 seconds)
docker compose ps
```

### Step 2 — Configure environment

```bash
cd smart-contracts
cp .env.example .env   # if using the example file
# Edit .env to set BESU_RPC_URL if your node is not on localhost:8545
```

### Step 3 — Install and compile

```bash
npm install
npm run compile
```

### Step 4 — Deploy

```bash
npm run deploy
```

The script automatically writes the deployed contract addresses back into `.env`:

```
VALIDATOR_REGISTRY_ADDRESS=0x...
CHRYSALIS_LEDGER_ADDRESS=0x...
```

### Step 5 — Interact

```bash
npm run interact
```

The interact script does the following in sequence:

| Step | What happens |
|------|--------------|
| 1 | Reads `VALIDATOR_REGISTRY_ADDRESS` and `CHRYSALIS_LEDGER_ADDRESS` from `.env` |
| 2 | Confirms the validator account is registered in `ValidatorRegistry` |
| 3 | Builds a JSON payload representing the batch (record IDs, checkpoint, metadata) |
| 4 | Generates an ML-DSA-65 keypair deterministically from a fixed seed |
| 5 | Signs the payload with ML-DSA — produces a 3,309-byte post-quantum signature |
| 6 | Computes `keccak256(payload)` → `hashData` (32 bytes, suitable for on-chain storage) |
| 7 | Calls `ChrysalisLedger.indexBatch()` with `hashData` as the validator signer |
| 8 | Reads back `getAnchor("record-001")` and prints all fields |
| 9 | Re-verifies the ML-DSA signature against the on-chain hash (audit path) |
| 10 | Re-runs `indexBatch` with the same IDs to confirm idempotency (0 events emitted) |

---

## 8. Environment Variables

All variables live in `.env` (gitignored):

| Variable | Description | Default |
|---|---|---|
| `BESU_RPC_URL` | JSON-RPC endpoint of the Besu node | `http://localhost:8545` |
| `DEPLOYER_PRIVATE_KEY` | Private key for the deployer account | Besu dev key 1 |
| `VALIDATOR_PRIVATE_KEY` | Private key for the validator account | Besu dev key 2 |
| `VALIDATOR_REGISTRY_ADDRESS` | Address of deployed `ValidatorRegistry` | Set by `deploy.js` |
| `CHRYSALIS_LEDGER_ADDRESS` | Address of deployed `ChrysalisLedger` | Set by `deploy.js` |

> **Warning:** The default private keys are Hyperledger Besu's publicly documented development keys. They are funded in the genesis block for convenience. Never use them on any public or production network.
