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
