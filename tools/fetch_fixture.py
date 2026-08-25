#!/usr/bin/env python3
"""
Build the replay fixture the backtest harness runs on, straight from chain history.

WHY A FIXTURE AND NOT A FORK TEST AGAINST THE REAL POOL
------------------------------------------------------
v4 binds a hook to a PoolKey, so AirbagHook can never be attached to an existing hookless
WETH/USDC pool. The harness therefore stands up a *clone* pool with the same tick spacing and
replays this price path through it. Amounts are not replayed — only the trajectory — because the
metric under test is a tick distance, and tick distances are exactly reproducible by driving each
swap to the historical post-swap price via sqrtPriceLimitX96.

This script also prints the reference distribution the Solidity harness is cross-checked against.
Two independent implementations agreeing on the same number is the strongest correctness
argument available here; a disagreement means one of them is wrong, which is worth knowing.

    python3 tools/fetch_fixture.py --hours 48 --out fixture
    python3 tools/fetch_fixture.py --chain unichain --rpc https://your-rpc

Read-only. No keys, no signing.
"""
import argparse, json, statistics, sys, time, urllib.request

# ── keccak-256 (stdlib only; hashlib.sha3_256 is NIST SHA-3, not Keccak) ──────
_RC = [0x0000000000000001,0x0000000000008082,0x800000000000808A,0x8000000080008000,
       0x000000000000808B,0x0000000080000001,0x8000000080008081,0x8000000000008009,
       0x000000000000008A,0x0000000000000088,0x0000000080008009,0x000000008000000A,
       0x000000008000808B,0x800000000000008B,0x8000000000008089,0x8000000000008003,
       0x8000000000008002,0x8000000000000080,0x000000000000800A,0x800000008000000A,
       0x8000000080008081,0x8000000000008080,0x0000000080000001,0x8000000080008008]
_ROT = [[0,36,3,41,18],[1,44,10,45,2],[62,6,43,15,61],[28,55,25,21,56],[27,20,39,8,14]]
_M = 0xFFFFFFFFFFFFFFFF
def _rol(x,n): return ((x<<n)|(x>>(64-n))) & _M
def _f1600(A):
    for r in range(24):
        C=[A[x][0]^A[x][1]^A[x][2]^A[x][3]^A[x][4] for x in range(5)]
        D=[C[(x-1)%5]^_rol(C[(x+1)%5],1) for x in range(5)]
        for x in range(5):
            for y in range(5): A[x][y]^=D[x]
        B=[[0]*5 for _ in range(5)]
        for x in range(5):
            for y in range(5): B[y][(2*x+3*y)%5]=_rol(A[x][y],_ROT[x][y])
        for x in range(5):
            for y in range(5): A[x][y]=(B[x][y]^((B[(x+1)%5][y]^_M)&B[(x+2)%5][y]))&_M
        A[0][0]^=_RC[r]
    return A
def keccak256(msg: bytes) -> bytes:
    rate, A = 136, [[0]*5 for _ in range(5)]
    m = bytearray(msg); m.append(0x01)
    while len(m)%rate: m.append(0)
    m[-1] ^= 0x80
    for off in range(0,len(m),rate):
        blk=m[off:off+rate]
        for i in range(rate//8): A[i%5][i//5]^=int.from_bytes(blk[i*8:(i+1)*8],"little")
        _f1600(A)
    out=bytearray()
    for i in range(4): out+=A[i%5][i//5].to_bytes(8,"little")
    return bytes(out[:32])

# ── chains ───────────────────────────────────────────────────────────────────
WETH = "0x4200000000000000000000000000000000000006"
CHAINS = {
    "base":     dict(rpc="https://mainnet.base.org",
                     pm="0x498581fF718922c3f8e6A244956aF099B2652b2b",
                     usdc="0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", secs=2.0),
    "unichain": dict(rpc="https://mainnet.unichain.org",
                     pm="0x1F98400000000000000000000000000000000004",
                     usdc="0x078D782b760474a361dDA0AF3839290b0EF57AD6", secs=1.0),
}
SWAP_SIG = b"Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"
ZERO = "0x" + "00"*20

def pool_id(c0,c1,fee,spacing,hooks):
    w = lambda a: bytes(12)+bytes.fromhex(a[2:].lower())
    u = lambda v: v.to_bytes(32,"big")
    return "0x"+keccak256(w(c0)+w(c1)+u(fee)+u(spacing)+w(hooks)).hex()

def selftest():
    assert keccak256(b"").hex() == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
    # Reproduces a pool id observed on-chain, so a wrong encoding cannot pass silently.
    got = pool_id(WETH, CHAINS["base"]["usdc"], 3000, 60,
                  "0x4fB56294f7bFf30A4d85c1bA676f0CFdB24114ce")
    assert got == "0xc92fdde3c2264c8abe30cea3ee4d3ffeeef6ca009117e843158f8f8a5fe6f03e", got

_H = {"Content-Type":"application/json","Accept":"application/json",
      "User-Agent":"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                   "(KHTML, like Gecko) Chrome/125.0 Safari/537.36"}  # public RPCs 403 urllib

def rpc(url, method, params, tries=4):
    body=json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params}).encode()
    last=None
    for a in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url,data=body,headers=_H),timeout=90) as r:
                out=json.loads(r.read())
            if "error" in out: raise RuntimeError(out["error"])
            return out["result"]
        except Exception as e:
            last=e; time.sleep(1.5*(a+1))
    raise RuntimeError(f"{method}: {last}")

def get_logs(url, addr, topics, lo, hi, chunk=5000):
    logs=[]
    while lo<=hi:
        top=min(lo+chunk-1,hi)
        try:
            logs += rpc(url,"eth_getLogs",[{"address":addr,"topics":topics,
                                            "fromBlock":hex(lo),"toBlock":hex(top)}],tries=2)
        except Exception:
            if chunk<=100: raise
            chunk=max(100,chunk//2); continue
        lo=top+1
        print(f"\r  {100.0*(lo-1-hi+ (hi-lo+1))/1:.0f}  logs={len(logs)}",end="",file=sys.stderr)
    print("",file=sys.stderr)
    return logs

def signed(w):
    v=int.from_bytes(w,"big")
    return v-(1<<256) if v>=(1<<255) else v

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--chain",default="base",choices=sorted(CHAINS))
    ap.add_argument("--hours",type=float,default=48.0)
    ap.add_argument("--fee",type=int,default=500)
    ap.add_argument("--spacing",type=int,default=10)
    ap.add_argument("--rpc",default=None)
    ap.add_argument("--out",default="test/fixtures/replay")
    args=ap.parse_args()

    selftest()
    cfg=CHAINS[args.chain]; url=args.rpc or cfg["rpc"]
    c0,c1=sorted([WETH,cfg["usdc"]],key=lambda a:int(a,16))
    pid=pool_id(c0,c1,args.fee,args.spacing,ZERO)
    print(f"pool {pid}  (fee {args.fee}, spacing {args.spacing})")

    head=int(rpc(url,"eth_blockNumber",[]),16)
    lo=head-int(args.hours*3600/cfg["secs"])
    print(f"blocks {lo:,}..{head:,}")

    logs=get_logs(url,cfg["pm"],["0x"+keccak256(SWAP_SIG).hex(),pid],lo,head)
    rows=[]
    for lg in logs:
        d=bytes.fromhex(lg["data"][2:])
        rows.append((int(lg["blockNumber"],16),
                     int.from_bytes(d[64:96],"big"),   # sqrtPriceX96 after the swap
                     signed(d[128:160])))              # tick after the swap
    rows.sort(key=lambda r:r[0])

    path=f"{args.out}.{args.chain}.fee{args.fee}.csv"
    with open(path,"w") as fh:
        fh.write("block,sqrtPriceX96,tick\n")
        for b,s,t in rows: fh.write(f"{b},{s},{t}\n")
    print(f"fixture -> {path}  ({len(rows):,} rows)")

    # Reference distribution: every tickSpacing-aligned tick strictly between one swap's end and
    # the next is a maker who would have been filled; one tick is one basis point.
    fills=[]
    for i in range(1,len(rows)):
        a,b=rows[i-1][2],rows[i][2]
        if a==b: continue
        lo_t,hi_t=min(a,b),max(a,b)
        first=(lo_t//args.spacing+1)*args.spacing
        for T in range(first,hi_t,args.spacing):
            fills.append(abs(b-T))
    if fills:
        s=sorted(fills); q=lambda p:s[min(len(s)-1,int(p*(len(s)-1)))]
        tail=[f for f in fills if f>args.fee//100]
        print(f"reference: n={len(fills):,} median={statistics.median(fills):.1f}bps "
              f"p90={q(.9)} p99={q(.99)} tail>{args.fee//100}bps={100.0*len(tail)/len(fills):.1f}% "
              f"mean_tail={statistics.fmean(tail):.1f}bps" if tail else "")

if __name__=="__main__": main()
