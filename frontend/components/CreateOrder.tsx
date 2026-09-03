"use client";

import { useMemo, useState } from "react";
import { useAccount, useReadContracts, useSwitchChain, useWriteContract } from "wagmi";
import { airbagAbi } from "@/lib/abi";
import { DEPLOYMENTS, SupportedChainId, alignTick, erc20Abi, stateViewAbi, tickToPrice } from "@/lib/contracts";

export function CreateOrder({ chainId }: { chainId: SupportedChainId }) {
  const d = DEPLOYMENTS[chainId];
  const { address, chainId: connected } = useAccount();
  const { writeContract, isPending } = useWriteContract();
  const { switchChain, isPending: isSwitching } = useSwitchChain();

  const [side, setSide] = useState<"above" | "below">("above");
  const [offset, setOffset] = useState("10");
  const [size, setSize] = useState("");

  const { data } = useReadContracts({
    contracts: [
      { chainId, address: d.stateView as `0x${string}`, abi: stateViewAbi, functionName: "getSlot0", args: [d.poolId as `0x${string}`] },
      { chainId, address: d.stateView as `0x${string}`, abi: stateViewAbi, functionName: "getLiquidity", args: [d.poolId as `0x${string}`] },
    ],
    query: { refetchInterval: 12_000 },
  });

  const tick = (data?.[0]?.result as readonly [bigint, number, number, number] | undefined)?.[1];
  const poolLiq = data?.[1]?.result as bigint | undefined;

  // Order size is bounded by pool depth, not chosen freely: at least 1bp of it so dust cannot
  // starve the fill budget, at most 1% so a position cannot move the price it is measured against.
  const bounds = useMemo(() => {
    if (poolLiq === undefined) return undefined;
    return { min: poolLiq / 10_000n, max: poolLiq / 100n };
  }, [poolLiq]);

  const target = useMemo(() => {
    if (tick === undefined) return undefined;
    const n = Number(offset);
    if (!Number.isFinite(n) || n <= 0) return undefined;
    const base = alignTick(tick, d.tickSpacing);
    return side === "above" ? base + n * d.tickSpacing : base - n * d.tickSpacing;
  }, [tick, offset, side, d.tickSpacing]);

  const wethIsZero = d.currency0.symbol === "WETH";
  const targetPrice = useMemo(() => {
    if (target === undefined) return undefined;
    const raw = tickToPrice(target, d.currency0.decimals, d.currency1.decimals);
    return wethIsZero ? raw : 1 / raw;
  }, [target, d, wethIsZero]);

  // Which token funds the order follows from which side of the market it rests on — the contract
  // derives it the same way rather than trusting a flag.
  const funding = side === "above" ? d.currency0 : d.currency1;

  const sizeBn = useMemo(() => {
    try { return size ? BigInt(size) : undefined; } catch { return undefined; }
  }, [size]);

  const sizeError =
    sizeBn === undefined || bounds === undefined
      ? undefined
      : sizeBn < bounds.min
        ? `Too small — the floor is ${bounds.min.toString()}`
        : sizeBn > bounds.max
          ? `Too large — the ceiling is ${bounds.max.toString()}`
          : undefined;

  const wrongChain = connected !== undefined && connected !== chainId;
  const ready = !!address && !wrongChain && target !== undefined && sizeBn !== undefined && !sizeError;

  const poolKey = {
    currency0: d.currency0.address as `0x${string}`,
    currency1: d.currency1.address as `0x${string}`,
    fee: d.fee,
    tickSpacing: d.tickSpacing,
    hooks: d.hook as `0x${string}`,
  };

  return (
    <div className="card">
      <div className="eyebrow">Place</div>
      <h2>New limit order</h2>
      <p className="sub">Rests as one tick-spacing of liquidity. The market fills it; the hook watches how far past you it went.</p>

      <div className="field">
        <label>Side</label>
        <div className="side">
          <button data-on={side === "above"} onClick={() => setSide("above")}>
            Sell {d.currency0.symbol} above
          </button>
          <button data-on={side === "below"} onClick={() => setSide("below")}>
            Sell {d.currency1.symbol} below
          </button>
        </div>
      </div>

      <div className="field">
        <label>Distance from the market, in tick spacings</label>
        <div className="row">
          <input value={offset} onChange={(e) => setOffset(e.target.value)} inputMode="numeric" />
        </div>
        <div className="hint">
          {target !== undefined
            ? `Tick ${target} · about ${targetPrice?.toFixed(2)} USDC per WETH · funded with ${funding.symbol}`
            : "Reading the pool…"}
        </div>
      </div>

      <div className="field">
        <label>Size, in liquidity units</label>
        <div className="row">
          <input value={size} onChange={(e) => setSize(e.target.value)} placeholder={bounds ? bounds.min.toString() : "…"} inputMode="numeric" />
          <button className="btn ghost" onClick={() => bounds && setSize(bounds.min.toString())} disabled={!bounds}>
            Min
          </button>
        </div>
        <div className={`hint${sizeError ? " warn" : ""}`}>
          {sizeError ??
            (bounds
              ? `Between ${bounds.min.toString()} and ${bounds.max.toString()} — 1bp to 1% of pool depth`
              : "Reading the pool…")}
        </div>
      </div>

      <div style={{ display: "flex", gap: 8 }}>
        <button
          className="btn ghost"
          disabled={!address}
          onClick={() =>
            writeContract({
              chainId,
              address: funding.address as `0x${string}`,
              abi: erc20Abi,
              functionName: "approve",
              args: [d.hook as `0x${string}`, 2n ** 255n],
            })
          }
        >
          Approve {funding.symbol}
        </button>
        <button
          className="btn"
          disabled={!ready || isPending}
          onClick={() =>
            writeContract({
              chainId,
              address: d.hook as `0x${string}`,
              abi: airbagAbi,
              functionName: "createOrder",
              args: [poolKey, target!, sizeBn!],
            })
          }
        >
          {isPending ? "Confirming…" : "Place order"}
        </button>
      </div>

      {!address && <div className="hint" style={{ marginTop: 10 }}>Connect a wallet to place an order.</div>}
      {/* Telling someone to switch networks without offering the switch is a dead end: the wallet
          holds the only button that can do it, and most people will read this as "broken" and
          leave. wagmi asks the wallet directly, so it is one click from here. */}
      {wrongChain && (
        <div className="hint warn" style={{ marginTop: 10, display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap" }}>
          <span>Your wallet is on another network.</span>
          <button
            className="btn ghost"
            style={{ padding: "6px 12px" }}
            disabled={isSwitching}
            onClick={() => switchChain({ chainId })}
          >
            {isSwitching ? "Switching…" : `Switch to ${d.label}`}
          </button>
        </div>
      )}
    </div>
  );
}
