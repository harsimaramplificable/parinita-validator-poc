require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

const DEPLOYER_KEY = process.env.DEPLOYER_PRIVATE_KEY || "8f2a55949038a9610f50fb23b5883af3b4ecb3c3bb792cbcefbd1542c692be63";
const VALIDATOR_KEY = process.env.VALIDATOR_PRIVATE_KEY || "c87509a1c067bbde78beb793e6fa76530b6382a4c0241e5e4a9ec0a0f44dc0d3";

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: { enabled: true, runs: 200 },
    },
  },
  networks: {
    // Local Hardhat network (for testing)
    hardhat: {
      chainId: 1337,
    },
    // Besu QBFT network (Docker, validator-1 RPC)
    besu: {
      url: process.env.BESU_RPC_URL || "http://localhost:8545",
      chainId: 1337,
      accounts: [DEPLOYER_KEY, VALIDATOR_KEY],
      // Besu with Berlin hardfork does not support EIP-1559; use legacy gas pricing
      gasPrice: 0,  // Besu dev networks accept 0 gasPrice
      gas: 6000000,
    },
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },
};
