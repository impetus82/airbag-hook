"use client";

import { WagmiProvider, createConfig, http } from "wagmi";
import { base, unichain } from "@/lib/chains";
import { injected } from "wagmi/connectors";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { ReactNode, useState } from "react";

const config = createConfig({
  chains: [base, unichain],
  connectors: [injected()],
  transports: {
    [base.id]: http("https://mainnet.base.org"),
    [unichain.id]: http("https://mainnet.unichain.org"),
  },
  /// Reads go one call at a time rather than through Multicall3.
  ///
  /// `useReadContracts` sends a plain eth_call when handed a single contract and aggregates
  /// through Multicall3 from two upwards. That is exactly the split observed here: `ownerOf` —
  /// one read — worked on Unichain, while the pool panel and the order form, two reads each,
  /// showed em-dashes forever. No thrown error, no console warning, and no request on the wire at
  /// all; the aggregated path gives up before it reaches the transport.
  ///
  /// Declaring multicall3 in the chain definition was missing and genuinely belongs there, but on
  /// its own it did not bring the request back — verified against the deployed bundle. Rather than
  /// keep guessing at viem's internals a week before submission, the batch is off: every read is
  /// a call shape proven to work on both chains. Two pools of dust do not need the saved round
  /// trips.
  batch: { multicall: false },
  ssr: true,
});

export function Providers({ children }: { children: ReactNode }) {
  const [qc] = useState(() => new QueryClient());
  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={qc}>{children}</QueryClientProvider>
    </WagmiProvider>
  );
}
