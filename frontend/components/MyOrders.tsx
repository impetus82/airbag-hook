"use client";

import { useMemo } from "react";
import { useAccount, useReadContract, useReadContracts, useWriteContract } from "wagmi";
import { airbagAbi } from "@/lib/abi";
import { DEPLOYMENTS, SupportedChainId, tickToPrice } from "@/lib/contracts";

type Order = {
  poolId: `0x${string}`; tickLower: number; tickSpacing: number; zeroForOne: boolean;
  liquidity: bigint; rebate0: bigint; rebate1: bigint; owed0: bigint; owed1: bigint;
  filled: boolean; tickIndex: number; paidDisplacement: number; filledBlock: bigint;
};

function fmt(v: bigint, decimals: number, places = 6): string {
  const s = v.toString().padStart(decimals + 1, "0");
  const whole = s.slice(0, s.length - decimals);
  const frac = s.slice(s.length - decimals).slice(0, places).replace(/0+$/, "");
  return frac ? `${whole}.${frac}` : whole;
}

export function MyOrders({ chainId }: { chainId: SupportedChainId }) {
  const d = DEPLOYMENTS[chainId];
  const { address } = useAccount();
  const { writeContract, isPending } = useWriteContract();

  const { data: nextId } = useReadContract({
    chainId, address: d.hook as `0x${string}`, abi: airbagAbi,
    functionName: "nextOrderId", query: { refetchInterval: 12_000 },
  });

  // No indexer and no subgraph: walk the ids the contract has minted and keep the ones this
  // wallet owns. Fine at demo scale, and it keeps the page honest about having no backend.
  const ids = useMemo(() => {
    const n = nextId ? Number(nextId as bigint) : 1;
    return Array.from({ length: Math.max(0, n - 1) }, (_, i) => BigInt(i + 1));
  }, [nextId]);

  const { data: owners } = useReadContracts({
    contracts: ids.map((id) => ({
      chainId, address: d.hook as `0x${string}`, abi: airbagAbi, functionName: "ownerOf" as const, args: [id],
    })),
    query: { enabled: ids.length > 0, refetchInterval: 12_000 },
  });

  const mine = useMemo(() => {
    if (!owners || !address) return [];
    return ids.filter((_, i) => {
      const o = owners[i];
      return o?.status === "success" && (o.result as string)?.toLowerCase() === address.toLowerCase();
    });
  }, [owners, ids, address]);

  const { data: details } = useReadContracts({
    contracts: mine.map((id) => ({
      chainId, address: d.hook as `0x${string}`, abi: airbagAbi, functionName: "orderOf" as const, args: [id],
    })),
    query: { enabled: mine.length > 0, refetchInterval: 12_000 },
  });

  const poolKey = {
    currency0: d.currency0.address as `0x${string}`,
    currency1: d.currency1.address as `0x${string}`,
    fee: d.fee, tickSpacing: d.tickSpacing, hooks: d.hook as `0x${string}`,
  };
  const wethIsZero = d.currency0.symbol === "WETH";

  if (!address) {
    return (
      <div className="card">
        <div className="eyebrow">Yours</div>
        <h2>Your orders</h2>
        <div className="empty">Connect a wallet to see your orders.</div>
      </div>
    );
  }

  return (
    <div className="card">
      <div className="eyebrow">Yours</div>
      <h2>Your orders</h2>
      <p className="sub">Each one is an ERC-721 — which is what lets the rebate have a specific recipient.</p>

      {mine.length === 0 ? (
        <div className="empty">Nothing resting yet.</div>
      ) : (
        <div className="orders">
          {mine.map((id, i) => {
            const o = details?.[i]?.result as unknown as Order | undefined;
            if (!o) return null;
            const raw = tickToPrice(o.tickLower, d.currency0.decimals, d.currency1.decimals);
            const px = wethIsZero ? raw : 1 / raw;
            const rebate = o.rebate0 + o.rebate1;
            const paid = rebate > 0n;
            const rebateCcy = o.rebate0 > 0n ? d.currency0 : d.currency1;

            return (
              <div className="order" key={id.toString()}>
                <div className="meta">
                  <span className="id mono">#{id.toString()} · tick {o.tickLower}</span>
                  <span className="px num">{px.toFixed(2)} USDC / WETH</span>
                  {paid && (
                    <span className="id mono" style={{ color: "var(--accent)" }}>
                      airbag paid {fmt(rebate, rebateCcy.decimals)} {rebateCcy.symbol}
                    </span>
                  )}
                </div>
                <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
                  <span className={`pill ${paid ? "paid" : o.filled ? "filled" : "waiting"}`}>
                    {paid ? "deployed" : o.filled ? "filled" : "waiting"}
                  </span>
                  <button
                    className="btn ghost"
                    disabled={isPending}
                    onClick={() =>
                      writeContract({
                        chainId, address: d.hook as `0x${string}`, abi: airbagAbi,
                        functionName: o.filled ? "claimOrder" : "cancelOrder",
                        args: [id, poolKey],
                      })
                    }
                  >
                    {o.filled ? "Claim" : "Cancel"}
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
