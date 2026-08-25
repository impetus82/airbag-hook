import { defineChain } from "viem";
import { base } from "wagmi/chains";

/// Defined here rather than imported: this wagmi release does not ship Unichain yet, and pinning
/// the definition locally also means the RPC and explorer are ours rather than whatever a future
/// upgrade decides.
export const unichain = defineChain({
  id: 130,
  name: "Unichain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://mainnet.unichain.org"] } },
  blockExplorers: { default: { name: "Uniscan", url: "https://uniscan.xyz" } },
});

export { base };
