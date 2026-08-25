"use client";

import { useReadContracts } from "wagmi";
import { DEPLOYMENTS, SupportedChainId, stateViewAbi, tickToPrice } from "@/lib/contracts";

export function PoolPanel({ chainId }: { chainId: SupportedChainId }) {
  const d = DEPLOYMENTS[chainId];

  const { data } = useReadContracts({
    contracts: [
      { chainId, address: d.stateView as `0x${string}`, abi: stateViewAbi, functionName: "getSlot0", args: [d.poolId as `0x${string}`] },
      { chainId, address: d.stateView as `0x${string}`, abi: stateViewAbi, functionName: "getLiquidity", args: [d.poolId as `0x${string}`] },
    ],
    query: { refetchInterval: 12_000 },
  });

  const slot0 = data?.[0]?.result as readonly [bigint, number, number, number] | undefined;
  const liquidity = data?.[1]?.result as bigint | undefined;
  const tick = slot0?.[1];
  const lpFee = slot0?.[3];

  // WETH is currency0 on Base and currency1 on Unichain, so the raw price is inverted on one of
  // them. Always show it the way a person thinks about it: USDC per WETH.
  const wethIsZero = d.currency0.symbol === "WETH";
  const raw = tick === undefined ? undefined : tickToPrice(tick, d.currency0.decimals, d.currency1.decimals);
  const price = raw === undefined ? undefined : wethIsZero ? raw : 1 / raw;

  return (
    <div className="card">
      <div className="eyebrow">Live pool</div>
      <h2>{d.currency0.symbol} / {d.currency1.symbol} · {(d.fee / 10000).toFixed(2)}%</h2>
      <p className="sub">
        <a href={`${d.explorer}/address/${d.hook}`} target="_blank" rel="noreferrer">
          {d.hook.slice(0, 10)}…{d.hook.slice(-6)}
        </a>{" "}
        on {d.label}
      </p>

      <div className="stats">
        <div className="stat">
          <div className="k">Price</div>
          <div className="v num">{price ? price.toFixed(2) : "—"}</div>
        </div>
        <div className="stat">
          <div className="k">Tick</div>
          <div className="v num">{tick ?? "—"}</div>
        </div>
        <div className="stat">
          <div className="k">Pool fee</div>
          <div className="v num accent">{lpFee !== undefined ? `${lpFee / 100} bps` : "—"}</div>
        </div>
        <div className="stat">
          <div className="k">Liquidity</div>
          <div className="v num">{liquidity !== undefined ? Number(liquidity).toExponential(1) : "—"}</div>
        </div>
      </div>

      <p className="hint" style={{ marginTop: 14 }}>
        The pool fee is also the threshold. A fill that lands within {lpFee !== undefined ? lpFee / 100 : "—"} bps
        of your price costs the swapper nothing, because that fee already made you whole.
      </p>
    </div>
  );
}
