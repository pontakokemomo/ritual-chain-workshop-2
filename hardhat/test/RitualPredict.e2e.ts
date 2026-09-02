/**
 * End-to-end walkthroughs of the workshop flow.
 *
 * The Solidity tests in `contracts/RitualPredict.t.sol` cover the contract's logic from
 * the inside. These cover the same market from the *outside*: a wallet signs real
 * transactions, blocks are actually mined between them, and every read goes through the
 * ABI exactly as a frontend or a script would see it.
 *
 * Ritual's precompiles and system contracts do not exist on a local chain, so their
 * runtime code is placed at the canonical addresses with `hardhat_setCode`. That is the
 * TypeScript counterpart of `vm.etch` in the Solidity tests: nothing in `RitualPredict`
 * is modified, mocked out, or told it is being tested. It calls 0x0801, 0x0803, the
 * Scheduler and the TEEServiceRegistry by their real addresses.
 *
 * By default they run on Hardhat's in-process EVM:
 *
 *   npx hardhat test nodejs
 *
 * Setting E2E_NETWORK points them at a network from hardhat.config.ts instead. To use a
 * real local node, run `npx hardhat node` in one terminal, then in another:
 *
 *   bash        E2E_NETWORK=localhost npx hardhat test nodejs
 *   PowerShell  $env:E2E_NETWORK="localhost"; npx hardhat test nodejs
 */

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { parseEther, toHex, getAddress } from "viem";
import type { Address, Hex } from "viem";

// ── canonical Ritual Chain addresses (contracts/ritual/RitualChain.sol) ──────
const HTTP_PRECOMPILE = "0x0000000000000000000000000000000000000801" as const;
const JQ_PRECOMPILE = "0x0000000000000000000000000000000000000803" as const;
const SCHEDULER = "0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B" as const;
const RITUAL_WALLET = "0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948" as const;
const TEE_SERVICE_REGISTRY = "0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F" as const;

// ── the market under test ────────────────────────────────────────────────────
const BLOCK_TIME_MS = 195n; // measured on Ritual Chain; see scripts/block-time.ts
const ORACLE_URL = "https://oracle.example/v1/price";
const JSON_PATH = ".ethereum.usd";
const ORACLE_JSON = '{"ethereum":{"usd":4200}}';
const OBSERVED = 4200n;
const TARGET = 4000n;
const BETTING_SECONDS = 60n;
const RESOLVE_DELAY_SECONDS = 30n;

const COMPARATOR_GTE = 1;
const STATE = { Open: 0, Closed: 1, Resolving: 2, Resolved: 3, Invalid: 4 } as const;
const OUTCOME = { Unresolved: 0, Yes: 1, No: 2 } as const;
const HTTP_MODE = { Ok: 0, Unsettled: 1, Garbage: 2, NotAnEnvelope: 3, Fail: 4 } as const;

const RETRY_INTERVAL_BLOCKS = 200n;

const EXECUTOR_A = "0x00000000000000000000000000000000000000e1" as const;
const EXECUTOR_B = "0x00000000000000000000000000000000000000e2" as const;

describe("RitualPredict end to end", async () => {
  // Point at a real `npx hardhat node` with E2E_NETWORK=localhost, otherwise use
  // Hardhat's in-process EVM. Both are local: no funded account, no RPC endpoint.
  const connection = process.env.E2E_NETWORK
    ? await network.getOrCreate(process.env.E2E_NETWORK)
    : await network.create();
  const { viem, networkHelpers } = connection;

  /**
   * Deploys a mock and copies its runtime code to the address the contract under test
   * will actually call. The mocks deliberately have no constructor logic and no inline
   * initialisers, because `setCode` copies code but not storage.
   */
  async function etch(
    name: Parameters<typeof viem.deployContract>[0],
    to: Address,
  ): Promise<void> {
    const publicClient = await viem.getPublicClient();
    const testClient = await viem.getTestClient();
    const impl = await viem.deployContract(name);
    const bytecode = (await publicClient.getCode({ address: impl.address })) as Hex;
    await testClient.setCode({ address: to, bytecode });
  }

  async function deployWorld() {
    const [deployer, alice, bob, carol] = await viem.getWalletClients();

    // The Scheduler has to answer `approveScheduler` from RitualPredict's constructor,
    // so every stand-in is in place before the contract exists.
    await etch("MockScheduler", SCHEDULER);
    await etch("MockHttpPrecompile", HTTP_PRECOMPILE);
    await etch("MockJqPrecompile", JQ_PRECOMPILE);
    await etch("MockTeeServiceRegistry", TEE_SERVICE_REGISTRY);
    await etch("MockRitualWallet", RITUAL_WALLET);

    // Driven through their real addresses, fully typed against the compiled ABI.
    const scheduler = await viem.getContractAt("MockScheduler", SCHEDULER);
    const http = await viem.getContractAt("MockHttpPrecompile", HTTP_PRECOMPILE);
    const jq = await viem.getContractAt("MockJqPrecompile", JQ_PRECOMPILE);
    const registry = await viem.getContractAt("MockTeeServiceRegistry", TEE_SERVICE_REGISTRY);
    const wallet = await viem.getContractAt("MockRitualWallet", RITUAL_WALLET);

    await registry.write.addExecutor([EXECUTOR_A]);
    await registry.write.addExecutor([EXECUTOR_B]);
    await http.write.setResponse([200, toHex(ORACLE_JSON), ""]);
    await jq.write.setResult([JSON_PATH, ORACLE_JSON, OBSERVED]);

    const predict = await viem.deployContract("RitualPredict", [BLOCK_TIME_MS]);

    return { predict, scheduler, http, jq, registry, wallet, deployer, alice, bob, carol };
  }

  async function createMarket(predict: any, question = "Will ETH/USD be at least $4,000?") {
    await predict.write.createMarket([
      {
        question,
        oracleUrl: ORACLE_URL,
        jsonPath: JSON_PATH,
        target: TARGET,
        comparator: COMPARATOR_GTE,
        bettingSeconds: BETTING_SECONDS,
        resolveDelaySeconds: RESOLVE_DELAY_SECONDS,
      },
    ]);
    return predict.read.marketCount();
  }

  /** Mines until the chain has reached `target`, the way waiting would on a real chain. */
  async function mineUpTo(target: bigint) {
    const publicClient = await viem.getPublicClient();
    const now = await publicClient.getBlockNumber();
    if (target > now) await networkHelpers.mine(Number(target - now));
  }

  it("runs a market from creation to a winner being paid", async () => {
    const { predict, scheduler, deployer, alice, bob } = await deployWorld();
    const publicClient = await viem.getPublicClient();

    const id = await createMarket(predict);
    assert.equal(id, 1n, "the first market gets id 1");

    const fresh = await predict.read.getMarket([id]);
    assert.equal(fresh.state, STATE.Open, "a new market is open for betting");
    assert.equal(
      getAddress(fresh.creator),
      getAddress(deployer.account.address),
      "the account that sent the transaction is recorded as the creator",
    );
    assert.ok(fresh.closeBlock > 0n, "betting closes at a block, not at a timestamp");
    assert.ok(fresh.resolveBlock > fresh.closeBlock, "resolution comes after the close");
    assert.ok(fresh.scheduleId > 0n, "the contract booked its own wake-up call");

    // Two people stake, in separate transactions, with blocks mined between them.
    await predict.write.bet([id, true], { account: alice.account, value: parseEther("3") });
    await predict.write.bet([id, false], { account: bob.account, value: parseEther("1") });

    const staked = await predict.read.getMarket([id]);
    assert.equal(staked.totalYes, parseEther("3"));
    assert.equal(staked.totalNo, parseEther("1"));
    assert.equal(
      await publicClient.getBalance({ address: predict.address }),
      parseEther("4"),
      "the contract is holding the whole pool",
    );

    // Betting closes on its own once the block passes. Nobody sends a transaction.
    await mineUpTo(staked.closeBlock);
    assert.equal(
      (await predict.read.getMarket([id])).state,
      STATE.Closed,
      "closed by the passage of blocks alone",
    );

    // The Scheduler wakes the contract at the block fixed when the market was created.
    await mineUpTo(staked.resolveBlock);
    await scheduler.write.fire([staked.scheduleId, 0n]);

    const resolved = await predict.read.getMarket([id]);
    assert.equal(resolved.state, STATE.Resolved, "it settled itself");
    assert.equal(resolved.outcome, OUTCOME.Yes, "4200 >= 4000");
    assert.equal(resolved.observedValue, OBSERVED, "the oracle reading is recorded on-chain");
    assert.equal(resolved.attempts, 1, "one attempt was enough");

    // Winners pull their share; the loser is owed nothing.
    const [, , , aliceClaimable] = await predict.read.stakesOf([id, alice.account.address]);
    const [, , , bobClaimable] = await predict.read.stakesOf([id, bob.account.address]);
    assert.equal(aliceClaimable, parseEther("4"), "the whole pool: she was the only winner");
    assert.equal(bobClaimable, 0n, "the losing side is owed nothing");

    await viem.assertions.balancesHaveChanged(
      predict.write.claimWinnings([id], { account: alice.account }),
      [{ address: alice.account.address, amount: parseEther("4") }],
    );

    assert.equal(
      await publicClient.getBalance({ address: predict.address }),
      0n,
      "the pool is empty once the only winner has been paid",
    );

    await viem.assertions.revertWithCustomError(
      predict.write.claimWinnings([id], { account: alice.account }),
      predict,
      "AlreadySettled",
    );
    await viem.assertions.revertWithCustomError(
      predict.write.claimWinnings([id], { account: bob.account }),
      predict,
      "NothingToClaim",
    );
  });

  it("refunds everyone when the oracle cannot be read three times", async () => {
    const { predict, scheduler, http, alice, bob } = await deployWorld();
    const publicClient = await viem.getPublicClient();

    const id = await createMarket(predict, "Will the oracle answer at all?");
    await predict.write.bet([id, true], { account: alice.account, value: parseEther("2") });
    await predict.write.bet([id, false], { account: bob.account, value: parseEther("5") });

    const m = await predict.read.getMarket([id]);
    await mineUpTo(m.resolveBlock);

    // The oracle is unreachable for every one of the three booked attempts.
    await http.write.setMode([HTTP_MODE.Fail]);

    await scheduler.write.fire([m.scheduleId, 0n]);
    let after = await predict.read.getMarket([id]);
    assert.equal(after.state, STATE.Resolving, "parked, waiting for the next attempt");
    assert.equal(after.attempts, 1);

    await networkHelpers.mine(Number(RETRY_INTERVAL_BLOCKS));
    await scheduler.write.fire([m.scheduleId, 1n]);
    after = await predict.read.getMarket([id]);
    assert.equal(after.state, STATE.Resolving, "still retrying");
    assert.equal(after.attempts, 2);

    await networkHelpers.mine(Number(RETRY_INTERVAL_BLOCKS));
    await scheduler.write.fire([m.scheduleId, 2n]);
    after = await predict.read.getMarket([id]);

    assert.equal(after.state, STATE.Invalid, "three failures, so nobody wins");
    assert.equal(
      after.outcome,
      OUTCOME.Unresolved,
      "a failed read is never treated as a NO",
    );
    assert.equal(after.attempts, 3);
    assert.ok(after.invalidReason.length > 0, "and the reason is recorded on-chain");

    // Everyone takes back exactly what they staked, not a share of anything.
    await viem.assertions.balancesHaveChanged(
      predict.write.claimRefund([id], { account: alice.account }),
      [{ address: alice.account.address, amount: parseEther("2") }],
    );
    await viem.assertions.balancesHaveChanged(
      predict.write.claimRefund([id], { account: bob.account }),
      [{ address: bob.account.address, amount: parseEther("5") }],
    );
    assert.equal(
      await publicClient.getBalance({ address: predict.address }),
      0n,
      "nothing is stranded in the contract",
    );

    await viem.assertions.revertWithCustomError(
      predict.write.claimWinnings([id], { account: alice.account }),
      predict,
      "NotResolved",
    );
  });

  it("exposes every market to a frontend in one call, newest first", async () => {
    const { predict, alice } = await deployWorld();

    await createMarket(predict, "Market one");
    await createMarket(predict, "Market two");
    const third = await createMarket(predict, "Market three");

    await predict.write.bet([1n, true], { account: alice.account, value: parseEther("1") });

    const all = await predict.read.getMarkets();
    assert.equal(all.length, 3, "every market comes back in a single read");
    assert.equal(all[0].question, "Market three", "newest first, which is what a UI wants");
    assert.equal(all[2].question, "Market one");
    assert.equal(all[2].totalYes, parseEther("1"), "with live pool totals");
    assert.equal(all.map((x: any) => x.id).join(","), `${third},2,1`);

    await viem.assertions.revertWithCustomError(
      predict.read.getMarket([99n]),
      predict,
      "UnknownMarket",
    );
  });
});
