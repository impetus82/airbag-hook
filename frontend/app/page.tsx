"use client";

import { useState } from "react";
import { useAccount, useConnect, useDisconnect } from "wagmi";
import { base } from "@/lib/chains";
import { DEPLOYMENTS, SUPPORTED_CHAINS, SupportedChainId } from "@/lib/contracts";
import { PoolPanel } from "@/components/PoolPanel";
import { CreateOrder } from "@/components/CreateOrder";
import { MyOrders } from "@/components/MyOrders";

export default function Page() {
  const [chainId, setChainId] = useState<SupportedChainId>(base.id);
  const { address } = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();

  return (
    <div className="shell">
      <div className="topbar">
        <div className="brand">
          <h1>Airbag</h1>
          <span>impact protection for limit orders</span>
        </div>

        <div style={{ display: "flex", gap: 10, alignItems: "center" }}>
          <div className="chainpick">
            {SUPPORTED_CHAINS.map((id) => (
              <button key={id} data-on={chainId === id} onClick={() => setChainId(id)}>
                {DEPLOYMENTS[id].label}
              </button>
            ))}
          </div>
          {address ? (
            <button className="btn ghost" onClick={() => disconnect()}>
              {address.slice(0, 6)}…{address.slice(-4)}
            </button>
          ) : (
            <button className="btn" onClick={() => connect({ connector: connectors[0] })}>
              Connect
            </button>
          )}
        </div>
      </div>

      <div className="grid two">
        <div className="grid">
          <PoolPanel chainId={chainId} />
          <MyOrders chainId={chainId} />
        </div>
        <CreateOrder chainId={chainId} />
      </div>

      <footer>
        A hackathon deployment on dust-seeded pools, from an immutable permissionless contract with
        three audit findings deliberately left open and written down. Read{" "}
        <a href="https://github.com/impetus82/airbag-hook/blob/main/docs/KNOWN-LIMITS.md" target="_blank" rel="noreferrer">
          the known limits
        </a>{" "}
        before putting anything you care about behind it. ·{" "}
        <a href="https://github.com/impetus82/airbag-hook" target="_blank" rel="noreferrer">source</a>
      </footer>
    </div>
  );
}
