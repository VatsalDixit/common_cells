#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Author: Vatsal Dixit
"""
Animated companion to Figure 1 (cc_arbiter_compare_tb).

Shows the *requestors* of the comparison testbench in motion: N-1 saturated "bulk"
flows plus one intermittent, high-priority "urgent" flow, arbitrated three ways at
once -- plain round-robin (cc_rr_arb_tree), weighted RR (cc_wrr_arbiter), and
QoS+weighted RR (cc_qos_wrr_arbiter). It is a faithful *behavioural model* of the
three arbiters (we have no cycle-accurate VCD here, only the swept results.csv), and
it reproduces the exact mechanism behind fig1:

  * RRA  : urgent waits ~one full rotation (served once per pass).
  * WRRA : urgent waits even longer -- each bulk flow holds the link for `BulkWeight`
           consecutive beats (a burst) before the pointer moves on.
  * QoS  : urgent's high QoS preempts the in-flight bulk burst -> served almost at once.

Output: fig1_requestor_animation.gif (Pillow writer, no ffmpeg needed).
Run:    python animate_fig1.py
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation, PillowWriter
from matplotlib.patches import Patch
import numpy as np

rng = np.random.default_rng(7)   # seeded -> reproducible GIF; jitter matches GapJitter=1

# ---- parameters (mirror cc_arbiter_compare_tb) --------------------------------------
N        = 5        # 1 urgent (row 0) + 4 saturated bulk flows (rows 1..4) = cascade source count
BULK_W   = 4        # BulkWeight: each bulk flow gets 4 consecutive beats under WRRA
URG_W    = 1        # urgent weight (1 beat) -- it wins on QoS, not on weight
URG_GAP  = 14       # mean think-time between urgent requests (UrgentGap)
T        = 150      # cycles to simulate
WIN      = 46       # visible scrolling window (cycles)
URG      = 0        # urgent is row 0 (drawn on top)

# colours
C_BG     = (1.00, 1.00, 1.00)   # not requesting (urgent idle)
C_BULKRQ = (0.86, 0.89, 0.94)   # bulk requesting, waiting
C_URGRQ  = (1.00, 0.85, 0.55)   # urgent requesting, waiting  (amber)
C_BULKGR = (0.20, 0.45, 0.80)   # bulk granted                (blue)
C_URGGR  = (0.85, 0.12, 0.12)   # urgent granted              (red)


def simulate(scheme):
    """Return (rgb[N,T,3], events) for one arbiter. events: list of (assert_t, grant_t)."""
    rgb = np.ones((N, T, 3))
    grant = [None] * T
    events = []

    ptr = 1                       # round-robin pointer (start past the urgent row)
    burst_owner, burst_left = None, 0
    urg_req = True                # urgent starts by requesting at t=0
    urg_assert_t = 0
    urg_idle_until = -1

    for t in range(T):
        # who is requesting this cycle
        req = [True] * N          # bulk flows saturated
        req[URG] = urg_req

        # ---- pick a grant according to the scheme -------------------------------
        g = None
        if scheme == "rra":
            for k in range(N):
                idx = (ptr + k) % N
                if req[idx]:
                    g = idx
                    break
            if g is not None:
                ptr = (g + 1) % N

        elif scheme == "wrra":
            if burst_owner is not None and burst_left > 0 and req[burst_owner]:
                g = burst_owner                      # continue the current burst
            else:
                for k in range(N):                   # start a new burst
                    idx = (ptr + k) % N
                    if req[idx]:
                        g = idx
                        burst_owner = idx
                        burst_left = URG_W if idx == URG else BULK_W
                        break
            if g is not None:
                burst_left -= 1
                if burst_left == 0:
                    ptr = (g + 1) % N
                    burst_owner = None

        else:  # "qos": urgent preempts; otherwise weighted-RR among the bulk flows
            if req[URG]:
                g = URG                              # high QoS abandons the bulk burst
                burst_owner, burst_left = None, 0
            else:
                if burst_owner is not None and burst_left > 0 and req[burst_owner]:
                    g = burst_owner
                else:
                    for k in range(N):
                        idx = (ptr + k) % N
                        if req[idx]:
                            g = idx
                            burst_owner = idx
                            burst_left = BULK_W
                            break
                if g is not None:
                    burst_left -= 1
                    if burst_left == 0:
                        ptr = (g + 1) % N
                        burst_owner = None

        grant[t] = g

        # ---- paint this column --------------------------------------------------
        for i in range(N):
            if req[i]:
                rgb[i, t] = C_URGRQ if i == URG else C_BULKRQ
            else:
                rgb[i, t] = C_BG
        if g is not None:
            rgb[g, t] = C_URGGR if g == URG else C_BULKGR

        # ---- urgent closed-loop (assert -> wait -> grant -> think) --------------
        if g == URG:
            events.append((urg_assert_t, t))
            urg_req = False
            # jittered think-time in [GAP/2, 3*GAP/2] (matches the TB's GapJitter=1)
            urg_idle_until = t + int(rng.integers(URG_GAP // 2, (3 * URG_GAP) // 2 + 1))
        if (not urg_req) and t >= urg_idle_until:
            urg_req = True
            urg_assert_t = t + 1

    return rgb, events


SCHEMES = [
    ("rra",  "RRA  (cc_rr_arb_tree)        round-robin: 1 grant per pass"),
    ("wrra", "WRRA (cc_wrr_arbiter)        bulk holds the link for BulkWeight beats"),
    ("qos",  "QoS+WRRA (cc_qos_wrr_arbiter) urgent QoS preempts the burst"),
]
sims = {s: simulate(s) for s, _ in SCHEMES}

# running urgent latency (cycles to grant = grant_t - assert_t + 1) up to time t
def lat_upto(events, t):
    done = [(gt - at + 1) for (at, gt) in events if gt <= t]
    cur = None
    for (at, gt) in events:          # an in-flight request waiting right now
        if at <= t < gt:
            cur = t - at + 1
    mean = sum(done) / len(done) if done else 0.0
    return cur, mean, len(done)

# ---- figure ------------------------------------------------------------------------
fig, axes = plt.subplots(3, 1, figsize=(9.0, 6.6))
fig.subplots_adjust(left=0.13, right=0.98, top=0.90, bottom=0.10, hspace=0.55)
ims, titles = [], []
ylabels = ["URG"] + [f"b{i}" for i in range(1, N)]

for ax, (s, desc) in zip(axes, SCHEMES):
    rgb, _ = sims[s]
    im = ax.imshow(rgb[:, :WIN], aspect="auto", interpolation="nearest",
                   extent=(0, WIN, N - 0.5, -0.5))
    ims.append(im)
    ax.set_yticks(range(N))
    ax.set_yticklabels(ylabels, fontsize=7)
    ax.set_xticks([])
    t = ax.set_title(desc, fontsize=9, loc="left")
    titles.append(t)
    ax.axhline(0.5, color="0.4", lw=0.8)          # separate urgent row from bulk
axes[-1].set_xlabel("time  (clock cycles)  ->", fontsize=9)

fig.suptitle(f"Figure 1, animated: one urgent flow vs. {N - 1} saturated bulk flows "
             f"(N={N}, BulkWeight={BULK_W})", fontsize=11)
legend = [Patch(facecolor=C_URGGR, label="urgent granted"),
          Patch(facecolor=C_URGRQ, label="urgent waiting"),
          Patch(facecolor=C_BULKGR, label="bulk granted"),
          Patch(facecolor=C_BULKRQ, label="bulk waiting")]
fig.legend(handles=legend, loc="upper right", ncol=4, fontsize=7,
           frameon=False, bbox_to_anchor=(0.99, 0.965))


def update(f):
    lo = max(0, f - WIN + 1)
    hi = lo + WIN
    arts = []
    for ax, im, (s, desc), t in zip(axes, ims, SCHEMES, titles):
        rgb, events = sims[s]
        im.set_data(rgb[:, lo:hi])
        im.set_extent((lo, hi, N - 0.5, -0.5))
        ax.set_xlim(lo, hi)
        cur, mean, n = lat_upto(events, f)
        cur_s = f"{cur:2d}" if cur is not None else " -"
        t.set_text(f"{desc}      urgent wait now: {cur_s} cyc   |   mean so far: {mean:4.1f} cyc")
        arts.append(im)
    return arts


anim = FuncAnimation(fig, update, frames=T, interval=120, blit=False)
out = "fig1_requestor_animation.gif"
anim.save(out, writer=PillowWriter(fps=9))
print("wrote", out)

# also report the converged means (sanity check vs fig1 ordering)
for s, _ in SCHEMES:
    _, ev = sims[s]
    lats = [gt - at + 1 for (at, gt) in ev]
    print(f"  {s:5s}: {len(lats)} urgent grants, mean wait = "
          f"{sum(lats)/len(lats):.1f} cyc, max = {max(lats)} cyc")
