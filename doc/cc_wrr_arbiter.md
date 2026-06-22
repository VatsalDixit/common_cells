# Weighted Round-Robin Arbiter (`cc_wrr_arbiter`)

**SoC-DAML — Extending FlooNoC with Weighted Round-Robin Arbitration**
Student: Vatsal Dixit

---

## 1. Motivation: topological unfairness in a NoC

A plain round-robin (RR) arbiter is *locally* fair: when `n` inputs contend, each
receives `1/n` of the output bandwidth. In a NoC, however, traffic towards a common
destination is merged by a **chain/tree of arbiters**, and local fairness at each hop
does **not** give global fairness. Working back from the 1.0 bottleneck link of a
linear chain of fair 2-input arbiters (Dally & Towles, *Principles and Practices of
Interconnection Networks*):

| Arbiter | splits | local source | through (upstream) |
| ------- | ------ | ------------ | ------------------ |
| A2      | 1.0    | r3 = 0.50    | 0.50               |
| A1      | 0.50   | r2 = 0.25    | 0.25               |
| A0      | 0.25   | r1 = 0.125   | r0 = 0.125         |

The source farthest from the destination (`r0`) is starved at `1/8` while the nearest
(`r3`) takes `1/2`. This is **topological unfairness**: it is a property of *where* a
requester sits, not of the arbiter being unfair.

**Fix.** Replace each RR arbiter with a *weighted* RR arbiter and weight every input by
the number of original requesters whose traffic it aggregates. Because each "through"
input is the funnel for all upstream sources, its weight must reflect that. Weights are
**additive up the tree** (an arbiter input's weight = sum of the leaf weights it carries),
so every leaf source ends up with an equal — or, more generally, an `ωᵢ`-proportional —
share at the bottleneck, regardless of hop depth or router radix.

---

## 2. The cell

`cc_wrr_arbiter` is a generic, `NumIn`-input, valid/ready arbiter that merges its inputs
onto one output while distributing bandwidth proportionally to a per-input weight:

```
bandwidth_i = w_i / Σ_j w_j      (j over the currently-contending inputs)
```

### Interface (summary)

| Port        | Dir | Description                                            |
| ----------- | --- | ----------------------------------------------------- |
| `req_i`     | in  | per-input valid                                       |
| `gnt_o`     | out | per-input ready (one-hot)                             |
| `data_i`    | in  | per-input payload (`data_t`, generic)                 |
| `weights_i` | in  | per-input weight (`WtWidth` bits each)                |
| `req_o`     | out | output valid                                          |
| `gnt_i`     | in  | output ready                                          |
| `data_o`    | out | winning input's payload                               |
| `idx_o`     | out | winning input index                                   |
| `flush_i`   | in  | synchronous clear of arbiter state                    |

### Mechanism: deficit / burst weighted round robin

The weight is realised as a **burst**. When an input wins, it is granted up to `wᵢ`
consecutive flits (one flit = one accepted valid/ready transfer) before the round-robin
pointer advances to the next contender. Over one full rotation that visits every contender
once, input `i` emits `wᵢ` of `Σⱼ wⱼ` flits — giving the bandwidth split above.

(Note: a *burst* here is a bandwidth allowance — `wᵢ` consecutive flits from one input — and
is deliberately **not** a NoC *packet*. The flits in a burst are independent and may span
several logical packets; "packet" is reserved for the atomic wormhole-routed unit.)

The cell is a thin wrapper around the existing `cc_rr_arb_tree`:

* The inner `cc_rr_arb_tree` (with `FairArb` + `LockIn`) is used **only as a winner
  picker** — it produces the winning index and holds it stable. Its `gnt_i` is pulsed
  exactly **once per burst** (on the last accepted flit), so its round-robin pointer
  advances once per burst rather than once per flit.
* The data path and the per-input ready are muxed externally from the winning index.
* A burst counter (`cnt`) tracks the flits remaining in the current burst.

---

## 3. Design decisions and trade-offs

These are also documented inline in `src/cc_wrr_arbiter.sv`.

1. **Burst weighting (deficit RR), not interleaving.** A burst arbiter is small and
   simple. The cost is *burstiness*: a low-weight input waits through a full high-weight
   burst, so its latency/jitter is worse than a WFQ-style interleaved scheme would give.
   The steady-state **bandwidth** ratio is identical either way, so for bandwidth shaping
   under contention the burst scheme is the right trade.

2. **Reuse `cc_rr_arb_tree` for selection.** Rather than re-implement fair rotation, the
   cell layers the burst counter on the proven tree. This keeps the new logic minimal
   and inherits the tree's fairness and timing properties.

3. **Contender snapshot (`req_lock_q`).** The inner arbiter's `LockIn` carries a formal
   assumption that *unserved requests are not deasserted while it is locked*. The wrapper
   therefore feeds the inner arbiter a **frozen snapshot** of the contender set, captured
   at the start of each burst and held until the burst completes. This keeps the inner
   arbiter within its usage contract even if a non-winning input bubbles mid-burst (which
   is harmless to the served traffic, but would otherwise trip the inner assertion). The
   snapshot is only refreshed on burst-boundary cycles, where the inner lock is
   disengaged and refreshing is legal.

4. **`cnt_eff` makes the weight live on the first flit.** A plain counter register lags by
   one cycle, so on the first flit of a burst it would still hold the previous value. The
   cell uses `cnt_eff = load_round ? sel_weight : cnt_q`, which presents the freshly
   selected weight on the very first flit. Without this, the first winner after every idle
   period would be truncated to a single grant (this was a bug in the original
   `floo_wrr_arbiter` prototype this cell is derived from).

5. **Non-work-conserving within a burst (intentional).** A burst only advances on accepted
   flits. If the locked winner bubbles, the output waits for it rather than serving another
   ready input. This keeps the bandwidth ratio exact in the **saturated** regime the WRRA
   targets (the regime in which the topological-unfairness analysis is defined). Under
   non-saturation the ratio degrades gracefully towards the offered load.

6. **Weight `0` means "no service".** A weight-0 input is excluded from arbitration entirely —
   skipped and never granted, even while requesting (it gets zero bandwidth, as the weight says).
   This is implemented by masking it out of the contention set (`eff_req = req_i & (weight != 0)`),
   which also keeps the burst counter from ever loading `0`. If *every* requester has weight 0 the
   output simply stays idle.

---

## 4. Evaluation

Two testbenches verify the cell; both pass with `Errors: 0` in QuestaSim. Run via:

```
make vsim-elab
cd build/vsim
bash ../../test/simulate-wrra.sh
```

### 4.1 Unit check — `cc_wrr_arbiter_tb`

A single flat 4-input arbiter, all inputs saturated, weights `wᵢ = i+1` (sum 10). The
measured bandwidth share matches the `wᵢ/Σwⱼ` ideal exactly:

| Input | Weight | Measured | Ideal |
| ----- | ------ | -------- | ----- |
| 0     | 1      | 0.100    | 0.100 |
| 1     | 2      | 0.200    | 0.200 |
| 2     | 3      | 0.300    | 0.300 |
| 3     | 4      | 0.400    | 0.400 |

This confirms that **a higher weight `ωᵢ` directly buys proportionally more bandwidth** —
the property the assignment asks to demonstrate. A data-integrity check (`data_o ===
data_i[idx_o]`) also passes, confirming the output always carries the winning input's data.

### 4.2 Topological-unfairness cascade — `cc_wrr_arbiter_cascade_tb`

Five saturated sources `r0..r4` are merged towards one destination through a
**mixed-radix** cascade — a 3-input first hop plus two 2-input hops — to show the cell
works at arbitrary radix:

```
 r0 r1 r2 ─►[A0 (3-in)]─┐
                        ├─►[A1 (2-in)]─┐
                   r3 ──┘              ├─►[A2 (2-in)]─► Dest
                                  r4 ──┘
```

Each flit carries its source id as payload, so counting payloads at the destination gives
each source's end-to-end share. Two configurations are run:

**`Weighted = 0` (unit weights → plain RR at each hop): topological unfairness reproduced**

| Source | Measured | Ideal (1/12, 1/4, 1/2) |
| ------ | -------- | ---------------------- |
| r0     | 0.0833   | 0.0833                 |
| r1     | 0.0833   | 0.0833                 |
| r2     | 0.0833   | 0.0833                 |
| r3     | 0.2500   | 0.2500                 |
| r4     | 0.5000   | 0.5000                 |

**`Weighted = 1` (through-weights = aggregated source count, A1=3, A2=4): fairness restored**

| Source | Measured | Ideal (1/5) |
| ------ | -------- | ----------- |
| r0     | 0.2000   | 0.2000      |
| r1     | 0.2000   | 0.2000      |
| r2     | 0.2000   | 0.2000      |
| r3     | 0.2000   | 0.2000      |
| r4     | 0.2000   | 0.2000      |

The before/after pair demonstrates the full result: the WRRA, with weights assigned by the
additive-up-the-tree rule, **cancels the topological bias and equalises end-to-end
bandwidth** across sources at any radius and any router radix. The same weights can instead
be set unequal to *deliberately* favour selected requesters in proportion to their `ωᵢ`.

---

## 5. Files

| File                                       | Purpose                                        |
| ------------------------------------------ | ---------------------------------------------- |
| `src/cc_wrr_arbiter.sv`                    | the weighted round-robin arbiter               |
| `test/cc_wrr_arbiter_tb.sv`                | flat `wᵢ/Σwⱼ` throughput unit test             |
| `test/cc_wrr_arbiter_cascade_tb.sv`        | mixed-radix topological-unfairness cascade     |
| `test/simulate-wrra.sh`                    | runs all three simulations                     |
| `test/waves/cc_wrr_arbiter_tb.wave.do`     | GUI waveform setup (flat TB)                   |
| `test/waves/cc_wrr_arbiter_cascade_tb.wave.do` | GUI waveform setup (cascade TB)            |
