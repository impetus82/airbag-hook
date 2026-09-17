import { base, unichain } from "@/lib/chains";

/// Live deployments. Both verified; see docs/DEPLOYMENTS.md.
export const DEPLOYMENTS = {
  [base.id]: {
    label: "Base",
    hook: "0xf328ff41720B6778d1610BB05a6CAB43D0CE40C4",
    poolId: "0x2b6bb6900488d50e90d5ef3dfed1ff6f35205cdbcd767100dae54e8029a2b05a",
    stateView: "0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71",
    // The tokens sort differently on each chain — currency0 is WETH here, USDC on Unichain.
    currency0: { address: "0x4200000000000000000000000000000000000006", symbol: "WETH", decimals: 18 },
    currency1: { address: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", symbol: "USDC", decimals: 6 },
    fee: 500,
    tickSpacing: 10,
    explorer: "https://basescan.org",
  },
  [unichain.id]: {
    label: "Unichain",
    hook: "0xCeC392D5388BB110c4082011901BD9FEBC6f00C4",
    poolId: "0x7db1fe33b9765ff48491d1a1670ab09d343144940cb2a7806bcb20dbea812f40",
    // EIP-55 checksummed, and it has to be: viem rejects a mis-cased address before it issues any
    // request. This one was wrong in two characters, so the panel read nothing on Unichain — with
    // no error, no console warning and nothing on the wire, because a rejected address never
    // becomes a request to notice missing.
    stateView: "0x86e8631A016F9068C3f085fAF484Ee3F5fDee8f2",
    currency0: { address: "0x078D782b760474a361dDA0AF3839290b0EF57AD6", symbol: "USDC", decimals: 6 },
    currency1: { address: "0x4200000000000000000000000000000000000006", symbol: "WETH", decimals: 18 },
    fee: 500,
    tickSpacing: 10,
    explorer: "https://uniscan.xyz",
  },
} as const;

export type SupportedChainId = keyof typeof DEPLOYMENTS;
export const SUPPORTED_CHAINS = [base.id, unichain.id] as const;

export const stateViewAbi = [
  {
    type: "function",
    name: "getSlot0",
    stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [
      { name: "sqrtPriceX96", type: "uint160" },
      { name: "tick", type: "int24" },
      { name: "protocolFee", type: "uint24" },
      { name: "lpFee", type: "uint24" },
    ],
  },
  {
    type: "function",
    name: "getLiquidity",
    stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [{ name: "liquidity", type: "uint128" }],
  },
] as const;

export const erc20Abi = [
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ name: "a", type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "allowance", stateMutability: "view", inputs: [{ name: "o", type: "address" }, { name: "s", type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "approve", stateMutability: "nonpayable", inputs: [{ name: "s", type: "address" }, { name: "v", type: "uint256" }], outputs: [{ type: "bool" }] },
] as const;

/// One tick is 1.0001x, i.e. one basis point — the identity the whole hook is built on.
export function tickToPrice(tick: number, dec0: number, dec1: number): number {
  return Math.pow(1.0001, tick) * Math.pow(10, dec0 - dec1);
}

export function alignTick(tick: number, spacing: number): number {
  return Math.floor(tick / spacing) * spacing;
}
