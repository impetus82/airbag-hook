# Ask what your harness cannot say

Three times in one project, a real bug was sitting in the one case the test suite could not
express. Not undertested — *unreachable*. And an unreachable branch does not lower a coverage
number. It hides behind one.

Their provenance is worth stating exactly, because the pattern is in it. The first was introduced by
my own fix for an earlier finding, and caught one audit round later. The second survived **both**
adversarial audit rounds and was found by a hackathon judge reading the source. The third was
introduced by my fix for the second, and caught by the detector I had just written to test that fix.

All three are in a public repository together with the tests that now reach them, so every number
below can be checked.

## 1. Half the charge surface had never been executed

The hook takes a payment out of a swap, so it has to know what that swap actually received. The
clamp bounded the charge by `received > 0`.

That reads as obviously correct, and it is — for exact-input swaps. In Uniswap v4 the *unspecified*
currency is the swap's output when the input is exact, and its **input** when the output is exact,
where the delta is always negative. So the bound evaluated to zero on 100% of exact-output swaps,
in both directions.

Measured on the same 40 bp crossing: **924,260,342,130** collected via exact input, and **exactly
zero** via exact output.

Nothing in the suite had ever passed a positive `amountSpecified`. Half the charge surface had
never once been executed — and the invariant that should have caught it had a handler with the sign
hard-coded, so the fuzzer could not produce an exact-output swap either. The detector had the same
blind spot as the tests it was supposed to backstop.

## 2. Wait one block, pay nothing

The hook revisits recently-filled makers to top up what they are owed as a move continues. The
top-up opened with:

```solidity
if (bf.blockNumber != uint64(block.number)) return 0;
```

Cross a maker by a hair in one block. Wait a single block. Push the price the rest of the way. You
pay for the sliver and nothing else.

Priced by the detector before anything was changed: **174,772,660,917 wei** for the split, against
**1,672,824,040,214** for the same distance in one swap. The maker was short **89.6%** — not a gap,
very nearly a total escape.

Why two audit rounds missed it: **no test in the suite had ever advanced the block number.**
`vm.roll` and `vm.warp` appeared nowhere across fifteen files. The branch asking whether a recorded
fill belongs to the current block had no test that could take it the other way.

## 3. My own fix, the same shape again

The fix replaced a block-keyed list with a 32-entry ring keyed on ticks, walked under a bounded work
budget of 32 orders — and spent that budget newest-first.

Which starves the oldest. The eviction had not been fixed; it had been moved out of the ring and
into the gas budget. Confirmed by raising the budget to 512, watching the test pass, and putting it
straight back.

Oldest-first is the principled order, and the argument is one sentence: a maker filled twenty-nine
seconds ago is about to leave the window and has no further chances, while one filled a second ago
has the rest of it. Spend the last chance on whoever is running out of them.

Writing that detector took three tries, and the failures were the useful part. The first version
**passed** — because the crowd never filled. One swap settles at most 24 orders, and the test tried
to queue 36. A detector that passes for the wrong reason is worse than no detector, and the only
thing that catches it is an assertion about the *setup* rather than the outcome.

## The pattern

Coverage measures which lines your tests reached. It says nothing about the lines they *could not*
reach, because a branch no test can enter never appears as a miss — it appears as though it isn't
there.

So the useful question is not "what is untested?" It is:

**What can my harness not say?**

Both criticals above lived in a case the harness had no vocabulary for. A sign that was never
positive. A clock that never moved. Neither is exotic. Both were one line of setup away from being
reachable, and that one line was missing everywhere at once — which is exactly why no individual
test looked suspicious.

## What to check in your own suite

Four questions, in rough order of how often they pay:

**Which primitives does the suite never use?** Grep for the ones that move the environment:
`vm.roll`, `vm.warp`, `vm.prank` on an unexpected caller, a re-entrant call, a second pool. A count
of zero across the whole repository is the signal. Not a low count — zero.

**Which parameters are hard-coded in your fuzz handlers?** Any constant in a handler is a case the
fuzzer cannot produce, however many runs you give it. Signs and directions are the expensive ones,
because they usually select between two code paths rather than two values.

**Does your invariant fail on the broken version?** An invariant that has never been shown to fail
is an assertion about your confidence, not about the code. Write the detector first; run it against
the old build; only then fix anything.

**Does your test assert on its own setup?** The most dangerous test is the one that passes because
it never built the state it claims to test. If the scenario needs 36 orders queued, assert that 36
are queued before asserting anything about the outcome.

## Source

Every case above is in
[github.com/impetus82/airbag-hook](https://github.com/impetus82/airbag-hook) — the code, the tests
that now reach these branches, and a build log recording each one as it was found rather than
reconstructed afterwards. `docs/BUILD-LOG.md` has the long version;
`docs/KNOWN-LIMITS.md` has what is still deliberately open, and why.
