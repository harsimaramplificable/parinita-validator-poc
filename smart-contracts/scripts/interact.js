const { ethers } = require("hardhat");
const { randomBytes } = require("crypto");
require("dotenv").config();

const REGISTRY_ADDR = process.env.VALIDATOR_REGISTRY_ADDRESS;
const LEDGER_ADDR   = process.env.CHRYSALIS_LEDGER_ADDRESS;

// ── ML-DSA helpers ─────────────────────────────────────────────────────────────
//
// ML-DSA (FIPS 204 / CRYSTALS-Dilithium) is a post-quantum signature scheme.
// Signatures are 3309 bytes (ML-DSA-65) — too large for bytes32 on-chain.
// Pattern: sign off-chain → store keccak256(payload) on-chain as the tamper-
// evident commitment; keep signature + public key off-chain for audit/verification.

async function buildMlDsaProof(payload) {
  // Dynamic import — @noble/post-quantum ships ESM; works from CJS async context
  const { ml_dsa65 } = await import("@noble/post-quantum/ml-dsa");

  // In production: derive seed from a secure HSM.
  // Here we use a fixed seed so the demo is reproducible across runs.
  const seed = Buffer.from(
    "chrysalis-ledger-demo-seed-v1-000".padEnd(32, "0").slice(0, 32)
  );

  const { secretKey, publicKey } = ml_dsa65.keygen(seed);

  const msgBytes = Buffer.from(JSON.stringify(payload));

  // Sign the payload — this is the PQC proof kept off-chain
  const signature = ml_dsa65.sign(secretKey, msgBytes);

  // Verify immediately so we know the signature is sound
  const valid = ml_dsa65.verify(publicKey, msgBytes, signature);
  if (!valid) throw new Error("ML-DSA signature verification failed");

  // On-chain commitment: keccak256 of the signed payload bytes
  const hashData = ethers.keccak256(msgBytes);

  return { publicKey, signature, hashData, msgBytes };
}

// ── Main ───────────────────────────────────────────────────────────────────────
async function main() {
  if (!REGISTRY_ADDR || !LEDGER_ADDR) {
    throw new Error(
      "Set VALIDATOR_REGISTRY_ADDRESS and CHRYSALIS_LEDGER_ADDRESS in .env (run deploy.js first)."
    );
  }

  const [deployer, validatorSigner] = await ethers.getSigners();
  console.log("Deployer  :", deployer.address);
  console.log("Validator :", validatorSigner.address);
  console.log();

  const registry = await ethers.getContractAt("ValidatorRegistry", REGISTRY_ADDR);
  const ledger   = await ethers.getContractAt("ChrysalisLedger",   LEDGER_ADDR);

  // ── 1. Confirm validator status ───────────────────────────────────────────
  const isVal = await registry.isValidator(validatorSigner.address);
  console.log(`isValidator(${validatorSigner.address}) =`, isVal);
  if (!isVal) throw new Error("Validator not registered — run deploy.js first.");

  // ── 2. Build sample data payload and sign with ML-DSA ────────────────────
  const recordIds = [
    ethers.id("record-001"),
    ethers.id("record-002"),
    ethers.id("record-003"),
  ];
  const checkpointId = ethers.id("checkpoint-block-100");
  const popId        = "POP-REGION-A-2025";
  const region       = 1;
  const recordType   = 2;
  const timestamp    = BigInt(Math.floor(Date.now() / 1000));

  // The payload that gets ML-DSA signed — represents the batch metadata
  const samplePayload = {
    recordIds: recordIds.map((id) => id),
    checkpointId,
    popId,
    region,
    recordType,
    timestamp: timestamp.toString(),
  };

  console.log("─── ML-DSA (FIPS 204 / Dilithium) ───────────────────────────────");
  console.log("Signing payload with ML-DSA-65...");
  const { publicKey, signature, hashData, msgBytes } = await buildMlDsaProof(samplePayload);

  console.log("Algorithm  : ML-DSA-65 (CRYSTALS-Dilithium, security level 3)");
  console.log("Public key : " + Buffer.from(publicKey).toString("hex").slice(0, 48) + "...");
  console.log("Sig size   :", signature.length, "bytes (stored off-chain)");
  console.log("Payload    :", msgBytes.length, "bytes");
  console.log("hashData   :", hashData, "(keccak256 of ML-DSA-signed payload → on-chain)");
  console.log("Sig valid  : true");
  console.log();

  // ── 3. Index batch — pass hashData on-chain ───────────────────────────────
  console.log("─── indexBatch ───────────────────────────────────────────────────");
  const ledgerAsValidator = ledger.connect(validatorSigner);
  const tx = await ledgerAsValidator.indexBatch(
    recordIds, checkpointId, popId, region, recordType, timestamp, hashData
  );
  const receipt = await tx.wait();
  console.log("tx hash    :", tx.hash);
  console.log("gas used   :", receipt.gasUsed.toString());
  console.log("events     :", receipt.logs.length, "(RecordIndexed ×", recordIds.length, ")");
  console.log();

  // ── 4. Read back anchor for record-001 ───────────────────────────────────
  console.log("─── getAnchor(record-001) ────────────────────────────────────────");
  const anchor = await ledger.getAnchor(ethers.id("record-001"));
  console.log("checkpointId :", anchor.checkpointId);
  console.log("popId        :", anchor.popId);
  console.log("region       :", anchor.region.toString());
  console.log("recordType   :", anchor.recordType.toString());
  console.log("timestamp    :", anchor.timestamp.toString());
  console.log("hashData     :", anchor.hashData, "← ML-DSA payload commitment");
  console.log("exists       :", anchor.exists);
  console.log();

  // ── 5. Off-chain ML-DSA verification (audit path) ─────────────────────────
  console.log("─── Off-chain audit verification ─────────────────────────────────");
  const { ml_dsa65 } = await import("@noble/post-quantum/ml-dsa");
  const onChainHash   = anchor.hashData;
  const recomputedHash = ethers.keccak256(msgBytes);
  const hashMatch      = onChainHash === recomputedHash;
  const sigVerified    = ml_dsa65.verify(publicKey, msgBytes, signature);
  console.log("on-chain hash matches recomputed :", hashMatch);
  console.log("ML-DSA signature still valid     :", sigVerified);
  console.log();

  // ── 6. Idempotency check ──────────────────────────────────────────────────
  console.log("─── Idempotency (re-index same IDs) ─────────────────────────────");
  const tx2 = await ledgerAsValidator.indexBatch(
    recordIds, checkpointId, popId, region, recordType, timestamp, hashData
  );
  const receipt2 = await tx2.wait();
  console.log("tx hash  :", tx2.hash);
  console.log("events   :", receipt2.logs.length, "(should be 0 — all already indexed)");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
