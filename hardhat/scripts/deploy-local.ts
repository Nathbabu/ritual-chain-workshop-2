/**
 * Deploy RitualPredict to the built-in Hardhat local node (edr-simulated).
 * Produces a real contract address and deploy tx hash for the Proof of Building form.
 *
 * Run with:
 *   npx hardhat run scripts/deploy-local.ts
 *
 * No private key or live RPC required. Everything runs against the built-in Hardhat
 * node. The canonical Ritual system contract addresses are stubbed with mocks so the
 * RitualPredict constructor (which calls Scheduler.approveScheduler) succeeds.
 */

import { network } from "hardhat";

const BLOCK_TIME_MS = 200n;

const CANONICAL: Record<string, `0x${string}`> = {
  scheduler:      "0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B",
  ritualWallet:   "0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948",
  teeRegistry:    "0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F",
  httpPrecompile: "0x0000000000000000000000000000000000000801",
  jqPrecompile:   "0x0000000000000000000000000000000000000803",
};

const connection   = await network.create({ network: "hardhatMainnet", chainType: "l1" });
const viem         = connection.viem;
const publicClient = await viem.getPublicClient();
const [wallet]     = await viem.getWalletClients();

console.log("── Deploying mocks at canonical Ritual addresses ──────────");

const MockScheduler = await viem.deployContract("MockScheduler");
const MockWallet    = await viem.deployContract("MockRitualWallet");
const MockTEEReg    = await viem.deployContract("MockTEEServiceRegistry");
const MockHttp      = await viem.deployContract("MockHttpPrecompile");
const MockJq        = await viem.deployContract("MockJqPrecompile");

const mockAddrs: Record<string, `0x${string}`> = {
  scheduler:      MockScheduler.address,
  ritualWallet:   MockWallet.address,
  teeRegistry:    MockTEEReg.address,
  httpPrecompile: MockHttp.address,
  jqPrecompile:   MockJq.address,
};

for (const [key, canonical] of Object.entries(CANONICAL)) {
  const code = await publicClient.getBytecode({ address: mockAddrs[key] });
  await connection.provider.request({
    method: "hardhat_setCode",
    params:  [canonical, code ?? "0x"],
  });
  console.log(`  ${key.padEnd(16)} → ${canonical}`);
}

console.log("\n── Deploying RitualPredict ─────────────────────────────────");

import hre from "hardhat";
const artifact = await hre.artifacts.readArtifact("RitualPredict");

const deployHash = await wallet.deployContract({
  abi:      artifact.abi,
  bytecode: artifact.bytecode as `0x${string}`,
  args:     [BLOCK_TIME_MS],
});

const receipt = await publicClient.waitForTransactionReceipt({ hash: deployHash });

console.log(`\nContract address : ${receipt.contractAddress}`);
console.log(`Deploy tx hash   : ${deployHash}`);
console.log(`Block number     : ${receipt.blockNumber}`);
console.log(`Gas used         : ${receipt.gasUsed}`);
console.log("\nLocal deployment complete.");
