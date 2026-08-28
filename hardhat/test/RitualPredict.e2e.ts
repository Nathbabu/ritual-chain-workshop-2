/**
 * RitualPredict end-to-end tests against a local Hardhat node.
 *
 * These two walkthroughs cover the full market lifecycle:
 *   1. Happy path: market created, bet placed, scheduler resolves, winner claims.
 *   2. Exhaustion path: oracle fails 3 times, market invalidated, bettor refunds.
 *
 * Mocks are deployed at the canonical Ritual Chain addresses using hardhat_setCode
 * so the contract's own imports are satisfied without any changes to the contract.
 *
 * Run with: npx hardhat test
 */

import hre from "hardhat";
import { parseEther, getAddress } from "viem";
import { expect } from "chai";

// ─── Helpers ────────────────────────────────────────────────────────────────

const BLOCK_TIME_MS = 200n;

const CANONICAL = {
  scheduler:       "0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B",
  ritualWallet:    "0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948",
  teeRegistry:     "0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F",
  httpPrecompile:  "0x0000000000000000000000000000000000000801",
  jqPrecompile:    "0x0000000000000000000000000000000000000803",
} as const;

// Packs a uint256 into a 32-byte big-endian hex string.
function encodeUint256(v: bigint): `0x${string}` {
  return `0x${v.toString(16).padStart(64, "0")}`;
}

/** ABI-encode the short-running-async HTTP envelope the precompile returns. */
function encodeHttpEnvelope(status: number, body: string): `0x${string}` {
  const viem = hre.viem;
  // actualOutput = abi.encode(uint16 status, string[], string[], bytes body, string errorMsg)
  const actualOutput = viem.encodeAbiParameters(
    [
      { type: "uint16"   },
      { type: "string[]" },
      { type: "string[]" },
      { type: "bytes"    },
      { type: "string"   },
    ],
    [status, [], [], Buffer.from(body), ""]
  );
  // full envelope = abi.encode(bytes simmedInput, bytes actualOutput)
  return viem.encodeAbiParameters(
    [{ type: "bytes" }, { type: "bytes" }],
    ["0x", actualOutput]
  );
}

describe("RitualPredict — E2E lifecycle", function () {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let predict: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let viem: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let publicClient: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let [owner, alice, bob]: any[] = [];
  let schedulerAddress: `0x${string}`;

  before(async function () {
    this.timeout(120_000);

    viem = hre.viem;
    const wallets = await viem.getWalletClients();
    [owner, alice, bob] = wallets;
    publicClient = await viem.getPublicClient();

    // ── Deploy mock contracts and etch their bytecode at canonical addresses ──

    const MockScheduler       = await viem.deployContract("MockScheduler");
    const MockRitualWallet    = await viem.deployContract("MockRitualWallet");
    const MockTEERegistry     = await viem.deployContract("MockTEEServiceRegistry");
    const MockHttp            = await viem.deployContract("MockHttpPrecompile");
    const MockJq              = await viem.deployContract("MockJqPrecompile");

    for (const [canonical, deployed] of [
      [CANONICAL.scheduler,      MockScheduler.address],
      [CANONICAL.ritualWallet,   MockRitualWallet.address],
      [CANONICAL.teeRegistry,    MockTEERegistry.address],
      [CANONICAL.httpPrecompile, MockHttp.address],
      [CANONICAL.jqPrecompile,   MockJq.address],
    ] as [`0x${string}`, `0x${string}`][]) {
      const code = await publicClient.getBytecode({ address: deployed });
      await hre.network.provider.send("hardhat_setCode", [canonical, code]);
    }

    schedulerAddress = getAddress(CANONICAL.scheduler);

    // Configure executor in registry.
    await publicClient.readContract({
      address: getAddress(CANONICAL.teeRegistry),
      abi: [{ name: "setExecutor", type: "function", inputs: [{ type: "address" }, { type: "bool" }], outputs: [] }],
      functionName: "setExecutor",
    });
    // Call setExecutor directly via a wallet write.
    const teeRegistryWrite = await viem.getContractAt("MockTEEServiceRegistry", getAddress(CANONICAL.teeRegistry));
    await teeRegistryWrite.write.setExecutor([alice.account.address, true]);

    // ── Deploy RitualPredict ──────────────────────────────────────────────────
    predict = await viem.deployContract("RitualPredict", [BLOCK_TIME_MS]);
  });

  // ─── Test 1: Happy path ─────────────────────────────────────────────────────
  it("creates a market, resolves via scheduler callback, winner claims payout", async function () {
    this.timeout(60_000);

    // Create market.
    const createTx = await predict.write.createMarket([{
      question:            "Will ETH/USD be >= $4000?",
      oracleUrl:           "https://oracle.example.com/eth",
      jsonPath:            ".price",
      target:              4000n,
      comparator:          1n, // GTE
      bettingSeconds:      60n,
      resolveDelaySeconds: 30n,
    }]);
    await publicClient.waitForTransactionReceipt({ hash: createTx });
    const marketId = 1n;

    // Both sides bet.
    const predictAlice = await viem.getContractAt("RitualPredict", predict.address, { client: { wallet: alice } });
    const predictBob   = await viem.getContractAt("RitualPredict", predict.address, { client: { wallet: bob   } });

    await (await predictAlice.write.bet([marketId, true],  { value: parseEther("1") }));
    await (await predictBob.write.bet([marketId, false], { value: parseEther("1") }));

    // Configure oracle mock to return ETH price = 4500 (YES wins).
    const envelope = encodeHttpEnvelope(200, '{"price":4500}');
    const mockHttp = await viem.getContractAt("MockHttpPrecompile", getAddress(CANONICAL.httpPrecompile));
    const mockJq   = await viem.getContractAt("MockJqPrecompile",   getAddress(CANONICAL.jqPrecompile));
    await mockHttp.write.setResponse([200n, Buffer.from('{"price":4500}'), ""]);
    await mockJq.write.setValue([4500n]);

    // Impersonate Scheduler and call onScheduledResolve.
    await hre.network.provider.send("hardhat_impersonateAccount", [schedulerAddress]);
    await hre.network.provider.send("hardhat_setBalance", [schedulerAddress, encodeUint256(parseEther("10"))]);

    const predictScheduler = await viem.getContractAt("RitualPredict", predict.address, {
      client: { wallet: await viem.getWalletClient(schedulerAddress) }
    });
    const resolveTx = await predictScheduler.write.onScheduledResolve([0n, marketId]);
    await publicClient.waitForTransactionReceipt({ hash: resolveTx });

    await hre.network.provider.send("hardhat_stopImpersonatingAccount", [schedulerAddress]);

    // Market should be resolved, YES outcome.
    const market = await predict.read.getMarket([marketId]);
    expect(Number(market.state)).to.equal(3); // Resolved
    expect(Number(market.outcome)).to.equal(1); // Yes
    expect(market.observedValue).to.equal(4500n);

    // Alice (YES bettor) should receive full pool = 2 ETH.
    const balBefore = await publicClient.getBalance({ address: alice.account.address });
    const claimTx = await predictAlice.write.claimWinnings([marketId]);
    const receipt = await publicClient.waitForTransactionReceipt({ hash: claimTx });
    const gasCost = receipt.gasUsed * receipt.effectiveGasPrice;
    const balAfter = await publicClient.getBalance({ address: alice.account.address });

    expect(balAfter - balBefore + gasCost).to.equal(parseEther("2"));
  });

  // ─── Test 2: Exhaustion → Invalid → Refund ──────────────────────────────────
  it("invalidates after 3 failed oracle reads, bettors claim full refunds", async function () {
    this.timeout(60_000);

    const createTx = await predict.write.createMarket([{
      question:            "Will BTC/USD be >= $100000?",
      oracleUrl:           "https://oracle.example.com/btc",
      jsonPath:            ".price",
      target:              100000n,
      comparator:          1n, // GTE
      bettingSeconds:      60n,
      resolveDelaySeconds: 30n,
    }]);
    await publicClient.waitForTransactionReceipt({ hash: createTx });
    const marketId = 2n;

    const predictAlice = await viem.getContractAt("RitualPredict", predict.address, { client: { wallet: alice } });
    const predictBob   = await viem.getContractAt("RitualPredict", predict.address, { client: { wallet: bob   } });

    await (await predictAlice.write.bet([marketId, true],  { value: parseEther("2") }));
    await (await predictBob.write.bet([marketId, false], { value: parseEther("3") }));

    // Force HTTP precompile to fail on all attempts.
    const mockHttp = await viem.getContractAt("MockHttpPrecompile", getAddress(CANONICAL.httpPrecompile));
    await mockHttp.write.setFailure();

    await hre.network.provider.send("hardhat_impersonateAccount", [schedulerAddress]);
    await hre.network.provider.send("hardhat_setBalance", [schedulerAddress, encodeUint256(parseEther("10"))]);

    const predictScheduler = await viem.getContractAt("RitualPredict", predict.address, {
      client: { wallet: await viem.getWalletClient(schedulerAddress) }
    });

    for (let i = 0; i < 3; i++) {
      const tx = await predictScheduler.write.onScheduledResolve([BigInt(i), marketId]);
      await publicClient.waitForTransactionReceipt({ hash: tx });
    }

    await hre.network.provider.send("hardhat_stopImpersonatingAccount", [schedulerAddress]);

    const market = await predict.read.getMarket([marketId]);
    expect(Number(market.state)).to.equal(4); // Invalid

    // Both bettors claim full refunds.
    const aliceBefore = await publicClient.getBalance({ address: alice.account.address });
    const aliceTx = await predictAlice.write.claimRefund([marketId]);
    const aliceReceipt = await publicClient.waitForTransactionReceipt({ hash: aliceTx });
    const aliceGas = aliceReceipt.gasUsed * aliceReceipt.effectiveGasPrice;
    const aliceAfter = await publicClient.getBalance({ address: alice.account.address });
    expect(aliceAfter - aliceBefore + aliceGas).to.equal(parseEther("2"));

    const bobBefore = await publicClient.getBalance({ address: bob.account.address });
    const bobTx = await predictBob.write.claimRefund([marketId]);
    const bobReceipt = await publicClient.waitForTransactionReceipt({ hash: bobTx });
    const bobGas = bobReceipt.gasUsed * bobReceipt.effectiveGasPrice;
    const bobAfter = await publicClient.getBalance({ address: bob.account.address });
    expect(bobAfter - bobBefore + bobGas).to.equal(parseEther("3"));
  });
});
