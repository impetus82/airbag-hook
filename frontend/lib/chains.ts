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
  /// viem resolves Multicall3 from the chain definition rather than assuming the canonical
  /// deployment, and `base` arrives from wagmi/chains already carrying it. Declaring it puts
  /// Unichain on the same footing, so any read of two or more values can aggregate here too. The
  /// contract is deployed at the canonical address and its `aggregate3` was checked by hand
  /// against this pool before the line was written.
  contracts: {
    multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" },
  },
});

export { base };
