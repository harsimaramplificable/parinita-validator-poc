const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const [deployer, validatorAccount] = await ethers.getSigners();

  console.log("Deployer   :", deployer.address);
  console.log("Validator  :", validatorAccount.address);
  console.log("Balance    :", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH");
  console.log("Chain ID   :", (await ethers.provider.getNetwork()).chainId.toString());
  console.log();

  // 1. Deploy ValidatorRegistry
  console.log("Deploying ValidatorRegistry...");
  const ValidatorRegistry = await ethers.getContractFactory("ValidatorRegistry");
  const registry = await ValidatorRegistry.deploy();
  await registry.waitForDeployment();
  const registryAddress = await registry.getAddress();
  console.log("ValidatorRegistry deployed to:", registryAddress);

  // 2. Register the validator account in the registry
  console.log("\nRegistering validator:", validatorAccount.address);
  const addTx = await registry.addValidator(validatorAccount.address);
  await addTx.wait();
  console.log("Validator registered. tx:", addTx.hash);

  // 3. Deploy ChrysalisLedger pointing at the registry
  console.log("\nDeploying ChrysalisLedger...");
  const ChrysalisLedger = await ethers.getContractFactory("ChrysalisLedger");
  const ledger = await ChrysalisLedger.deploy(registryAddress);
  await ledger.waitForDeployment();
  const ledgerAddress = await ledger.getAddress();
  console.log("ChrysalisLedger deployed to:", ledgerAddress);

  // 4. Persist addresses to .env for the interact script
  const envPath = path.join(__dirname, "../.env");
  let envContent = fs.readFileSync(envPath, "utf8");
  envContent = envContent
    .replace(/^VALIDATOR_REGISTRY_ADDRESS=.*/m, `VALIDATOR_REGISTRY_ADDRESS=${registryAddress}`)
    .replace(/^CHRYSALIS_LEDGER_ADDRESS=.*/m, `CHRYSALIS_LEDGER_ADDRESS=${ledgerAddress}`);
  fs.writeFileSync(envPath, envContent);

  console.log("\n.env updated with contract addresses.");
  console.log("\n─── Deployment summary ──────────────────────────────");
  console.log("ValidatorRegistry :", registryAddress);
  console.log("ChrysalisLedger   :", ledgerAddress);
  console.log("Validator account :", validatorAccount.address);
  console.log("─────────────────────────────────────────────────────");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
