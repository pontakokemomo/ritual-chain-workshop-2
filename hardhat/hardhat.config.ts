import hardhatToolboxViemPlugin from "@nomicfoundation/hardhat-toolbox-viem";
import { configVariable, defineConfig } from "hardhat/config";

// Node 20+ reads a .env file with no extra dependency. A missing file is fine:
// the values below fall back to real environment variables and public defaults.
// (This call was present until commit 6e93b08 removed it, which left
// .env.example's "loaded automatically by hardhat.config.ts" note inaccurate.)
try {
  process.loadEnvFile();
} catch {
  // no .env file
}

export default defineConfig({
  plugins: [hardhatToolboxViemPlugin],
  solidity: {
    profiles: {
      default: {
        version: "0.8.28",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
      production: {
        version: "0.8.28",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
    },
  },
  networks: {
    hardhatMainnet: {
      type: "edr-simulated",
      chainType: "l1",
    },
    // A real node started with `npx hardhat node`. The end-to-end tests are pointed
    // at it through the E2E_NETWORK environment variable, which is set per shell:
    //   bash        E2E_NETWORK=localhost npx hardhat test nodejs
    //   PowerShell  $env:E2E_NETWORK="localhost"; npx hardhat test nodejs
    localhost: {
      type: "http",
      chainType: "l1",
      url: process.env.LOCALHOST_RPC_URL ?? "http://127.0.0.1:8545",
    },
    // Ritual Chain testnet. Requires EIP-1559 (type-2) transactions; viem sends
    // those by default.
    ritual: {
      type: "http",
      chainType: "l1",
      chainId: 1979,
      url: process.env.RITUAL_RPC_URL ?? "https://rpc.ritualfoundation.org",
      accounts: [configVariable("RITUAL_PRIVATE_KEY")],
    },
  },
});
